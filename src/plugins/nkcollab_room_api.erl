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
-export([room_stopped/3, api_room_down/3]).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


%% ===================================================================
%% Commands
%% ===================================================================


cmd(<<"create">>, #api_req{srv_id=SrvId, data=Data}, State) ->
    case nkcollab_room:start(SrvId, Data) of
        {ok, Id, _Pid} ->
            {ok, #{room_id=>Id}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"destroy">>, #api_req{data=#{room_id:=Id}}, State) ->
    case nkcollab_room:stop(Id, api_stop) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"get_list">>, _Req, State) ->
    Ids = [#{room_id=>Id} || {Id, _Pid} <- nkcollab_room:get_all()],
    {ok, Ids, State};

cmd(<<"get_info">>, #api_req{data=#{room_id:=RoomId}}, State) ->
    case nkcollab_room:get_info(RoomId) of
        {ok, Info} ->
            {ok, Info, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"create_member">>, Req, State) ->
    #api_req{srv_id=SrvId, data=Data, user=User, session=UserSession} = Req,
    #{room_id:=RoomId} = Data,
    Config = Data#{
        register => {nkmedia_api, self()},
        user_id => User,
        user_session => UserSession
    },
    Role = maps:get(role, Data, presenter),
    case nkcollab_room:create_member(RoomId, Role, Config) of
        {ok, MemberId, SessId, Pid} ->
            nkservice_api_server:register(self(), {nkcollab_room, RoomId, Pid}),
            RegId = room_reg_id(SrvId, <<"*">>, MemberId),
            Body = maps:get(events_body, Data, #{}),
            nkservice_api_server:register_events(self(), RegId, Body),
            case session_reply(SessId, Data) of
                {ok, Reply} ->
                    {ok, Reply#{member_id=>MemberId}, State};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"destroy_member">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, member_id:=MemberId} = Data,
    case nkcollab_room:destroy_member(RoomId, MemberId) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"update_presenter">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, member_id:=MemberId} = Data,
    case nkcollab_room:update_presenter(RoomId, MemberId, Data) of
        {ok, SessId} ->
            case session_reply(SessId, Data) of
                {ok, Reply} ->
                    {ok, Reply, State};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"add_viewer">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, member_id:=MemberId, presenter_id:=PresenterId} = Data,
    case nkcollab_room:add_viewer(RoomId, MemberId, PresenterId, Data) of
        {ok, SessId} ->
            case session_reply(SessId, Data) of
                {ok, Reply} ->
                    {ok, Reply, State};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"remove_viewer">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, member_id:=MemberId, presenter_id:=PresenterId} = Data,
    case nkcollab_room:remove_viewer(RoomId, MemberId, PresenterId) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"update_meta">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, member_id:=MemberId, meta:=Meta} = Data,
    case nkcollab_room:update_meta(RoomId, MemberId, Meta) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"update_media">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, member_id:=MemberId} = Data,
    case nkcollab_room:update_media(RoomId, MemberId, Data) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"set_answer">>, Req, State) ->
    nkmedia_api:cmd(<<"set_answer">>, Req, State);

cmd(<<"get_answer">>, Req, State) ->
    nkmedia_api:cmd(<<"get_answer">>, Req, State);

cmd(<<"set_candidate">>, Req, State) ->
    nkmedia_api:cmd(<<"set_candidate">>, Req, State);

cmd(<<"set_candidate_end">>, Req, State) ->
    nkmedia_api:cmd(<<"set_candidate_end">>, Req, State);

cmd(<<"send_broadcast">>, ApiReq, State) ->
    #api_req{data=Data, user=User, session=MemberId} = ApiReq,
    #{room_id:=RoomId, msg:=Msg} = Data,
    RoomMsg = Msg#{user_id=>User, member_id=>MemberId},
    case nkcollab_room:broadcast(RoomId, RoomMsg) of
        {ok, #{msg_id:=MsgId}} ->
            {ok, #{msg_id=>MsgId}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"get_all_msgs">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId} = Data,
    case nkcollab_room:get_msgs(RoomId, #{}) of
        {ok, List} ->
            {ok, List, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(_Cmd, _Data, _State) ->
    continue.



%% ===================================================================
%% Room callbacks
%% ===================================================================

room_stopped(RoomId, Pid, Room) ->
    #{srv_id:=SrvId} = Room,
    RegId = room_reg_id(SrvId, <<"*">>, RoomId),
    nkservice_api_server:unregister_events(Pid, RegId),
    nkservice_api_server:unregister(Pid, {nkcollab_room, RoomId, self()}),
    {ok, Room}.


%% ===================================================================
%% API server callbacks
%% ===================================================================

%% @private Called when the API server detects room has fallen

api_room_down(RoomId, Reason, State) ->
    #{srv_id:=SrvId} = State,
    lager:warning("API Server: Collab Room ~s is down: ~p", [RoomId, Reason]),
    RegId = room_reg_id(SrvId, <<"*">>, RoomId),
    nkservice_api_server:unregister_events(self(), RegId),
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
room_reg_id(SrvId, Type, MemberId) ->
    #reg_id{
        srv_id = SrvId, 
        class = <<"collab">>, 
        subclass = <<"room">>,
        type = nklib_util:to_binary(Type),
        obj_id = MemberId
    }.



