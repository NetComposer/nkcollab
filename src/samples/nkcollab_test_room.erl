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

%% @doc Testing the media API
-module(nkcollab_test_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Sample (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


-define(URL1, "nkapic://127.0.0.1:9010").
-define(URL2, "nkapic://c2.netc.io:9010").


%% ===================================================================
%% Public
%% ===================================================================


start() ->
    Spec1 = #{
        callback => ?MODULE,
        plugins => [nkmedia_janus, nkmedia_fs, nkmedia_kms],  %% Call janus->fs->kms
        web_server => "https:all:8081",
        web_server_path => "./www",
        api_server => "wss:all:9010",
        api_server_timeout => 180,
        verto_listen => "verto:all:8082",
        verto_proxy => "verto_proxy:all:8083",
        janus_listen => "janus:all:8989", 
        janus_proxy=> "janus_proxy:all:8990",
        kurento_proxy => "kms:all:8433",
        nksip_trace => {console, all},
        sip_listen => "sip:all:9012",
        log_level => debug,
        api_gelf_server => "c2.netc.io"
    },
    Spec2 = nkmedia_util:add_certs(Spec1),
    nkservice:start(test, Spec2).


stop() ->
    nkservice:stop(test).

restart() ->
    stop(),
    timer:sleep(100),
    start().




%% ===================================================================
%% Config callbacks
%% ===================================================================



plugin_deps() ->
    [
        nkcollab_room,
        nksip_registrar, nksip_trace,
        nkmedia_janus, nkmedia_fs, nkmedia_kms, 
        nkmedia_janus_proxy, nkmedia_kms_proxy,
        nkcollab_verto, nkcollab_janus, nkcollab_sip,
        nkservice_api_gelf,
        nkmedia_room_msglog
    ].




%% ===================================================================
%% Cmds
%% ===================================================================

%% Connect
connect() ->
    connect(u1, #{}).

connect(User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, Pid} = nkservice_api_client:start(test, ?URL1, User, "p1", Fun, Data),
    Pid.

connect2() ->
    connect2(u1, #{}).

connect2(User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, Pid} = nkservice_api_client:start(test, ?URL2, User, "p1", Fun, Data),
    Pid.

get_client() ->
    [{_, Pid}|_] = nkservice_api_client:get_all(),
    Pid.


%% Room
list(Pid) ->
    cmd(Pid, get_list, #{}).

create(Pid, Data) ->
    cmd(Pid, create, Data).

destroy(Pid, Id) ->
    cmd(Pid, destroy, #{room_id=>Id}).

info(Pid, Id) ->
    cmd(Pid, get_info, #{room_id=>Id}).

presenters(Pid, Id) ->
    cmd(Pid, get_presenters, #{room_id=>Id}).

cmd(Pid, Cmd, Data) ->
    nkservice_api_client:cmd(Pid, collab, room, Cmd, Data).



destroy_member(Pid, Room, Member) ->
    cmd(Pid, destroy_member, #{room_id=>Room, member_id=>Member}).




%% Session
media(Pid, Data) ->
    cmd(Pid, update_media, Data).

candidate(Pid, SessId, #candidate{last=true}) ->
    cmd(Pid, set_candidate_end, #{session_id=>SessId});

candidate(Pid, SessId, #candidate{a_line=Line, m_id=Id, m_index=Index}) ->
    Data = #{session_id=>SessId, sdpMid=>Id, sdpMLineIndex=>Index, candidate=>Line},
    cmd(Pid, set_candidate, Data).




%% Events

subscribe_session(Pid, SessId, Body) ->
    Data = #{class=>media, subclass=>session, obj_id=>SessId, body=>Body},
    nkservice_api_client:cmd(Pid, core, event, subscribe, Data).


subscribe(Pid, SessId, Body) ->
    Data = #{class=>media, subclass=>session, obj_id=>SessId, body=>Body},
    nkservice_api_client:cmd(Pid, core, event, subscribe, Data).


subscribe_all(Pid) ->
    Data = #{class=>media},
    nkservice_api_client:cmd(Pid, core, event, subscribe, Data).




%% Invite
start_viewer(Dest, RoomId, PresenterId) ->
    case nkservice_api_client:get_user_pids(Dest) of
        [Pid|_] ->
            start_viewer(Dest, RoomId, PresenterId, Pid, #{});
        [] ->
            {error, not_found}
    end.

% switch(SessId, Pos) ->
%     {ok, listen, #{room_id:=Room}, _} = nkmedia_session:get_type(SessId),
%     {ok, PubId, _Backend} = nkcollab_test:get_publisher(Room, Pos),
%     C = get_client(),
%     type(C, SessId, listen, #{publisher_id=>PubId}).



% %% Msglog
broadcast(Pid, Room, Msg) ->
    cmd(Pid, send_broadcast, #{room_id=>Room, msg=>Msg}).


%% Gelf
gelf(C, Src, Short) ->
    Msg = #{
        source => Src,
        message => Short,
        full_message => base64:encode(crypto:rand_bytes(10))
    },
    nkservice_api_client:cmd(C, core, session, log, Msg).



 

%% ===================================================================
%% api server callbacks
%% ===================================================================


%% @doc Called on login
api_server_login(#{<<"user">>:=User}, _SessId, State) ->
    nkservice_api_server:start_ping(self(), 60),
    {true, User, State};

api_server_login(_Data, _SessId, _State) ->
    continue.


%% @doc
api_allow(_Req, State) ->
    {true, State}.


%% @oc
api_subscribe_allow(_SrvId, _Class, _SubClass, _Type, State) ->
    {true, State}.




%% ===================================================================
%% nkcollab_verto callbacks
%% ===================================================================

%% @private
nkcollab_verto_login(Login, Pass, Verto) ->
    case nkcollab_test:nkcollab_verto_login(Login, Pass, Verto) of
        {true, User, Verto2} ->
            Pid = connect(User, #{test_verto_server=>self()}),
            {true, User, Verto2#{test_api_server=>Pid}};
        Other ->
            Other
    end.


% @private Called when we receive INVITE from Verto
nkcollab_verto_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Verto) ->
    #{dest:=Dest} = Offer,
    Opts = #{
        offer => Offer,
        no_answer_trickle_ice => true,
        events_body => #{
            verto_call_id => CallId,
            verto_pid => pid2bin(self())
        }
    },
    case start_presenter(Dest, Ws, Opts) of
        {ok, _MemberId, SessId, Answer} ->
            % We register Verto at the session, so that when the session stops,
            % it will be detected (in nkcollab_verto_callbacks)
            {ok, SessPid} = 
                nkmedia_session:register(SessId, {nkcollab_verto, CallId, self()}),
            % We register the session at Verto, so that when we BYE we will stop 
            % the session
            {answer, Answer, {nkmedia_session, SessId, SessPid}, Verto};
        {error, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end;

nkcollab_verto_invite(_SrvId, _CallId, _Offer, _Verto) ->
    continue.


%% @private
nkcollab_verto_answer(_CallId, {nkmedia_session, SessId, _SessPid}, Answer, 
                     #{test_api_server:=Ws}=Verto) ->
    {ok, _} = cmd(Ws, set_answer, #{session_id=>SessId, answer=>Answer}),
    {ok, Verto};

nkcollab_verto_answer(_CallId, _Link, _Answer, Verto) ->
    {ok, Verto}.


% % @private Called when we receive BYE from Verto
% nkcollab_verto_bye(_CallId, {room, _RoomId, _MemberId, SessId}, Verto) ->
%     nkmedia_session:stop(SessId, verto_bye),
%     {ok, Verto};

nkcollab_verto_bye(_CallId, _Link, _Verto) ->
    continue.

%% @private
nkcollab_verto_terminate(_Reason, #{test_api_server:=Pid}=Verto) ->
    nkservice_api_client:stop(Pid),
    {ok, Verto};

nkcollab_verto_terminate(_Reason, Verto) ->
    {ok, Verto}.



%% ===================================================================
%% nkcollab_janus callbacks
%% ===================================================================

%% @private
nkcollab_janus_registered(User, Janus) ->
    Pid = connect(User, #{test_janus_server=>self()}),
    {ok, Janus#{test_api_server=>Pid}}.


% @private Called when we receive INVITE from Janus
nkcollab_janus_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Janus) ->
    #{dest:=Dest} = Offer,
    Opts = #{
        offer => Offer,
        no_answer_trickle_ice => true,
        events_body => #{
            janus_call_id => CallId,
            janus_pid => pid2bin(self())
        }
    },
    case start_presenter(Dest, Ws, Opts) of
        {ok, SessId, _SessPid} ->
            {ok, {api_test_session, SessId, Ws}, Janus};
        {error, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end.


%% @private
nkcollab_janus_candidate(_CallId, {api_test_session, SessId, WsPid}, Candidate, Janus) ->
    {ok, _} = candidate(WsPid, SessId, Candidate),
    {ok, Janus};

nkcollab_janus_candidate(_CallId, _Link, _Candidate, _Janus) ->
    continue.


%% @private
nkcollab_janus_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, 
                     #{test_api_server:=Ws}=Janus) ->
    {ok, _} = cmd(Ws, set_answer, #{session_id=>SessId, answer=>Answer}),
    {ok, Janus};

nkcollab_janus_answer(_CallId, _Link, _Answer, Janus) ->
    {ok, Janus}.


%% @private BYE from Janus
nkcollab_janus_bye(_CallId, {api_test_session, SessId, WsPid}, Janus) ->
    lager:notice("Janus Session BYE for ~s (~p)", [SessId, WsPid]),
    {ok, _} = cmd(WsPid, SessId, destroy),
    {ok, Janus};

nkcollab_janus_bye(_CallId, _Link, _Janus) ->
    continue.


%% @private
nkcollab_janus_terminate(_Reason, #{test_api_server:=Pid}=Janus) ->
    nkservice_api_client:stop(Pid),
    {ok, Janus};

nkcollab_janus_terminate(_Reason, Janus) ->
    {ok, Janus}.





%% ===================================================================
%% Internal
%% ===================================================================

%% @private
start_presenter(<<"p", RoomId/binary>>, WsPid, Opts) ->
    RoomConfig = #{
        class => sfu, 
        room_id => RoomId,
        backend => nkmedia_janus, 
        bitrate => 100000
    },
    case create(WsPid, RoomConfig) of
        {ok, _} -> ok;
        {error, {304002, _}} -> ok
    end,
    Opts2 = Opts#{
        room_id => RoomId,
        meta => #{module=>nkcollab_test_room, type=>presenter}
    },
    case cmd(WsPid, start_presenter, Opts2) of
        {ok, 
            #{
                <<"member_id">> := MemberId, 
                <<"session_id">> := SessId, 
                <<"answer">> := #{<<"sdp">>:=SDP}
            }
        } ->
            {ok, MemberId, SessId, #{sdp=>SDP}};
        {error, Error} ->
            {error, Error}
    end;

start_presenter(_Dest, _WsPid, _Opts) ->
    {error, unknown_destination}.


%% @private
start_viewer(Num, RoomId, Presenter, WsPid, Opts) ->
    case nkcollab_test:find_user(Num) of
        not_found ->
            {error, unknown_user};
        Dest ->
            Opts2 = Opts#{
                room_id => RoomId,
                backend => nkmedia_janus,
                meta => #{module=>nkcollab_test_room, type=>viewer},
                presenter_id => Presenter
            },
            case cmd(WsPid, start_viewer, Opts2) of
                {ok, 
                    #{
                        <<"member_id">> := _MemberId, 
                        <<"session_id">> := SessId, 
                        <<"offer">> := Offer
                    }
                } ->
                    Syntax = nkmedia_api_syntax:offer(),
                    {ok, Offer2, _} = 
                        nklib_config:parse_config(Offer, Syntax, #{return=>map}),
                    {ok, SessPid} = nkmedia_session:find(SessId),
                    Link = {nkmedia_session, SessId, SessPid},
                    start_invite2(Dest, SessId, Offer2, Link);
                {error, Error} ->
                    {error, Error}
            end
    end.


%% @private
start_invite2({nkcollab_verto, VertoPid}, SessId, Offer, SessLink) ->
    % We register the session at Verto, so that Verto can send the answer
    % (nkcollab_verto_answer here) and stops
    {ok, InvLink} = nkcollab_verto:invite(VertoPid, SessId, Offer, SessLink),
    % We register Verto at the session, so that Verto detects stops
    {ok, _} = nkmedia_session:register(SessId, InvLink);

start_invite2({nkcollab_janus, JanusPid}, SessId, Offer, SessLink) ->
    {ok, InvLink} = nkcollab_janus:invite(JanusPid, SessId, Offer, SessLink),
    {ok, _} = nkmedia_session:register(SessId, InvLink).



%% @private
api_client_fun(#api_req{class = <<"core">>, cmd = <<"event">>, data = Data}, UserData) ->
    #{user:=User} = UserData,
    Class = maps:get(<<"class">>, Data),
    Sub = maps:get(<<"subclass">>, Data, <<"*">>),
    Type = maps:get(<<"type">>, Data, <<"*">>),
    ObjId = maps:get(<<"obj_id">>, Data, <<"*">>),
    Body = maps:get(<<"body">>, Data, #{}),
    Sender = case Body of
        #{
            <<"verto_call_id">> := SCallId,
            <<"verto_pid">> := BinPid
        } ->
            {verto, SCallId, bin2pid(BinPid)};
        #{
            <<"janus_call_id">> := SCallId,
            <<"janus_pid">> := BinPid
        } ->
            {janus, SCallId,  bin2pid(BinPid)};
        _ ->
            unknown
    end,
    case {Class, Sub, Type} of
        % {<<"media">>, <<"session">>, <<"answer">>} ->
        %     #{<<"answer">>:=#{<<"sdp">>:=SDP}} = Body,
        %     case Sender of
        %         {verto, CallId, Pid} ->
        %             nkcollab_verto:answer_async(Pid, CallId, #{sdp=>SDP});
        %         {janus, CallId, Pid} ->
        %             nkcollab_janus:answer_async(Pid, CallId, #{sdp=>SDP});
        %         unknown ->
        %             lager:notice("TEST CLIENT ANSWER")
        %     end;
        {<<"collab">>, <<"room">>, <<"stopped_session">>} ->
            case Sender of
                {verto, CallId, Pid} ->
                    nkcollab_verto:hangup(Pid, CallId);
                {janus, CallId, Pid} ->
                    nkcollab_janus:hangup(Pid, CallId);
                unknown ->
                    lager:notice("UNMANAGED CLIENT SESSION STOP: ~p", [Data])
            end;
        _ ->
            lager:notice("CLIENT ~s event ~s:~s:~s:~s: ~p", 
                         [User, Class, Sub, Type, ObjId, Body])
    end,
    {ok, #{}, UserData};

api_client_fun(_Req, UserData) ->
    #{user:=User} = UserData,
    lager:error("CLIENT ~s req: ~p", [User, lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.


pid2bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin2pid(Bin) -> list_to_pid(binary_to_list(Bin)).
