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

%% @doc Room Plugin
-module(nkcollab_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, stop/2]).
-export([get_room/1, get_publish_sessions/1, get_all_sessions/1]).
-export([add_publish_session/4, add_listen_session/5, remove_session/2]).
-export([remove_member/2, remove_member_conn/3, get_member_sessions/2]).
-export([update_publish_session/3, update_meta/3, update_session/3]).
-export([send_room_info/2, send_session_info/3, send_member_info/3]).
-export([broadcast/3, get_all_msgs/1]).
-export([register/2, unregister/2, get_all/0]).
-export([media_session_event/3, media_room_event/2]).
-export([find/1, do_call/2, do_call/3, do_cast/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, room/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkCOLLAB Room ~s (~p) "++Txt, 
               [State#state.id, State#state.backend | Args])).

-include("nkcollab_room.hrl").



%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type session_id() :: nkmedia_session:id().

-type member_id() :: binary().

-type conn_id() :: binary().

-type meta() :: map().


-type config() ::
    #{
        backend => atom(),
        audio_codec => opus | isac32 | isac16 | pcmu | pcma,    
        video_codec => vp8 | vp9 | h264,                        
        bitrate => integer(),                                   
        meta => meta(),
        register => nklib:link()
    }.


-type room() ::
    config() |
    #{
        room_id => id(),
        srv_id => nkservice:id(),
        members => #{member_id() => member_info()},
        sessions => #{session_id() => session_data()},
        status => map()
    }.


-type member_info() :: 
    #{
        sessions => #{conn_id() => [session_id()]}
    }.


-type session_config() ::
    #{
        offer => nkmedia:offer(),
        no_offer_trickle_ice => boolean(),          % Buffer candidates and insert in SDP
        no_answer_trickle_ice => boolean(),       
        trickle_ice_timeout => integer(),
        sdp_type => webrtc | rtp,
        register => nklib:link(),
        member => nkservice:user_id(),                
        member_conn_id => nkservice:user_session(),   

        mute_audio => boolean(),
        mute_video => boolean(),
        mute_data => boolean(),
        bitrate => integer(),

        type => binary(),
        device => binary(),
        meta => map()
    }.


-type session_data() ::
    #{
        class => publish | listen,
        type => atom() | binary(),
        device => atom() | binary(),
        bitrate => integer(),
        started_time => nklib_util:l_timestamp(),
        stopped_time => nklib_util:l_timestamp(),
        meta => map(),
        announce => map(),
        member_id => member_id(),
        member_conn_id => conn_id(),
        publisher_id => session_id()
    }.


-type media_opts() ::
    #{
        mute_audio => boolean(),
        mute_video => boolean(),
        mute_data => boolean(),
        bitrate => integer()
    }.


-type event() :: 
    created                                         |
    {started_session, session_data()}               |
    {stopped_session, session_data()}               |
    {room_info, map()}                              |
    {member_info, member_id(), map()}               |
    {session_info, member_id(), session_id, map()}  |
    {broadcast, msg()}                              |
    {stopped, nkservice:error()}                    |
    destroyed.

-type msg_id() :: integer().


-type msg() ::
    #{
        msg_id => msg_id(),
        user_id => binary(),
        session_id => binary(),
        timestamp => nklib_util:l_timestamp(),
        body => map()
    }.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Creates a new room
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()} | {error, term()}.

