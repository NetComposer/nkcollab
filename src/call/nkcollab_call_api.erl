%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Call Plugin API
-module(nkcollab_call_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/3]).
-export([expand/3, invite/6]).
-export([api_call_hangup /4, api_call_down/3]).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


%% ===================================================================
%% Commands
%% ===================================================================


%% @doc An call start has been received
%% We create the call linked with the API server process
%% - we capture the destroy event %%
%%   (nkcollab_call_reg_event() -> call_hangup () here)
%% - if the session is killed, it is detected
%%   (api_server_reg_down() -> api_call_down() here)
%% It also subscribes the API session to events
cmd(<<"create">>, Req, State) ->
    #api_req{srv_id=SrvId, data=Data, user=User, session=UserSession} = Req,
    #{dest:=Dest} = Data,
    Config = Data#{
        caller_link => {nkcollab_api, self()},
        user_id => User,
        user_session => UserSession
    },
    Type = maps:get(type, Data, nkcollab_any),
    {ok, CallId, Pid} = nkcollab_call:start_type(SrvId, Type, Dest, Config),
    nkservice_api_server:register(self(), {nkcollab_call, CallId, Pid}), 
    case maps:get(subscribe, Data, true) of
        true ->
            % In case of no_destination, the call will wait 100msecs before stop
            Body = maps:get(events_body, Data, #{}),
            Event = get_call_event(SrvId, CallId, Body),
            nkservice_api_server:register_event(self(), Event);
        false ->
            ok
    end,
    {ok, #{call_id=>CallId}, State};

cmd(<<"ringing">>, #api_req{data=Data}, State) ->
    #{call_id:=CallId} = Data,
    Callee = maps:get(callee, Data, #{}),
    case nkcollab_call:ringing(CallId, {nkcollab_api, self()}, Callee) of
        ok ->
            {ok, #{}, State};
        {error, invite_not_found} ->
            {error, already_answered, State};
        {error, call_not_found} ->
            {error, call_not_found, State};
        {error, Error} ->
            lager:warning("Error in call ringing: ~p", [Error]),
            {error, call_error, State}
    end;

cmd(<<"accepted">>, #api_req{srv_id=_SrvId, data=Data}, State) ->
    #{call_id:=CallId} = Data,
    Answer = maps:get(answer, Data, #{}),
    Callee = maps:get(callee, Data, #{}),
    case nkcollab_call:accepted(CallId, {nkcollab_api, self()}, Answer, Callee) of
        {ok, _Pid} ->
            {ok, #{}, State};
        {error, invite_not_found} ->
            {error, already_answered, State};
        {error, call_not_found} ->
            {error, call_not_found, State};
        {error, Error} ->
            lager:warning("Error in call accepted: ~p", [Error]),
            {error, call_error, State}
    end;

cmd(<<"rejected">>, #api_req{data=Data}, State) ->
    #{call_id:=CallId} = Data,
    case nkcollab_call:rejected(CallId, {nkcollab_api, self()}) of
        ok ->
            {ok, #{}, State};
        {error, call_not_found} ->
            {error, call_not_found, State};
        {error, Error} ->
            lager:warning("Error in call rejected: ~p", [Error]),
            {error, call_error, State}
    end;

cmd(<<"set_candidate">>, #api_req{data=Data}, State) ->
    #{
        call_id := CallId, 
        sdpMid := Id, 
        sdpMLineIndex := Index, 
        candidate := ALine
    } = Data,
    Candidate = #candidate{m_id=Id, m_index=Index, a_line=ALine},
    case nkcollab_call:candidate(CallId, {nkcollab_api, self()}, Candidate) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"set_candidate_end">>, #api_req{data=Data}, State) ->
    #{call_id := CallId} = Data,
    Candidate = #candidate{last=true},
    case nkcollab_call:candidate(CallId, {nkcollab_api, self()}, Candidate) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"hangup">>, #api_req{data=Data}, State) ->
    #{call_id:=CallId} = Data,
    Reason = case maps:find(reason, Data) of
        {ok, UserReason} -> {api_hangup, UserReason};
        error -> api_hangup
    end,
    case nkcollab_call:hangup(CallId, Reason) of
        ok ->
            {ok, #{}, State};
        {error, call_not_found} ->
            {error, call_not_found, State};
        {error, Error} ->
            lager:warning("Error in call answered: ~p", [Error]),
            {error, call_error, State}
    end;

cmd(<<"get_info">>, #api_req{data=Data}, State) ->
    #{call_id:=CallId} = Data,
    case nkcollab_call:get_call(CallId) of
        {ok, Call} ->
            Info = nkcollab_call_api_syntax:get_call_info(Call),
            {ok, Info, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"get_list">>, _Req, State) ->
    Res = [#{call_id=>Id} || {Id, _Pid} <- nkcollab_call:get_all()],
    {ok, Res, State};


cmd(Cmd, _Req, State) ->
    {error, {unknown_command, Cmd}, State}.


%% ===================================================================
%% API server callbacks
%% ===================================================================


%% @private Sent by the call when it is stopping
%% We sent a message to the API session to remove the call before 
%% it receives the DOWN.
api_call_hangup(CallId, ApiPid, _Reason, Call) ->
    #{srv_id:=SrvId} = Call,
    Event = get_call_event(SrvId, CallId, undefined),
    nkservice_api_server:unregister_event(ApiPid, Event),
    nkservice_api_server:unregister(ApiPid, {nkcollab_call, CallId, self()}),
    {ok, Call}.


%% @private Called when API server detects a registered call is down
%% Normally it should have been unregistered first
%% (detected above and sent in the cast after)
api_call_down(CallId, Reason, State) ->
    #{srv_id:=SrvId} = State,
    lager:warning("API Server: Call ~s is down: ~p", [CallId, Reason]),
    Event = get_call_event(SrvId, CallId, undefined),
    nkservice_api_server:unregister_event(self(), Event),
    nkcollab_call_api_events:call_down(SrvId, CallId).


%% ===================================================================
%% Internal
%% ===================================================================


%% @private Called from nkcollab_call_callbacks
expand({nkcollab_user, User}, Acc, Call) ->
    Dests = [
        #{dest=>{nkcollab_api_user, Pid}} 
        || {_SessId, Pid} <- nkservice_api_server:find_user(User)
    ],
    {ok, Acc++Dests, Call};

expand({nkcollab_session, Session}, Acc, Call) ->
    Session2 = nklib_util:to_binary(Session),
    Dests = case nkservice_api_server:find_session(Session2) of
        {ok, _User, Pid} ->
            [#{dest=>{nkcollab_api_session, Session2, Pid}}];
        not_found ->
            []
    end,
    {ok, Acc++Dests, Call};

expand({nkcollab_any, Dest}, Acc, Call) ->
    {ok, Acc2, Call2} = expand({nkcollab_user, Dest}, Acc, Call),
    expand({nkcollab_session, Dest}, Acc2, Call2);

expand(_Dest, Acc, Call) ->
    {ok, Acc, Call}.


%% @private Sends a call INVITE over the API (for user or session types)
%% Called from nkcollab_call_callbacks
%% - If the user accepts the call, the user session will be registered as callee
%% - The user must call accepted or rejected
invite(CallId, {Type, Pid}, SessId, Offer, Caller, #{srv_id:=SrvId}=Call) ->
    Data = #{
        call_id => CallId, 
        type => Type, 
        session_id => SessId, 
        offer => Offer,
        caller => Caller
    },
    case nkservice_api_server:cmd(Pid, media, call, invite, Data) of
        {ok, <<"ok">>, Res} ->
            nkservice_api_server:register(Pid, {nkcollab_call, CallId, self()}), 
            case maps:get(subscribe, Res, true) of
                true ->
                    Body = maps:get(events_body, Res, #{}),
                    Event = get_call_event(SrvId, CallId, Body),
                    nkservice_api_server:register_event(Pid, Event);
                false -> 
                    ok
            end,
            {ok, {nkcollab_api, Pid}, Call};
        {ok, <<"error">>, _} ->
            {remove, Call};
        {error, _Error} ->
            {remove, Call}
    end.


% %% @private
% cancel(CallId, Pid, Call) ->
%     nkcollab_call_api_events:event(CallId, cancelled, Call, Pid).


% %% @private 
% answer(CallId, Pid, SessId, Answer, Callee, Call) ->
%     nkcollab_call_api_events:event(CallId, {answer, SessId, Answer, Callee}, Call, Pid).


% %% @private 
% candidate(CallId, Pid, Candidate, Call) ->
%     nkcollab_call_api_events:event(CallId, {candidate, Candidate}, Call, Pid).


%% ===================================================================
%% Private
%% ===================================================================


%% @private
get_call_event(SrvId, CallId, Body) ->
    #event{
        srv_id = SrvId,     
        class = <<"collab">>, 
        subclass = <<"call">>,
        type = <<"*">>,
        obj_id = CallId,
        body = Body
    }.


