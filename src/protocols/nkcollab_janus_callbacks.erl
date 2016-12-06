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

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2]).
-export([nkcollab_janus_init/2, nkcollab_janus_registered/2,
         nkcollab_janus_invite/4, nkcollab_janus_answer/4, nkcollab_janus_bye/3,
         nkcollab_janus_candidate/4,
         nkcollab_janus_start/3, nkcollab_janus_terminate/2,
         nkcollab_janus_handle_call/3, nkcollab_janus_handle_cast/2,
         nkcollab_janus_handle_info/2]).
-export([error_code/1]).
-export([nkcollab_call_expand/3, nkcollab_call_invite/4, 
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



%% ===================================================================
%% Offering Callbacks
%% ===================================================================

-type janus() :: nkcollab_janus:janus().
-type call_id() :: nkcollab_janus:call_id().
-type continue() :: continue | {continue, list()}.


%% @doc Called when a new janus connection arrives
-spec nkcollab_janus_init(nkpacket:nkport(), janus()) ->
    {ok, janus()}.

nkcollab_janus_init(_NkPort, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an INVITE
-spec nkcollab_janus_registered(binary(), janus()) ->
    {ok, janus()}.

nkcollab_janus_registered(_User, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an INVITE
%% See nkcollab_verto_invite for explanation
-spec nkcollab_janus_invite(nkservice:id(), call_id(), nkmedia:offer(), janus()) ->
    {ok, nklib:link(), janus()} | 
    {answer, nkcollab_janus:answer(), nklib:link(), janus()} | 
    {rejected, nkservice:error(), janus()} | continue().

nkcollab_janus_invite(SrvId, CallId, #{dest:=Dest}=Offer, Janus) ->
    Config = #{
        call_id => CallId,
        offer => Offer, 
        caller_link => {nkcollab_janus, CallId, self()},
        caller => #{info=>janus_native},
        no_answer_trickle_ice => true
    },
    case nkcollab_call:start_type(SrvId, nkcollab_any, Dest, Config) of
        {ok, CallId, CallPid} ->
            {ok, {nkcollab_call, CallId, CallPid}, Janus};
        {error, Error} ->
            lager:warning("NkCOLLAB Janus session error: ~p", [Error]),
            {rejected, Error, Janus}
    end.


%% @doc Called when the client sends an ANSWER
-spec nkcollab_janus_answer(call_id(), nklib:link(), nkmedia:answer(), janus()) ->
    {ok, janus()} |{hangup, nkservice:error(), janus()} | continue().

% If the registered process happens to be {nkmedia_session, ...} and we have
% an answer for an invite we received, we set the answer in the session
% (we are ignoring the possible proxy answer in the reponse)
nkcollab_janus_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, Janus) ->
    case nkmedia_session:set_answer(SessId, Answer) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            {hangup, Error, Janus}
    end;

% If the registered process happens to be {nkcollab_call, ...} and we have
% an answer for an invite we received, we set the answer in the call
nkcollab_janus_answer(_CallId, {nkcollab_call, CallId, _Pid}, Answer, Janus) ->
    Id = {nkcollab_janus, CallId, self()},
    Callee = #{module=>nkcollab_janus},
    case nkcollab_call:accepted(CallId, Id, {answer, Answer}, Callee) of
        {ok, _} ->
            {ok, Janus};
        {error, Error} ->
            {hangup, Error, Janus}
    end;

nkcollab_janus_answer(_CallId, _Link, _Answer, Janus) ->
    {ok, Janus}.


%% @doc Sends when the client sends a BYE
-spec nkcollab_janus_bye(call_id(), nklib:link(), janus()) ->
    {ok, janus()} | continue().

% We recognize some special Links
nkcollab_janus_bye(_CallId, {nkmedia_session, SessId, _Pid}, Janus) ->
    nkmedia_session:stop(SessId, janus_bye),
    {ok, Janus};

nkcollab_janus_bye(_CallId, {nkcollab_call, CallId, _Pid}, Janus) ->
    nkcollab_call:hangup(CallId, janus_bye),
    {ok, Janus};

nkcollab_janus_bye(_CallId, _Link, Janus) ->
    {ok, Janus}.


%% @doc Called when the client sends an START for a PLAY
-spec nkcollab_janus_start(call_id(), nkmedia:offer(), janus()) ->
    ok | {hangup, nkservice:error(), janus()} | continue().

nkcollab_janus_start(SessId, Answer, Janus) ->
    case nkmedia_session:set_answer(SessId, Answer, #{}) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            lager:warning("Janus janus_start error: ~p", [Error]),
            {hangup, <<"MediaServer Error">>, Janus}
    end.


%% @doc Called when an SDP candidate is received
-spec nkcollab_janus_candidate(call_id(), nklib:link(), nkcollab:candidate(), janus()) ->
    {ok, janus()}.

nkcollab_janus_candidate(_CallId, {nkmedia_session, SessId, _Pid}, Candidate, Janus) ->
    ok = nkmedia_session:candidate(SessId, Candidate),
    {ok, Janus};

nkcollab_janus_candidate(_CallId, {nkcollab_call, CallId, _Pid}, Candidate, Janus) ->
    ok = nkcollab_call:candidate(CallId, {nkcollab_janus, CallId, self()}, Candidate),
    {ok, Janus};

nkcollab_janus_candidate(_CallId, _Link, _Candidate, Janus) ->
    lager:info("Janus Proto ignoring ICE Candidate (no session)"),
    {ok, Janus}.


%% @doc Called when the connection is stopped
-spec nkcollab_janus_terminate(Reason::term(), janus()) ->
    {ok, janus()}.

nkcollab_janus_terminate(_Reason, Janus) ->
    {ok, Janus}.


%% @doc 
-spec nkcollab_janus_handle_call(Msg::term(), {pid(), term()}, janus()) ->
    {ok, janus()} | continue().

nkcollab_janus_handle_call(Msg, _From, Janus) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% @doc 
-spec nkcollab_janus_handle_cast(Msg::term(), janus()) ->
    {ok, janus()}.

nkcollab_janus_handle_cast(Msg, Janus) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% @doc 
-spec nkcollab_janus_handle_info(Msg::term(), janus()) ->
    {ok, Janus::map()}.

nkcollab_janus_handle_info(Msg, Janus) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================


%% @private See nkservice_callabcks
error_code(_)               -> continue.


%% @private
%% Convenient functions in case we are registered with the session as
%% {nkcollab_janus, CallId, Pid}
nkmedia_session_reg_event(_SessId, {nkcollab_janus, CallId, Pid}, Event, Session) ->
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
        {stopped, Reason} ->
            lager:info("Janus Proto stopping after session stop: ~p", [Reason]),
            nkcollab_janus:hangup(Pid, CallId, Reason);
        _ ->
            ok
    end,
    continue;

nkmedia_session_reg_event(_CallId, _Link, _Event, _Call) ->
    continue.




%% @private
%% If call has type 'nkcollab_janus' we will capture it
nkcollab_call_expand({nkcollab_janus, Id}=Dest, Acc, Call) ->
    {continue, [Dest, Acc++expand(Id), Call]};
        
nkcollab_call_expand({nkcollab_any, Id}=Dest, Acc, Call) ->
    {continue, [Dest, Acc++expand(Id), Call]};

nkcollab_call_expand(_Dest, _Acc, _Call) ->
    continue.


%% @private
%% When a call is sento to {nkcollab_janus, pid()}
%% See nkcollab_call_invite in nkcollab_verto_callbacks for explanation


%% We register with janus as {nkcollab_janus_call, CallId, PId},
%% and with the call as {nkcollab_janus, Pid}
nkcollab_call_invite(CallId, {nkcollab_janus, Pid}, #{offer:=Offer}, Call) ->
    CallLink = {nkcollab_call, CallId, self()},
    {ok, JanusLink} = nkcollab_janus:invite(Pid, CallId, Offer, CallLink),
    {ok, JanusLink, Call};

nkcollab_call_invite(_CallId, _Dest, _Data, _Call) ->
    continue.


%% @private
nkcollab_call_reg_event(CallId, {nkcollab_janus, CallId, Pid}=Link, Event, _Call) ->
    case Event of
        {session_answer, _SessId, Answer, Link} ->
            case nkcollab_janus:answer(Pid, CallId, Answer) of
                ok ->
                    ok;
                {error, Error} ->
                    lager:error("Error setting Janus answer: ~p", [Error]),
                    nkcollab_call:hangup(CallId, verto_error)
            end;
        {session_cancelled, _SessId, Link} ->
            nkcollab_janus:hangup(Pid, CallId, originator_cancel);
        {session_status, _SessId, Status, Data, Link} ->
            lager:notice("Janus status: ~p ~p", [Status, Data]);
        {stopped, Reason} ->
            nkcollab_verto:hangup(Pid, CallId, Reason);
        _ ->
            % lager:notice("Verto unknown call event: ~p", [Event])
            ok
    end,
    continue;

nkcollab_call_reg_event(_CallId, _Link, _Event, _Call) ->
    % lager:error("CALL REG: ~p", [_Link]),
    continue.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
expand(Dest) ->
    [
        #{dest=>{nkcollab_janus, Pid}, session_config=>#{no_offer_trickle_ice=>true}}
        || Pid <- nkcollab_janus:find_user(Dest)
    ].


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(janus_listen, Url, _Ctx) ->
    Opts = #{valid_schemes=>[janus], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.


