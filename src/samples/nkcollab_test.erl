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

%% @doc Tests for media functionality
%% Things to test:
%% 
%% - Register a Verto or a Janus (videocall) (not using direct Verto connections here)
%%
%%   - Verto / Janus originator:
%%     Verto or Janus call je, fe, ke, p1, p2, m1, m2 all work the same way
%%     Verto (or Janus) register with the session on start as 
%%     {nkcollab_verto, CallId, Pid}. This way, we can use nkmedia_session_reg_event
%%     in their callback modules to detect the available answer and session stop.
%%     Also, if the Verto/Janus process stops, the session detects it and stops.
%%     The session 'link' {nkmedia_session, SessId, SessPid} is returned to Verto/Janus
%%     This way, if Verto/Janus needs to stop the session or send an info, it uses it 
%%     in their callback modules as an 'specially recognized' link type.
%%     Also, if the session is killed, stops, it is detected by Verto/Janus
%% 
%%   - Trickle ICE
%%     When the client is Verto, it sends the SDP without trickle. It uses
%%     no_answer_trickle_ice=true, so if the backend sends an SDP with trickle ICE
%%     (like Kurento) the candidates will be buffered and the answer
%%     will be sent when ready
%%     If the client is Janus, it sends the offer SDP with trickle. 
%%     When it sends a candidate the nkcollab_janus_candidate callback sends it
%%     to the session. If the backend has not set no_offer_trickle_ice, they will
%%     be sent directly to the backend. Otherwise (FS), they will be buffered and sent 
%%     to the backend when ready.
%%     Verto does not support receiving candidates either, so uses no_answer_trickle_ice
%%     If we had a client that supports them, should listen to the {candidate, _}
%%     event from nkmedia_session (neither Janus or Verto support receiving candidates)
%%
%%   - Verto / Janus receiver
%%     If we call invite/3 to a registered client, we locate it and we start the 
%%     session without offer. We then get the offer from the session, and send
%%     the invite to Verto/Janus with the session 'link'
%%     This way Verto/Janus monitor the session and send the answer or bye
%%     We also register the Verto/Janus process with the session, so that it can 
%%     detect session stops and kills.
%%
%%   - Direct call
%%     If we dial "dXXX", we start a 'master' session (p2p type, offeree), 
%%     and a 'slave' session (offerer), with the same offer. 
%%     The session sets set_master_answer, so the answer from slave is set on the master
%%     in the slave session, so that it takes the 'offerer' role
%%     If the master sends an offer ICE candidate, since no backend uses it,
%%     it is sent to the slave, where it is announced (unless no_offer_trickle_ice)
%%     If the caller sends a candidate (and no no_offer...), it is sent to the
%%     peer. If again no_offer..., and event is sent for the client
%%     If the peer sends a candidate (and no no_answer_...) it is sent to the master.
%%     If again no no_answer_..., an event is sent
%%
%%   - Call through Janus proxy
%%     A session with type proxy is created (offeree), and a slave session as offerer,
%%     that, upon start, gets the 'secondary offer' from the first.
%%     When the client replys (since it sets set_master_answer) the answer 
%%     is sent to master, where a final answer is generated.
%%     If the master sends a candidate, it is captured by the janus backend
%%     If the peer sends a candidate, it is captured by the janus session
%%     (in nkcollab_jaus_session:candidate/2) and sent to the master to be sent to Janus
%%
%%   - Call through FS
%%     A session master is created and parked, and then a slave is created as bridge.
%%     (set_master_answer is false). It contacts the first to launch the fs bridge
%%     If the bridge stops, the other side parks
%%     Depending on stop_after_peer (default true) the other side will hangup
%%     You can update the call 
%%
%%   - Invite with Janus
%%     Used for listeners. See invite_listen
%%
%%   - Invite with FS, KMS
%%     Allows the mediaserver to make the offer, an then start any session



%%  - Register a SIP Phone
%%    The registrations is allowed and the domain is forced to 'nkcollab'

%%    - Incoming SIP (Janus version)
%%      When a call arrives, we create a proxy session with janus  
%%      and register the nkcollab-generated 'sip link' with it.
%%      We then start a second 'slave' proxy sesssion, and proceed with the invite
%%
%%    - Outcoming SIP (Janus version)
%%      As a Verto/Janus originator, we start a call with j that happens to
%%      resolve to a registered SIP endpoint.
%%      We start a second (slave, offerer, without offer) session, but with sdp_type=rtp.
%%      We get the offer and invite as usual