start(Srv, Config) ->
    {RoomId, Config2} = nkmedia_util:add_id(room_id, Config, room),
    case find(RoomId) of
        {ok, _} ->
            {error, room_already_exists};
        not_found ->
            case nkmedia_room:start(Srv, Config2#{class=>sfu}) of
                {ok, RoomId, RoomPid} ->
                    {ok, BaseRoom} = nkmedia_room:get_room(RoomPid),
                    BaseRoom2 = maps:with([srv_id, backend], BaseRoom),
                    Config3 = maps:merge(Config2, BaseRoom2),
                    {ok, Pid} = gen_server:start(?MODULE, [Config3, RoomPid], []),
                    {ok, RoomId, Pid};
                {error, Error} ->
                    {error, Error}
            end
    end.


%% @doc
-spec stop(id()) ->
    ok | {error, term()}.

stop(Id) ->
    stop(Id, user_stop).


%% @doc
-spec stop(id(), nkservice:error()) ->
    ok | {error, term()}.

stop(Id, Reason) ->
    do_cast(Id, {stop, Reason}).


%% @doc
-spec get_room(id()) ->
    {ok, room()} | {error, term()}.

get_room(Id) ->
    do_call(Id, get_room).


%% @doc
-spec get_publish_sessions(id()) ->
    {ok, [session_data()]} | {error, term()}.

get_publish_sessions(Id) ->
    do_call(Id, get_publish_sessions).


%% @doc
-spec get_all_sessions(id()) ->
    {ok, [session_data()]} | {error, term()}.

get_all_sessions(Id) ->
    do_call(Id, get_all_sessions).


%% @doc 
-spec add_publish_session(id(), member_id(), conn_id(), session_config()) ->
    {ok, session_id(), pid()} | {error, term()}.

add_publish_session(Id, MemberId, ConnId, SessConfig) ->
    do_call(Id, {add_session, publish, MemberId, ConnId, SessConfig}).


%% @doc 
-spec add_listen_session(id(), member_id(), conn_id(), session_id(), session_config()) ->
    {ok, session_id(), pid()} | {error, term()}.

add_listen_session(Id, MemberId, ConnId, SessId, SessConfig) ->
    do_call(Id, {add_session, {listen, SessId}, MemberId, ConnId, SessConfig}).


%% Changes presenter's sessions and updates all viewers
-spec update_publish_session(id(), session_id(), session_config()) ->
    {ok, session_id()} | {error, term()}.

update_publish_session(Id, SessId, SessConfig) ->
    do_call(Id, {update_publish_session, SessId, SessConfig}).


%% Removes a session
-spec remove_session(id(), session_id()) ->
    ok | {error, term()}.

remove_session(Id, SessId) ->
    do_call(Id, {remove_session, SessId}).


%% @doc 
-spec remove_member(id(), member_id()) ->
    ok | {error, term()}.

remove_member(Id, MemberId) ->
    do_call(Id, {remove_member, MemberId}).


%% @doc 
-spec remove_member_conn(id(), member_id(), conn_id()) ->
    ok | {error, term()}.

remove_member_conn(Id, MemberId, ConnId) ->
    do_call(Id, {remove_member_conn, MemberId, ConnId}).


%% @private
-spec update_meta(id(), session_id(), meta()) ->
    ok | {error, term()}.

update_meta(Id, SessId, Meta) ->
    do_call(Id, {update_meta, SessId, Meta}).


%% @private
-spec update_session(id(), session_id(), media_opts()) ->
    ok | {error, term()}.

update_session(Id, SessId, Media) ->
    do_call(Id, {update_session, SessId, Media}).


%% @private
-spec get_member_sessions(id(), member_id()) ->
    ok | {error, term()}.

get_member_sessions(Id, MemberId) ->
    do_call(Id, {get_member_sessions, MemberId}).


%% @private
-spec broadcast(id(), member_id(), msg()) ->
    {ok, msg_id()} | {error, term()}.

broadcast(Id, MemberId, Msg) when is_map(Msg) ->
    do_call(Id, {broadcast, MemberId, Msg}).


%% @private
-spec send_room_info(id(), map()) ->
    ok | {error, term()}.

send_room_info(Id, Data) when is_map(Data) ->
    do_cast(Id, {send_room_info, Data}).


%% @private
-spec send_session_info(id(), session_id(), map()) ->
    ok | {error, term()}.

send_session_info(Id, SessId, Data) when is_map(Data) ->
    do_cast(Id, {send_session_info, SessId, Data}).


%% @private
-spec send_member_info(id(), member_id(), map()) ->
    ok | {error, term()}.

send_member_info(Id, MemberId, Data) when is_map(Data) ->
    do_cast(Id, {send_member_info, MemberId, Data}).


%% @private
-spec get_all_msgs(id()) ->
    {ok, [msg()]} | {error, term()}.

get_all_msgs(Id) ->
    do_call(Id, get_all_msgs).


%% @doc Registers a process with the room
-spec register(id(), nklib:link()) ->     
    {ok, pid()} | {error, nkservice:error()}.

register(RoomId, Link) ->
    case find(RoomId) of
        {ok, Pid} -> 
            do_cast(RoomId, {register, Link}),
            {ok, Pid};
        not_found ->
            {error, room_not_found}
    end.


%% @doc Registers a process with the call
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkservice:error()}.

