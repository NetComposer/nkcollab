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

%% @doc Room Plugin API
-module(nkcollab_room_api_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/3, room_down/2]).

% -include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Events
%% ===================================================================


%% @private
-spec event(nkcollab_room:id(), nkcollab_room:event(), nkcollab_room:room()) ->
    {ok, nkcollab_room:room()}.

event(RoomId, created, Room) ->
    Data = nkcollab_room_api_syntax:get_room_info(Room),
    send_event(RoomId, created, Data, Room);

event(RoomId, {destroyed, Reason}, #{srv_id:=SrvId}=Room) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    send_event(RoomId, destroyed, #{code=>Code, reason=>Txt}, Room);

event(RoomId, {started_member, MemberId, Info}, Room) ->
    Info2 = nkcollab_room_api_syntax:get_member_info(Info),
    send_event(RoomId, started_member, Info2#{member_id=>MemberId}, Room);

event(RoomId, {stopped_member, MemberId, Info}, Room) ->
    Info2 = nkcollab_room_api_syntax:get_member_info(Info),
    send_event(RoomId, stopped_member, Info2#{member_id=>MemberId}, Room);

event(RoomId, {started_session, SessId, MemberId}, Room) ->
    Data = #{member_id=>MemberId, session_id=>SessId},
    send_event(RoomId, started_session, Data, Room);

event(RoomId, {stopped_session, SessId, MemberId}, Room) ->
    Data = #{member_id=>MemberId, session_id=>SessId},
    send_event(RoomId, stopped_session, Data, Room);

event(RoomId, {broadcast, Msg}, Room) ->
    send_event(RoomId, broadcast, Msg, Room);

event(RoomId, {info, Info, Meta}, Room) ->
    send_event(RoomId, info, Meta#{info=>Info}, Room);

event(_RoomId, _Event, Room) ->
    {ok, Room}.


%% @private
-spec room_down(nkservice:id(), nkmedia_session:id()) ->
    ok.

room_down(SrvId, RoomId) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, process_down),
    Body = #{code=>Code, reason=>Txt},
    nkcollab_api_events:send_event(SrvId, room, RoomId, destroyed, Body).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
send_event(RoomId, Type, Body, #{srv_id:=SrvId}=Room) ->
    nkcollab_api_events:send_event(SrvId, room, RoomId, Type, Body),
    {ok, Room}.


