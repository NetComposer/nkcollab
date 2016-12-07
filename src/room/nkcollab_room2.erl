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
-module(nkcollab_room2).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/2, stop/1, stop/2, get_room/1, get_members/2]).
-export([create_member/3, destroy_member/2]).
-export([update_publisher/3, remove_publisher/2,
         add_listener/4, remove_listener/3]).
-export([update_meta/3, update_media/3, update_all_media/2]).
-export([broadcast/3, get_all_msgs/1]).
-export([send_room_info/2, send_session_info/3, send_member_info/3]).
-export([media_session_event/3, media_room_event/2]).
-export([register/2, unregister/2, get_all/0]).
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


-type role() :: presenter | viewer.


-type backend() :: nkmedia_janus | nkmedia_kms.


-type member_id() :: integer().


-type meta() :: map().


-type member_info() :: 
    #{
        user_id => binary(),        
        meta => meta(),
        role => role(),
        status => map(),
        publish_session_id => session_id(),
        listen_session_ids => #{session_id() => member_id()}
    }.


-type config() ::
    #{
        backend => backend(),
        audio_codec => opus | isac32 | isac16 | pcmu | pcma,    % info only
        video_codec => vp8 | vp9 | h264,                        % "
        bitrate => integer(),                                   % "
        meta => meta(),
        register => nklib:link()
    }.


-type room() ::
    config() |
    #{
        room_id => id(),
        srv_id => nkservice:id(),
        members => #{member_id() => member_info()},
        status => map()
    }.


-type create_member_opts() ::
    #{
        user_id => nkservice:user_id(),         
        user_session => nkservice:user_session(),
        meta => meta(),
        presenter => member_id(),
        register => nklib:link()
    } |
    media_opts() | session_opts().


-type update_publisher_opts() :: media_opts() | session_opts().


-type media_opts() ::
    #{
        mute_audio => boolean(),
        mute_video => boolean(),
        mute_data => boolean(),
        bitrate => integer()
    }.


-type session_opts() ::
    #{
        offer => nkmedia:offer(),
        no_offer_trickle_ice => boolean(),
        no_answer_trickle_ice => boolean(),
        trickle_ice_timeout => integer(),
        sdp_type => rtp | webrtc
    }.


-type event() :: 
    created                                         |
    {started_member, member_id(), member_info()}    |
    {stopped_member, member_id(), member_info()}    |
    {stopped_session, session_id(), member_id()}    |
    {info, map()}                                   |
    {member_info, member_id(), map()}               |
    {session_info, member_id(), session_id, map()}  |
    {broadcast, msg()}                              |
    {destroyed, nkservice:error()}.


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
                {ok, RoomId, _RoomPid} ->
                    {ok, Pid} = gen_server:start(?MODULE, [Config2], []),
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
-spec get_members(id(), role()) ->
    {ok, room()} | {error, term()}.

get_members(Id, Role) ->
    do_call(Id, {get_members, Role}).


%% @doc Creates a new member, as presenter or viewer
-spec create_member(id(), role(), create_member_opts()) ->
    {ok, member_id(), session_id(), pid()} | {error, term()}.

create_member(Id, Role, Config) when Role==presenter; Role==viewer->
    do_call(Id, {create_member, Role, Config}).


%% @doc 
-spec destroy_member(id(), member_id()) ->
    ok | {error, term()}.

destroy_member(Id, MemberId) ->
    do_call(Id, {destroy_member, MemberId}).


%% Changes presenter's sessions and updates all viewers
-spec update_publisher(id(), member_id(), update_publisher_opts()) ->
    {ok, session_id()} | {error, term()}.

update_publisher(Id, MemberId, Config) ->
    do_call(Id, {update_publisher, MemberId, Config}).


%% Changes presenter's sessions and updates all viewers
-spec remove_publisher(id(), member_id()) ->
    ok | {error, term()}.

remove_publisher(Id, MemberId) ->
    do_call(Id, {remove_publisher, MemberId}).


%% @private
-spec add_listener(id(), member_id(), member_id(), session_opts()) ->
    {ok, session_id()} | {error, term()}.

add_listener(Id, MemberId, PresenterId, Config) ->
    do_call(Id, {add_listener, MemberId, PresenterId, Config}).


%% @private
-spec remove_listener(id(), member_id(), member_id()) ->
    {ok, session_id()} | {error, term()}.

remove_listener(Id, MemberId, PresenterId) ->
    do_call(Id, {remove_listener, MemberId, PresenterId}).


%% @private
-spec update_meta(id(), member_id(), meta()) ->
    ok | {error, term()}.

