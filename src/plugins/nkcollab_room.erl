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

-export([start/2, stop/1, stop/2, get_room/1, get_info/1]).
-export([add_member/2, remove_member/2, send_msg/2, get_all_msgs/1]).
-export([set_answer/3, get_answer/2, candidate/3, update_media/3]).
-export([started_member/3, started_member/4, stopped_member/2]).
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
-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


-define(CHECK_TIME, 5*60).  


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type session_id() :: nkmedia_session:id().

-type class() :: sfu | mcu.

-type backend() :: nkmedia_janus | nkmedia_kms | nkmedia_fs.

-type config() ::
    #{
        class => class(), 
        backend => backend(),
        audio_codec => opus | isac32 | isac16 | pcmu | pcma,    % info only
        video_codec => vp8 | vp9 | h264,                        % "
        bitrate => integer(),                                   % "
        register => nklib:link()
    }.

-type room() ::
    config() |
    #{
        room_id => id(),
        srv_id => nkservice:id()
    }.


-type meta() ::
    map().

-type add_opts() ::
    #{
        offer => nkmedia:offer(),
        meta => meta(),
        no_offer_trickle_ice => boolean(),          % Buffer candidates and insert in SDP
        no_answer_trickle_ice => boolean(),       
        trickle_ice_timeout => integer(),
        user_id => nkservice:user_id(),             % Informative only
        user_session => nkservice:user_session(),   % Informative only
        publisher_id => binary(),
        mute_audio => boolean(),
        mute_video => boolean(),
        mute_data => boolean(),
        bitrate => integer()
    }.



-type member_id() ::
    nkmedia_session:id().


-type member_info() ::
    #{
        role => publisher | listener,
        user_id => binary(),
        peer_id => session_id(),
        meta => meta()
    }.

-type event() :: 
    started |
    {stopped, nkservice:error()} |
    {started_member, session_id(), member_info()} |
    {stopped_member, session_id(), member_info()} |
    {new_msg, msg()}.



-type msg_id() ::
    integer().


-type msg() ::
    #{
        msg_id => msg_id(),
        user_id => binary(),
        session_id => binary(),
        timestamp => nklib_util:l_timestamp()
    }.

-type media() ::
    #{
    }.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Creates a new room
-spec start(nkservice:id(), config()) ->
    {ok, id(), pid()} | {error, term()}.

start(Srv, Config) ->
    {RoomId, Config2} = nkcollab_util:add_id(room_id, Config, room),
    case find(RoomId) of
        {ok, _} ->
            {error, room_already_exists};
        not_found ->
            case nkservice_srv:get_srv_id(Srv) of
                {ok, SrvId} ->
                    % Get events and detect we killed at nkmedia_room
                    Media = Config2#{
                        register => {nkcollab_room, RoomId, self()}
                    },
                    case nkmedia_room:start(SrvId, Media) of
                        {ok, RoomId, RoomPid} ->
                            Config3 = Config2#{srv_id=>SrvId, room_pid=>RoomPid},
                            {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
                            {ok, RoomId, Pid};
                        {error, Error} ->
                            {error, Error}
                    end;
                not_found ->
                    {error, service_not_found}
            end
    end.


%% @doc
-spec stop(id()) ->
    ok | {error, term()}.

stop(Id) ->
    stop(Id, normal).


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
-spec get_info(id()) ->
    {ok, room()} | {error, term()}.

get_info(Id) ->
    case get_room(Id) of
        {ok, Room} ->
            Keys = [
                class, 
                backend,
                members, 
                audio_codec, 
                video_codec, 
                bitrate
            ],
            {ok, maps:with(Keys, Room)};
        {error, Error} ->
            {error, Error}
    end.



%% @doc 
-spec add_member(id(), add_opts()) ->
    {ok, map()} | {error, term()}.

add_member(Id, Config) ->
    do_call(Id, {add_member, Config}).


%% @doc 
-spec remove_member(id(), member_id()) ->
    ok | {error, term()}.

remove_member(Id, MemberId) ->
    do_call(Id, {remove_member, MemberId}).


%% @doc 
-spec set_answer(id(), member_id(), nkmedia:answer()) ->
    ok | {error, term()}.

set_answer(Id, MemberId, Answer) ->
    do_call(Id, {set_answer, MemberId, Answer}).


%% @doc 
-spec get_answer(id(), member_id()) ->
    {ok, nkmedia:answer()} | {error, term()}.

get_answer(Id, MemberId) ->
    do_call(Id, {get_answer, MemberId}).


%% @doc Sends a ICE candidate from the client to the backend
-spec candidate(id(), member_id(), nkmedia:candidate()) ->
    ok | {error, term()}.

candidate(Id, MemberId, #candidate{}=Candidate) ->
    do_call(Id, {candidate, MemberId, Candidate}).

%% @private
-spec update_media(id(), member_id(), media()) ->
    ok | {error, term()}.

update_media(Id, MemberId, Media) ->
    do_call(Id, {update_media, MemberId, Media}).


%% @private
-spec send_msg(id(), msg()) ->
    {ok, msg_id()} | {error, term()}.

send_msg(Id, Msg) when is_map(Msg) ->
    do_call(Id, {send_msg, Msg}).


%% @private
-spec get_all_msgs(id()) ->
    {ok, [msg()]} | {error, term()}.

get_all_msgs(Id) ->
    do_call(Id, get_all_msgs).


%% @doc
-spec started_member(id(), session_id(), member_info()) ->
    ok | {error, term()}.

started_member(RoomId, MemberId, MemberInfo) ->
    started_member(RoomId, MemberId, MemberInfo, undefined).


%% @doc
-spec started_member(id(), session_id(), member_info(), pid()|undefined) ->
    ok | {error, term()}.

started_member(RoomId, MemberId, MemberInfo, Pid) ->
    do_cast(RoomId, {started_member, MemberId, MemberInfo, Pid}).


%% @doc
-spec stopped_member(id(), session_id()) ->
    ok | {error, term()}.

stopped_member(RoomId, MemberId) ->
    do_cast(RoomId, {stopped_member, MemberId}).


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
    [{id(), nkcollab:backend(), pid()}].

get_all() ->
    [{Id, Backend, Pid} || 
        {{Id, Backend}, Pid}<- nklib_proc:values(?MODULE)].


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
    stop_sent = false :: boolean(),
    links :: nklib_links:links(),
    msg_pos = 1 :: integer(),
    msgs :: orddict:orddict(),
    room :: room()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{srv_id:=SrvId, room_id:=RoomId, room_pid:=RoomPid}=Room]) ->
    yes = nklib_proc:reg({?MODULE, RoomId}),
    Backend = maps:get(backend, Room, undefined),
    nklib_proc:put(?MODULE, {RoomId, Backend}),
    State1 = #state{
        id = RoomId, 
        srv_id = SrvId, 
        backend = Backend,
        links = nklib_links:new(),
        msgs = orddict:new(),
        room = Room#{members=>#{}}
    },
    State2 = links_add(nkmedia_room, none, RoomPid, State1),
    State3 = case Room of
        #{register:=Link} ->
            links_add(Link, State2);
        _ ->
            State2
    end,
    ?LLOG(notice, "started", [], State3),
    State4 = do_event(started, State3),
    {ok, State4}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

    
