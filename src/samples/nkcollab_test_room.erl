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
        nkservice_api_gelf
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


%% External
list() ->
    cmd(get_list, #{}).

create(Data) ->
    cmd(create, Data).

destroy(Id) ->
    cmd(destroy, #{room_id=>Id}).

info(Id) ->
    cmd(get_info, #{room_id=>Id}).

presenters(Id) ->
    cmd(get_presenters, #{room_id=>Id}).

viewers(Id) ->
    cmd(get_viewers, #{room_id=>Id}).

destroy_member(Room, Member) ->
    cmd(destroy_member, #{room_id=>Room, member_id=>Member}).

broadcast(Room, MemberId, Msg) ->
    cmd(send_broadcast, #{room_id=>Room, member_id=>MemberId, msg=>Msg}).

get_msgs(RoomId) ->
    cmd(get_all_broadcasts, #{room_id=>RoomId}).

update_meta(RoomId, MemberId, Meta) ->
    cmd(update_meta, #{room_id=>RoomId, member_id=>MemberId, meta=>Meta}).

update_media(RoomId, MemberId, Media) ->
    cmd(update_media, Media#{room_id=>RoomId, member_id=>MemberId}).

update_all_media(RoomId, Media) ->
    cmd(update_all_media, Media#{room_id=>RoomId}).

cmd(Cmd, Data) ->
    Pid = get_client(),
    cmd(Pid, Cmd, Data).

cmd(Pid, Cmd, Data) ->
    nkservice_api_client:cmd(Pid, collab, room, Cmd, Data).


%% Invite
start_viewer(Dest, RoomId, PresenterId) ->
    case nkservice_api_client:get_user_pids(Dest) of
        [Pid|_] ->
            start_viewer(Dest, RoomId, PresenterId, Pid, #{});
        [] ->
            {error, not_found}
    end.


add_listener(Dest, RoomId, MemberId, PresenterId) ->
    case nkservice_api_client:get_user_pids(Dest) of
        [Pid|_] ->
            add_listener(Dest, RoomId, MemberId, PresenterId, Pid, #{});
        [] ->
            {error, not_found}
    end.

remove_listener(RoomId, MemberId, PresenterId) ->
    Pid = get_client(),
    Body = #{room_id=>RoomId, member_id=>MemberId, presenter_id=>PresenterId},
    cmd(Pid, remove_listener, Body).


%% Internal
candidate(Pid, SessId, #candidate{last=true}) ->
    cmd(Pid, set_candidate_end, #{session_id=>SessId});

candidate(Pid, SessId, #candidate{a_line=Line, m_id=Id, m_index=Index}) ->
    Data = #{session_id=>SessId, sdpMid=>Id, sdpMLineIndex=>Index, candidate=>Line},
    cmd(Pid, set_candidate, Data).








% switch(SessId, Pos) ->
%     {ok, listen, #{room_id:=Room}, _} = nkmedia_session:get_type(SessId),
%     {ok, PubId, _Backend} = nkcollab_test:get_publisher(Room, Pos),
%     C = get_client(),
%     type(C, SessId, listen, #{publisher_id=>PubId}).





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
    case create_presenter(Dest, Ws, Opts) of
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
    case create_presenter(Dest, Ws, Opts) of
        {ok, _MemberId, SessId, Answer} ->
            % We register Janus at the session, so that when the session stops,
            % it will be detected (in nkcollab_janus_callbacks)
            {ok, SessPid} = 
                nkmedia_session:register(SessId, {nkcollab_janus, CallId, self()}),
            % We register the session at Janus, so that when we BYE we will stop 
            % the session
            {answer, Answer, {nkmedia_session, SessId, SessPid}, Janus};
        {error, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end;

nkcollab_janus_invite(_SrvId, _CallId, _Offer, _Janus) ->
    continue.


%% @private
nkcollab_janus_candidate(_CallId, {nkmedia_session, SessId, _Pid}, Candidate, 
                         #{test_api_server:=Pid}=Janus) ->
    {ok, _} = candidate(Pid, SessId, Candidate),
    {ok, Janus};

nkcollab_janus_candidate(_CallId, _Link, _Candidate, _Janus) ->
    continue.


%% @private
nkcollab_janus_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, 
                      #{test_api_server:=Pid}=Janus) ->
    {ok, _} = cmd(Pid, set_answer, #{session_id=>SessId, answer=>Answer}),
    {ok, Janus};

nkcollab_janus_answer(_CallId, _Link, _Answer, Janus) ->
    {ok, Janus}.


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
create_presenter(<<"p", RoomId/binary>>, WsPid, Opts) ->
    RoomConfig = #{
        class => sfu, 
        room_id => RoomId,
        backend => nkmedia_janus, 
        bitrate => 100000
    },
    case create(RoomConfig) of
        {ok, _} -> timer:sleep(199);
        {error, {304002, _}} -> ok
    end,
    Opts2 = Opts#{
        room_id => RoomId,
        meta => #{module=>nkcollab_test_room, type=>presenter}
    },
    case cmd(WsPid, create_presenter, Opts2) of
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

create_presenter(<<"u", RoomId/binary>>, WsPid, Opts) ->
    Opts2 = Opts#{
        room_id => RoomId,
        member_id => 1
    },
    case cmd(WsPid, update_publisher, Opts2) of
        {ok, 
            #{
                <<"session_id">> := SessId, 
                <<"answer">> := #{<<"sdp">>:=SDP}
            }
        } ->
            {ok, 1, SessId, #{sdp=>SDP}};
        {error, Error} ->
            {error, Error}
    end;

create_presenter(_Dest, _WsPid, _Opts) ->
    {error, unknown_destination}.


%% @private
start_viewer(Num, RoomId, Presenter, WsPid, Opts) ->
    case nkcollab_test:find_user(Num) of
        not_found ->
            {error, unknown_user};
        Dest ->
            Opts2 = Opts#{
                room_id => RoomId,
                meta => #{module=>nkcollab_test_room, type=>viewer},
                presenter_id => Presenter
            },
            case cmd(WsPid, create_viewer, Opts2) of
                {ok, 
                    #{
                        <<"member_id">> := _MemberId, 
                        <<"session_id">> := SessId, 
                        <<"offer">> := Offer
                    }
                } ->
                    start_invite(Dest, SessId, Offer);
                {error, Error} ->
                    {error, Error}
            end
    end.


%% @private
add_listener(Num, RoomId, Member, Presenter, WsPid, Opts) ->
    case nkcollab_test:find_user(Num) of
        not_found ->
            {error, unknown_user};
        Dest ->
            Opts2 = Opts#{
                room_id => RoomId,
                member_id => Member,
                presenter_id => Presenter
            },
            case cmd(WsPid, add_listener, Opts2) of
                {ok, 
                    #{
                        <<"session_id">> := SessId, 
                        <<"offer">> := Offer
                    }
                } ->
                    start_invite(Dest, SessId, Offer);
                {error, Error} ->
                    {error, Error}
            end
    end.



start_invite(Dest, SessId, Offer) ->
    Syntax = nkmedia_api_syntax:offer(),
    {ok, Offer2, _} = nklib_config:parse_config(Offer, Syntax, #{return=>map}),
    {ok, SessPid} = nkmedia_session:find(SessId),
    Link = {nkmedia_session, SessId, SessPid},
    start_invite2(Dest, SessId, Offer2, Link).


%% @private
start_invite2({nkcollab_verto, VertoPid}, SessId, Offer, SessLink) ->
    % We register the session at Verto, so that Verto can send the answer
    % (nkcollab_verto_answer here) and also send byes
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
    lager:notice("CLIENT ~s event ~s:~s:~s:~s: ~p", 
                 [User, Class, Sub, Type, ObjId, Body]),
    {ok, #{}, UserData};

api_client_fun(_Req, UserData) ->
    #{user:=User} = UserData,
    lager:error("CLIENT ~s req: ~p", [User, lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.


pid2bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin2pid(Bin) -> list_to_pid(binary_to_list(Bin)).
