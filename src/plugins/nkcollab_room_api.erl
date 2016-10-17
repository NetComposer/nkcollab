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
    Ids = [#{room_id=>Id, class=>Class} || {Id, Class, _Pid} <- nkcollab_room:get_all()],
    {ok, Ids, State};

cmd(<<"get_info">>, #api_req{data=#{room_id:=RoomId}}, State) ->
    case nkcollab_room:get_info(RoomId) of
        {ok, Info} ->
            {ok, Info, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"add_member">>, Req, State) ->
    #api_req{srv_id=SrvId, data=Data, user=User, session=UserSession} = Req,
    #{room_id:=RoomId, role:=Role} = Data,
    Config = Data#{
        register => {nkmedia_api, self()},
        user_id => User,
        user_session => UserSession
    },
    case nkcollab_room:add_member(RoomId, Role, Config) of
        {ok, MemberId, Pid} ->
            nkservice_api_server:register(self(), {nkcollab_room, RoomId, Pid}),
            RegId = session_reg_id(SrvId, <<"*">>, MemberId),
            Body = maps:get(events_body, Data, #{}),
            nkservice_api_server:register_events(self(), RegId, Body),
            case get_create_reply(MemberId, Config) of
                {ok, Reply} ->
                    {ok, Reply, State};
                {error, Error} ->
                    nkmedia_room:remove_member(MemberId, Error),
                    {error, Error, State}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"remove_member">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, member_id:=MemberId} = Data,
    case nkcollab_room:remove_member(RoomId, MemberId) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"set_answer">>, #api_req{data=Data}, State) ->
    #{answer:=Answer, room_id:=RoomId, member_id:=MemberId} = Data,
    case nkcollab_room:set_answer(RoomId, MemberId, Answer) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"get_answer">>, #api_req{data=#{room_id:=RoomId, member_id:=MemberId}}, State) ->
    case nkcollab_room:get_answer(RoomId, MemberId) of
        {ok, Answer} ->
            {ok, #{answer=>Answer}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(Cmd, #api_req{data=Data}, State)
        when Cmd == <<"update_media">>; 
             Cmd == <<"recorder_action">>; 
             Cmd == <<"player_action">>; 
             Cmd == <<"room_action">> ->
    #{room_id:=RoomId, member_id:=MemberId} = Data,
    Cmd2 = binary_to_atom(Cmd, latin1),
    case nkcollab_room:member_cmd(RoomId, MemberId, Cmd2, Data) of
        {ok, Reply} ->
            {ok, Reply, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"set_candidate">>, #api_req{data=Data}, State) ->
    #{
        room_id := RoomId,
        member_id := MemberId, 
        sdpMid := Id, 
        sdpMLineIndex := Index, 
        candidate := ALine
    } = Data,
    Candidate = #candidate{m_id=Id, m_index=Index, a_line=ALine},
    case nkcollab_room:candidate(RoomId, MemberId, Candidate) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"set_candidate_end">>, #api_req{data=Data}, State) ->
    #{room_id:=RoomId, member_id := MemberId} = Data,
    Candidate = #candidate{last=true},
    case nkcollab_room:candidate(RoomId, MemberId, Candidate) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"send_msg">>, ApiReq, State) ->
    #api_req{data=Data, user=User, session=MemberId} = ApiReq,
    #{room_id:=RoomId, msg:=Msg} = Data,
    RoomMsg = Msg#{user_id=>User, member_id=>MemberId},
    case nkcollab_room:send_msg(RoomId, RoomMsg) of
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
%% Internal
%% ===================================================================

%% @private
get_create_reply(MemberId, Config) ->
    case maps:get(wait_reply, Config, false) of
        false ->
            {ok, #{member_id=>MemberId}};
        true ->
            case Config of
                #{offer:=_, answer:=_} -> 
                    {ok, #{member_id=>MemberId}};
                #{offer:=_} -> 
                    case nkmedia_session:get_answer(MemberId) of
                        {ok, Answer} ->
                            {ok, #{member_id=>MemberId, answer=>Answer}};
                        {error, Error} ->
                            {error, Error}
                    end;
                _ -> 
                    case nkmedia_session:get_offer(MemberId) of
                        {ok, Offer} ->
                            {ok, #{member_id=>MemberId, offer=>Offer}};
                        {error, Error} ->
                            {error, Error}
                    end
            end
    end.


%% @private
session_reg_id(SrvId, Type, MemberId) ->
    #reg_id{
        srv_id = SrvId, 
        class = <<"media">>, 
        subclass = <<"session">>,
        type = nklib_util:to_binary(Type),
        obj_id = MemberId
    }.