%% NOTES
%%
%% - Janus client does not send candidates when it is a direct call (?)
%% - Janus doest not currently work if we buffer candidates. 
%%   (not usually neccesary, since it accets trickle ice)




-module(nkcollab_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Test (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").

s(Pos, Size) ->
    Bytes1 = base64:encode(crypto:rand_bytes(Size)),
    {Bytes2, _} = split_binary(Bytes1, Size-113),
    nkservice_api_gelf:send(test, src, short, Bytes2, 2, #{data1=>Pos}).

             

%% ===================================================================
%% Public
%% ===================================================================


start() ->
    Spec1 = #{
        callback => ?MODULE,
        web_server => "https:all:8081",
        web_server_path => "./www",
        api_server => "wss:all:9010",
        api_server_timeout => 180,
        verto_listen => "verto:all:8082",
        verto_proxy => "verto_proxy:all:8083",
        janus_listen => "janus:all:8989", 
        janus_proxy=> "janus_proxy:all:8990",
        kurento_proxy => "kmss:all:8433, kms:all:8888",
        nksip_trace => {console, all},
        sip_listen => "sip:all:8060",
        api_gelf_server => "c2.netc.io",
        log_level => debug
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
        nksip_registrar, nksip_trace,
        nkmedia_janus, nkmedia_fs, nkmedia_kms, 
        nkmedia_janus_proxy, nkmedia_kms_proxy,
        nkcollab_verto, nkcollab_janus, nkcollab_sip,
        nkservice_api_gelf
    ].




%% ===================================================================
%% Cmds
%% ===================================================================


%% Invite
invite(Dest, Type, Opts) ->
    Opts2 = maps:merge(#{backend => nkmedia_kms}, Opts),
    start_invite(Dest, Type, Opts2).

invite_listen(Dest, Room) ->
    {ok, PubId, Backend} = get_publisher(Room, 1),
    start_invite(Dest, listen, #{backend=>Backend, publisher_id=>PubId}).
    

%% Session
media(SessId, Media) ->
    cmd(SessId, update_media, Media).

recorder(SessId, Opts) ->
    cmd(SessId, recorder_action, Opts).

player(SessId, Opts) ->
    cmd(SessId, player_action, Opts).

type(SessId, Type, Opts) ->
    cmd(SessId, set_type, Opts#{type=>Type}).

room(SessId, Opts) ->
    cmd(SessId, room_action, Opts).

room_layout(SessId, Layout) ->
    Layout2 = nklib_util:to_binary(Layout),
    room(SessId, #{action=>layout, layout=>Layout2}).

switch(SessId, Pos) ->
    {ok, listen, #{room_id:=Room}, _} = nkmedia_session:get_type(SessId),
    {ok, PubId, _Backend} = get_publisher(Room, Pos),
    type(SessId, listen, #{publisher_id=>PubId}).

cmd(SessId, Cmd, Opts) ->
    nkmedia_session:cmd(SessId, Cmd, Opts).



%% Tests
play_to_mcu() ->
    ConfigA = #{backend=>nkmedia_kms, sdp_type=>rtp, publisher_id=><<"b3ff402a-3d7f-c697-78af-38c9862f00d9">>},
    {ok, SessIdA, _SessLinkA} = start_session(listen, ConfigA),
    {ok, Offer} = nkmedia_session:get_offer(SessIdA),
    ConfigB = #{
        backend => nkmedia_fs, 
        offer => Offer, 
        master_id => SessIdA, 
        set_master_answer => true,
        room_id => m1
    },
    {ok, _SessIdB, _SessLinkB} = start_session(mcu, ConfigB).

play_to_janus() ->
    ConfigA = #{backend=>nkmedia_kms, no_offer_trickle_ice=>true},
    {ok, SessIdA, _SessLinkA} = start_session(play, ConfigA),
    {ok, Offer} = nkmedia_session:get_offer(SessIdA),
    ConfigB = #{
        backend => nkmedia_janus, 
        offer => Offer, 
        master_id => SessIdA, 
        set_master_answer => true,
        room_id => sfu
    },
    {ok, _SessIdB, _SessLinkB} = start_session(publish, ConfigB).




%% ===================================================================
%% nkcollab_verto callbacks
%% ===================================================================

nkcollab_verto_login(Login, Pass, Verto) ->
    case binary:split(Login, <<"@">>) of
        [User, _] ->
            Verto2 = Verto#{user=>User},
            lager:info("Verto login: ~s (pass ~s)", [User, Pass]),
            {true, User, Verto2};
        _ ->
            {false, Verto}
    end.


% @private Called when we receive INVITE from Verto
nkcollab_verto_invite(_SrvId, CallId, Offer, Verto) ->
    #{dest:=Dest} = Offer,
    Offer2 = nkmedia_util:filter_codec(video, vp8, Offer),
    Offer3 = nkmedia_util:filter_codec(audio, opus, Offer2),
    Reg = {nkcollab_verto, CallId, self()},
    case incoming(Dest, Offer3, Reg, #{no_answer_trickle_ice => true}) of
        {ok, _SessId, SessLink} ->
            {ok, SessLink, Verto};
        {error, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end.



%% ===================================================================
%% nkcollab_janus callbacks
%% ===================================================================


% @private Called when we receive INVITE from Janus
nkcollab_janus_invite(_SrvId, CallId, Offer, Janus) ->
    #{dest:=Dest} = Offer, 
    Reg = {nkcollab_janus, CallId, self()},
    case incoming(Dest, Offer, Reg, #{no_answer_trickle_ice => true}) of
        {ok, _SessId, SessLink} ->
            {ok, SessLink, Janus};
        {error, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end.



%% ===================================================================
%% Sip callbacks
%% ===================================================================

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    process.


nks_sip_connection_sent(SipMsg, _Packet) ->
    case SipMsg#sipmsg.cseq of
        {_, 'REGISTER'} -> ok;
        _ -> continue
    end.

nks_sip_connection_recv(SipMsg, _Packet) ->
    case SipMsg#sipmsg.cseq of
        {_, 'REGISTER'} -> ok;
        _ -> continue
    end.


sip_register(Req, Call) ->
    Req2 = nksip_registrar_util:force_domain(Req, <<"nkcollab">>),
    {continue, [Req2, Call]}.



% Version that calls an echo... does not work!
nkcollab_sip_invite(_SrvId, <<"je">>, Offer, _Req, _Call) ->
    ConfigA = incoming_config(nkmedia_janus, Offer, {nkcollab_sip, self()}, #{}),
    {ok, SessId, SessLink} = start_session(proxy, ConfigA),
    ConfigB = slave_config(nkmedia_janus, SessId, #{}),
    {ok, SessId2, _SessLink2} = start_session(proxy, ConfigB),
    {ok, Offer2} = nkmedia_session:get_offer(SessId2),
    ConfigC = slave_config(nkmedia_janus, SessId2, #{}),
    start_session(echo, ConfigC#{offer=>Offer2}),
    {ok, SessLink};

% Version that calls another user using Janus proxy
nkcollab_sip_invite(_SrvId, <<"j", Dest/binary>>, Offer, _Req, _Call) ->
    ConfigA = incoming_config(nkmedia_janus, Offer, {nkcollab_sip, self()}, #{}),
    {ok, SessId, SessLink} = start_session(proxy, ConfigA),
    ConfigB = slave_config(nkmedia_janus, SessId, #{}),
    case start_invite(Dest, bridge, ConfigB#{peer_id=>SessId}) of
        {ok, _} ->
            {ok, SessLink};
        {error, Error} ->
            {error, Error}
    end;

% Version using FS
nkcollab_sip_invite(_SrvId, <<"f">>, Offer, _Req, _Call) ->
    ConfigA = incoming_config(nkmedia_fs, Offer, {nkcollab_sip, self()}, #{}),
    {ok, _SessId, SessLink} = start_session(mcu, ConfigA#{room_id=>m1}),
    {ok, SessLink};

% Version using KMS
nkcollab_sip_invite(_SrvId, <<"k">>, Offer, _Req, _Call) ->
    ConfigA = incoming_config(nkmedia_kms, Offer, {nkcollab_sip, self()}, #{}),
    {ok, _SessId, SessLink} = start_session(play, ConfigA),
    {ok, SessLink};

nkcollab_sip_invite(_SrvId, _Dest, _Offer, _Req, _Call) ->
    {rejected, decline}.



%% ===================================================================
%% Internal
%% ===================================================================

incoming(<<"je">>, Offer, Reg, Opts) ->
    % Can update mute_audio, mute_video, record, bitrate
    Config = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    start_session(echo, Config#{bitrate=>500000});

incoming(<<"fe">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    start_session(echo, Config);

incoming(<<"fp">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    start_session(park, Config);

incoming(<<"ke">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(echo, Config#{use_data=>false});

incoming(<<"kp">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(park, Config);

incoming(<<"m1">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    start_session(mcu, Config#{room_id=>"m1"});

incoming(<<"m2">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    start_session(mcu, Config#{room_id=>"m2"});

incoming(<<"jp1">>, Offer, Reg, Opts) ->
    nkmedia_room:start(test, #{room_id=>sfu, backend=>nkmedia_janus}),
    Config = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    start_session(publish, Config#{room_id=>sfu});

incoming(<<"jp2">>, Offer, Reg, Opts) ->
    Config1 = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    Config2 = Config1#{
        room_audio_codec => pcma,
        room_video_codec => vp9,
        room_bitrate => 100000
    },
    start_session(publish, Config2);

incoming(<<"kp1">>, Offer, Reg, Opts) ->
    nkmedia_room:start(test, #{room_id=>sfu, backend=>nkmedia_kms}),
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(publish, Config#{room_id=>sfu});

incoming(<<"kp2">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(publish, Config);

incoming(<<"d", Num/binary>>, Offer, Reg, Opts) ->
    ConfigA = incoming_config(p2p, Offer, Reg, Opts),
    {ok, SessId, SessLink} = start_session(p2p, ConfigA),
    %% TODO: move this to a specific p2p backend?
    Opts2 = Opts#{
        offer => Offer,
        peer_id => SessId,
        master_id => SessId,
        set_master_answer => true
    },
    ConfigB = slave_config(p2p, SessId, Opts2),
    case start_invite(Num, p2p, ConfigB) of
        {ok, _} ->
            {ok, SessId, SessLink};
        {error, Error} ->
            {error, Error}
    end;

incoming(<<"j", Num/binary>>, Offer, Reg, Opts) ->
    ConfigA1 = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    ConfigA2 = case find_user(Num) of
        {nkcollab_sip, _, _} -> ConfigA1#{sdp_type=>rtp};
        _ -> ConfigA1
    end,
    {ok, SessId, SessLink} = start_session(proxy, ConfigA2#{bitrate=>100000}),
    ConfigB = slave_config(nkmedia_janus, SessId, Opts#{bitrate=>150000}),
    case start_invite(Num, bridge, ConfigB#{peer_id=>SessId}) of
        {ok, _} ->
            {ok, SessId, SessLink};
        {error, Error} ->
            {error, Error}
    end;

incoming(<<"f", Num/binary>>, Offer, Reg, Opts) ->
    % You can use stop_after_peer=>true on A and/or B legs
    ConfigA = incoming_config(nkmedia_fs, Offer, Reg, Opts),
    {ok, SessId, SessLink} = start_session(park, ConfigA#{}),
    ConfigB = slave_config(nkmedia_fs, SessId, Opts),
    case start_invite(Num, bridge, ConfigB#{peer_id=>SessId}) of
        {ok, _} ->
            {ok, SessId, SessLink};
        {error, Error} ->
            {error, Error}
    end;

incoming(<<"k", Num/binary>>, Offer, Reg, Opts) ->
    % You can use stop_after_peer=>true on A and/or B legs
    % Muting audio or here has no effect on A, but will be copied from B
    ConfigA = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    {ok, SessId, SessLink} = start_session(park, ConfigA),
    ConfigB = slave_config(nkmedia_kms, SessId, Opts#{mute_video=>false}),
    case start_invite(Num, bridge, ConfigB#{peer_id=>SessId}) of
        {ok, _} ->
            {ok, SessId, SessLink};
        {error, Error} ->
            {error, Error}
    end;

incoming(<<"play">>, Offer, Reg, Opts) ->
    Config = incoming_config(nkmedia_kms, Offer, Reg, Opts),
    start_session(play, Config);

incoming(<<"proxy-test">>, Offer, Reg, Opts) ->
    ConfigA1 = incoming_config(nkmedia_janus, Offer, Reg, Opts),
    {ok, SessId, SessLink} = start_session(proxy, ConfigA1),
    {ok, #{offer:=Offer2}} = nkmedia_session:cmd(SessId, get_proxy_offer, #{}),

    % % This should work, but Juanus fails with a ICE failed message
    % ConfigB = slave_config(nkmedia_janus, SessId, Opts#{offer=>Offer2}),
    % {ok, _, _} = start_session(echo, ConfigB),

    % % This, however works:
    % {nkcollab_janus, Pid} = find_user(a),
    % SessLink = {nkmedia_session, SessId, SessPid},
    % {ok, _} = nkcollab_janus:invite(Pid, SessId, Offer2, SessLink),

    % % Doint the answering by hand fails with the same error
    % {ok, SessB, _} = start_session(publish, #{backend=>nkmedia_janus, offer=>Offer2}),
    % {ok, Answer2} = nkmedia_session:get_answer(SessB),
    % nkmedia_session:set_answer(SessId, Answer2),

    ConfigB = slave_config(nkmedia_fs, SessId, Opts#{offer=>Offer2}),
    {ok, _, _} = start_session(mcu, ConfigB),

    {ok, SessId, SessLink};


incoming(_Dest, _Offer, _Reg, _Opts) ->
    {error, no_destination}.



%% @private
incoming_config(Backend, Offer, Reg, Opts) ->
    Opts#{backend=>Backend, offer=>Offer, register=>Reg}.


%% @private
slave_config(Backend, MasterId, Opts) ->
    Opts#{backend=>Backend, master_id=>MasterId}.


%% @private
start_session(Type, Config) ->
    case nkmedia_session:start(test, Type, Config) of
        {ok, SessId, SessPid} ->
            {ok, SessId, {nkmedia_session, SessId, SessPid}};
        {error, Error} ->
            {error, Error}
    end.



%% Creates a new 'B' session, gets an offer and invites a Verto, Janus or SIP endoint
start_invite(Dest, Type, Config) ->
    case find_user(Dest) of
        {nkcollab_verto, VertoPid} ->
            Config2 = Config#{no_offer_trickle_ice=>true},
            {ok, SessId, SessLink} = start_session(Type, Config2),
            {ok, Offer} = nkmedia_session:get_offer(SessId),
            {ok, InvLink} = nkcollab_verto:invite(VertoPid, SessId, Offer, SessLink),
            {ok, _} = nkmedia_session:register(SessId, InvLink),
            {ok, SessId};
        {nkcollab_janus, JanusPid} ->
            Config2 = Config#{no_offer_trickle_ice=>true},
            {ok, SessId, SessLink} = start_session(Type, Config2),
            {ok, Offer} = nkmedia_session:get_offer(SessId),
            {ok, InvLink} = nkcollab_janus:invite(JanusPid, SessId, Offer, SessLink),
            {ok, _} = nkmedia_session:register(SessId, InvLink),
            {ok, SessId};
        {nkcollab_sip, Uri, Opts} ->
            Config2 = Config#{sdp_type=>rtp},
            {ok, SessId, SessLink} = start_session(Type, Config2),
            {ok, SipOffer} = nkmedia_session:get_offer(SessId),
            {ok, InvLink} = nkcollab_sip:send_invite(test, Uri, SipOffer, SessLink, Opts),
            {ok, _} = nkmedia_session:register(SessId, InvLink),
            {ok, SessId};
        not_found ->
            {error, unknown_user}
    end.


%% @private
find_user(User) ->
    User2 = nklib_util:to_binary(User),
    case nkcollab_verto:find_user(User2) of
        [Pid|_] ->
            {nkcollab_verto, Pid};
        [] ->
            case nkcollab_janus:find_user(User2) of
                [Pid|_] ->
                    {nkcollab_janus, Pid};
                [] ->
                    case 
                        nksip_registrar:find(test, sip, User2, <<"nkcollab">>) 
                    of
                        [Uri|_] -> 
                            {nkcollab_sip, Uri, []};
                        []  -> 
                            not_found
                    end
            end
    end.


get_publisher(RoomId, Pos) ->
    case nkmedia_room:get_room(RoomId) of
        {ok, #{backend:=Backend}=Room} ->
            Pubs = nkmedia_room:get_all_with_role(publisher, Room),
            {ok, lists:nth(Pos, Pubs), Backend};
        {error, Error} ->
            {error, Error}
    end.




speed(N) ->
    Start = nklib_util:l_timestamp(),
    speed(#{c=>3, d=>4}, N),
    Stop = nklib_util:l_timestamp(),
    Time = (Stop - Start) / 1000000,
    N / Time.




speed(_Acc, 0) ->
    ok;
speed(Acc, Pos) ->
    #{a:=1, b:=2, c:=3, d:=4} = maps:merge(Acc, #{a=>1, b=>2}),
    speed(Acc, Pos-1).


