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
            {ok, nkcollab_room_api_syntax:get_info(Room), State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(get_publishers, #api_req{data=#{room_id:=RoomId}}, State) ->
    case nkcollab_room:get_publishers(RoomId) of
        {ok, Data} ->
            {ok, Data, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(get_listeners, #api_req{data=#{room_id:=RoomId}}, State) ->
    case nkcollab_room:get_listeners(RoomId) of
        {ok, Data} ->
            {ok, Data, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(get_user_sessions, #api_req{data=#{room_id:=RoomId}, session_id=ConnId}, State) ->
    case nkcollab_room:get_user_sessions(RoomId, ConnId) of
        {ok, _User, Data} ->
            {ok, Data, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(get_user_all_sessions, #api_req{data=#{room_id:=RoomId}, user_id=UserId}, State) ->
    case nkcollab_room:get_user_all_sessions(RoomId, UserId) of
        {ok, Data} ->
            {ok, Data, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(add_publish_session, Req, State) ->
    #api_req{
        data = #{room_id:=RoomId}=Data, 
        user_id = MemberId, 
        session_id = ConnId
    } = Req,
    Data2 = Data#{register => {nkcollab_api, self()}},
    case nkcollab_room:add_publish_session(RoomId, MemberId, ConnId, Data2) of
        {ok, SessId, Pid} ->
            nkservice_api_server:register(self(), {nkcollab_room, RoomId, Pid}),
            session_reply(SessId, Data, State);
        {error, Error} ->
            {error, Error, State}
    end;

cmd(add_listen_session, Req, State) ->
    #api_req{
        data = #{room_id:=RoomId, publisher_id:=PubId} = Data, 
        user_id = MemberId, 
        session_id = ConnId
    } = Req,
    Data2 = Data#{register => {nkcollab_api, self()}},
    case nkcollab_room:add_listen_session(RoomId, MemberId, ConnId, PubId, Data2) of
        {ok, SessId, Pid} ->
            nkservice_api_server:register(self(), {nkcollab_room, RoomId, Pid}),
            session_reply(SessId, Data, State);
        {error, Error} ->
            {error, Error, State}
    end;

cmd(remove_session, Req, State) ->
    #api_req{data=#{room_id:=RoomId, session_id:=SessId}} = Req,
    case nkcollab_room:remove_session(RoomId, SessId) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(remove_user_sessions, Req, State) ->
    #api_req{data=#{room_id:=RoomId}, session_id=ConnId} = Req,
    case nkcollab_room:remove_user_sessions(RoomId, ConnId) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(remove_user_all_sessions, Req, State) ->
    #api_req{data=#{room_id:=RoomId}, user_id=UserId} = Req,
    case nkcollab_room:remove_user_all_sessions(RoomId, UserId) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(send_msg, ApiReq, State) ->
    #api_req{data=Data, user_id=UserId} = ApiReq,
    #{room_id:=RoomId, msg:=Msg} = Data,
    case nkcollab_room:send_msg(RoomId, UserId, Msg) of
        {ok, MsgId} ->
            {ok, #{msg_id=>MsgId}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(get_all_msgs, #api_req{data=Data}, State) ->
    #{room_id:=RoomId} = Data,
    case nkcollab_room:get_all_msgs(RoomId) of
        {ok, List} ->
            {ok, List, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(add_timelog, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, msg:=Msg} = Data,
    Body = maps:get(body, Data, #{}),
    case nkcollab_room:add_timelog(RoomId, Body#{msg=>Msg}) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(set_answer, Req, State) ->
    nkmedia_session_api:cmd(set_answer, Req, State);

cmd(set_candidate, Req, State) ->
    nkmedia_session_api:cmd(set_candidate, Req, State);

cmd(set_candidate_end, Req, State) ->
    nkmedia_session_api:cmd(set_candidate_end, Req, State);

cmd(update_media, Req, State) ->
    nkmedia_session_api:cmd(update_media, Req, State);

cmd(update_status, Req, State) ->
    nkmedia_session_api:cmd(update_status, Req, State);

cmd(_Cmd, _Data, _State) ->
    continue.



%% ===================================================================
%% API server callbacks
%% ===================================================================

%% @private Sent by the room when it is stopping
%% We sent a message to the API session to remove the reg before 
%% it receives the DOWN.
api_room_stopped(RoomId, ApiPid, _Reason, _Room) ->
    nkservice_api_server:unregister(ApiPid, {nkcollab_room, RoomId, self()}),
    unsubscribe(RoomId, ApiPid).


%% @private The API server detected room has fallen
api_room_down(RoomId, Reason, State) ->
    #{srv_id:=SrvId} = State,
    lager:warning("API Server: Collab Room ~s is down: ~p", [RoomId, Reason]),
    nkcollab_room_api_events:event_room_down(SrvId, RoomId),
    unsubscribe(RoomId, self()).



%% ===================================================================
%% Internal
%% ===================================================================

unsubscribe(RoomId, ConnId) ->
    Fun = fun(#event{class=Class, subclass=Sub, obj_id=ObjId}) ->
        to_bin(Class) == <<"nkcollab">> andalso
        to_bin(Sub) == <<"room">> andalso
        ObjId == RoomId 
    end,
    nkservice_api_server:unsubscribe_fun(ConnId, Fun).


%% @private
session_reply(SessId, Config, State) ->
    case Config of
        #{offer:=_} -> 
            case nkmedia_session:get_answer(SessId) of
                {ok, Answer} ->
                    {ok, #{session_id=>SessId, answer=>Answer}, State};
                {error, Error} ->
                    {error, Error, State}
            end;
        _ -> 
            case nkmedia_session:get_offer(SessId) of
                {ok, Offer} ->
                    {ok, #{session_id=>SessId, offer=>Offer}, State};
                {error, Error} ->
                    {error, Error, State}
            end
    end.

to_bin(Term) -> nklib_util:to_binary(Term).

