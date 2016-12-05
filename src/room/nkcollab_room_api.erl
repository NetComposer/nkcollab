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
-module(nkcollab_room_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/3]).
-export([api_room_stopped/4, api_room_down/3]).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


%% ===================================================================
%% Commands
%% ===================================================================


cmd(create, #api_req{srv_id=SrvId, data=Data}, State) ->
    case nkcollab_room:start(SrvId, Data) of
        {ok, Id, _Pid} ->
            {ok, #{room_id=>Id}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(destroy, #api_req{data=#{room_id:=Id}}, State) ->
    case nkcollab_room:stop(Id, api_stop) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(get_list, _Req, State) ->
    Ids = [#{room_id=>Id, meta=>Meta} || {Id, Meta, _Pid} <- nkcollab_room:get_all()],
    {ok, Ids, State};

cmd(get_info, #api_req{data=#{room_id:=RoomId}}, State) ->
    case nkcollab_room:get_room(RoomId) of
        {ok, Room} ->
            {ok, nkcollab_room_api_syntax:get_room_info(Room), State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(add_publish_session, Req, State) ->
    #api_req{
        data = #{room_id:=RoomId}=Data, 
        user = MemberId, 
        session_id = ConnId
    } = Req,
    Data2 = Data#{register => {nkcollab_api, self()}},
    case nkcollab_room:add_publish_session(RoomId, MemberId, ConnId, Data2) of
        {ok, SessId, Pid} ->
            nkservice_api_server:register(self(), {nkcollab_room, RoomId, Pid}),
            session_reply(SessId, Data);
        {error, Error} ->
            {error, Error, State}
    end;

cmd(add_listen_session, Req, State) ->
    #api_req{
        data = #{room_id:=RoomId, publisher_id:=PubId} = Data, 
        user = MemberId, 
        session_id = ConnId
    } = Req,
    Data2 = Data#{register => {nkcollab_api, self()}},
    case nkcollab_room:add_listen_session(RoomId, MemberId, ConnId, PubId, Data2) of
        {ok, SessId, Pid} ->
            nkservice_api_server:register(self(), {nkcollab_room, RoomId, Pid}),
            session_reply(SessId, Data);
        {error, Error} ->
            {error, Error, State}
    end;

cmd(remove_session, Req, State) ->
    #api_req{data=#{room_id:=RoomId, session_id:=SessId}} = Req,
    case nkcollab_room:remove_session(RoomId, SessId) of
        {ok, Reply} ->
            {ok, Reply, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(remove_member, Req, State) ->
    #api_req{data=#{room_id:=RoomId}, user=MemberId} = Req,
    case nkcollab_room:remove_member(RoomId, MemberId) of
        {ok, Reply} ->
            {ok, Reply, State};
        {error, Error} ->
            {error, Error, State}
    end;


% In the future, this call and next ones should check if user has the session
cmd(update_publisher, Req, State) ->
    #api_req{data=#{room_id:=RoomId, session_id:=SessId} = Data} = Req,
    case nkcollab_room:update_publisher(RoomId, SessId, Data) of
        {ok, Reply} ->
            {ok, Reply, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(update_meta, Req, State) ->
    #api_req{data=#{room_id:=RoomId, session_id:=SessId} = Data} = Req,
    case nkcollab_room:update_meta(RoomId, SessId, Data) of
        {ok, Reply} ->
            {ok, Reply, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(update_media, Req, State) ->
    #api_req{data=#{room_id:=RoomId, session_id:=SessId} = Data} = Req,
    case nkcollab_room:update_media(RoomId, SessId, Data) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(set_answer, Req, State) ->
    nkmedia_api:cmd(set_answer, Req, State);

cmd(set_candidate, Req, State) ->
    nkmedia_api:cmd(set_candidate, Req, State);

cmd(set_candidate_end, Req, State) ->
    nkmedia_api:cmd(set_candidate_end, Req, State);

cmd(send_broadcast, ApiReq, State) ->
    #api_req{data=Data, user=User} = ApiReq,
    #{room_id:=RoomId, member_id:=MemberId, msg:=Msg} = Data,
    RoomMsg = Msg#{user_id=>User},
    case nkcollab_room:broadcast(RoomId, MemberId, RoomMsg) of
        {ok, MsgId} ->
            {ok, #{msg_id=>MsgId}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(get_all_broadcasts, #api_req{data=Data}, State) ->
    #{room_id:=RoomId} = Data,
    case nkcollab_room:get_all_msgs(RoomId) of
        {ok, List} ->
            {ok, List, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(_Cmd, _Data, _State) ->
    continue.



%% ===================================================================
%% API server callbacks
%% ===================================================================

%% @private Sent by the room when it is stopping
%% We sent a message to the API session to remove the reg before 
%% it receives the DOWN.
api_room_stopped(RoomId, ApiPid, _Reason, Room) ->
    #{srv_id:=SrvId} = Room,
    Event = get_room_event(SrvId, <<"*">>, RoomId, undefined),
    nkservice_api_server:unsubscribe(ApiPid, Event, none),
    nkservice_api_server:unregister(ApiPid, {nkcollab_room, RoomId, self()}),
    {ok, Room}.


%% @private The API server detected room has fallen
api_room_down(RoomId, Reason, State) ->
    #{srv_id:=SrvId} = State,
    lager:warning("API Server: Collab Room ~s is down: ~p", [RoomId, Reason]),
    Event = get_room_event(SrvId, <<"*">>, RoomId, undefined),
    nkservice_api_server:unsubscribe(self(), Event, all),
    nkcollab_room_api_events:room_down(SrvId, RoomId).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
session_reply(SessId, Config) ->
    case Config of
        #{offer:=_} -> 
            case nkmedia_session:get_answer(SessId) of
                {ok, Answer} ->
                    {ok, #{session_id=>SessId, answer=>Answer}};
                {error, Error} ->
                    {error, Error}
            end;
        _ -> 
            case nkmedia_session:get_offer(SessId) of
                {ok, Offer} ->
                    {ok, #{session_id=>SessId, offer=>Offer}};
                {error, Error} ->
                    {error, Error}
            end
    end.


%% @private
get_room_event(SrvId, Type, RoomId, Body) ->
    #event{
        srv_id = SrvId, 
        class = <<"collab">>, 
        subclass = <<"room">>,
        type = nklib_util:to_binary(Type),
        obj_id = RoomId,
        body = Body
    }.