unregister(RoomId, Link) ->
    do_cast(RoomId, {unregister, Link}).


%% @doc Gets all started rooms
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).
    

%% @private Called from nkcollab_room_callbacks for session events
-spec media_session_event(id(), session_id(), nkmedia_session:event()) ->
    ok | {error, nkservice:error()}.

media_session_event(RoomId, SessId, {status, Class, Data}) ->
    send_session_info(RoomId, SessId, Data#{class=>Class});

media_session_event(_RoomId, _SessId, _Event) ->
    ok.


%% @private Called from nkcollab_room_callbacks for base room's events
-spec media_room_event(id(), nkmedia_room:event()) ->
    ok | {error, nkservice:error()}.

media_room_event(RoomId, {status, Class, Data}) ->
    lager:error("ROOM INFO: ~p, ~p", [Class, Data]),
    send_room_info(RoomId, Data#{class=>Class});

media_room_event(RoomId, {stopped, Reason}) ->
    stop(RoomId, Reason);

media_room_event(_RoomId, _Event) ->
    ok.


% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    backend :: nkcollab:backend(),
    stop_reason = false :: false | nkservice:error(),
    links :: nklib_links:links(),
    msg_pos = 1 :: integer(),
    msgs :: orddict:orddict(),
    room :: room()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{room_id:=RoomId, srv_id:=SrvId, backend:=Backend}=Room, BasePid]) ->
    true = nklib_proc:reg({?MODULE, RoomId}),
    nklib_proc:put(?MODULE, RoomId),
    {ok, BasePid} = nkmedia_room:register(RoomId, {nkcollab_room, BasePid, self()}),
    State1 = #state{
        id = RoomId, 
        srv_id = SrvId, 
        backend = Backend,
        links = nklib_links:new(),
        msgs = orddict:new(),
        room = Room#{members=>#{}, sessions=>#{}}
    },
    State2 = links_add(nkmedia_room, none, BasePid, State1),
    State3 = case Room of
        #{register:=Link} ->
            links_add(Link, reg, State2);
        _ ->
            State2
    end,
    ?LLOG(notice, "started", [], State3),
    State4 = do_event(created, State3),
    {ok, State4}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({add_session, Type, MemberId, ConnId, Config}, _From, State) ->
    restart_timer(State),
    case add_session(Type, MemberId, ConnId, Config, State) of
        {ok, SessId, State2} ->
            State3 = case Config of
                #{register:=Link} ->
                    links_add(Link, {member, SessId}, State2);
                _ ->
                    State2
            end,
            {reply, {ok, SessId, self()}, State3};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call({get_member_sessions, MemberId}, _From, State) ->
    SessIds = get_member_all_sessions(MemberId, all, State),
    {reply, {ok, SessIds}, State};

handle_call({remove_session, SessId}, _From, State) ->
    State2 = remove_sessions([SessId], State),
    {reply, ok, State2};

handle_call({remove_member, MemberId}, _From, State) ->
    restart_timer(State),
    SessIds = get_member_all_sessions(MemberId, all, State),
    State2 = remove_sessions(SessIds, State),
    {reply, {ok, SessIds}, State2};

handle_call({remove_member_conn, MemberId, ConnId}, _From, State) ->
    restart_timer(State),
    SessIds = get_member_all_sessions(MemberId, ConnId, State),
    State2 = remove_sessions(SessIds, State),
    {reply, {ok, SessIds}, State2};




