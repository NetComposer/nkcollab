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
-export([get_room/1, get_publishers/1, get_listeners/1]).
-export([add_publish_session/4, add_listen_session/5, remove_session/2]).
-export([remove_user_sessions/2, remove_user_all_sessions/2]).
-export([get_user_sessions/2, get_user_all_sessions/2]).
-export([update_publish_session/3]).
-export([send_info/2, send_msg/3, get_all_msgs/1]).
-export([add_timelog/2, get_timelog/1]).
-export([register/2, unregister/2, get_all/0]).
-export([media_session_event/3, media_room_event/2]).
-export([find/1, do_call/2, do_call/3, do_cast/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, room/0, event/0]).


% To debug, set debug => [nkcollab_room]

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkcollab_room_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkCOLLAB Room '~s' "++Txt, 
               [State#state.id | Args])).

-include("nkcollab_room.hrl").
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type session_id() :: nkmedia_session:id().

-type user_id() :: binary().

-type conn_id() :: binary().

-type meta() :: map().


-type config() ::
    #{
        backend => atom(),
        audio_codec => opus | isac32 | isac16 | pcmu | pcma,    
        video_codec => vp8 | vp9 | h264,                        
        bitrate => integer(),                                   
        room_meta => meta(),
        register => nklib:link()
    }.


-type room() ::
    config() |
    #{
        room_id => id(),
        srv_id => nkservice:id(),
        users => #{user_id() => [conn_id()]},
        conns => #{conn_id() => conn_data()},
        publish => #{session_id() => session_data()},
        listen => #{session_id() => session_data()},
        start_time => nklib_util:timestamp(),
        stop_time => nklib_util:timestamp(),
        status => map()
    }.


-type session_config() ::
    #{
        offer => nkmedia:offer(),
        no_offer_trickle_ice => boolean(),          % Buffer candidates and insert in SDP
        no_answer_trickle_ice => boolean(),       
        trickle_ice_timeout => integer(),
        sdp_type => webrtc | rtp,
        register => nklib:link(),

        mute_audio => boolean(),
        mute_video => boolean(),
        mute_data => boolean(),
        bitrate => integer(),

        class => binary(),
        device => binary(),
        meta => map(),
        session_events => [nkservice_events:type()],
        session_events_body => map()
    }.


-type conn_data() ::
    #{
        user_id => user_id(),
        sessions => [session_id()],
        room_events => [nkservice_events:type()],
        room_events_body => map()
    }.



-type session_data() ::
    #{
        type => publish | listen,
        device => atom() | binary(),
        bitrate => integer(),
        started_time => nklib_util:l_timestamp(),
        stopped_time => nklib_util:l_timestamp(),
        session_meta => map(),
        announce => map(),
        user_id => user_id(),
        conn_id => conn_id(),
        publisher_id => session_id()
    }.


-type event() :: 
    created                                         |
    {started_publisher, session_data()}             |
    {stopped_publisher, session_data()}             |
    {updated_publisher, session_data()}             |
    {started_listener, session_data()}              |
    {stopped_listener, session_data()}              |
    {room_info, map()}                              |
    {room_msg, msg()}                               |
    {stopped, nkservice:error()}                    |
    {record, [map()]}                               |
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
                    BaseRoom2 = maps:with(room_opts(), BaseRoom),
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
-spec get_publishers(id()) ->
    {ok, [session_data()]} | {error, term()}.

get_publishers(Id) ->
    do_call(Id, get_publishers).


%% @doc
-spec get_listeners(id()) ->
    {ok, [session_data()]} | {error, term()}.

get_listeners(Id) ->
    do_call(Id, get_listeners).


%% @private
-spec get_user_sessions(id(), conn_id()) ->
    {ok, [session_data()]} | {error, term()}.

get_user_sessions(Id, ConnId) ->
    do_call(Id, {get_user_sessions, ConnId}).


%% @private
-spec get_user_all_sessions(id(), user_id()) ->
    {ok, [session_data()]} | {error, term()}.

get_user_all_sessions(Id, UserId) ->
    do_call(Id, {get_user_all_sessions, UserId}).


%% @doc 
-spec add_publish_session(id(), user_id(), conn_id(), session_config()) ->
    {ok, session_id(), pid()} | {error, term()}.

add_publish_session(Id, UserId, ConnId, SessConfig) ->
    do_call(Id, {add_session, publish, UserId, ConnId, SessConfig}).


