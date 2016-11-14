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

%% @doc Call Callbacks
-module(nkcollab_call_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkcollab_call_init/2, nkcollab_call_terminate/2, 
         nkcollab_call_expand/3, nkcollab_call_invite/4, 
         nkcollab_call_event/3, nkcollab_call_reg_event/4, 
         nkcollab_call_handle_call/3, nkcollab_call_handle_cast/2, 
         nkcollab_call_handle_info/2,
         nkcollab_call_start_caller_session/4, 
         nkcollab_call_start_callee_session/5,
         nkcollab_call_set_accepted/6]).
-export([error_code/1]).
-export([api_server_cmd/2, api_server_syntax/4]).
-export([api_server_reg_down/3]).
-export([nkmedia_session_reg_event/4]).

-include("../../include/nkcollab.hrl").
-include("../../include/nkcollab_call.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-type continue() :: continue | {continue, list()}.




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkcollab].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkCOLLAB CALL (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkCOLLAB CALL (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Error Codes
%% ===================================================================

%% @doc NkCOLLAB CALL 
-spec error_code(term()) ->
    {integer(), binary()} | continue.

error_code(call_error)              ->  {305001, "Call error"};
error_code(call_not_found)          ->  {305002, "Call not found"};
error_code(call_rejected)           ->  {305003, "Call rejected"};
error_code(ring_timeout)            ->  {305004, "Ring timeout"};
error_code(no_destination)          ->  {305005, "No destination"};
error_code(no_answer)               ->  {305006, "No answer"};
error_code(already_answered)        ->  {305007, "Already answered"};
error_code(originator_cancel)       ->  {305008, "Originator cancel"};
error_code(caller_stopped)          ->  {305009, "Caller stopped"};
error_code(callee_stopped)          ->  {305010, "Callee stopped"};
error_code(api_hangup)              ->  {305011, "API hangup"};
error_code({api_hangup, Reason})    ->  {305011, "API hangup: ~s", [Reason]};
error_code(_) -> continue.



%% ===================================================================
%% Call Callbacks
%% ===================================================================

-type call_id() :: nkcollab_call:id().
-type dest() :: nkcollab_call:dest().
-type dest_ext() :: nkcollab_call:dest_ext().
-type call() :: nkcollab_call:call().
-type session_id() :: nkmedia_session:id().


%% @doc Called when a new call starts
-spec nkcollab_call_init(call_id(), call()) ->
    {ok, call()}.

nkcollab_call_init(_Id, Call) ->
    {ok, Call}.

%% @doc Called when the call stops
-spec nkcollab_call_terminate(Reason::term(), call()) ->
    {ok, call()}.

nkcollab_call_terminate(_Reason, Call) ->
    {ok, Call}.


%% @doc Called when an call is created. The initial dest is included,
%% along with the current extended destinations. You may add new destinations.
%%
%% The default implementation will look for types 'user' and 'session', adding 
%% {nkcollab_api, {user|session, pid()}} destinations
%% Then nkcollab_call_invite must send the real invitations
-spec nkcollab_call_expand(dest(), [dest_ext()], call()) ->
    {ok, [dest_ext()], call()} | continue().

nkcollab_call_expand(Dest, DestExts, Call) ->
    nkcollab_call_api:expand(Dest, DestExts, Call).


%% @doc Called for each defined destination to be invited
%% If backend==none, Data may only have a 'callee' field
%% Otherwhise, a session is already started and data may cointain 
%% 'session_id' and 'offer'
%% Then link will be registered with the session, and if it is selected, with the call
%% If accepted, must call nkcollab_call:ringing/answered/rejected
%% nkmeida_call will "bridge" the sessions
-spec nkcollab_call_invite(call_id(), dest(), map(), call()) ->
    {ok, nklib:link(), call()} | 
    {ok, nklib:link(), session_id(), call()} | 
    {retry, Secs::pos_integer(), call()} | 
    {remove, call()} | 
    continue().

nkcollab_call_invite(CallId, {nkcollab_api_user, Pid}, Data, Call) ->
    nkcollab_call_api:invite(CallId, {user, Pid}, Data, Call);

nkcollab_call_invite(CallId, {nkcollab_api_session, Pid}, Data, Call) ->
    nkcollab_call_api:invite(CallId, {session, Pid}, Data, Call);

nkcollab_call_invite(_CallId, _Dest, _Data, Call) ->
    {remove, Call}.


%% @doc Called when the status of the call changes
-spec nkcollab_call_event(call_id(), nkcollab_call:event(), call()) ->
    {ok, call()} | continue().

nkcollab_call_event(CallId, Event, Call) ->
    nkcollab_call_api_events:event(CallId, Event, Call).


%% @doc Called when the status of the call changes, for each registered
%% process to the session
-spec nkcollab_call_reg_event(call_id(), nklib:link(), nkcollab_call:event(), call()) ->
    {ok, call()} | continue().

nkcollab_call_reg_event(CallId, {nkcollab_api, ApiPid}, {hangup, Reason}, Call) ->
    nkcollab_call_api:api_call_hangup(CallId, ApiPid, Reason, Call);

nkcollab_call_reg_event(CallId, {nkcollab_api, _}=Link, Event, Call) ->
    nkcollab_call_api_events:event_linked(CallId, Link, Event, Call);

nkcollab_call_reg_event(_CallId, _Link, _Event, Call) ->
    {ok, Call}.


%% @doc
-spec nkcollab_call_handle_call(term(), {pid(), term()}, call()) ->
    {reply, term(), call()} | {noreply, call()} | continue().

nkcollab_call_handle_call(Msg, _From, Call) ->
    lager:error("Module nkcollab_call received unexpected call: ~p", [Msg]),
    {noreply, Call}.


%% @doc
-spec nkcollab_call_handle_cast(term(), call()) ->
    {noreply, call()} | continue().

nkcollab_call_handle_cast(Msg, Call) ->
    lager:error("Module nkcollab_call received unexpected call: ~p", [Msg]),
    {noreply, Call}.


%% @doc
-spec nkcollab_call_handle_info(term(), call()) ->
    {noreply, call()} | continue().

nkcollab_call_handle_info(Msg, Call) ->
    lager:warning("Module nkcollab_call received unexpected info: ~p", [Msg]),
    {noreply, Call}.


%% @doc Called when the Call must start the 'caller' session
%% Implemented by backends
-spec nkcollab_call_start_caller_session(call_id(), nkmedia_session:config(), 
                                         nkmedia:backend()|none, call()) ->
    {none, call()} | {ok, nkmedia_session:id(), pid(), call()} | 
    {error, nkservice:error(), call()} |
    continue().

nkcollab_call_start_caller_session(CallId, Config, Backend, Call) -> 
    nkcollab_call_backends:start_caller_session(CallId, Config, Backend, Call).


%% @doc Called when the Call must start a 'callee' session
%% Implemented by backends
-spec nkcollab_call_start_callee_session(call_id(), nkmedia_session:id(), 
                                        nkmedia_session:config(), nkmedia:backend()|none,
                                        call()) ->
    {ok, nkmedia_session:id(), pid(), nkmedia:offer(), call()} | 
    {error, nkservice:error(), call()} |
    continue().

nkcollab_call_start_callee_session(CallId, MasterId, Config, Backend, Call) ->
    nkcollab_call_backends:start_callee_session(CallId, MasterId, Config, Backend, Call).

%% @doc Called when the call has both sessions and must be connected
%% Implemented by backend
-spec nkcollab_call_set_accepted(call_id(), session_id(), session_id(), 
                              nkmedia:answer(), nkmedia:backend()|none, call()) ->
    {ok, call()} | {error, nkservice:error(), term()} | continue().

nkcollab_call_set_accepted(CallId, MasterId, SlaveId, Answer, Backend, Call) ->
    nkcollab_call_backends:set_accepted(CallId, MasterId, SlaveId, Answer, Backend, Call).



%% ===================================================================
%% API CMD
%% ===================================================================

%% @private
api_server_cmd(
    #api_req{class=collab, subclass=call, cmd=Cmd}=Req, State) ->
    nkcollab_call_api:cmd(Cmd, Req, State);

api_server_cmd(_Req, _State) ->
    continue.


%% @privat
api_server_syntax(#api_req{class=collab, subclass=call, cmd=Cmd}, 
                  Syntax, Defaults, Mandatory) ->
    nkcollab_call_api_syntax:syntax(Cmd, Syntax, Defaults, Mandatory);
    
api_server_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.


%% ===================================================================
%% API Server
%% ===================================================================

%% @private
api_server_reg_down({nkcollab_call, CallId, _Pid}, Reason, State) ->
    nkcollab_api:api_call_down(CallId, Reason, State),
    continue;

api_server_reg_down(_Link, _Reason, _State) ->
    continue.


%% ===================================================================
%% nkmedia_session
%% ===================================================================


%% @private
%% If the session is from nkcollab_call, inform us
nkmedia_session_reg_event(SessId, {nkcollab_call, CallId, _Pid}, Event, _Session) ->
    nkcollab_call:session_event(CallId, SessId, Event),
    continue;

nkmedia_session_reg_event(_SessId, _Link, _Event, _Session) ->
    continue.

