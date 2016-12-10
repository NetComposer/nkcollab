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

%% @doc Testing room system
%% - With Janus or Verto, dial "pROOM" to enter as presenter in a room
%% - Then add listeners with add_listener
%%   or create viewers
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%






-module(nkcollab_test_room).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Sample (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


-define(URL, "wss://127.0.0.1:9010").


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
        debug => [nkcollab_room],
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
    connect(test, u1, #{}).

connect(SrvId, User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    Login = #{user => nklib_util:to_binary(User), password=><<"p1">>},
    {ok, _, Pid} = nkservice_api_client:start(SrvId, ?URL, Login, Fun, Data),
    Pid.


get_client() ->
    [{_, Pid}|_] = nkservice_api_client:get_all(),
    Pid.


%% External
list() ->
    cmd(get_list, #{}).

create(Data) ->
    case cmd(create, Data#{room_meta => #{?MODULE=>room_meta}}) of
        {ok, _} -> timer:sleep(200);
        {error, {304002, _}} -> ok
    end.

destroy() ->
    cmd(destroy, #{room_id=>test}).

get_info() ->
    cmd(get_info, #{room_id=>test}).

get_publishers() ->
    cmd(get_publishers, #{room_id=>test}).

get_listeners() ->
    cmd(get_listeners, #{room_id=>test}).

get_sessions() ->
    cmd(get_user_sessions, #{room_id=>test}).

get_all_sessions() ->
    cmd(get_user_all_sessions, #{room_id=>test}).

remove(SessId) ->
    cmd(remove_session, #{room_id=>test, session_id=>SessId}).

remove_user_sessions() ->
    cmd(remove_user_sessions, #{room_id=>test}).

remove_user_all_sessions() ->
    cmd(remove_user_all_sessions, #{room_id=>test}).

send_msg(Msg) ->
    cmd(send_msg, #{room_id=>test, msg=>Msg}).

get_msgs() ->
    cmd(get_all_msgs, #{room_id=>test}).

update_media(SessId, Media) ->
    cmd(update_media, Media#{room_id=>test, session_id=>SessId}).

update_status(SessId, Media) ->
    cmd(update_status, Media#{room_id=>test, session_id=>SessId}).

timelog(Msg, Body) ->
    cmd(add_timelog, #{room_id=>test, msg=>Msg, body=>Body}).

cmd(Cmd, Data) ->
    Pid = get_client(),
    cmd(Pid, Cmd, Data).

cmd(Pid, Cmd, Data) ->
    nkservice_api_client:cmd(Pid, collab, room, Cmd, Data).


%% Invite
start_viewer(Dest, Presenter) ->
    case nkservice_api_client:get_user_pids(Dest) of
        [Pid|_] ->
            start_viewer(Dest, Presenter, Pid, #{});
        [] ->
            {error, not_found}
    end.


% add_listener(Dest, RoomId, MemberId, PresenterId) ->
%     case nkservice_api_client:get_user_pids(Dest) of
%         [Pid|_] ->
%             add_listener(Dest, RoomId, MemberId, PresenterId, Pid, #{});
%         [] ->
%             {error, not_found}
%     end.

% remove_listener(RoomId, MemberId, PresenterId) ->
%     Pid = get_client(),
%     Body = #{room_id=>RoomId, member_id=>MemberId, presenter_id=>PresenterId},
%     cmd(Pid, remove_listener, Body).


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
api_server_login(#{user:=User}, State) ->
    {true, User, #{}, State};

api_server_login(_Data, _State) ->
    continue.


%% @doc
api_server_allow(_Req, State) ->  
    {true, State}.





%% ===================================================================
%% nkcollab_verto callbacks
%% ===================================================================

%% @private
nkcollab_verto_login(Login, Pass, #{srv_id:=SrvId}=Verto) ->
    case nkcollab_test:nkcollab_verto_login(Login, Pass, Verto) of
        {true, User, Verto2} ->
            Pid = connect(SrvId, User, #{test_verto_server=>self()}),
            {true, User, Verto2#{test_api_server=>Pid}};
        Other ->
            Other
    end.


% @private Called when we receive INVITE from Verto
nkcollab_verto_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Verto) ->
    #{dest:=Dest} = Offer,
    Opts = #{
        offer => Offer,
        no_answer_trickle_ice => true
    },
    Events = #{
        verto_call_id => CallId,
        verto_pid => pid2bin(self())
    },
    case create_publisher(Dest, Ws, Opts, Events) of
        {ok, SessId, Answer} ->
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
nkcollab_janus_registered(User, #{srv_id:=SrvId}=Janus) ->
    Pid = connect(SrvId, User, #{test_janus_server=>self()}),
    {ok, Janus#{test_api_server=>Pid}}.


% @private Called when we receive INVITE from Janus
nkcollab_janus_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Janus) ->
    #{dest:=Dest} = Offer,
    Opts = #{
        offer => Offer,
        no_answer_trickle_ice => true
    },
    Events = #{
        janus_call_id => CallId,
        janus_pid => pid2bin(self())
    },
    case create_publisher(Dest, Ws, Opts, Events) of
        {ok, SessId, Answer} ->
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
create_publisher(<<"p", Meta/binary>>, WsPid, Opts, Events) ->
    RoomConfig = #{
        class => sfu, 
        room_id => test,
        backend => nkmedia_janus
    },
    ok = create(RoomConfig),
    Opts2 = Opts#{
        room_id => test,
        class => type1,
        device => device1,
        session_meta => #{?MODULE=>#{session_meta=>Meta}},
        session_events => [answer, destroyed, status],
        session_events_body => Events,
        room_events => [started_publisher, updated_publisher, destroyed],
        room_events_body => #{?MODULE=>body}
    },
    case cmd(WsPid, add_publish_session, Opts2) of
        {ok, 
            #{
                <<"session_id">> := SessId, 
                <<"answer">> := #{<<"sdp">>:=SDP}
            }
        } ->
            {ok, SessId, #{sdp=>SDP}};
        {error, Error} ->
            {error, Error}
    end;

% create_publisher(<<"u", RoomId/binary>>, WsPid, Opts) ->
%     Opts2 = Opts#{
%         room_id => RoomId,
%         member_id => 1
%     },
%     case cmd(WsPid, update_publisher, Opts2) of
%         {ok, 
%             #{
%                 <<"session_id">> := SessId, 
%                 <<"answer">> := #{<<"sdp">>:=SDP}
%             }
%         } ->
%             {ok, 1, SessId, #{sdp=>SDP}};
%         {error, Error} ->
%             {error, Error}
%     end;

create_publisher(_Dest, _WsPid, _Opts, _Events) ->
    {error, unknown_destination}.


%% @private
start_viewer(Num, Presenter, WsPid, Opts) ->
    case nkcollab_test:find_user(Num) of
        not_found ->
            {error, unknown_user};
        Dest ->
            case find_publisher(Presenter) of
                {ok, PublisherId} ->
                    create_listener(Dest, WsPid, PublisherId, Opts);
                {error, Error} ->
                    {error, Error}
            end
    end.



%% @private
create_listener(Dest, Pid, PublisherId, Opts) ->
    Opts2 = Opts#{
        room_id => test,
        class => class2,
        type => type2,
        session_meta => #{?MODULE=>listener},
        session_events => [answer, destroyed, status],
        % session_events_body => Events,
        room_events => [started_publisher, updated_publisher, destroyed],
        room_events_body => #{?MODULE=>body},
        publisher_id => PublisherId
    },
    case cmd(Pid, add_listen_session, Opts2) of
        {ok, 
            #{
                <<"session_id">> := SessId, 
                <<"offer">> := Offer
            }
        } ->
            start_invite(Dest, SessId, Offer);
        {error, Error} ->
            {error, Error}
    end.


start_invite(Dest, SessId, Offer) ->
    Syntax = nkmedia_session_api_syntax:offer(),
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



find_publisher(Presenter) ->
    Presenter2 = nklib_util:to_binary(Presenter),
    {ok, All} = get_publishers(),
    List = [
        SessId || 
        #{<<"session_id">>:=SessId, <<"user_id">>:=User} <- All, User==Presenter2
    ],
    case List of
        [First|_] -> {ok, First};
        [] -> {error, not_found}
    end.





%% @private
api_client_fun(#api_req{class=event, data=Event}, UserData) ->
    #{user:=User} = UserData,
    #event{class=Class, subclass=Sub, type=Type, obj_id=ObjId, body=Body}=Event,
    lager:notice("CLIENT ~s event ~s:~s:~s:~s: ~p", 
                 [User, Class, Sub, Type, ObjId, Body]),
    {ok, #{}, UserData};

api_client_fun(_Req, UserData) ->
    #{user:=User} = UserData,
    lager:error("CLIENT ~s req: ~p", [User, lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.


pid2bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin2pid(Bin) -> list_to_pid(binary_to_list(Bin)).