%% @doc 
-spec add_listen_session(id(), user_id(), conn_id(), session_id(), session_config()) ->
    {ok, session_id(), pid()} | {error, term()}.

add_listen_session(Id, UserId, ConnId, SessId, SessConfig) ->
    SessConfig2 = SessConfig#{publisher_id=>SessId},
    do_call(Id, {add_session, listen, UserId, ConnId, SessConfig2}).


%% Changes presenter's sessions and updates all viewers
-spec update_publish_session(id(), session_id(), session_config()) ->
    {ok, session_id()} | {error, term()}.

update_publish_session(Id, SessId, SessConfig) ->
    do_call(Id, {update_publish_session, SessId, SessConfig}).


%% Removes a session
-spec remove_session(id(), session_id()) ->
    ok | {error, term()}.

remove_session(Id, SessId) ->
    do_cast(Id, {remove_session, SessId}).


%% @doc 
-spec remove_user_sessions(id(), conn_id()) ->
    ok | {error, term()}.

remove_user_sessions(Id, ConnId) ->
    do_cast(Id, {remove_user_sessions, ConnId}).

%% @doc 
-spec remove_user_all_sessions(id(), user_id()) ->
    ok | {error, term()}.

remove_user_all_sessions(Id, UserId) ->
    do_cast(Id, {remove_user_all_sessions, UserId}).


%% @private
-spec send_msg(id(), user_id(), msg()) ->
    {ok, msg_id()} | {error, term()}.

send_msg(Id, UserId, Msg) when is_map(Msg) ->
    do_call(Id, {send_msg, UserId, Msg}).


%% @private
-spec send_info(id(), map()) ->
    ok | {error, term()}.

send_info(Id, Data) when is_map(Data) ->
    do_cast(Id, {send_info, Data}).


%% @doc Sends an info to the sesison
-spec add_timelog(id(), map()) ->
    ok | {error, nkservice:error()}.

add_timelog(RoomId, #{msg:=_}=Data) ->
    do_cast(RoomId, {add_timelog, Data}).


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



%% @doc Gets currents timelog
-spec get_timelog(id()) ->
    {ok, [map()]} | {error, nkservice:error()}.

get_timelog(RoomId) ->
    do_call(RoomId, get_timelog).


%% @doc Gets all started rooms
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    [{RoomId, Meta, Pid} || {{RoomId, Meta}, Pid} <- nklib_proc:values(?MODULE)].
    

%% @private Called from nkcollab_room_callbacks for session events
-spec media_session_event(id(), session_id(), nkmedia_session:event()) ->
    ok | {error, nkservice:error()}.

media_session_event(RoomId, SessId, {stopped, _Reason}) ->
    remove_session(RoomId, SessId);

media_session_event(RoomId, SessId, {status, Status}) ->
    do_cast(RoomId, {session_status, SessId, Status});

media_session_event(_RoomId, _SessId, _Event) ->
    ok.


%% @private Called from nkcollab_room_callbacks for base room's events
-spec media_room_event(id(), nkmedia_room:event()) ->
    ok | {error, nkservice:error()}.

media_room_event(RoomId, {status, Class, Data}) ->
    lager:error("ROOM INFO: ~p, ~p", [Class, Data]),
    send_info(RoomId, Data#{class=>Class});

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
    room :: room(),
    started :: nklib_util:l_timestamp(),
    timelog = [] :: [{integer(), map()}]
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{room_id:=RoomId, srv_id:=SrvId, backend:=Backend}=Room, BasePid]) ->
    true = nklib_proc:reg({?MODULE, RoomId}),
    Meta = maps:get(room_meta, Room, #{}),
    nklib_proc:put(?MODULE, {RoomId, Meta}),
    {ok, BasePid} = nkmedia_room:register(RoomId, {nkcollab_room, BasePid, self()}),
    Room1 = Room#{
        users => #{},
        conns => #{}, 
        publish => #{},
        listen => #{},
        start_time => nklib_util:timestamp()
    },
    State1 = #state{
        id = RoomId, 
        srv_id = SrvId, 
        backend = Backend,
        links = nklib_links:new(),
        msgs = orddict:new(),
        room = Room1,
        started = nklib_util:l_timestamp()
    },
    State2 = links_add(nkmedia_room, none, BasePid, State1),
    State3 = case Room of
        #{register:=Link} ->
            links_add(Link, reg, State2);
        _ ->
            State2
    end,
    set_log(State3),
    nkservice_util:register_for_changes(SrvId),
    ?LLOG(info, "started", [], State3),
    State4 = do_event(created, State3),
    {ok, State4}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({add_session, Type, UserId, ConnId, Config}, _From, State) ->
    restart_timer(State),
    case add_session(Type, UserId, ConnId, Config, State) of
        {ok, SessId, State2} ->
            State3 = case Config of
                #{register:=Link} ->
                    links_add(Link, {conn_id, UserId, ConnId}, State2);
                _ ->
                    State2
            end,
            {reply, {ok, SessId, self()}, State3};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call({get_user_sessions, ConnId}, _From, State) ->
    case do_get_conn(ConnId, State) of
        #{user_id:=UserId, sessions:=SessionIds} ->
            Sessions = [do_get_session(Id, State) || Id<-SessionIds],
            {reply, {ok, UserId, Sessions}, State};
        not_found ->
            {reply, {error, user_not_found}, State}
    end;

