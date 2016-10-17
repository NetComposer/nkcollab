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
-module(nkcollab_call_api_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/3, event/4]).

-include_lib("nksip/include/nksip.hrl").




%% ===================================================================
%% Events
%% ===================================================================


%% @private
-spec event(nkcollab_call:id(), nkcollab_call:event(), nkcollab_call:call()) ->
    {ok, nkcollab_call:call()}.

event(CallId, {ringing, Callee}, Call) ->
    send_event(CallId, ringing, #{callee=>Callee}, Call);

event(CallId, {accepted, Callee}, Call) ->
    send_event(CallId, accepted, #{callee=>Callee}, Call);

event(CallId, {hangup, Reason}, #{srv_id:=SrvId}=Call) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    send_event(CallId, hangup, #{code=>Code, reason=>Txt}, Call);

event(_CallId, _Event, Call) ->
    {ok, Call}.



%% @private
-spec event(nkcollab_call:id(), term(), nkcollab_call:call(), pid()) ->
    {ok, nkcollab_call:call()}.

event(CallId, {answer, SessId, Answer, Callee}, Call, Pid) ->
    Data = #{session_id=>SessId, answer=>Answer, callee=>Callee},
    send_event(CallId, answer, Data, Call, Pid);

event(CallId, {candidate, #candidate{}=Candidate}, Call, Pid) ->
    #candidate{a_line=Line, m_id=Id, m_index=Index} = Candidate,
    Data = #{sdpMid=>Id, sdpMLineIndex=>Index, candidate=>Line},
	send_event(CallId, candidate, Data, Call, Pid);

event(_CallId, _Event, Call, _Pid) ->
    {ok, Call}.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
send_event(CallId, Type, Body, Call) ->
	send_event(CallId, Type, Body, Call, all).

%% @private
send_event(CallId, Type, Body, #{srv_id:=SrvId}=Call, Pid) ->
    nkcollab_api_events:send_event(SrvId, call, CallId, Type, Body, Pid),
    {ok, Call}.