% handle_call({update_publisher, MemberId, Config}, _From, State) ->
%     restart_timer(State),
%     case get_info(MemberId, State) of
%         {ok, Info} ->
%             OldSessId = maps:get(publish_session_id, Info, undefined),
%             case add_session(publish, MemberId, Config, Info, State) of
%                 {ok, SessId, _Info2, State2} ->
%                     Self = self(),
%                     spawn_link(
%                         fun() ->
%                             timer:sleep(500),
%                             gen_server:cast(Self,
%                                             {switch_all_listeners, MemberId, OldSessId})
%                         end),
%                     {reply, {ok, SessId}, State2};
%                 {error, Error} ->
%                     {reply, {error, Error}, State}
%             end;
%         not_found ->
%             {reply, {error, member_not_found}, State}
%     end;


% handle_call({update_meta, MemberId, Meta}, _From, State) -> 
%     case get_info(MemberId, State) of
%         {ok, Info} ->
%             BaseMeta = maps:get(meta, Info, #{}),
%             Meta2 = maps:merge(BaseMeta, Meta),
%             Info2 = Info#{meta=>Meta2},
%             State2 = store_info(MemberId, Info2, State),
%             State3 = do_event({updated_member, MemberId, Info2}, State2),
%             {reply, ok, State3};
%         not_found ->
%             {reply, {error, member_not_found}, State}
%     end;

% handle_call({update_media, MemberId, Media}, _From, State) -> 
%     case do_update_media(MemberId, Media, State) of
%         {ok, State2} ->
%             {reply, ok, State2};
%         {error, Error} ->
%             {reply, {error, Error}, State}
%     end;

% handle_call({update_all_media, Media}, _From, #state{room=Room}=State) -> 
%     #{members:=Members} = Room,
%     State2 = lists:foldl(
%         fun(MemberId, Acc) ->
%             case do_update_media(MemberId, Media, Acc) of
%                 {ok, Acc2} -> Acc2;
%                 _ -> Acc
%             end
%         end,
%         State,
%         maps:keys(Members)),
%     {reply, ok, State2};

% handle_cast({switch_all_listeners, MemberId, OldSessId}, State) ->
%     case get_info(MemberId, State) of
%         {ok, #{publish_session_id:=NewSessId}} ->
%             State2 = switch_all_listeners(MemberId, NewSessId, State),
%             State3 = case OldSessId of
%                 undefined ->
%                     State2;
%                 _ ->
%                     % stop_sessions(MemberId, [OldSessId], State2);
%                     State2
%             end,
%             {noreply, State3};
%         _ ->
%             ?LLOG(warning, "received switch_all_listeners for invalid publisher", 
%                   [], State),
%             {noreply, State}
%     end;


handle_call(get_room, _From, #state{room=Room}=State) -> 
    {reply, {ok, Room}, State};

handle_call(get_publish_sessions, _From, #state{room=Room}=State) -> 
    #{sessions:=Sessions} = Room,
    Data = lists:filtermap(
        fun
            ({_SessId, #{stopped_time:=_}}) ->
                false;
            ({_SessId, #{class:=publish}=Session}) ->
                {true, Session};
            ({_SessId, _Session}) ->
                false
        end,
        maps:to_list(Sessions)),
    {reply, {ok, Data}, State};

handle_call(get_all_sessions, _From, #state{room=Room}=State) -> 
    #{sessions:=Sessions} = Room,
    {reply, {ok, maps:to_list(Sessions)}, State};

handle_call({broadcast, MemberId, Msg}, _From, #state{msg_pos=Pos, msgs=Msgs}=State) ->
    restart_timer(State),
    case do_find_member(MemberId, State) of
        {ok, _} -> 
            Msg2 = Msg#{msg_id => Pos, member_id=>MemberId},
            State2 = State#state{
                msg_pos = Pos+1, 
                msgs = orddict:store(Pos, Msg2, Msgs)
            },
            State3 = do_event({broadcast, Msg2}, State2),
            {reply, {ok, Pos}, State3};
        error ->
            {reply, {error, member_not_found}, State}
    end;

handle_call(get_all_msgs, _From, #state{msgs=Msgs}=State) ->
    restart_timer(State),
    Reply = [Msg || {_Id, Msg} <- orddict:to_list(Msgs)],
    {reply, {ok, Reply}, State};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) -> 
    handle(nkcollab_room_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

%% @private
handle_cast({send_room_info, Data}, State) ->
    {noreply, do_event({room_info, Data}, State)};

handle_cast({send_member_info, MemberId, Data}, State) ->
    case do_find_member(MemberId, State) of
        {ok, _} ->
            {noreply, do_event({member_info, MemberId, Data}, State)};
        error ->
            {noreply, State}
    end;

handle_cast({send_session_info, SessId, Data}, State) ->
    case do_find_session(SessId, State) of
        {ok, _} ->
            {noreply, do_event({session_info, SessId, Data}, State)};
        _ ->
            {noreply, State}
    end;

handle_cast({register, Link}, State) ->
    ?LLOG(info, "proc registered (~p)", [Link], State),
    State2 = links_add(Link, reg, State),
    {noreply, State2};

handle_cast({unregister, Link}, State) ->
    ?LLOG(info, "proc unregistered (~p)", [Link], State),
    {noreply, links_remove(Link, State)};

handle_cast({set_status, Status}, #state{room=Room}=State) ->
    State2 = restart_timer(State),
    Status2 = maps:get(status, Room),
    State3 = State2#state{room=?ROOM(#{status=>Status2}, Room)},
    {noreply, do_event({status, Status}, State3)};

handle_cast({stop, Reason}, State) ->
    ?LLOG(info, "external stop: ~p", [Reason], State),
    do_stop(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkcollab_room_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, State) ->
    #state{stop_reason=Stop} = State,
    case links_down(Ref, State) of
        {ok, _, _, State2} when Stop /= false ->
            {noreply, State2};
        {ok, nkmedia_room, _, State2} ->
            ?LLOG(warning, "media room down", [], State2),
            do_stop(media_room_down, State2);
        {ok, _Link, {member, SessId}, State2} ->
            case do_find_session(SessId, State2) of
                {ok, #{member_id:=MemberId}} ->
                    ?LLOG(notice, "member ~p down: session ~s stopped", 
                          [MemberId, SessId], State2),
                    State3 = remove_sessions([SessId], State2),
                    {noreply, State3};
                error ->
                    {noreply, State2}
            end;
        {ok, _Link, {session, SessId}, State2} ->
            case do_find_session(SessId, State2) of
                {ok, #{member_id:=MemberId}} ->
                    ?LLOG(notice, "session ~s down (~p)", [SessId, MemberId], State2),
                    State3 = remove_sessions([SessId], State2),
                    {noreply, State3};
                error ->
                    {noreply, State2}
            end;
        {ok, Link, reg, State2} ->
            #state{id=Id} = State2,
            case handle(nkcollab_room_reg_down, [Id, Link, Reason], State2) of
                {ok, State3} ->
                    {noreply, State3};
                {stop, Reason2, State3} ->
                    ?LLOG(notice, "stopping because of reg '~p' down (~p)",
                          [Link, Reason2], State2),
                    do_stop(Reason2, State3)
            end;
        not_found ->
            handle(nkcollab_room_handle_info, [Msg], State)
    end;

handle_info(destroy, State) ->
    {stop, normal, State};

handle_info(Msg, #state{}=State) -> 
    handle(nkcollab_room_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, #state{stop_reason=Stop}=State) ->
    case Stop of
        false ->
            Ref = nklib_util:uid(),
            ?LLOG(notice, "terminate error ~s: ~p", [Ref, Reason], State),
            {noreply, State2} = do_stop({internal_error, Ref}, State);
        _ ->
            State2 = State
    end,
    State3 = do_event(destroyed, State2),
    {ok, _State4} = handle(nkcollab_room_terminate, [Reason], State3),
    ok.


% ===================================================================
%% Internal
%% ===================================================================

%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(#{room_id:=RoomId}) ->
    find(RoomId);

find(Id) ->
    Id2 = nklib_util:to_binary(Id),
    case nklib_proc:values({?MODULE, Id2}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(Id, Msg) ->
    do_call(Id, Msg, 5000).


%% @private
do_call(Id, Msg, Timeout) ->
    case find(Id) of
        {ok, Pid} -> 
            nkservice_util:call(Pid, Msg, Timeout);
        not_found -> 
            {error, room_not_found}
    end.


%% @private
do_cast(Id, Msg) ->
    case find(Id) of
        {ok, Pid} -> 
            gen_server:cast(Pid, Msg);
        not_found -> 
            {error, room_not_found}
    end.


%% @private
-spec add_session(publish|{listen, session_id()}, member_id(), conn_id(), 
                  map(), #state{}) ->
    {ok, session_id(), #state{}} | {error, nkservice:error()}.

add_session(Type, MemberId, ConnId, Config, State) ->
    #state{srv_id=SrvId, id=RoomId, backend=Backend} = State,
    SessConfig1 = maps:with(session_opts(), Config),
    SessConfig2 = SessConfig1#{
        backend => Backend,
        room_id => RoomId,
        register => {nkcollab_room, RoomId, self()}
    },
    SessData1 = maps:with(session_data_keys(), Config),
    SessData2 = SessData1#{
        started => nklib_util:l_timestamp()
    },
    case Type of
        publish ->
            SessType = publish,
            SessConfig3 = SessConfig2,
            SessData3 = SessData2#{class => publish};
        {listen, PubId} ->
            SessType = listen,
            SessConfig3 = SessConfig2#{publisher_id => PubId},
            SessData3 = SessData2#{class => listen, publisher_id => PubId}
    end,
    case nkmedia_session:start(SrvId, SessType, SessConfig3) of
        {ok, SessId, Pid} ->
            State2 = links_add(SessId, {session, MemberId}, Pid, State),
            {ok, State3} = do_event({started_session, SessData3}, State2),
            State4 = do_update_session(SessId, SessData3, State3),
            State5 = do_member_add_session(MemberId, ConnId, SessId, State4),
            {ok, SessId, State5};
        {error, Error} ->
            {error, Error}
    end.


%% @private
remove_sessions([], State) ->
    State;

remove_sessions([SessId|Rest], State) ->
    nkmedia_session:stop(SessId, member_stop),
    State2 = case do_find_session(SessId, State) of
        {ok, Session} ->            
            do_remove_session(SessId, Session, State);
        error ->
            State
    end,
    remove_sessions(Rest, State2).


%% @private
do_remove_session(SessId, Session, State) ->
    #{member_id:=MemberId, member_conn_id:=ConnId} = Session,
    State2 = links_remove(SessId, State),
    Session2 = Session#{stopped_time=>nklib_util:l_timestamp()},
    State3 = do_update_session(SessId, Session2, State2),
    State4 = do_event({stopped_session, Session2}, State3),
    do_member_remove_session(MemberId, ConnId, SessId, State4).


% %% @private
% do_remove_member_conns(_MemberId, [], Acc, State) ->
%     {ok, Acc, State};

% do_remove_member_conns(MemberId, [ConnId|Rest], Acc,State) ->
%     case do_find_member(MemberId, State) of
%         error ->
%             do_remove_member_conns(MemberId, Rest, Acc, State);
%         {ok, #{session:=Sessions}=MemberInfo} ->
%             case maps:find(ConnId, Sessions) of
%                 {ok, SessIds} ->
%                     State2 = remove_sessions(SessIds, State),
%                     Sessions2 = maps:remove(ConnId, Sessions),
%                     MemberInfo2 = case map_size(Sessions2) of
%                         0 -> delete;
%                         _ -> MemberInfo#{sessions:=Sessions2}
%                     end,
%                     State3 = do_update_member(MemberId, MemberInfo2, State2),
%                     do_remove_member_conns(MemberId, Rest, SessIds++Acc, State3);
%                 error ->
%                     do_remove_member_conns(MemberId, Rest, Acc, State)
%             end
%     end.




% %% @private
% switch_all_listeners(PresenterId, PublishId, #state{room=Room}=State) ->
%     #{members:=Members} = Room,
%     switch_all_listeners(maps:to_list(Members), PresenterId, PublishId, State).


% %% @private
% switch_all_listeners([], _PresenterId, _PublishId, State) ->
%     State;

% switch_all_listeners([{_MemberId, Info}|Rest], PresenterId, PublishId, State) ->
%     State2 = case has_this_presenter(Info, PresenterId) of
%         {true, SessId} ->
%             switch_listener(SessId, PublishId),
%             State;
%         false ->
%             State
%     end,
%     switch_all_listeners(Rest, PresenterId, PublishId, State2).


%% @private
%% @private
do_stop(Reason, #state{stop_reason=false, id=Id, room=Room}=State) ->
    ?LLOG(notice, "stopped: ~p", [Reason], State),
    #{sessions:=Sessions} = Room,
    State2 = remove_sessions(maps:keys(Sessions), State),
    case nkmedia_room:stop(Id) of
        ok -> ok;
        Other -> ?LLOG(warning, "error stopping base room: ~p", [Other], State)
    end,
    % Give time for possible registrations to success and capture stop event
    timer:sleep(100),
    State3 = do_event({stopped, Reason}, State2),
    {ok, State4} = handle(nkcollab_room_stop, [Reason], State3),
    erlang:send_after(5000, self(), destroy),
    {noreply, State4#state{stop_reason=Reason}};

do_stop(_Reason, State) ->
    % destroy already sent
    {noreply, State}.


%% @private
do_event(Event, #state{id=Id}=State) ->
    ?LLOG(info, "sending 'event': ~p", [Event], State),
    State2 = do_event_regs(Event, State),
    State3 = do_event_members(Event, State2),
    {ok, State4} = handle(nkcollab_room_event, [Id, Event], State3),
    State4.


%% @private
do_event_regs(Event, #state{id=Id}=State) ->
    links_fold(
        fun(Link, reg, Acc) ->
            {ok, Acc2} = 
                handle(nkcollab_room_reg_event, [Id, Link, Event], Acc),
                Acc2;
            (_Link, _Data, Acc) ->
                Acc
        end,
        State,
        State).


%% @private
do_event_members(Event, #state{id=Id}=State) ->
    links_fold(
        fun(Link, {member, MemberId}, Acc) ->
            {ok, Acc2} = 
                handle(nkcollab_room_member_event, [Id, Link, MemberId, Event], Acc),
                Acc2;
            (_Link, _Data, Acc) ->
                Acc
        end,
        State,
        State).



% %% @private
% do_update_media(MemberId, Media, State) ->
%     case get_info(MemberId, State) of
%         {ok, #{publish_session_id:=SessId}} ->
%             case nkmedia_session:cmd(SessId, update_media, Media) of
%                 {ok, _} ->
%                     {ok, do_event({updated_media, MemberId, Media}, State)};
%                 {error, Error} ->
%                     {error, Error}
%             end;
%         {ok, _} ->
%             {error, member_is_not_publisher};
%         _ ->
%             {error, member_not_found}
%     end.


% %% @private Get presenter's publishing session
% -spec get_info(member_id(), #state{}) ->
%     {ok, nkmedia_session:id()} | not_found.

% get_info(MemberId, #state{room=Room}) ->
%     Members = maps:get(members, Room),
%     case maps:find(MemberId, Members) of
%         {ok, Info} -> 
%             {ok, Info};
%         error -> 
%             not_found
%     end.



% %% @private Get presenter's publishing session
% -spec get_publisher(member_id(), #state{}) ->
%     {ok, nkmedia_session:id()} | no_publisher | not_presenter.

% get_publisher(PresenterId, State) ->
%     case get_info(PresenterId, State) of
%         {ok, #{publish_session_id:=SessId}} ->
%             {ok, SessId};
%         {ok, _} ->
%             not_presenter;
%         not_found ->
%             not_found
%     end.

% %% @private
% store_info(MemberId, Info, #state{room=Room}=State) ->
%     #{members:=Members1} = Room,
%     Members2 = maps:put(MemberId, Info, Members1),
%     State#state{room=?ROOM(#{members=>Members2}, Room)}.


% %% @private
% has_this_presenter(#{listen_session_ids:=Ids}, PresenterId) ->
%     case lists:keyfind(PresenterId, 2, maps:to_list(Ids)) of
%         {SessId, PresenterId} ->
%             {true, SessId};
%         false ->
%             false
%     end;

% has_this_presenter(_Info, _PresenterId) ->
%     false.


% %% @private
% switch_listener(SessId, PublishId) ->
%     lager:error("SWITCH: ~p -> ~p", [SessId, PublishId]),
%     nkmedia_session:cmd(SessId, set_type, #{type=>listen, publisher_id=>PublishId}).


%% @private
do_find_member(MemberId, #state{room=#{members:=Members}}) ->
    maps:find(MemberId, Members).
        

%% @private
do_update_member(MemberId, delete, #state{room=#{members:=Members}=Room}=State) ->
    Members2 = maps:remove(MemberId, Members),
    State#state{room=?ROOM(#{members=>Members2}, Room)};

do_update_member(MemberId, MemberInfo, #state{room=#{members:=Members}=Room}=State) ->
    Members2 = maps:put(MemberId, MemberInfo, Members),
    State#state{room=?ROOM(#{members=>Members2}, Room)}.


%% @private
do_member_add_session(MemberId, ConnId, SessId, State) ->
    case do_find_member(MemberId, State) of
        {ok, MemberInfo} -> ok;
        error -> MemberInfo = #{}
    end,
    MemberSessions = maps:get(sessions, MemberInfo, #{}),
    MemberSessionIds = [SessId|maps:get(ConnId, MemberSessions, [])],
    MemberInfo2 = maps:put(ConnId, MemberSessions, MemberSessionIds),
    do_update_member(MemberId, MemberInfo2, State).


%% @private
do_member_remove_session(MemberId, ConnId, SessId, State) ->
    case do_find_member(MemberId, State) of
        {ok, #{sessions:=Sessions}=MemberInfo} ->
            case maps:find(ConnId, Sessions) of
                {ok, SessIds} ->
                    MemberInfo2 = case SessIds -- [SessId] of
                        [] ->
                            Sessions2 = maps:remove(ConnId, Sessions),
                            case map_size(Sessions2) of
                                0 -> delete;
                                _ -> MemberInfo#{sessions:=Sessions2}
                            end;
                        SessIds2 ->
                            Sessions2 = maps:put(ConnId, SessIds2, Sessions),
                            MemberInfo#{sessions:=Sessions2}
                    end,
                    do_update_member(MemberId, MemberInfo2, State);
                error ->
                    State
            end;
        error ->
            State
    end.


%% @private
get_member_all_sessions(MemberId, ConnId, State) ->
    case do_find_member(MemberId, State) of
        error ->
            [];
        {ok, #{session:=Sessions}} when ConnId==all ->
            lists:flatten(maps:values(Sessions));
        {ok, #{session:=Sessions}} ->
            maps:get(ConnId, Sessions)
    end.



%% @private
do_find_session(SessId, #state{room=#{sessions:=Sessions}}) ->
    maps:find(SessId, Sessions).
        

%% @private
do_update_session(SessId, Session, #state{room=#{sessions:=Sessions}=Room}=State) ->
    Sessions2 = maps:put(SessId, Session#{session_id=>SessId}, Sessions),
    State#state{room=?ROOM(#{sessions=>Sessions2}, Room)}.




%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.room).


%% @private
links_add(Id, Data, State) ->
    Pid = nklib_links:get_pid(Id),
    links_add(Id, Data, Pid, State).


%% @private
links_add(Id, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Id, Data, Pid, Links)}.


% %% @private
% links_get(Link, #state{links=Links}) ->
%     nklib_links:get_value(Link, Links).


%% @private
links_remove(Id, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Id, Links)}.


%% @private
links_down(Ref, #state{links=Links}=State) ->
    case nklib_links:down(Ref, Links) of
        {ok, Link, Data, Links2} -> 
            {ok, Link, Data, State#state{links=Links2}};
        not_found -> 
            not_found
    end.

%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold_values(Fun, Acc, Links).


%% @private
restart_timer(#state{id=RoomId}) ->
    nkmedia_room:restart_timeout(RoomId).



%% @private
session_opts() ->
    [
        offer,
        no_offer_trickle_ice,
        no_answer_trickle_ice,
        trickle_ice_timeout,
        sdp_type,
        mute_audio,
        mute_video,
        mute_data,
        bitrate
    ].


%% @private
session_data_keys() ->
    [
        type, 
        device, 
        bitrate, 
        meta, 
        announce,
        member_id, 
        member_conn_id
    ].