handle_call({get_user_all_sessions, UserId}, _From, State) ->
    case do_get_user_conns(UserId, State) of
        ConnIds when is_list(ConnIds) ->
            Sessions = lists:foldl(
                fun(ConnId, Acc) ->
                    #{sessions:=SessionIds} = do_get_conn(ConnId, State),
                    Acc ++  [do_get_session(Id, State) || Id<-SessionIds]
                end,
                [],
                ConnIds),
            {reply, {ok, Sessions}, State};
        not_found ->
            {reply, {error, user_not_found}, State}
    end;

% handle_call({update_publisher, UserId, Config}, _From, State) ->
%     restart_timer(State),
%     case get_info(UserId, State) of
%         {ok, Info} ->
%             OldSessId = maps:get(publish_session_id, Info, undefined),
%             case add_session(publish, UserId, Config, Info, State) of
%                 {ok, SessId, _Info2, State2} ->
%                     Self = self(),
%                     spawn_link(
%                         fun() ->
%                             timer:sleep(500),
%                             gen_server:cast(Self,
%                                             {switch_all_listeners, UserId, OldSessId})
%                         end),
%                     {reply, {ok, SessId}, State2};
%                 {error, Error} ->
%                     {reply, {error, Error}, State}
%             end;
%         not_found ->
%             {reply, {error, user_not_found}, State}
%     end;


