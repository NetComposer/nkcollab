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

%% @doc Plugin implementing a Verto server
-module(nkmedia_verto_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_verto_init/2, nkmedia_verto_login/3, 
         nkmedia_verto_invite/4, nkmedia_verto_bye/3,
         nkmedia_verto_answer/4, nkmedia_verto_rejected/3,
         nkmedia_verto_dtmf/4, nkmedia_verto_terminate/2,
         nkmedia_verto_handle_call/3, nkmedia_verto_handle_cast/2,
         nkmedia_verto_handle_info/2]).
-export([nkmedia_call_resolve/4, nkmedia_call_invite/6, 
         nkmedia_call_answer/6, nkmedia_call_cancelled/3, 
         nkmedia_call_reg_event/4]).
-export([nkmedia_session_reg_event/4]).

-define(VERTO_WS_TIMEOUT, 60*60*1000).
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.





%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nkmedia_call].


plugin_syntax() ->
    nkpacket:register_protocol(verto, nkmedia_verto),
    #{
        verto_listen => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % verto_listen will be already parsed
    Listen = maps:get(verto_listen, Config, []),
    Opts = #{
        class => {nkmedia_verto, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?VERTO_WS_TIMEOUT
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Verto (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Verto (~p) stopping", [Name]),
    {ok, Config}.




-type call_id() :: nkmedia_verto:call_id().
-type verto() :: nkmedia_verto:verto().


%% @doc Called when a new verto connection arrives
-spec nkmedia_verto_init(nkpacket:nkport(), verto()) ->
    {ok, verto()}.

nkmedia_verto_init(_NkPort, Verto) ->
    {ok, Verto#{?MODULE=>#{}}}.


%% @doc Called when a login request is received
-spec nkmedia_verto_login(Login::binary(), Pass::binary(), verto()) ->
    {boolean(), verto()} | {true, Login::binary(), verto()} | continue().

nkmedia_verto_login(_Login, _Pass, Verto) ->
    {false, Verto}.


%% @doc Called when the Verto client sends an INVITE
%% This default implementation will start a call:
%% - The caller_link is {nkmedia_verto, Call, Pid}, so that NkMEDIA will 
%%   monitor the caller and use it for nkmedia_answer (when the answer is availanble)
%%   and other events (in nkmedia_call_reg_event).
%% - Verto is registered with nkmedia_call, to be able to send byes and detect kills
%% - The call generates the 'caller' session and registers itself with it.
%%   Then it generates a 'callee' session and call nkmedia_call_invite
%% - Use the backend field to select backends for the bridge
%% - The call monitors both sessions, and stop thems if it stops.
%% - The call monitors also both the caller and the callee processes
%% - The sessions monitor the call, as a fallback mechanism
-spec nkmedia_verto_invite(nkservice:id(), call_id(), nkmedia:offer(), verto()) ->
    {ok, nklib:link(), verto()} | 
    {answer, nkmedia:answer(), nklib_:link(), verto()} | 
    {rejected, nkservice:error(), verto()} | continue().

nkmedia_verto_invite(SrvId, CallId, #{dest:=Dest}=Offer, Verto) ->
    Config = #{
        call_id => CallId,
        offer => Offer, 
        caller_link => {nkmedia_verto, CallId, self()},
        caller => #{info=>verto_native},
        no_answer_trickle_ice => true
    },
    case nkmedia_call:start2(SrvId, Dest, Config) of
        {ok, CallId, CallPid} ->
            {ok, {nkmedia_call, CallId, CallPid}, Verto};
        {error, Error} ->
            lager:warning("NkMEDIA Verto session error: ~p", [Error]),
            {rejected, Error, Verto}
    end.


%% @doc Called when the client sends an ANSWER after nkmedia_verto:invite/4
-spec nkmedia_verto_answer(call_id(), nklib:link(), nkmedia:answer(), verto()) ->
    {ok, verto()} |{hangup, nkservice:error(), verto()} | continue().

% If the registered process happens to be {nkmedia_session, ...} and we have
% an answer for an invite we received, we set the answer in the session
nkmedia_verto_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, Verto) ->
    case nkmedia_session:set_answer(SessId, Answer) of
        ok ->
            {ok, Verto};
        {error, Error} -> 
            {hangup, Error, Verto}
    end;

% If the registered process happens to be {nkmedia_call, ...} and we have
% an answer for an invite we received, we set the answer in the call
nkmedia_verto_answer(CallId, {nkmedia_call, CallId, _Pid}, Answer, Verto) ->
    Id = {nkmedia_verto, CallId, self()},
    case nkmedia_call:accepted(CallId, Id, Answer, #{module=>nkmedia_verto}) of
        {ok, _} ->
            {ok, Verto};
        {error, Error} ->
            {hangup, Error, Verto}
    end;

nkmedia_verto_answer(_CallId, _Link, _Answer, Verto) ->
    {ok, Verto}.


%% @doc Called when the client sends an BYE after nkmedia_verto:invite/4
-spec nkmedia_verto_rejected(call_id(), nklib:link(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_rejected(_CallId, {nkmedia_session, SessId, _Pid}, Verto) ->
    nkmedia_session:stop(SessId, verto_rejected),
    {ok, Verto};

nkmedia_verto_rejected(CallId, {nkmedia_call, CallId, _Pid}, Verto) ->
    nkmedia_call:rejected(CallId, {nkmedia_verto, CallId, self()}),
    {ok, Verto};

nkmedia_verto_rejected(_CallId, _Link, Verto) ->
    {ok, Verto}.


%% @doc Sends when the client sends a BYE during a call
-spec nkmedia_verto_bye(call_id(), nklib:link(), verto()) ->
    {ok, verto()} | continue().

% We recognize some special Links
nkmedia_verto_bye(_CallId, {nkmedia_session, SessId, _Pid}, Verto) ->
    nkmedia_session:stop(SessId, verto_bye),
    {ok, Verto};

nkmedia_verto_bye(CallId, {nkmedia_call, CallId, _Pid}, Verto) ->
    nkmedia_call:hangup(CallId, verto_bye),
    {ok, Verto};

nkmedia_verto_bye(_CallId, _Link, Verto) ->
    {ok, Verto}.


%% @doc
-spec nkmedia_verto_dtmf(call_id(), nklib:link(), DTMF::binary(), verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_dtmf(_CallId, _Link, _DTMF, Verto) ->
    {ok, Verto}.


%% @doc Called when the connection is stopped
-spec nkmedia_verto_terminate(Reason::term(), verto()) ->
    {ok, verto()}.

nkmedia_verto_terminate(_Reason, Verto) ->
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_call(Msg::term(), {pid(), term()}, verto()) ->
    {ok, verto()} | continue().

nkmedia_verto_handle_call(Msg, _From, Verto) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_cast(Msg::term(), verto()) ->
    {ok, verto()}.

nkmedia_verto_handle_cast(Msg, Verto) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkmedia_verto_handle_info(Msg::term(), verto()) ->
    {ok, Verto::map()}.

nkmedia_verto_handle_info(Msg, Verto) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, Verto}.




%% ===================================================================
%% Implemented Callbacks - Error
%% ===================================================================


%% @private See nkservice_callbacks
error_code(verto_bye)       -> {306001, "Verto bye"};
error_code(verto_rejected)  -> {306002, "Verto rejected"};
error_code(_) -> continue.



%% ===================================================================
%% Implemented Callbacks - Session
%% ===================================================================


%% @private
%% Convenient functions in case we are registered with the session as
%% {nkmedia_verto, CallId, Pid}
nkmedia_session_reg_event(_SessId, {nkmedia_verto, CallId, Pid}, Event, _Session) ->
    case Event of
        {answer, Answer} ->
            % we may be blocked waiting for the same session creation
            case nkmedia_verto:answer_async(Pid, CallId, Answer) of
                ok ->
                    ok;
                {error, Error} ->
                    lager:error("Error setting Verto answer: ~p", [Error])
            end;
        {stop, Reason} ->
            lager:info("Verto stopping after session stop: ~p", [Reason]),
            nkmedia_verto:hangup(Pid, CallId, Reason);
        _ ->
            ok
    end,
    continue;

nkmedia_session_reg_event(_SessId, _Link, _Event, _Call) ->
    continue.


%% ===================================================================
%% Implemented Callbacks - Call
%% ===================================================================

%% @private
%% If call has type 'verto' we will capture it
nkmedia_call_resolve(Callee, Type, Acc, Call) when Type==verto; Type==all ->
    Dest = [
        #{dest=>{nkmedia_verto, Pid}, session_config=>#{no_offer_trickle_ice=>true}}
        || Pid <- nkmedia_verto:find_user(Callee)
    ],
    {continue, [Callee, Type, Acc++Dest, Call]};

nkmedia_call_resolve(_Callee, _Type, _Acc, _Call) ->
    continue.


%% @private Called when a call want to INVITE a Verto session
%% - We start a verto INVITE with this CallId and registered with the call
%%   (to be able to send BYEs)
%% - The Verto session registers with the call as {nkmedia_verto, CallId, Pid}, 
%%   and will send hangups and rejected using this
nkmedia_call_invite(CallId, {nkmedia_verto, Pid}, _SessId, Offer, _Caller, Call) ->
    CallLink = {nkmedia_call, CallId, self()},
    {ok, VertoLink} = nkmedia_verto:invite(Pid, CallId, Offer, CallLink),
    {ok, VertoLink, Call};

nkmedia_call_invite(_CallId, _Dest, _SessId, _Offer, _Caller, _Call) ->
    continue.


%% @private
nkmedia_call_answer(CallId, {nkmedia_verto, CallId, Pid}, _SessId, Answer, 
                    _Callee, Call) ->
    case nkmedia_verto:answer(Pid, CallId, Answer) of
        ok ->
            {ok, Call};
        {error, Error} ->
            lager:error("Error setting Verto answer: ~p", [Error]),
            {error, Error, Call}
    end;

nkmedia_call_answer(_CallId, _Link, _SessId, _Answer, _Callee, _Call) ->
    continue.


%% @private
nkmedia_call_cancelled(_CallId, {nkmedia_verto, CallId, Pid}, _Call) ->
    nkmedia_verto:hangup(Pid, CallId, originator_cancel),
    continue;

nkmedia_call_cancelled(_CallId, _Link, _Call) ->
    continue.


%% @private
%% Convenient functions in case we are registered with the call as
%% {nkmedia_verto, CallId, Pid}
nkmedia_call_reg_event(CallId, {nkmedia_verto, CallId, Pid}, {hangup, Reason}, _Call) ->
    nkmedia_verto:hangup(Pid, CallId, Reason),
    continue;

nkmedia_call_reg_event(_CallId, _Link, _Event, _Call) ->
    % lager:error("CALL REG: ~p", [_Link]),
    continue.



%% ===================================================================
%% Internal
%% ===================================================================

parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(verto_listen, Url, _Ctx) ->
    Opts = #{valid_schemes=>[verto], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.





