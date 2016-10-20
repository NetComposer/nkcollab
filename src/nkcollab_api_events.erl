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

%% @doc NkCOLLAB external events processing

-module(nkcollab_api_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/3, send_event/5]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Callbacks
%% ===================================================================

%% @private
-spec event(nkmedia_session:id(), nkmedia_session:event(),
            nkmedia_session:session()) ->
	{ok, nkmedia_session:session()}.

event(_SessId, _Event, Session) ->
    {ok, Session}.



%% ===================================================================
%% Internal
%% ===================================================================

%% @doc Sends an event
-spec send_event(nkservice:id(), atom(), binary(), atom(), map()) ->
    ok.

send_event(SrvId, Class, Id, Type, Body) ->
    send_event(SrvId, Class, Id, Type, Body, all).


%% @doc Sends an event
-spec send_event(nkservice:id(), atom(), binary(), atom(), map(), pid()) ->
    ok.

send_event(SrvId, Class, Id, Type, Body, Pid) ->
    lager:notice("COLLAB EVENT (~s:~s:~s): ~p", [Class, Type, Id, Body]),
    RegId = #reg_id{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = nklib_util:to_binary(Class),
        type = nklib_util:to_binary(Type),
        obj_id = Id
    },
    nkservice_events:send(RegId, Body, Pid).