% handle_cast({switch_all_listeners, UserId, OldSessId}, State) ->
%     case get_info(UserId, State) of
%         {ok, #{publish_session_id:=NewSessId}} ->
%             State2 = switch_all_listeners(UserId, NewSessId, State),
%             State3 = case OldSessId of
%                 undefined ->
%                     State2;
%                 _ ->
%                     % stop_sessions(UserId, [OldSessId], State2);
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

handle_call(get_timelog, _From, #state{timelog=Log}=State) -> 
    {reply, {ok, lists:reverse(Log)}, State};

handle_call(get_publishers, _From, #state{room=Room}=State) -> 
    #{publish:=Publish} = Room,
    {reply, {ok, maps:values(Publish)}, State};

handle_call(get_listeners, _From, #state{room=Room}=State) -> 
    #{listen:=Listen} = Room,
    {reply, {ok, maps:values(Listen)}, State};

handle_call({send_msg, UserId, Msg}, _From, #state{msg_pos=Pos, msgs=Msgs}=State) ->
    restart_timer(State),
    Msg2 = Msg#{msg_id => Pos, user_id=>UserId},
    State2 = State#state{
        msg_pos = Pos+1, 
        msgs = orddict:store(Pos, Msg2, Msgs)
    },
    State3 = do_event({room_msg, Msg2}, State2),
    {reply, {ok, Pos}, State3};

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
handle_cast({remove_session, SessId}, State) ->
    restart_timer(State),
    State2 = remove_sessions([SessId], State),
    {noreply, State2};

handle_cast({remove_user_sessions, ConnId}, State) ->
    restart_timer(State),
    {noreply, do_remove_user_sessions(ConnId, State)};

handle_cast({remove_user_all_sessions, UserId}, State) ->
    restart_timer(State),
    case do_get_user_conns(UserId, State) of
        ConnIds when is_list(ConnIds) ->
            State2 = lists:foldl(
                fun(ConnId, Acc) ->
                    case do_get_conn(ConnId, State) of
                        #{sessions:=SessIds} ->
                            remove_sessions(SessIds, Acc);
                        not_found ->
                            lager:error("REMOVING ~s, ~p", 
                                        [ConnId, lager:pr(State, ?MODULE)]),
                            Acc
                    end
                end,
                State,
                ConnIds),
            {noreply, State2};
        not_found ->
            {noreply, State}
    end;

handle_cast({send_info, Data}, State) ->
    restart_timer(State),
    {noreply, do_event({room_info, Data}, State)};

handle_cast({add_timelog, Data}, State) ->
    restart_timer(State),
    {noreply, do_add_timelog(Data, State)};

handle_cast({register, Link}, State) ->
    ?DEBUG("proc registered (~p)", [Link], State),
    State2 = links_add(Link, reg, State),
    {noreply, State2};

handle_cast({unregister, Link}, State) ->
    ?DEBUG("proc unregistered (~p)", [Link], State),
    {noreply, links_remove(Link, State)};

handle_cast({session_status, SessId, Data}, State) ->
    case do_get_session(SessId, State) of
        #{type:=Type, status:=Status}=Session ->
            Session2 = Session#{status:=maps:merge(Status, Data)},
            State2 = do_update_session(SessId, Session2, State),
            Data2 = Data#{session_id=>SessId},
            State3 = do_add_timelog(Data2#{msg=>session_updated_status}, State2),
            ?DEBUG("updated status: ~p", [Data2], State3),
            State4 = case Type of
                publish -> 
                    do_event({updated_publisher, Data2}, State3);
                listen ->
                    State3
            end,
            {noreply, State4};
        not_found ->
            {noreply, State}
    end;

handle_cast({stop, Reason}, State) ->
    ?DEBUG("external stop: ~p", [Reason], State),
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
            ?LLOG(notice, "media room down", [], State2),
            do_stop(media_room_down, State2);
        {ok, _Link, {conn_id, UserId, ConnId}, State2} ->
            ?DEBUG("connection ~s is down (user ~s)", [ConnId, UserId], State),
            {noreply, do_remove_conn(ConnId, State2)};
        {ok, SessId, session, State2} ->
            case do_get_session(SessId, State2) of
                #{user_id:=UserId} ->
                    ?DEBUG("session ~s down (~p)", [SessId, UserId], State2),
                    State3 = remove_sessions([SessId], State2),
                    {noreply, State3};
                not_found ->
                    {noreply, State2}
            end;
        {ok, Link, reg, State2} ->
            #state{id=Id} = State2,
            case handle(nkcollab_room_reg_down, [Id, Link, Reason], State2) of
                {ok, State3} ->
                    {noreply, State3};
                {stop, normal, State3} ->
                    ?DEBUG("stopping because of reg '~p' down",  [Link], State2),
                    do_stop(reg_down, State3);
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

handle_info({nkservice_updated, _SrvId}, State) ->
    {noreply, set_log(State)};

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

terminate(Reason, #state{stop_reason=Stop, timelog=Log}=State) ->
    case Stop of
        false ->
            {noreply, State2} = do_stop({terminate, Reason}, State);
        _ ->
            State2 = State
    end,
    State3 = do_event({record, lists:reverse(Log)}, State2),
    State4 = do_event(destroyed, State3),
    {ok, _State5} = handle(nkcollab_room_terminate, [Reason], State4),
    ok.


% ===================================================================
%% Internal
%% ===================================================================

%% @private
set_log(#state{srv_id=SrvId}=State) ->
    Debug = case nkservice_util:get_debug_info(SrvId, ?MODULE) of
        {true, _} -> true;
        _ -> false
    end,
    put(nkcollab_room_debug, Debug),
    State.


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
-spec add_session(publish|{listen, session_id()}, user_id(), conn_id(), 
                  map(), #state{}) ->
    {ok, session_id(), #state{}} | {error, nkservice:error()}.

add_session(Type, UserId, ConnId, Config, State) ->
    #state{srv_id=SrvId, id=RoomId, backend=Backend} = State,
    SessConfig1 = maps:with(session_opts(), Config),
    SessMeta1 = maps:get(session_meta, SessConfig1, #{}),
    % Fields session_events and session_events_body wil be included
    SessConfig2 = SessConfig1#{
        backend => Backend,
        room_id => RoomId,
        register => {nkcollab_room, RoomId, self()},
        session_meta => SessMeta1#{nkcollab_room=>true},
        user_id => UserId,
        user_session => ConnId
    },
    case nkmedia_session:start(SrvId, Type, SessConfig2) of
        {ok, SessId, Pid} ->
            SessData1 = maps:with(session_data_keys(), Config),
            SessData2 = SessData1#{
                session_id => SessId,
                type => Type,
                started_time => nklib_util:l_timestamp(),
                user_id => UserId,
                conn_id => ConnId,
                status => #{}
            },
            State2 = links_add(SessId, session, Pid, State),
            State3 = case Type of
                publish -> do_event({started_publisher, SessData2}, State2);
                listen -> do_event({started_listener, SessData2}, State2)
            end,
            State4 = do_update_session(SessId, SessData2, State3),
            State5 = do_conn_add_session(UserId, ConnId, SessId, Config, State4),
            Log = #{msg=>started_session, session=>SessData2},
            State6 = do_add_timelog(Log, State5),
            {ok, SessId, State6};
        {error, Error} ->
            {error, Error}
    end.


%% @private
remove_sessions([], State) ->
    State;

remove_sessions([SessId|Rest], State) ->
    State2 = case do_get_session(SessId, State) of
        #{}=Session ->            
            do_remove_session(SessId, Session, State);
        not_found ->
           State
    end,
    remove_sessions(Rest, State2).


%% @private
do_remove_session(SessId, Session, State) ->
    #{type:=Type, conn_id:=ConnId} = Session,
    State2 = links_remove(SessId, State),
    Session2 = Session#{stopped_time=>nklib_util:l_timestamp()},
    State3 = do_update_session(SessId, Session2, State2),
    State4 = case Type of
        publish -> do_event({stopped_publisher, Session2}, State3);
        listen -> do_event({stopped_listener, Session2}, State3)
    end,
    nkmedia_session:stop(SessId, user_stop),
    ?DEBUG("removed session ~s", [SessId], State),
    State5 = do_conn_remove_session(ConnId, SessId, State4),
    do_add_timelog(#{msg=>stopped_session, session_id=>SessId}, State5).


%% @private
do_remove_user_sessions(ConnId, State) ->
    case do_get_conn(ConnId, State) of
        #{sessions:=SessIds} ->
            remove_sessions(SessIds, State);
        not_found ->
            State
    end.


%% @private
do_remove_conn(ConnId, #state{room=Room}=State) ->
    State2 = do_remove_user_sessions(ConnId, State),
    #{conns:=Conns} = Room,
    add_to_room(conns, maps:remove(ConnId, Conns), State2).





% %% @private
% switch_all_listeners([], _PresenterId, _PublishId, State) ->
%     State;

% switch_all_listeners([{_UserId, Info}|Rest], PresenterId, PublishId, State) ->
%     State2 = case has_this_presenter(Info, PresenterId) of
%         {true, SessId} ->
%             switch_listener(SessId, PublishId),
%             State;
%         false ->
%             State
%     end,
%     switch_all_listeners(Rest, PresenterId, PublishId, State2).


%% @private
do_stop(Reason, #state{stop_reason=false, srv_id=SrvId, id=Id, room=Room}=State) ->
    ?LLOG(info, "stopped: ~p", [Reason], State),
    #{listen:=Listen} = Room,
    #{publish:=Publish} = Room,
    State2 = remove_sessions(maps:keys(Listen), State),
    State3 = remove_sessions(maps:keys(Publish), State2),
    case nkmedia_room:stop(Id) of
        ok -> ok;
        Other -> ?LLOG(notice, "error stopping base room: ~p", [Other], State)
    end,
    % Give time for possible registrations to success and capture stop event
    State4 = add_to_room(stop_time, nklib_util:timestamp(), State3),
    timer:sleep(100),
    State5 = do_event({stopped, Reason}, State4),
    {ok, State6} = handle(nkcollab_room_stop, [Reason], State5),
    {_Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    State7 = do_add_timelog(#{msg=>stopped, reason=>Txt}, State6),
    erlang:send_after(?SRV_DELAYED_DESTROY, self(), destroy),
    {noreply, State7#state{stop_reason=Reason}};

do_stop(_Reason, State) ->
    % destroy already sent
    {noreply, State}.


%% @private
do_event(Event, #state{id=Id}=State) ->
    ?DEBUG("sending 'event': ~p", [Event], State),
    State2 = links_fold(
        fun(Link, AccState) ->
            {ok, AccState2} = 
                handle(nkcollab_room_reg_event, [Id, Link, Event], AccState),
                AccState2
        end,
        State,
        State),
    {ok, State3} = handle(nkcollab_room_event, [Id, Event], State2),
    State3.


%% @private
do_get_user_conns(UserId, #state{room=#{users:=Users}}) ->
    case maps:find(UserId, Users) of
        {ok, ConnIds} -> ConnIds;
        error -> not_found
    end.
        

%% @private
do_get_conn(ConnId, #state{room=#{conns:=Conns}}) ->
    case maps:find(ConnId, Conns) of
        {ok, Conn} -> Conn;
        error -> not_found
    end.


%% @private
do_conn_add_session(UserId, ConnId, SessId, Config, #state{room=Room}=State) ->
    #{users:=AllUsers1, conns:=AllConns1} = Room,
    UserConnIds1 = maps:get(UserId, AllUsers1, []),
    UserConnIds2 = nklib_util:store_value(ConnId, UserConnIds1),
    AllUsers2 = maps:put(UserId, UserConnIds2, AllUsers1),
    case maps:find(ConnId, AllConns1) of
        {ok, #{user_id:=UserId}=Conn1} -> ok;
        error -> Conn1 = #{}
    end,
    Sessions = maps:get(sessions, Conn1, []),
    Conn2 = Conn1#{
        user_id => UserId,
        sessions => [SessId|Sessions],
        room_events => maps:get(room_events, Config, []),
        room_events_body => maps:get(room_events_body, Config, #{})
    },
    AllConns2 = maps:put(ConnId, Conn2, AllConns1),
    State#state{room=?ROOM(#{users=>AllUsers2, conns=>AllConns2}, Room)}.


%% @private
do_conn_remove_session(ConnId, SessId, #state{room=Room}=State) ->
    AllConns1 = maps:get(conns, Room),
    case maps:find(ConnId, AllConns1) of
        {ok, #{sessions:=Sessions}=Conn1} ->
            Conn2 = Conn1#{sessions:=Sessions--[SessId]},
            AllConns2 = maps:put(ConnId, Conn2, AllConns1),
            add_to_room(conns, AllConns2, State);
        error ->
            State
    end.


%% @private
do_get_session(SessId, #state{room=Room}) ->
    Publish = maps:get(publish, Room),
    case maps:find(SessId, Publish) of
        {ok, Session} ->
            Session;
        error ->
            Listen = maps:get(listen, Room),
            case maps:find(SessId, Listen) of
                {ok, Sessions} -> 
                    Sessions;
                error ->
                    not_found
            end
    end.
       

%% @private
do_update_session(SessId, #{stopped_time:=_}=Session, #state{room=Room}=State) ->
    case Session of
        #{type:=publish} ->
            Publish1 = maps:get(publish, Room),
            Publish2 = maps:remove(SessId, Publish1),
            add_to_room(publish, Publish2, State);
        #{type:=listen} ->
            Listen1 = maps:get(listen, Room),
            Listen2 = maps:remove(SessId, Listen1),
            add_to_room(listen, Listen2, State)
    end;
    
do_update_session(SessId, Session, #state{room=Room}=State) ->
    case Session of
        #{type:=publish} ->
            Publish1 = maps:get(publish, Room),
            Publish2 = maps:put(SessId, Session, Publish1),
            add_to_room(publish, Publish2, State);
        #{type:=listen} ->
            Listen1 = maps:get(listen, Room),
            Listen2 = maps:put(SessId, Session, Listen1),
            add_to_room(listen, Listen2, State)
    end.


%% @private
add_to_room(Key, Val, #state{room=Room}=State) ->
    State#state{room=maps:put(Key, Val, Room)}.



%% @private
do_add_timelog(Msg, State) when is_atom(Msg); is_binary(Msg) ->
    do_add_timelog(#{msg=>Msg}, State);

do_add_timelog(#{msg:=_}=Data, #state{started=Started, timelog=Log}=State) ->
    Time = (nklib_util:l_timestamp() - Started) div 1000,
    State#state{timelog=[{Time, Data}|Log]}.


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
    nklib_links:fold(Fun, Acc, Links).


%% @private
restart_timer(#state{id=RoomId}) ->
    nkmedia_room:restart_timeout(RoomId).



room_opts() -> 
    [
        srv_id, 
        backend, 
        timeout,
        audio_codec,
        video_codec,
        room_meta
    ].


%% @private
session_opts() ->
    [
        offer,
        no_offer_trickle_ice,
        no_answer_trickle_ice,
        trickle_ice_timeout,
        sdp_type,
        publisher_id,
        mute_audio,
        mute_video,
        mute_data,
        bitrate,
        session_meta,
        session_events,
        session_events_body
    ].


%% @private
session_data_keys() ->
    [
        type, 
        device, 
        bitrate, 
        session_meta, 
        announce,
        publisher_id
    ].
