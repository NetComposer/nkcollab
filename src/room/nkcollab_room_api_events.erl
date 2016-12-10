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

-export([event/3, event_room_down/2]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Events
%% ===================================================================


%% @private
-spec event(nkcollab_room:id(), nkcollab_room:event(), nkcollab_room:room()) ->
    {ok, nkcollab_room:room()}.

event(RoomId, created, Room) ->
    Data = nkcollab_room_api_syntax:get_info(Room),
    send_event(RoomId, created, Data, Room);

event(RoomId, {room_msg, Msg}, Room) ->
    send_event(RoomId, room_msg, Msg, Room);

event(RoomId, {room_info, Meta}, Room) ->
    send_event(RoomId, room_info, Meta, Room);

event(RoomId, {started_publisher, Data}, Room) ->
    send_event(RoomId, started_publisher, Data, Room);

event(RoomId, {stopped_publisher, Data}, Room) ->
    send_event(RoomId, stopped_publisher, Data, Room);

event(RoomId, {updated_publisher, Data}, Room) ->
    send_event(RoomId, updated_publisher, Data, Room);

event(RoomId, {started_listener, Data}, Room) ->
    send_event(RoomId, started_listener, Data, Room);

event(RoomId, {stopped_listener, Data}, Room) ->
    send_event(RoomId, stopped_listener, Data, Room);

%% 'destroyed' event is only for internal use
event(RoomId, {stopped, Reason}, #{srv_id:=SrvId}=Room) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    send_event(RoomId, destroyed, #{code=>Code, reason=>Txt}, Room);

event(RoomId, {record, Log}, Room) ->
    Record = #{info=>nkcollab_room_api_syntax:get_info(Room), timelog=>Log},
    send_event(RoomId, record, Record, Room);

event(_RoomId, _Event, Room) ->
    {ok, Room}.


%% @private
-spec event_room_down(nkservice:id(), nkmedia_session:id()) ->
    ok.

event_room_down(SrvId, RoomId) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, process_down),
    Body = #{code=>Code, reason=>Txt},
    send_event(RoomId, destroyed, Body, #{srv_id=>SrvId, conns=>#{}}).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
send_event(RoomId, Type, Body, #{srv_id:=SrvId, conns:=Conns}=Room) ->
    Event = #event{
        srv_id = SrvId,     
        class = <<"collab">>, 
        subclass = <<"room">>,
        type = nklib_util:to_binary(Type),
        obj_id = RoomId,
        body = Body
    },
    send_direct_events(maps:to_list(Conns), Event, Room),
    nkservice_events:send(Event),
    ok.



%% @private
send_direct_events([], _Event, _Room) ->
    ok;

send_direct_events([{ConnId, ConnData}|Rest], Event, Room) ->
    #{room_events:=Events} = ConnData,
    #event{type=Type, body=Body} = Event,
    case lists:member(Type, Events) of
        true ->
            Event2 = case ConnData of
                #{room_events_body:=Body2} ->
                    Event#event{body=maps:merge(Body, Body2)};
                _ ->
                    Event
            end,
            nkservice_api_server:event(ConnId, Event2);
        false ->
            ok
    end,
    send_direct_events(Rest, Event, Room).










