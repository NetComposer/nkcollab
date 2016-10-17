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
-module(nkcollab_verto_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkcollab_verto_init/2, nkcollab_verto_login/3, 
         nkcollab_verto_invite/4, nkcollab_verto_bye/3,
         nkcollab_verto_answer/4, nkcollab_verto_rejected/3,
         nkcollab_verto_dtmf/4, nkcollab_verto_terminate/2,
         nkcollab_verto_handle_call/3, nkcollab_verto_handle_cast/2,
         nkcollab_verto_handle_info/2]).
-export([nkcollab_call_resolve/4, nkcollab_call_invite/6, 
         nkcollab_call_answer/6, nkcollab_call_cancelled/3, 
         nkcollab_call_reg_event/4]).
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
    [nkcollab, nkcollab_call].


plugin_syntax() ->
    nkpacket:register_protocol(verto, nkcollab_verto),
    #{
        verto_listen => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % verto_listen will be already parsed
    Listen = maps:get(verto_listen, Config, []),
    Opts = #{
        class => {nkcollab_verto, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?VERTO_WS_TIMEOUT
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkCOLLAB Verto (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkCOLLAB Verto (~p) stopping", [Name]),
    {ok, Config}.




-type call_id() :: nkcollab_verto:call_id().
-type verto() :: nkcollab_verto:verto().


%% @doc Called when a new verto connection arrives
-spec nkcollab_verto_init(nkpacket:nkport(), verto()) ->
    {ok, verto()}.

nkcollab_verto_init(_NkPort, Verto) ->
    {ok, Verto#{?MODULE=>#{}}}.


%% @doc Called when a login request is received
-spec nkcollab_verto_login(Login::binary(), Pass::binary(), verto()) ->
    {boolean(), verto()} | {true, Login::binary(), verto()} | continue().

nkcollab_verto_login(_Login, _Pass, Verto) ->
    {false, Verto}.


%% @doc Called when the Verto client sends an INVITE
%% This default implementation will start a call:
%% - The caller_link is {nkcollab_verto, Call, Pid}, so that NkCOLLAB will 
%%   monitor the caller and use it for nkcollab_answer (when the answer is availanble)
%%   and other events (in nkcollab_call_reg_event).
%% - Verto is registered with nkcollab_call, to be able to send byes and detect kills
%% - The call generates the 'caller' session and registers itself with it.
%%   Then it generates a 'callee' session and call nkcollab_call_invite
%% - Use the backend field to select backends for the bridge
%% - The call monitors both sessions, and stop thems if it stops.
%% - The call monitors also both the caller and the callee processes
%% - The sessions monitor the call, as a fallback mechanism
-spec nkcollab_verto_invite(nkservice:id(), call_id(), nkmedia:offer(), verto()) ->
    {ok, nklib:link(), verto()} | 
    {answer, nkmedia:answer(), nklib_:link(), verto()} | 
    {rejected, nkservice:error(), verto()} | continue().

nkcollab_verto_invite(SrvId, CallId, #{dest:=Dest}=Offer, Verto) ->
    Config = #{
        call_id => CallId,
        offer => Offer, 
        caller_link => {nkcollab_verto, CallId, self()},
        caller => #{info=>verto_native},
        no_answer_trickle_ice => true
    },
    case nkcollab_call:start2(SrvId, Dest, Config) of
        {ok, CallId, CallPid} ->
            {ok, {nkcollab_call, CallId, CallPid}, Verto};
        {error, Error} ->
            lager:warning("NkCOLLAB Verto session error: ~p", [Error]),
            {rejected, Error, Verto}
    end.


%% @doc Called when the client sends an ANSWER after nkcollab_verto:invite/4
-spec nkcollab_verto_answer(call_id(), nklib:link(), nkmedia:answer(), verto()) ->
    {ok, verto()} |{hangup, nkservice:error(), verto()} | continue().

% If the registered process happens to be {nkmedia_session, ...} and we have
% an answer for an invite we received, we set the answer in the session
nkcollab_verto_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, Verto) ->
    case nkmedia_session:set_answer(SessId, Answer) of
        ok ->
            {ok, Verto};
        {error, Error} -> 
            {hangup, Error, Verto}
    end;

% If the registered process happens to be {nkcollab_call, ...} and we have
% an answer for an invite we received, we set the answer in the call
nkcollab_verto_answer(CallId, {nkcollab_call, CallId, _Pid}, Answer, Verto) ->
    Id = {nkcollab_verto, CallId, self()},
    case nkcollab_call:accepted(CallId, Id, Answer, #{module=>nkcollab_verto}) of
        {ok, _} ->
            {ok, Verto};
        {error, Error} ->
            {hangup, Error, Verto}
    end;

nkcollab_verto_answer(_CallId, _Link, _Answer, Verto) ->
    {ok, Verto}.


%% @doc Called when the client sends an BYE after nkcollab_verto:invite/4
-spec nkcollab_verto_rejected(call_id(), nklib:link(), verto()) ->
    {ok, verto()} | continue().

nkcollab_verto_rejected(_CallId, {nkmedia_session, SessId, _Pid}, Verto) ->
    nkmedia_session:stop(SessId, verto_rejected),
    {ok, Verto};

nkcollab_verto_rejected(CallId, {nkcollab_call, CallId, _Pid}, Verto) ->
    nkcollab_call:rejected(CallId, {nkcollab_verto, CallId, self()}),
    {ok, Verto};

nkcollab_verto_rejected(_CallId, _Link, Verto) ->
    {ok, Verto}.


%% @doc Sends when the client sends a BYE during a call
-spec nkcollab_verto_bye(call_id(), nklib:link(), verto()) ->
    {ok, verto()} | continue().

% We recognize some special Links
nkcollab_verto_bye(_CallId, {nkmedia_session, SessId, _Pid}, Verto) ->
    nkmedia_session:stop(SessId, verto_bye),
    {ok, Verto};

nkcollab_verto_bye(CallId, {nkcollab_call, CallId, _Pid}, Verto) ->
    nkcollab_call:hangup(CallId, verto_bye),
    {ok, Verto};

nkcollab_verto_bye(_CallId, _Link, Verto) ->
    {ok, Verto}.


%% @doc
-spec nkcollab_verto_dtmf(call_id(), nklib:link(), DTMF::binary(), verto()) ->
    {ok, verto()} | continue().

nkcollab_verto_dtmf(_CallId, _Link, _DTMF, Verto) ->
    {ok, Verto}.


%% @doc Called when the connection is stopped
-spec nkcollab_verto_terminate(Reason::term(), verto()) ->
    {ok, verto()}.

nkcollab_verto_terminate(_Reason, Verto) ->
    {ok, Verto}.


%% @doc 
-spec nkcollab_verto_handle_call(Msg::term(), {pid(), term()}, verto()) ->
    {ok, verto()} | continue().

nkcollab_verto_handle_call(Msg, _From, Verto) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkcollab_verto_handle_cast(Msg::term(), verto()) ->
    {ok, verto()}.

nkcollab_verto_handle_cast(Msg, Verto) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkcollab_verto_handle_info(Msg::term(), verto()) ->
    {ok, Verto::map()}.

nkcollab_verto_handle_info(Msg, Verto) ->
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
%% {nkcollab_verto, CallId, Pid}
nkmedia_session_reg_event(_SessId, {nkcollab_verto, CallId, Pid}, Event, _Session) ->
    case Event of
        {answer, Answer} ->
            % we may be blocked waiting for the same session creation
            case nkcollab_verto:answer_async(Pid, CallId, Answer) of
                ok ->
                    ok;
                {error, Error} ->
                    lager:error("Error setting Verto answer: ~p", [Error])
            end;
        {stop, Reason} ->
            lager:info("Verto stopping after session stop: ~p", [Reason]),
            nkcollab_verto:hangup(Pid, CallId, Reason);
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
nkcollab_call_resolve(Callee, Type, Acc, Call) when Type==verto; Type==all ->
    Dest = [
        #{dest=>{nkcollab_verto, Pid}, session_config=>#{no_offer_trickle_ice=>true}}
        || Pid <- nkcollab_verto:find_user(Callee)
    ],
    {continue, [Callee, Type, Acc++Dest, Call]};

nkcollab_call_resolve(_Callee, _Type, _Acc, _Call) ->
    continue.


%% @private Called when a call want to INVITE a Verto session
%% - We start a verto INVITE with this CallId and registered with the call
%%   (to be able to send BYEs)
%% - The Verto session registers with the call as {nkcollab_verto, CallId, Pid}, 
%%   and will send hangups and rejected using this
nkcollab_call_invite(CallId, {nkcollab_verto, Pid}, _SessId, Offer, _Caller, Call) ->
    CallLink = {nkcollab_call, CallId, self()},
    {ok, VertoLink} = nkcollab_verto:invite(Pid, CallId, Offer, CallLink),
    {ok, VertoLink, Call};

nkcollab_call_invite(_CallId, _Dest, _SessId, _Offer, _Caller, _Call) ->
    continue.


%% @private
nkcollab_call_answer(CallId, {nkcollab_verto, CallId, Pid}, _SessId, Answer, 
                    _Callee, Call) ->
    case nkcollab_verto:answer(Pid, CallId, Answer) of
        ok ->
            {ok, Call};
        {error, Error} ->
            lager:error("Error setting Verto answer: ~p", [Error]),
            {error, Error, Call}
    end;

nkcollab_call_answer(_CallId, _Link, _SessId, _Answer, _Callee, _Call) ->
    continue.


%% @private
nkcollab_call_cancelled(_CallId, {nkcollab_verto, CallId, Pid}, _Call) ->
    nkcollab_verto:hangup(Pid, CallId, originator_cancel),
    continue;

nkcollab_call_cancelled(_CallId, _Link, _Call) ->
    continue.


%% @private
%% Convenient functions in case we are registered with the call as
%% {nkcollab_verto, CallId, Pid}
nkcollab_call_reg_event(CallId, {nkcollab_verto, CallId, Pid}, {hangup, Reason}, _Call) ->
    nkcollab_verto:hangup(Pid, CallId, Reason),
    continue;

nkcollab_call_reg_event(_CallId, _Link, _Event, _Call) ->
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





