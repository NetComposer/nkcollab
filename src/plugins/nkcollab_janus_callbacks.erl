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

-module(nkcollab_janus_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_janus_init/2, nkmedia_janus_registered/2,
         nkmedia_janus_invite/4, nkmedia_janus_answer/4, nkmedia_janus_bye/3,
         nkmedia_janus_candidate/4,
         nkmedia_janus_start/3, nkmedia_janus_terminate/2,
         nkmedia_janus_handle_call/3, nkmedia_janus_handle_cast/2,
         nkmedia_janus_handle_info/2]).
-export([error_code/1]).
-export([nkcollab_call_resolve/4, nkcollab_call_invite/6, 
         nkcollab_call_answer/6, nkcollab_call_cancelled/3, 
         nkcollab_call_reg_event/4]).
-export([nkmedia_session_reg_event/4]).

-include_lib("nksip/include/nksip.hrl").

-define(JANUS_WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkcollab, nkcollab_call].


plugin_syntax() ->
    nkpacket:register_protocol(janus, nkcollab_janus),
    #{
        janus_listen => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % janus_listen will be already parsed
    Listen = maps:get(janus_listen, Config, []),
    Opts = #{
        class => {nkcollab_janus, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?JANUS_WS_TIMEOUT,
        ws_proto => <<"janus-protocol">>
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkCOLLAB JANUS Proto (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkCOLLAB JANUS Proto (~p) stopping", [Name]),
    {ok, Config}.




%% ===================================================================
%% Offering Callbacks
%% ===================================================================

-type janus() :: nkcollab_janus:janus().
-type call_id() :: nkcollab_janus:call_id().
-type continue() :: continue | {continue, list()}.


%% @doc Called when a new janus connection arrives
-spec nkmedia_janus_init(nkpacket:nkport(), janus()) ->
    {ok, janus()}.

nkmedia_janus_init(_NkPort, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an INVITE
-spec nkmedia_janus_registered(binary(), janus()) ->
    {ok, janus()}.

nkmedia_janus_registered(_User, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an INVITE
%% See nkcollab_verto_invite for explanation
-spec nkmedia_janus_invite(nkservice:id(), call_id(), nkmedia:offer(), janus()) ->
    {ok, nklib:link(), janus()} | 
    {answer, nkcollab_janus:answer(), nklib:link(), janus()} | 
    {rejected, nkservice:error(), janus()} | continue().

nkmedia_janus_invite(SrvId, CallId, #{dest:=Dest}=Offer, Janus) ->
    Config = #{
        call_id => CallId,
        offer => Offer, 
        caller_link => {nkmedia_janus, CallId, self()},
        caller => #{info=>janus_native},
        no_answer_trickle_ice => true
    },
    case nkcollab_call:start2(SrvId, Dest, Config) of
        {ok, CallId, CallPid} ->
            {ok, {nkcollab_call, CallId, CallPid}, Janus};
        {error, Error} ->
            lager:warning("NkCOLLAB Janus session error: ~p", [Error]),
            {rejected, Error, Janus}
    end.


%% @doc Called when the client sends an ANSWER
-spec nkmedia_janus_answer(call_id(), nklib:link(), nkmedia:answer(), janus()) ->
    {ok, janus()} |{hangup, nkservice:error(), janus()} | continue().

% If the registered process happens to be {nkmedia_session, ...} and we have
% an answer for an invite we received, we set the answer in the session
% (we are ignoring the possible proxy answer in the reponse)
nkmedia_janus_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, Janus) ->
    case nkmedia_session:set_answer(SessId, Answer) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            {hangup, Error, Janus}
    end;

% If the registered process happens to be {nkcollab_call, ...} and we have
% an answer for an invite we received, we set the answer in the call
nkmedia_janus_answer(_CallId, {nkcollab_call, CallId, _Pid}, Answer, Janus) ->
    Id = {nkmedia_janus, CallId, self()},
    case nkcollab_call:accepted(CallId, Id, Answer, #{module=>nkmedia_janus}) of
        {ok, _} ->
            {ok, Janus};
        {error, Error} ->
            {hangup, Error, Janus}
    end;

nkmedia_janus_answer(_CallId, _Link, _Answer, Janus) ->
    {ok, Janus}.


%% @doc Sends when the client sends a BYE
-spec nkmedia_janus_bye(call_id(), nklib:link(), janus()) ->
    {ok, janus()} | continue().

% We recognize some special Links
nkmedia_janus_bye(_CallId, {nkmedia_session, SessId, _Pid}, Janus) ->
    nkmedia_session:stop(SessId, janus_bye),
    {ok, Janus};

nkmedia_janus_bye(_CallId, {nkcollab_call, CallId, _Pid}, Janus) ->
    nkcollab_call:hangup(CallId, janus_bye),
    {ok, Janus};

nkmedia_janus_bye(_CallId, _Link, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an START for a PLAY
-spec nkmedia_janus_start(call_id(), nkmedia:offer(), janus()) ->
    ok | {hangup, nkservice:error(), janus()} | continue().

nkmedia_janus_start(SessId, Answer, Janus) ->
    case nkmedia_session:set_answer(SessId, Answer, #{}) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            lager:warning("Janus janus_start error: ~p", [Error]),
            {hangup, <<"MediaServer Error">>, Janus}
    end.


%% @doc Called when an SDP candidate is received
-spec nkmedia_janus_candidate(call_id(), nklib:link(), nkcollab:candidate(), janus()) ->
    {ok, janus()}.

nkmedia_janus_candidate(_CallId, {nkmedia_session, SessId, _Pid}, Candidate, Janus) ->
    ok = nkmedia_session:candidate(SessId, Candidate),
    {ok, Janus};

nkmedia_janus_candidate(_CallId, {nkcollab_call, CallId, _Pid}, Candidate, Janus) ->
    ok = nkcollab_call:candidate(CallId, {nkmedia_janus, CallId, self()}, Candidate),
    {ok, Janus};

nkmedia_janus_candidate(_CallId, _Link, _Candidate, Janus) ->
    lager:info("Janus Proto ignoring ICE Candidate (no session)"),
    {ok, Janus}.


%% @doc Called when the connection is stopped
-spec nkmedia_janus_terminate(Reason::term(), janus()) ->
    {ok, janus()}.

nkmedia_janus_terminate(_Reason, Janus) ->
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_call(Msg::term(), {pid(), term()}, janus()) ->
    {ok, janus()} | continue().

nkmedia_janus_handle_call(Msg, _From, Janus) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_cast(Msg::term(), janus()) ->
    {ok, janus()}.

nkmedia_janus_handle_cast(Msg, Janus) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_info(Msg::term(), janus()) ->
    {ok, Janus::map()}.

nkmedia_janus_handle_info(Msg, Janus) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================


%% @private See nkservice_callabcks
error_code(_)               -> continue.


%% @private
%% Convenient functions in case we are registered with the session as
%% {nkmedia_janus, CallId, Pid}
nkmedia_session_reg_event(_SessId, {nkmedia_janus, CallId, Pid}, Event, Session) ->
    case Event of
        {answer, Answer} ->
            case maps:get(backend_role, Session) of
                offeree ->                
                    % we may be blocked waiting for the same session creation
                    case nkcollab_janus:answer_async(Pid, CallId, Answer) of
                        ok ->
                            ok;
                        {error, Error} ->
                            lager:error("Error setting Janus answer: ~p", [Error])
                    end;
                offerer ->
                    % This is our own answer!
                    ok
            end;
        {stop, Reason} ->
            lager:info("Janus Proto stopping after session stop: ~p", [Reason]),
            nkcollab_janus:hangup(Pid, CallId, Reason);
        _ ->
            ok
    end,
    continue;

nkmedia_session_reg_event(_CallId, _Link, _Event, _Call) ->
    continue.




%% @private
%% If call has type 'nkmedia_janus' we will capture it
nkcollab_call_resolve(Callee, Type, Acc, Call) when Type==janus; Type==all ->
    Dest = [
        #{dest=>{nkmedia_janus, Pid}, session_config=>#{no_offer_trickle_ice=>true}}
        || Pid <- nkmedia_janus_proto:find_user(Callee)
    ],
    {continue, [Callee, Type, Acc++Dest, Call]};
        
nkcollab_call_resolve(_Callee, _Type, _Acc, _Call) ->
    continue.


%% @private
%% When a call is sento to {nkmedia_janus, pid()}
%% See nkcollab_call_invite in nkmedia_verto_callbacks for explanation


%% We register with janus as {nkmedia_janus_call, CallId, PId},
%% and with the call as {nkmedia_janus, Pid}
nkcollab_call_invite(CallId, {nkmedia_janus, Pid}, _SessId, Offer, _Caller, Call) ->
    CallLink = {nkcollab_call, CallId, self()},
    {ok, JanusLink} = nkmedia_janus_proto:invite(Pid, CallId, Offer, CallLink),
    {ok, JanusLink, Call};

nkcollab_call_invite(_CallId, _Dest, _SessId, _Offer, _Caller, _Call) ->
    continue.


%% @private
nkcollab_call_answer(CallId, {nkmedia_janus, CallId, Pid}, _SessId, Answer, 
                    _Callee, Call) ->
    case nkmedia_janus_proto:answer(Pid, CallId, Answer) of
        ok ->
            {ok, Call};
        {error, Error} ->
            lager:error("Error setting Verto answer: ~p", [Error]),
            {error, Error, Call}
    end;

nkcollab_call_answer(_CallId, _Link, _SessId, _Answer, _Callee, _Call) ->
    continue.


%% @private
nkcollab_call_cancelled(_CallId, {nkmedia_janus, CallId, Pid}, _Call) ->
    nkmedia_janus_proto:hangup(Pid, CallId, originator_cancel),
    continue;

nkcollab_call_cancelled(_CallId, _Link, _Call) ->
    continue.


%% @private
nkcollab_call_reg_event(CallId, {nkmedia_janus, CallId, Pid}, {hangup, Reason}, _Call) ->
    nkmedia_janus_proto:hangup(Pid, CallId, Reason),
    continue;

nkcollab_call_reg_event(_CallId, _Link, _Event, _Call) ->
    % lager:error("CALL REG: ~p", [_Link]),
    continue.



%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(janus_listen, Url, _Ctx) ->
    Opts = #{valid_schemes=>[janus], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.