handle_call({add_member, Config}, _From, State) ->
    do_add_member(Config, State);

handle_call({remove_member, MemberId}, _From, State) ->
    case do_stop_member(MemberId, user_stop, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {not_found, State2} ->
            {reply, {error, not_found}, State2}
    end;

handle_call({set_answer, MemberId, Answer}, _From, State) ->
    case get_info(MemberId, State) of
        {ok, _} ->
            Reply = case nkmedia_session:set_answer(MemberId, Answer) of
                {error, session_not_found} ->
                    {error, member_not_found};
                Other ->
                    Other
            end,
            {reply, Reply, State};
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call({get_answer, MemberId}, From, State) ->
    case get_info(MemberId, State) of
        {ok, _} ->
            spawn(
                fun() ->
                    Reply = case nkmedia_session:get_answer(MemberId) of
                        {error, session_not_found} ->
                            {error, member_not_found};
                        Other ->
                            Other
                    end,
                    gen_server:reply(From, Reply)
                end),
            {noreply, State};
        not_found ->
            {reply, {error, member_not_found}, State}
    end;

handle_call(get_room, _From, #state{room=Room}=State) -> 
    {reply, {ok, Room}, State};

handle_call({send_msg, Msg}, _From, #state{msg_pos=Pos, msgs=Msgs}=State) ->
    % nkcollab_room:restart_timer(Room),
    Msg2 = Msg#{msg_id => Pos},
    State2 = State#state{
        msg_pos = Pos+1, 
        msgs = orddict:store(Pos, Msg2, Msgs)
    },
    {reply, {ok, Pos}, State2};

handle_call(get_all_msgs, _From, #state{msgs=Msgs}=State) ->
    % nkcollab_room:restart_timer(Room),
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
handle_cast({register, Link}, State) ->
    ?LLOG(info, "proc registered (~p)", [Link], State),
    State2 = links_add(Link, State),
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
            do_stop(media_room_stopped, State2);
        {ok, MemberId, member, State2} ->
            ?LLOG(notice, "member ~s down", [MemberId], State2),
            {_, State3} = do_stop_member(MemberId, process_down, State2),
            {noreply, State3};
        {ok, Link, reg, State2} ->
            ?LLOG(notice, "stopping beacuse of reg '~p' down (~p)",
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

terminate(Reason, State) ->
    {ok, State2} = handle(nkcollab_room_terminate, [Reason], State),
    case Reason of
        normal ->
            ?LLOG(info, "terminate: ~p", [Reason], State2),
            _ = do_stop(normal_termination, State2);
        _ ->
            Ref = nkcollab_lib:uid(),
            ?LLOG(notice, "terminate error ~s: ~p", [Ref, Reason], State2),
            _ = do_stop({internal_error, Ref}, State2)
    end,    
    timer:sleep(100),
    ok.

% ===================================================================
%% Internal
%% ===================================================================

%% @private
do_add_member(Config, #state{id=RoomId, srv_id=SrvId, backend=Backend}=State) ->
    Config2 = maps:with(session_opts(), Config),
    Config3 = Config2#{
        register => {nkcollab_room, RoomId, self()},
        backend => Backend,
        room_id => RoomId
    },
    Type = case maps:find(role, Config) of
        {ok, publisher} -> publish;
        {ok, listener} -> listen;
        _ -> error
    end,
    case Type of
        error ->
            {reply, {error, invalid_role}, State};
        Type ->
            case nkmedia_session:start(SrvId, Type, Config3) of
                {ok, MemberId, Pid} ->
                    Info = maps:with(info_opts(), Config),
                    State2 = do_started_member(MemberId, Info, Pid, State),
                    {reply, {ok, MemberId}, State2};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end
    end.


%% @private
do_started_member(MemberId, Info, Pid, #state{room=#{members:=Members}=Room}=State) ->
    State2 = links_remove(MemberId, State),
    State3 = links_add(MemberId, member, Pid, State2),        
    Room2 = ?ROOM(#{members=>maps:put(MemberId, Info, Members)}, Room),
    State4 = State3#state{room=Room2},
    do_event({started_member, MemberId, Info}, State4).


%% @private
do_stop_member(MemberId, Reason, State) ->
    #state{room=#{members:=Members}=Room}=State,
    case get_info(MemberId, State) of
        {ok, Info} ->
            nkmedia_session:stop(MemberId, Reason),
            State2 = links_remove(MemberId, State),
            Members2 = maps:remove(MemberId, Members),
            Room2 = ?ROOM(#{members=>Members2}, Room),
            State3 = State2#state{room=Room2},
            {ok, do_event({stopped_member, MemberId, Info}, State3)};
        not_found ->
            {not_found, State}
    end.


%% @private
do_stop_all(Reason, #state{room=#{members:=Members}}=State) ->
    lists:foldl(
        fun({MemberId, _Info}, Acc) ->
            {_, Acc2} = do_stop_member(MemberId, Reason, Acc),
            Acc2
        end,
        State,
        maps:to_list(Members)).






%% @private
do_media_room_event({stopped, Reason}, State) ->
    ?LLOG(info, "media room stopped", [], State),
    do_stop(Reason, State);

do_media_room_event({started_member, MemberId, _Info}, State) ->
    case get_info(MemberId, State) of
        {ok, _} ->
            ok;
        not_found ->
            ?LLOG(warning, "received start_member for unknown member ~s", 
                  [MemberId], State)
    end,
    {noreply, State};

do_media_room_event({stopped_member, MemberId, _Info}, State) ->
    case get_info(MemberId, State) of
        {ok, _} ->
            ?LLOG(warning, "received stopped_member for current member ~s", 
                  [MemberId], State);
        error ->
            ok
    end,
    {noreply, State};

do_media_room_event(Event, State) ->
    ?LLOG(warning, "unexpected room event ~p", [], Event),
    {noreply, State}.



%% @private
get_info(MemberId, #state{room=#{members:=Members}}) ->
    case maps:find(MemberId, Members) of
        {ok, Info} -> {ok, Info};
        error -> not_found
    end.


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
do_stop(_Reason, #state{stop_sent=true}=State) ->
    {stop, normal, State};

do_stop(Reason, State) ->
    State2 = do_stop_all(room_destroyed, State),
    State3 = do_event({stopped, Reason}, State2#state{stop_sent=true}),
    % Allow events to be processed
    timer:sleep(100),
    {stop, normal, State3}.


%% @private
do_event(Event, #state{id=Id}=State) ->
    ?LLOG(info, "sending 'event': ~p", [Event], State),
    State2 = links_fold(
        fun
            (Link, reg, AccState) ->
                {ok, AccState2} = 
                    handle(nkcollab_room_reg_event, [Id, Link, Event], AccState),
                    AccState2;
            (_MemberId, member, AccState) ->
                AccState
        end,
        State,
        State),
    {ok, State3} = handle(nkcollab_room_event, [Id, Event], State2),
    State3.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.room).


%% @private
links_add(Id, #state{links=Links}=State) ->
    Pid = nklib_links:get_pid(Id),
    State#state{links=nklib_links:add(Id, reg, Pid, Links)}.


%% @private
links_add(Id, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Id, Data, Pid, Links)}.


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
info_opts() ->
    [role, peer_id, user_id, session_id, meta].


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
