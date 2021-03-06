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

%% @doc Room Plugin Callbacks
-module(nkcollab_room_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0]).
-export([nkcollab_room_init/2, nkcollab_room_stop/2, nkcollab_room_terminate/2, 
         nkcollab_room_event/3, nkcollab_room_reg_event/4, 
         nkcollab_room_reg_down/4,
         nkcollab_room_handle_call/3, nkcollab_room_handle_cast/2, 
         nkcollab_room_handle_info/2]).
-export([error_code/1]).
-export([api_server_cmd/2, api_server_syntax/4, api_server_reg_down/3]).
-export([nkmedia_session_reg_event/4, nkmedia_room_reg_event/4]).
-export([nkcollab_call_start_caller_session/3, nkcollab_call_start_callee_session/4]).

-include("../../include/nkcollab.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-type continue() :: continue | {continue, list()}.




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkcollab, nkcollab_call].




%% ===================================================================
%% Error Codes
%% ===================================================================

%% @doc See nkservice_callbacks
-spec error_code(term()) ->
    {integer(), binary()} | continue.

error_code(media_room_down)         -> {401001, "Media room failed"};
error_code(presenter_not_found)     -> {401002, "Presenter not found"};
error_code(already_listening)       -> {401003, "Already listening"};
error_code(member_is_not_publisher) -> {401004, "Member is not a publisher"};
error_code(_) -> continue.


%% ===================================================================
%% Room Callbacks - Generated from nkcollab_room
%% ===================================================================

-type room_id() :: nkcollab_room:id().
-type room() :: nkcollab_room:room().



%% @doc Called when a new room starts
-spec nkcollab_room_init(room_id(), room()) ->
    {ok, room()} | {error, term()}.

nkcollab_room_init(_RoomId, Room) ->
    {ok, Room}.


%% @doc Called when the room stops
-spec nkcollab_room_stop(Reason::term(), room()) ->
    {ok, room()}.

nkcollab_room_stop(_Reason, Room) ->
    {ok, Room}.


%% @doc Called when the room stops
-spec nkcollab_room_terminate(Reason::term(), room()) ->
    {ok, room()}.

nkcollab_room_terminate(_Reason, Room) ->
    {ok, Room}.


%% @doc Called when the status of the room changes
-spec nkcollab_room_event(room_id(), nkcollab_room:event(), room()) ->
    {ok, room()} | continue().

nkcollab_room_event(RoomId, Event, Room) ->
    nkcollab_room_api_events:event(RoomId, Event, Room),
    {ok, Room}.


%% @doc Called when the status of the room changes, for each registered
%% process to the room
-spec nkcollab_room_reg_event(room_id(), nklib:link(), nkcollab_room:event(), room()) ->
    {ok, room()} | continue().

nkcollab_room_reg_event(RoomId, {nkcollab_api, Pid}, {stopped, Reason}, Room) ->
    nkcollab_room_api:api_room_stopped(RoomId, Pid, Reason, Room),
    {ok, Room};

nkcollab_room_reg_event(_RoomId, _Link, _Event, Room) ->
    {ok, Room}.


%% @doc Called when a registered process fails
-spec nkcollab_room_reg_down(room_id(), nklib:link(), term(), room()) ->
    {ok, room()} | {stop, Reason::term(), room()} | continue().

nkcollab_room_reg_down(_RoomId, _Link, _Reason, Room) ->
    {stop, registered_down, Room}.


%% @doc
-spec nkcollab_room_handle_call(term(), {pid(), term()}, room()) ->
    {reply, term(), room()} | {noreply, room()} | continue().

nkcollab_room_handle_call(Msg, _From, Room) ->
    lager:error("Module nkcollab_room received unexpected call: ~p", [Msg]),
    {noreply, Room}.


%% @doc
-spec nkcollab_room_handle_cast(term(), room()) ->
    {noreply, room()} | continue().

nkcollab_room_handle_cast(Msg, Room) ->
    lager:error("Module nkcollab_room received unexpected cast: ~p", [Msg]),
    {noreply, Room}.


%% @doc
-spec nkcollab_room_handle_info(term(), room()) ->
    {noreply, room()} | continue().

nkcollab_room_handle_info(Msg, Room) ->
    lager:warning("Module nkcollab_room received unexpected info: ~p", [Msg]),
    {noreply, Room}.



%% ===================================================================
%% API Server
%% ===================================================================


%% @private
api_server_cmd(
    #api_req{class=collab, subclass=room, cmd=Cmd}=Req, State) ->
    nkcollab_room_api:cmd(Cmd, Req, State);

api_server_cmd(_Req, _State) ->
    continue.


%% @privat
api_server_syntax(#api_req{class=collab, subclass=room, cmd=Cmd}, 
                  Syntax, Defaults, Mandatory) ->
    nkcollab_room_api_syntax:syntax(Cmd, Syntax, Defaults, Mandatory);
    
api_server_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
    continue.


%% @private
api_server_reg_down({nkcollab_room, RoomId, _Pid}, Reason, State) ->
    nkcollab_room_api:api_room_down(RoomId, Reason, State),
    continue;

api_server_reg_down(_Link, _Reason, _State) ->
    continue.


%% ===================================================================
%% nkmedia_session
%% ===================================================================


% %% @private
nkmedia_session_reg_event(SessId, {nkcollab_room, RoomId, _Pid}, Event, _Session) ->
    nkcollab_room:media_session_event(RoomId, SessId, Event),
    continue;

nkmedia_session_reg_event(_SessId, _Link, _Event, _Session) ->
    continue.


%% ===================================================================
%% nkmedia_room
%% ===================================================================


% %% @private
nkmedia_room_reg_event(RoomId, {nkcollab_room, RoomId, _Pid}, Event, _Session) ->
    nkcollab_room:media_room_event(RoomId, Event),
    continue;

nkmedia_room_reg_event(_RoomId, _Link, _Event, _Session) ->
    continue.



%% ===================================================================
%% Call callbacks
%% ===================================================================

nkcollab_call_start_caller_session(_CallId, _Config, Call) -> 
    case Call of
        #{caller_link:={nkcollab_room, _, _}} ->
            {none, Call};
        _ ->
            continue
    end.


nkcollab_call_start_callee_session(_CallId, _MasterId, _Config, _Call) ->
    continue.