update_meta(Id, MemberId, Media) ->
    do_call(Id, {update_meta, MemberId, Media}).


%% @private
-spec update_media(id(), member_id(), media_opts()) ->
    ok | {error, term()}.

update_media(Id, MemberId, Media) ->
    do_call(Id, {update_media, MemberId, Media}).


%% @private
-spec update_all_media(id(), media_opts()) ->
    ok | {error, term()}.

update_all_media(Id, Media) ->
    do_call(Id, {update_all_media, Media}).


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
    [{id(), meta(), pid()}].

get_all() ->
    [
        {Id, Meta, Pid} ||
        {{Id, Meta}, Pid} <- nklib_proc:values(?MODULE)
    ].


%% @private Called from nkcollab_room_callbacks
-spec media_session_event(id(), session_id(), nkmedia_session:event()) ->
    ok | {error, nkservice:error()}.

media_session_event(RoomId, SessId, {status, Class, Data}) ->
    send_session_info(RoomId, SessId, Data#{class=>Class});

media_session_event(_RoomId, _SessId, _Event) ->
    ok.


%% @private Called from nkcollab_room_callbacks
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
    timer :: reference(),
    stop_reason = false :: false | nkservice:error(),
    links :: nklib_links:links(),
    member_pos = 1 :: integer(),
    msg_pos = 1 :: integer(),
    msgs :: orddict:orddict(),
    room :: room()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{room_id:=RoomId}=Room]) ->
    true = nklib_proc:reg({?MODULE, RoomId}),
    Meta = maps:get(meta, Room, #{}),
    nklib_proc:put(?MODULE, {RoomId, Meta}),
    {ok, Pid} = nkmedia_room:register(RoomId, {nkcollab_room, RoomId, self()}),
    {ok, Media} = nkmedia_room:get_room(Pid),
    Room2 = maps:merge(Room, Media),
    Room3 = Room2#{members=>#{}, status=>#{}},
    #{backend:=Backend, srv_id:=SrvId} = Room3,
    State1 = #state{
        id = RoomId, 
        srv_id = SrvId, 
        backend = Backend,
        links = nklib_links:new(),
        msgs = orddict:new(),
        room = Room3
    },
    State2 = links_add(nkmedia_room, none, Pid, State1),
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

    
handle_call({create_member, Role, Config}, _From, State) ->
    restart_timer(State),
    #state{member_pos=MemberId} = State,
    Info = maps:with([user_id, meta], Config),
    SessType = case Role of
        presenter -> publish;
        viewer -> listen
    end,
    case add_session(SessType, MemberId, Config, Info, State) of
        {ok, SessId, Info2, State2} ->
            State3 = case Config of
                #{register:=Link} ->
                    links_add(Link, {member, MemberId}, State2);
                _ ->
                    State2
            end,
            State4 = do_event({started_member, MemberId, Info2}, State3),
            % State5 = do_event({started_session, SessId, MemberId}, State4),
            State6 = State4#state{member_pos=MemberId+1},
            {reply, {ok, MemberId, SessId, self()}, State6};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call({destroy_member, MemberId}, _From, State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, Info} ->
            State2 = destroy_member(MemberId, Info, State),
            {reply, ok, State2};
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({update_publisher, MemberId, Config}, _From, State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, Info} ->
            OldSessId = maps:get(publish_session_id, Info, undefined),
            case add_session(publish, MemberId, Config, Info, State) of
                {ok, SessId, _Info2, State2} ->
                    Self = self(),
                    spawn_link(
                        fun() ->
                            timer:sleep(500),
                            gen_server:cast(Self,
                                            {switch_all_listeners, MemberId, OldSessId})
                        end),
                    {reply, {ok, SessId}, State2};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end;
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({remove_publisher, MemberId}, _From, State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, #{publish_session_id:=SessId}=Info} ->
            State2 = remove_session(SessId, MemberId, Info, State),
            {reply, ok, State2};
        {ok, _} ->
            {reply, {error, member_is_not_publisher}, State};
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({add_listener, MemberId, PresenterId, Config}, _From, State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, Info} ->
            case has_this_presenter(Info, PresenterId) of
                {true, _SessId} ->
                    {reply, {error, already_listening}, State};
                false ->
                    Config2 = Config#{presenter=>PresenterId},
                    case add_session(listen, MemberId, Config2, Info, State) of
                        {ok, SessId, _Info2, State2} ->
                            % State3 = 
                            %     do_event({started_session, SessId, MemberId}, State2),
                            {reply, {ok, SessId}, State2};
                        {error, Error} ->
                            {reply, {error, Error}, State}
                    end
            end;
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({remove_listener, MemberId, PresenterId}, _From, State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, Info} ->
            State2 = case has_this_presenter(Info, PresenterId) of
                {true, SessId} ->
                    remove_session(SessId, MemberId, Info, State);
                false ->
                    State
            end,
            {reply, ok, State2};
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({update_meta, MemberId, Meta}, _From, State) -> 
    case get_info(MemberId, State) of
        {ok, Info} ->
            BaseMeta = maps:get(meta, Info, #{}),
            Meta2 = maps:merge(BaseMeta, Meta),
            Info2 = Info#{meta=>Meta2},
            State2 = store_info(MemberId, Info2, State),
            State3 = do_event({updated_member, MemberId, Info2}, State2),
            {reply, ok, State3};
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({update_media, MemberId, Media}, _From, State) -> 
    case do_update_media(MemberId, Media, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call({update_all_media, Media}, _From, #state{room=Room}=State) -> 
    #{members:=Members} = Room,
    State2 = lists:foldl(
        fun(MemberId, Acc) ->
            case do_update_media(MemberId, Media, Acc) of
                {ok, Acc2} -> Acc2;
                _ -> Acc
            end
        end,
        State,
        maps:keys(Members)),
    {reply, ok, State2};

handle_call(get_room, _From, #state{room=Room}=State) -> 
    {reply, {ok, Room}, State};

handle_call({get_members, Role}, _From, #state{room=Room}=State) -> 
    #{members:=Members} = Room,
    Data = lists:filtermap(
        fun
            ({MemberId, #{role:=FR}=Info}) when FR==Role ->
                Fields = maps:with([user_id, meta], Info),
                {true, Fields#{member_id=>MemberId}};
            (_) ->
                false
        end,
        maps:to_list(Members)),
    {reply, {ok, Data}, State};

handle_call({broadcast, MemberId, Msg}, _From, #state{msg_pos=Pos, msgs=Msgs}=State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, _} -> 
            Msg2 = Msg#{msg_id => Pos, member_id=>MemberId},
            State2 = State#state{
                msg_pos = Pos+1, 
                msgs = orddict:store(Pos, Msg2, Msgs)
            },
            State3 = do_event({broadcast, Msg2}, State2),
            {reply, {ok, Pos}, State3};
        not_found ->
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
    {noreply, do_event({info, Data}, State)};

handle_cast({send_member_info, MemberId, Data}, State) ->
    case get_info(MemberId, State) of
        {ok, _} ->
            {noreply, do_event({member_info, MemberId, Data}, State)};
        _ ->
            {noreply, State}
    end;

handle_cast({send_session_info, SessId, Data}, State) ->
    case links_get(SessId, State) of
        {ok, {session, MemberId}} ->
            {noreply, do_event({session_info, MemberId, SessId, Data}, State)};
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

% handle_cast({media_room_event, Event}, State) ->
%     do_media_room_event(Event, State);

handle_cast({set_status, Key, Data}, #state{room=Room}=State) ->
    State2 = restart_timer(State),
    Status1 = maps:get(status, Room),
    Status2 = maps:put(Key, Data, Status1),
    State3 = State2#state{room=?ROOM(#{status=>Status2}, Room)},
    {noreply, do_event({status, Key, Data}, State3)};

handle_cast({switch_all_listeners, MemberId, OldSessId}, State) ->
    case get_info(MemberId, State) of
        {ok, #{publish_session_id:=NewSessId}} ->
            State2 = switch_all_listeners(MemberId, NewSessId, State),
            State3 = case OldSessId of
                undefined ->
                    State2;
                _ ->
                    % stop_sessions(MemberId, [OldSessId], State2);
                    State2
            end,
            {noreply, State3};
        _ ->
            ?LLOG(warning, "received switch_all_listeners for invalid publisher", 
                  [], State),
            {noreply, State}
    end;

handle_cast({stop, Reason}, State) ->
    ?LLOG(info, "external stop: ~p", [Reason], State),
    do_stop(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkcollab_room_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, State) ->
    case links_down(Ref, State) of
        {ok, nkmedia_room, _, State2} ->
            ?LLOG(warning, "media room down", [], State2),
            do_stop(media_room_down, State2);
        {ok, Link, {member, MemberId}, State2} ->
            case get_info(MemberId, State2) of
                {ok, Info} ->
                    ?LLOG(notice, "member reg ~p down (~p)", [Link, MemberId], State2),
                    State3 = destroy_member(MemberId, Info, State2),
                    {noreply, State3};
                not_found ->
                    {noreply, State}
            end;
        {ok, SessId, {session, MemberId}, State2} ->
            case get_info(MemberId, State2) of
                {ok, Info} ->
                    ?LLOG(notice, "session ~s down (~p)", [SessId, MemberId], State2),
                    State3 = remove_session(SessId, MemberId, Info, State2),
                    {noreply, State3};
                not_found ->
                    {noreply, State}
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
    State2 = do_stop_all(State),
    Stop2 = case Stop of
        false ->
            Ref = nklib_util:uid(),
            ?LLOG(notice, "terminate error ~s: ~p", [Ref, Reason], State),
            {internal_error, Ref};
        _ ->
            Stop
    end,
    timer:sleep(100),
    % Give time for registrations to success
    State3 = do_event({destroyed, Stop2}, State2),
    {ok, _State4} = handle(nkcollab_room_terminate, [Reason], State3),
    % Wait to receive events before receiving DOWN
    timer:sleep(100),
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
-spec add_session(role(), member_id(), map(), map(), #state{}) ->
    {ok, session_id(), #state{}} | {error, nkservice:error()}.

add_session(publish, MemberId, Config, Info, State) ->
    #state{srv_id=SrvId, id=RoomId, backend=Backend} = State,
    SessConfig1 = maps:with(session_opts(), Config),
    SessConfig2 = SessConfig1#{
        register => {nkcollab_room, RoomId, self()},
        backend => Backend,
        room_id => RoomId
    },
    case nkmedia_session:start(SrvId, publish, SessConfig2) of
        {ok, SessId, Pid} ->
            State2 = links_add(SessId, {session, MemberId}, Pid, State),
            Info2 = Info#{role=>presenter, publish_session_id=>SessId},
            State3 = store_info(MemberId, Info2, State2),
            {ok, SessId, Info2, State3};
        {error, Error} ->
            {error, Error}
    end;

add_session(listen, MemberId, #{presenter_id:=PresenterId}=Config, Info, State) ->
    #state{srv_id=SrvId, id=RoomId, backend=Backend} = State,
    case get_publisher(PresenterId, State) of
        {ok, PublisherId} ->
            SessConfig1 = maps:with(session_opts(), Config),
            SessConfig2 = SessConfig1#{
                register => {nkcollab_room, RoomId, self()},
                backend => Backend,
                room_id => RoomId,
                publisher_id => PublisherId
            },
            case nkmedia_session:start(SrvId, listen, SessConfig2) of
                {ok, SessId, Pid} ->
                    State2 = links_add(SessId, {session, MemberId}, Pid, State),
                    Listen1 = maps:get(listen_session_ids, Info, #{}),
                    Listen2 = maps:put(SessId, PresenterId, Listen1),
                    Role = case Info of
                        #{publish_session_id:=_} -> presenter;
                        _ -> viewer
                    end,
                    Info2 = Info#{role=>Role, listen_session_ids=>Listen2},
                    State3 = store_info(MemberId, Info2, State2),
                    {ok, SessId, Info2, State3};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, presenter_not_found}
    end;

add_session(listen, _MemberId, _Config, _Info, _State) ->
    {error, missing_presenter}.


%% @private
-spec destroy_member(member_id(), map(), #state{}) ->
    #state{}.

%% @private
destroy_member(MemberId, Info, #state{room=Room}=State) ->
    SessIds1 = case Info of
        #{listen_session_ids:=ListenIds} ->
            maps:keys(ListenIds);
        _ ->
            []
    end,
    SessIds2 = case Info of
        #{publish_session_id:=PublishId} ->
            [PublishId|SessIds1];
        _ ->
            SessIds1
    end,
    State2 = stop_sessions(MemberId, SessIds2, State),
    #{members:=Members1} = Room,
    Members2 = maps:remove(MemberId, Members1),
    Room2 = ?ROOM(#{members=>Members2}, Room),
    State3 = State2#state{room=Room2},
    do_event({stopped_member, MemberId, Info}, State3).


%% @private
-spec remove_session(session_id(), member_id(), map(), #state{}) ->
    #state{}.

remove_session(SessId, MemberId, Info, State) ->
    State2 = stop_sessions(MemberId, [SessId], State),
    #{role:=Role} = Info,
    Info2 = case Info of
        #{publish_session_id:=SessId} ->
            maps:remove(publish_session_id, Info);
        #{listen_session_ids:=Ids1} ->
            Ids2 = maps:remove(SessId, Ids1),
            case map_size(Ids2) of
                0 ->
                    maps:remove(listen_session_ids, Info);
                _ ->
                    maps:put(listen_session_ids, Ids2, Info)
            end
    end,
    Role2 = case Info2 of
        #{publish_session_id:=_} -> presenter;
        #{listen_session_ids:=_} -> viewer;
        _ -> removed
    end,
    case Role2 of
        removed ->
            destroy_member(MemberId, Info2, State);
        Role ->
            store_info(MemberId, Info2, State2);
        _ ->
            Info3 = Info2#{role=>Role2},
            State3 = store_info(MemberId, Info3, State2),
            do_event({updated_member, MemberId, Info3}, State3)
    end.


%% @private
switch_all_listeners(PresenterId, PublishId, #state{room=Room}=State) ->
    #{members:=Members} = Room,
    switch_all_listeners(maps:to_list(Members), PresenterId, PublishId, State).


%% @private
switch_all_listeners([], _PresenterId, _PublishId, State) ->
    State;

switch_all_listeners([{_MemberId, Info}|Rest], PresenterId, PublishId, State) ->
    State2 = case has_this_presenter(Info, PresenterId) of
        {true, SessId} ->
            switch_listener(SessId, PublishId),
            State;
        false ->
            State
    end,
    switch_all_listeners(Rest, PresenterId, PublishId, State2).


%% @private
do_stop(Reason, #state{id=RoomId}=State) ->
    nkmedia_room:stop(RoomId, Reason),
    {stop, normal, State#state{stop_reason=Reason}}.


%% @private
do_stop_all(#state{room=#{members:=Members}}=State) ->
    lists:foldl(
        fun({MemberId, Info}, Acc) -> destroy_member(MemberId, Info, Acc) end,
        State,
        maps:to_list(Members)).


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



%% @private
do_update_media(MemberId, Media, State) ->
    case get_info(MemberId, State) of
        {ok, #{publish_session_id:=SessId}} ->
            case nkmedia_session:cmd(SessId, update_media, Media) of
                {ok, _} ->
                    {ok, do_event({updated_media, MemberId, Media}, State)};
                {error, Error} ->
                    {error, Error}
            end;
        {ok, _} ->
            {error, member_is_not_publisher};
        _ ->
            {error, member_not_found}
    end.


%% @private Get presenter's publishing session
-spec get_info(member_id(), #state{}) ->
    {ok, nkmedia_session:id()} | not_found.

get_info(MemberId, #state{room=Room}) ->
    Members = maps:get(members, Room),
    case maps:find(MemberId, Members) of
        {ok, Info} -> 
            {ok, Info};
        error -> 
            not_found
    end.



%% @private Get presenter's publishing session
-spec get_publisher(member_id(), #state{}) ->
    {ok, nkmedia_session:id()} | no_publisher | not_presenter.

get_publisher(PresenterId, State) ->
    case get_info(PresenterId, State) of
        {ok, #{publish_session_id:=SessId}} ->
            {ok, SessId};
        {ok, _} ->
            not_presenter;
        not_found ->
            not_found
    end.

%% @private
store_info(MemberId, Info, #state{room=Room}=State) ->
    #{members:=Members1} = Room,
    Members2 = maps:put(MemberId, Info, Members1),
    State#state{room=?ROOM(#{members=>Members2}, Room)}.


%% @private
has_this_presenter(#{listen_session_ids:=Ids}, PresenterId) ->
    case lists:keyfind(PresenterId, 2, maps:to_list(Ids)) of
        {SessId, PresenterId} ->
            {true, SessId};
        false ->
            false
    end;

has_this_presenter(_Info, _PresenterId) ->
    false.

%% @private
stop_sessions(_MemberId, [], State) ->
    State;

stop_sessions(MemberId, [SessId|Rest], State) ->
    nkmedia_session:stop(SessId, member_stop),
    State2 = links_remove(SessId, State),
    State3 = do_event({stopped_session, SessId, MemberId}, State2),
    stop_sessions(MemberId, Rest, State3).


%% @private
switch_listener(SessId, PublishId) ->
    lager:error("SWITCH: ~p -> ~p", [SessId, PublishId]),
    nkmedia_session:cmd(SessId, set_type, #{type=>listen, publisher_id=>PublishId}).


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


%% @private
links_get(Link, #state{links=Links}) ->
    nklib_links:get_value(Link, Links).


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
        user_id,
        user_session,
        publisher_id,
        mute_audio,
        mute_video,
        mute_data,
        bitrate
    ].
