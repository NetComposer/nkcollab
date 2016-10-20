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

-export([start/2, stop/1, stop/2, get_room/1, get_presenters/1]).
-export([create_member/3, destroy_member/2, update_presenter/3,
         add_viewer/4, remove_viewer/3]).
-export([update_meta/3, update_media/3]).
-export([broadcast/2, get_all_msgs/1, send_info/3]).
-export([register/2, unregister/2, get_all/0]).
-export([media_room_event/2]).
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


% -type presenter_type() :: camera | screen.


-type backend() :: nkmedia_janus | nkmedia_kms.


-type member_id() :: integer().


-type meta() :: map().


-type member_info() :: 
    #{
        user_id => binary(),        
        meta => meta(),
        role => role(),
        presenter_session_id => session_id(),
        viewer_session_ids => #{session_id() => member_id()}
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
        members => #{member_id() => member_info()}
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


-type update_presenter_opts() :: media_opts() | session_opts().


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


-type info() :: atom().


-type event() :: 
    created                                         |
    {started_member, member_id(), member_info()}    |
    {stopped_member, member_id(), member_info()}    |
    {started_session, session_id(), member_id()}    |
    {stopped_session, session_id(), member_id()}    |
    {info, info(), map()}                           |
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
            case nkmedia_room:start(Srv, Config#{class=>sfu}) of
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
-spec get_presenters(id()) ->
    {ok, room()} | {error, term()}.

get_presenters(Id) ->
    do_call(Id, get_presenters).


%% @doc Creates a new member, as presenter or viewer
-spec create_member(id(), role(), create_member_opts()) ->
    {ok, member_id(), session_id(), pid()} | {error, term()}.

create_member(Id, Role, Config) ->
    do_call(Id, {create_member, Role, Config}).


%% @doc 
-spec destroy_member(id(), member_id()) ->
    ok | {error, term()}.

destroy_member(Id, MemberId) ->
    do_call(Id, {destroy_member, MemberId}).


%% Changes presenter's sessions and updates all viewers
-spec update_presenter(id(), member_id(), update_presenter_opts()) ->
    {ok, session_id()} | {error, term()}.

update_presenter(Id, MemberId, Config) ->
    do_call(Id, {update_presenter, MemberId, Config}).


%% @private
-spec add_viewer(id(), member_id(), member_id(), session_opts()) ->
    {ok, session_id()} | {error, term()}.

add_viewer(Id, MemberId, PresenterId, Config) ->
    do_call(Id, {add_viewer, MemberId, PresenterId, Config}).


%% @private
-spec remove_viewer(id(), member_id(), member_id()) ->
    {ok, session_id()} | {error, term()}.

remove_viewer(Id, MemberId, PresenterId) ->
    do_call(Id, {remove_viewer, MemberId, PresenterId}).


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
-spec broadcast(id(), msg()) ->
    {ok, msg_id()} | {error, term()}.

broadcast(Id, Msg) when is_map(Msg) ->
    do_call(Id, {broadcast, Msg}).


%% @private
-spec send_info(id(), info(), meta()) ->
    ok | {error, term()}.

send_info(Id, Info, Meta) when is_map(Meta) ->
    do_cast(Id, {info, Info, Meta}).


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


%% @private Called from nkcollab_room_callbacks
-spec media_room_event(id(), nkmedia_room:event()) ->
    ok | {error, nkservice:error()}.

media_room_event(RoomId, Event) ->
    do_cast(RoomId, {media_room_event, Event}).




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
    nklib_proc:put(?MODULE, RoomId),
    {ok, Pid} = nkmedia_room:register(RoomId, {nkcollab_room, RoomId, self()}),
    {ok, Media} = nkmedia_room:get_room(Pid),
    Room2 = maps:merge(Room, Media),
    Room3 = Room2#{members=>#{}},
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
    case add_session(Role, MemberId, Config, Info, State) of
        {ok, SessId, Info2, State2} ->
            State3 = case Config of
                #{register:=Link} ->
                    links_add(Link, {member, MemberId}, State2);
                _ ->
                    State2
            end,
            State4 = do_event({started_member, MemberId, Info2}, State3),
            State5 = do_event({started_session, SessId, MemberId}, State4),
            State6 = State5#state{member_pos=MemberId+1},
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

handle_call({update_presenter, MemberId, Config}, _From, State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, Info} ->
            case add_session(presenter, MemberId, Config, #{}, State) of
                {ok, SessId, _Info2, State2} ->
                    State3 = update_all_viewers(MemberId, SessId, State2),
                    State4 = case Info of
                        #{presenter_session_id:=OldSessId} ->
                            stop_sessions(MemberId, [OldSessId], State3);
                        _ ->
                            State3
                    end,
                    State5 = do_event({started_session, SessId, MemberId}, State4),
                    {reply, {ok, SessId}, State5};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end;
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({add_viewer, MemberId, PresenterId, Config}, _From, State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, Info} ->
            case has_presenter(Info, PresenterId) of
                {true, _SessId} ->
                    {reply, {error, already_listening}, State};
                false ->
                    Config2 = Config#{presenter=>PresenterId},
                    case add_session(viewer, MemberId, Config2, #{}, State) of
                        {ok, SessId, _Info2, State2} ->
                            State3 = 
                                do_event({started_session, SessId, MemberId}, State2),
                            {reply, {ok, SessId}, State3};
                        {error, Error} ->
                            {reply, {error, Error}, State}
                    end
            end;
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({remove_viewer, MemberId, PresenterId}, _From, State) ->
    restart_timer(State),
    case get_info(MemberId, State) of
        {ok, Info} ->
            State2 = case has_presenter(Info, PresenterId) of
                {true, SessId} ->
                    remove_session(MemberId, SessId, Info, State);
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
            State2 = store_info(MemberId, Info#{meta=>Meta2}, State),
            {reply, ok, State2};
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({update_media, MemberId, Media}, _From, State) -> 
    Reply = case get_info(MemberId, State) of
        {ok, #{presenter_session_id:=SessId}} ->
            case nkmedia_session:cmd(SessId, update_media, Media) of
                {ok, _} ->
                    ok;
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {reply, {error, member_not_found}, State}
    end,
    {reply, Reply, State};

handle_call(get_room, _From, #state{room=Room}=State) -> 
    {reply, {ok, Room}, State};

handle_call(get_presenters, _From, #state{room=Room}=State) -> 
    #{members:=Members} = Room,
    Data = lists:filtermap(
        fun
            ({MemberId, #{role:=presenter}=Info}) ->
                Fields = maps:with([user_id, meta], Info),
                {true, Fields#{member_id=>MemberId}};
            (_) ->
                false
        end,
        maps:to_list(Members)),
    {reply, {ok, Data}, State};

handle_call({broadcast, Msg}, _From, #state{msg_pos=Pos, msgs=Msgs}=State) ->
    restart_timer(State),
    Msg2 = Msg#{msg_id => Pos},
    State2 = State#state{
        msg_pos = Pos+1, 
        msgs = orddict:store(Pos, Msg2, Msgs)
    },
    State3 = do_event({broadcast, Msg2}, State2),
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
handle_cast({send_info, Info, Meta}, State) ->
    {noreply, do_event({info, Info, Meta}, State)};

handle_cast({register, Link}, State) ->
    ?LLOG(info, "proc registered (~p)", [Link], State),
    State2 = links_add(Link, reg, State),
    {noreply, State2};

handle_cast({unregister, Link}, State) ->
    ?LLOG(info, "proc unregistered (~p)", [Link], State),
    {noreply, links_remove(Link, State)};

handle_cast({media_room_event, Event}, State) ->
    do_media_room_event(Event, State);

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
                    ?LLOG(notice, "member ~p down (~p)", [Link, MemberId], State2),
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
            ?LLOG(notice, "stopping because of reg '~p' down (~p)",
                  [Link, Reason], State2),
            do_stop(registered_down, State2);
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
    State3 = do_event({destroyed, Stop2}, State2),
    {ok, _State4} = handle(nkcollab_room_terminate, [Reason], State3),
    % Wait for events
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

add_session(presenter, MemberId, Config, Info, State) ->
    #state{srv_id=SrvId, id=RoomId, room=Room, backend=Backend} = State,
    SessConfig1 = maps:with(session_opts(), Config),
    SessConfig2 = SessConfig1#{
        register => {nkcollab_room, RoomId, self()},
        backend => Backend,
        room_id => RoomId
    },
    case nkmedia_session:start(SrvId, publish, SessConfig2) of
        {ok, SessId, Pid} ->
            State2 = links_add(SessId, {session, MemberId}, Pid, State),
            #{members:=Members1} = Room,
            Info2 = Info#{role=>presenter, presenter_session_id=>SessId},
            Members2 = maps:put(MemberId, Info2, Members1),
            Room2 = ?ROOM(#{members=>Members2}, Room),
            {ok, SessId, Info2, State2#state{room=Room2}};
        {error, Error} ->
            {error, Error}
    end;

add_session(viewer, MemberId, #{presenter:=PresenterId}=Config, Info, State) ->
    #state{srv_id=SrvId, id=RoomId, room=Room, backend=Backend} = State,
    SessConfig1 = maps:with(session_opts(), Config),
    case get_presenter_session(PresenterId, State) of
        {ok, PublisherId} ->
            SessConfig2 = SessConfig1#{
                register => {nkcollab_room, RoomId, self()},
                backend => Backend,
                room_id => RoomId,
                publisher_id => PublisherId
            },
            case nkmedia_session:start(SrvId, listen, SessConfig2) of
                {ok, SessId, Pid} ->
                    State2 = links_add(SessId, {session, MemberId}, Pid, State),
                    #{members:=Members1} = Room,
                    Listen1 = maps:get(viewer_session_ids, Info, #{}),
                    Listen2 = maps:put(SessId, PresenterId, Listen1),
                    Role = case Info of
                        #{presenter_session_id:=_} -> presenter;
                        _ -> viewer
                    end,
                    Info2 = Info#{role=>Role, viewer_session_ids=>Listen2},
                    Members2 = maps:put(MemberId, Info2, Members1),
                    Room2 = ?ROOM(#{members=>Members2}, Room),
                    {ok, SessId, Info2, State2#state{room=Room2}};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, presenter_not_found}
    end;

add_session(viewer, _MemberId, _Config, _Info, _State) ->
    {error, missing_presenter};

add_session(_Role, _MemberId, _Config, _Info, _State) ->
    {error, invalid_role}.


%% @private
-spec destroy_member(member_id(), map(), #state{}) ->
    #state{}.

%% @private
destroy_member(MemberId, Info, #state{room=Room}=State) ->
    SessIds1 = case Info of
        #{viewer_session_ids:=ListenIds} ->
            maps:keys(ListenIds);
        _ ->
            []
    end,
    SessIds2 = case Info of
        #{presenter_session_id:=PublishId} ->
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

remove_session(SessId, MemberId, Info, #state{room=Room}=State) ->
    State2 = stop_sessions(MemberId, [SessId], State),
    Info2 = case Info of
        #{presenter_session_id:=SessId} ->
            maps:remove(presenter_session_id, Info);
        #{viewer_session_ids:=Ids1} ->
            Ids2 = maps:remove(SessId, Ids1),
            case map_size(Ids2) of
                0 ->
                    maps:remove(viewer_session_ids, Info);
                _ ->
                    maps:put(viewer_session_ids, Ids2, Info)
            end
    end,
    Role = case Info of
        #{presenter_session_id:=_} -> presenter;
        #{viewer_session_id:=_} -> viewer;
        _ -> removed
    end,
    case Role of
        removed ->
            destroy_member(MemberId, Info2, State);
        _ ->
            Info3 = Info2#{role=>Role},
            #{members:=Members1} = Room,
            Members2 = maps:put(MemberId, Info3, Members1),
            Room2 = ?ROOM(#{members=>Members2}, Room),
            State2#state{room=Room2}
    end.


%% @private
update_all_viewers(PresenterId, PublishId, #state{room=Room}=State) ->
    #{members:=Members} = Room,
    update_all_viewers(maps:to_list(Members), PresenterId, PublishId, State).


%% @private
update_all_viewers([], _PresenterId, _PublishId, State) ->
    State;

update_all_viewers([{_MemberId, Info}|Rest], PresenterId, PublishId, State) ->
    case has_presenter(Info, PresenterId) of
        {true, SessId} ->
                switch_listener(SessId, PublishId);
        false ->
                ok
    end,
    update_all_viewers(Rest, PresenterId, PublishId, State).



%% @private
do_media_room_event({stopped, Reason}, State) ->
    ?LLOG(info, "media room stopped", [], State),
    do_stop(Reason, State);

do_media_room_event({started_member, SessId, _Info}, State) ->
    case links_get(SessId, State) of
        {ok, {session, _MemberId}} ->
            ok;
        not_found ->
            ?LLOG(warning, "received start_member for unknown member ~s", 
                  [SessId], State)
    end,
    {noreply, State};

do_media_room_event({stopped_member, SessId, _Info}, State) ->
    case links_get(SessId, State) of
        {ok, {session, MemberId}} ->
            ?LLOG(warning, "received stopped_member for current member ~p", 
                  [MemberId], State);
        not_found ->
            ok
    end,
    {noreply, State};

do_media_room_event(Event, State) ->
    ?LLOG(warning, "unexpected room event ~p", [Event], State),
    {noreply, State}.


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
    State2 = links_fold(
        fun
            (Link, reg, AccState) ->
                {ok, AccState2} = 
                    handle(nkcollab_room_reg_event, [Id, Link, Event], AccState),
                    AccState2;
            (_Member, _Data, AccState) ->
                AccState
        end,
        State,
        State),
    {ok, State3} = handle(nkcollab_room_event, [Id, Event], State2),
    State3.


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
-spec get_presenter_session(member_id(), #state{}) ->
    {ok, nkmedia_session:id()} | no_publisher | not_presenter.

get_presenter_session(PresenterId, State) ->
    case get_info(PresenterId, State) of
        {ok, #{presenter_session_id:=SessId}} ->
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
has_presenter(#{viewer_session_ids:=Ids}, PresenterId) ->
    case lists:keyfind(PresenterId, 2, maps:to_list(Ids)) of
        {SessId, PresenterId} ->
            {true, SessId};
        false ->
            false
    end.


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
    nkmedia_room:restart_timer(RoomId).



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
