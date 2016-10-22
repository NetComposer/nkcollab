
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

%% @doc Testing the call system (try after nkcollab_test and nkcollab_test_api)
%% 
%% Ww have native connections (Verto, Janus, SIP, API) and 
%% we can use Verto/Janus to simulate API connections (login with tXXX, api user is XXX)
%%
%% 1) Call from Verto/Janus native to API (Verto/Janus emulated)
%%    - A Verto or Janus session logins (caller, native, without "t")
%%    - Another Verto/Janus logins as API (with "t")
%%    - When the first calls, the native processing in nkcollab_verto_callabacks
%%      takes place (see nkcollab_verto_invite).
%%    - A call is started that generates two sessions.
%%      nkcollab_call_resolve and nkcollab_call_invite are called
%%    - Since the callee is an API 'user' endpoint, in nkcollab_call_api:resolve/3 it
%%      is directed to {nkcollab_api_user, Pid}. In invite/6, we send the invite
%%      over the wire. It is captured in api_client_fun/2 here, and a INVITE is
%%      sent to Janus/Verto registerd with {test_api_server, Pid}.
%%    - If it rejects, is detected here and a 'rejected' is sent over the wire.
%%      Same if hangup. If answered, an 'accepted' is sent.
%%    - NkCOLLAB detects the answer and nkcollab_call_answer is called, detected
%%      by Janus/Verto
%%    - Must test rejecting the call at any destination, hangup, cancel
%%    - Must test calling Janus, to send candidates. If caller is also Janus, 
%%      candidates must flow in both directions
%%
%% 2) Call from API (Verto/Janus emulated) to Verto/Janus
%%    - A Janus/Verto emulated (with "t") calls to a native one
%%    - nkcollab_verto_invite (or janus) here is called. It sends a call creation
%%      request over the API, and registers the Verto/Janus session with our client API
%%    - When the answer is received it gets api_client_fun, same for hangup
%%    - nkcollab_call_resolve is called, and captured at destination Verto/Janus
%%    - nkcollab_call_invite is also captured (see nkcollab_verto_callbacks for details)
%%    - Test rejecting, cancelling, candidates in destination or both
%%    - Test Janus/Janus to test candidates in both directions
%% 
%% 3) Call from Verto/Janus to SIP
%%    - When native Verto/Janus calls a number that is resolved to sip in
%%      nkcollab_sip_callbacks:nkcollab_call_resolve(), the invite is also captured.
%%      Functions nkcollab_sip_invite_ringing, _rejected and _answered are called
%%      However, with the default janus backend, you must use "sip:XXX" so that 
%%      the caller session is created with sdp_type=rtp (see nkcollab_call:start2())
%%    - Try cancel, rejected, hangup on both sides
%%    - See options sip_registrar, sip_invite_to_not_registered, etc. in
%%      nkcollab_sip_callbacks
%%
%% 4) Call from API to SIP
%%    - The same happens here in start_call() when the call comes from an emulated
%%      API with Janus or Verto (registered with "t")
%%
%% 5) Call from SIP to native Verto/Janus or API
%%    - nkcollab_sip_invite() is called, and starts a normal call us before
%%    - destination can be a native or emulated API session
%%
%% 6) Use nkmedia_fs and kms backends
%%    - Since nkcollab_call:start2/3 is being used, the following prefixes are used:
%%    - fs: use nkmedia_fs backend. It will bufer candidates if received
%%    - kms: use nkmedia_kms backend. Verto and Janus use no_answer_trickle_ice for
%%      the caller and no_offer_trickle_ice for the callee.
%%
%% 7) P2P calls
%%    - when using p2p:XXX, the call is peer to peer
%%    - to use Janus, must disable trikcle ice 





-module(nkcollab_test_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Sample (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").

-define(URL1, "nkapic://127.0.0.1:9010").
-define(URL2, "nkapic://media2.netcomposer.io:9010").


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
        sip_listen => "sip:all:8060",
        log_level => debug,
        api_gelf_server => "c2.netc.io"
    },
    % export NKCOLLAB_CERTS="/etc/letsencrypt/live/casa.carlosj.net"
    Spec2 = case os:getenv("NKCOLLAB_CERTS") of
        false ->
            Spec1;
        Dir ->
            Spec1#{
                tls_certfile => filename:join(Dir, "cert.pem"),
                tls_keyfile => filename:join(Dir, "privkey.pem"),
                tls_cacertfile => filename:join(Dir, "fullchain.pem")
            }
    end,
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
        nkcollab_sip, nksip_registrar, nksip_trace,
        nkcollab_verto, nkcollab_janus,
        nkmedia_fs, nkmedia_kms, nkmedia_janus,
        nkmedia_fs_verto_proxy, 
        nkmedia_janus_proxy, 
        nkmedia_kms_proxy,
        nkservice_api_gelf,
        nkmedia_room_msglog
    ].




%% ===================================================================
%% Cmds
%% ===================================================================

%% Connect

connect(User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL1, User, "p1", Fun, Data),
    C.

connect2(User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL2, User, "p1", Fun, Data),
    C.

get_client() ->
    [{_, C}|_] = nkservice_api_client:get_all(),
    C.


call_cmd(C, Cmd, Data) ->
    nkservice_api_client:cmd(C, media, call, Cmd, Data).



%% ===================================================================
%% api server callbacks
%% ===================================================================


%% @doc Called on login
api_server_login(Data, SessId, State) ->
    nkcollab_test_api:api_server_login(Data, SessId, State).


%% @doc
api_allow(Req, State) ->
    nkcollab_test_api:api_allow(Req, State).


%% @oc
api_subscribe_allow(SrvId, Class, SubClass, Type, State) ->
    nkcollab_test_api:api_subscribe_allow(SrvId, Class, SubClass, Type, State).




%% ===================================================================
%% nkcollab_verto callbacks
%% ===================================================================

%% @private
% If the login is tXXXX, an API session is emulated (not Verto specific)
% Without t, it is a 'standard' verto Session
nkcollab_verto_login(Login, Pass, Verto) ->
    case nkcollab_test:nkcollab_verto_login(Login, Pass, Verto) of
        {true, <<"t", Num/binary>>=User, Verto2} ->
            Pid = connect(Num, #{test_verto_server=>self()}),
            {true, User, Verto2#{test_api_server=>Pid}};
        {true, User, Verto2} ->
            {true, User, Verto2};
        Other ->
            Other
    end.


%% @private Verto incoming call using API Call emulation
nkcollab_verto_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Verto) ->
    true = is_process_alive(Ws),
    #{dest:=Dest} = Offer,
    Events = #{
        verto_call_id => CallId,
        verto_pid => pid2bin(self())
    },
    Link = {nkcollab_verto, CallId, self()},
    case start_call(Dest, Offer, CallId, Ws, Events, Link) of
        ok ->
            {ok, {test_api_server, Ws}, Verto};
        {rejected, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end;

%% @private Standard Verto calling (see default implementation)
nkcollab_verto_invite(_SrvId, _CallId, _Offer, _Verto) ->
    continue.


%% @private
nkcollab_verto_answer(CallId, {test_api_server, Ws}, Answer, Verto) ->
    Callee = #{info => nkcollab_verto_test},
    case call_cmd(Ws, accepted, #{call_id=>CallId, answer=>Answer, callee=>Callee}) of
        {ok, #{}} ->
            %% Call will get the answer and send it back to the session
            ok;
        {error, Error} ->
            lager:notice("VERTO CALL ERROR: ~p", [Error]),
            nkcollab_verto:hangup(self(), CallId)
    end,
    {ok, Verto};

nkcollab_verto_answer(_CallId, _Link, _Answer, _Verto) ->
    continue.


%% @private
nkcollab_verto_rejected(CallId, {test_api_server, Ws}, Verto) ->
    call_cmd(Ws, rejected, #{call_id=>CallId}),
    {ok, Verto};

nkcollab_verto_rejected(_CallId, _Link, _Verto) ->
    continue.


%% @private
nkcollab_verto_bye(CallId, {test_api_server, Ws}, Verto) ->
    call_cmd(Ws, hangup, #{call_id=>CallId, reason=>vertoBye}),
    {ok, Verto};

nkcollab_verto_bye(_CallId, _Link, _Verto) ->
    continue.


%% @private
nkcollab_verto_terminate(Reason, Verto) ->
    nkcollab_test_api:nkcollab_verto_terminate(Reason, Verto).


%% ===================================================================
%% nkcollab_janus callbacks
%% ===================================================================


%% @private
%% If the register with tXXXX, and API session is emulated
nkcollab_janus_registered(<<"t", Num/binary>>, Janus) ->
    Pid = connect(Num, #{test_janus_server=>self()}),
    {ok, Janus#{test_api_server=>Pid}};

nkcollab_janus_registered(_User, Janus) ->
    {ok, Janus}.



% @private Called when we receive INVITE from Janus
nkcollab_janus_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Janus) ->
    true = is_process_alive(Ws),
    #{dest:=Dest} = Offer,
    Events = #{
        janus_call_id => CallId,
        janus_pid => pid2bin(self())
    },
    Link = {nkcollab_janus, CallId, self()},
    case start_call(Dest, Offer, CallId, Ws, Events, Link) of
        ok ->
            {ok, {test_api_server, Ws}, Janus};
        {rejected, Reason} ->
            lager:notice("Janus invite rejected ~p", [Reason]),
            {rejected, Reason, Janus}
    end;

%% @private Standard Janus calling (see default implementation)
nkcollab_janus_invite(_SrvId, _CallId, _Offer, _Janus) ->
    continue.


%% @private
nkcollab_janus_answer(CallId, {test_api_server, Ws}, Answer, Janus) ->
    Callee = #{info => nkcollab_janus_test},
    case call_cmd(Ws, accepted, #{call_id=>CallId, answer=>Answer, callee=>Callee}) of
        {ok, #{}} ->
            %% Call will get the answer and send it back to the session
            ok;
        {error, Error} ->
            lager:notice("JANUS CALL ERROR: ~p", [Error]),
            nkcollab_janus:hangup(self(), CallId)
    end,
    {ok, Janus};

nkcollab_janus_answer(_CallId, _Link, _Answer, _Janus) ->
    continue.


%% @private
nkcollab_janus_candidate(CallId, {test_api_server, Ws}, Candidate, Janus) ->
    case Candidate of
        #candidate{last=true} ->
            lager:error("CC1"),
            {ok, _} = call_cmd(Ws, set_candidate_end, #{call_id=>CallId});
        #candidate{m_id=Id, m_index=Index, a_line=ALine} ->
            lager:error("CC2"),
            Data = #{
                call_id => CallId, 
                sdpMid => Id, 
                sdpMLineIndex => Index, 
                candidate => ALine
            },
            {ok, _} = call_cmd(Ws, set_candidate, Data)
    end,
    {ok, Janus};

nkcollab_janus_candidate(_CallId, _Link, _Candidate, _Janus) ->
    continue.


%% @private
nkcollab_janus_bye(CallId, {test_api_server, Ws}, Janus) ->
    call_cmd(Ws, hangup, #{call_id=>CallId, reason=><<"Janus Stop">>}),
    {ok, Janus};

nkcollab_janus_bye(_CallId, _Link, _Verto) ->
    continue.


%% @private
nkcollab_janus_terminate(Reason, Janus) ->
    nkcollab_test_api:nkcollab_janus_terminate(Reason, Janus).



%% ===================================================================
%% Sip callbacks
%% ===================================================================


%% @private
nks_sip_connection_sent(SipMsg, _Packet) ->
    case SipMsg#sipmsg.cseq of
        {_, 'REGISTER'} -> ok;
        _ -> continue
    end.

%% @private
nks_sip_connection_recv(SipMsg, _Packet) ->
    case SipMsg#sipmsg.cseq of
        {_, 'REGISTER'} -> ok;
        _ -> continue
    end.



%% ===================================================================
%% Internal
%% ===================================================================


start_call(Dest, Offer, CallId, Ws, Events, _Link) ->
    Config = #{ 
        call_id => CallId,
        type => all,
        callee => Dest,
        caller => #{info=>nkcollab_call_test},
        offer => Offer,
        events_body => Events,
        no_answer_trickle_ice => true,      % For our answer
        no_offer_trickle_ice => true        % For B-side offer
    },
    case call_cmd(Ws, create, Config) of
        {ok, #{<<"call_id">>:=CallId}} -> 
            ok;
        {error, Error} ->
            {error, Error}
    end.


%% @private
incoming_config(Backend, Type, Offer, Events, Opts) ->
    Opts#{
        backend => Backend, 
        type => Type, 
        offer => Offer, 
        events_body => Events
    }.


%% @private
start_call(Ws, Callee, Config) ->
    case call_cmd(Ws, start, Config#{callee=>Callee}) of
        {ok, #{<<"call_id">>:=_CallId}} -> 
            ok;
        {error, Error} ->
            {error, Error}
    end.


%% @private
api_client_fun(#api_req{class = <<"core">>, cmd = <<"event">>, data = Data}, UserData) ->
    % lager:error("FUN: ~p", [Data]),
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
        {<<"media">>, <<"call">>, <<"answer">>} ->
            #{<<"answer">>:=#{<<"sdp">>:=SDP}} = Body,
            case Sender of
                {verto, CallId, Pid} ->
                    nkcollab_verto:answer(Pid, CallId, #{sdp=>SDP});
                {janus, CallId, Pid} ->
                    nkcollab_janus:answer(Pid, CallId, #{sdp=>SDP})
            end;
        {<<"media">>, <<"call">>, <<"hangup">>} ->
            case Sender of
                {verto, CallId, Pid} ->
                    nkcollab_verto:hangup(Pid, CallId);
                {janus, CallId, Pid} ->
                    nkcollab_janus:hangup(Pid, CallId);
                unknown ->
                    case UserData of
                        #{test_janus_server:=Pid} ->
                            nkcollab_janus:hangup(Pid, ObjId);
                        #{test_verto_server:=Pid} ->
                            nkcollab_verto:hangup(Pid, ObjId)
                    end
            end;
        _ ->
            lager:notice("TEST CLIENT event ~s:~s:~s:~s: ~p", 
                         [Class, Sub, Type, ObjId, Body])
    end,
    {ok, #{}, UserData};

api_client_fun(#api_req{cmd= <<"invite">>, data=Data}, UserData) ->
    #{<<"call_id">>:=CallId, <<"offer">>:=Offer} = Data,
    #{<<"sdp">>:=SDP} = Offer,
    lager:info("INVITE: ~p", [UserData]),
    Self = self(),
    spawn(
        fun() ->
            {ok, _} = 
                call_cmd(Self, ringing, #{call_id=>CallId, callee=>#{api_test=>true}}),
            Link = {test_api_server, Self},
            case UserData of
                #{test_janus_server:=JanusPid} ->
                    {ok, _} = 
                        nkcollab_janus:invite(JanusPid, CallId, #{sdp=>SDP}, Link);
                #{test_verto_server:=VertoPid} ->
                    {ok, _} = 
                        nkcollab_verto:invite(VertoPid, CallId, #{sdp=>SDP}, Link)
            end
        end),
    {ok, #{}, UserData};

api_client_fun(#api_req{subclass = <<"call">>, cmd= <<"hangup">>, data=Data}, UserData) ->
    #{<<"call_id">>:=_CallId} = Data,
    lager:error("HANGUP ~p", [UserData]),
    {ok, #{}, UserData};

api_client_fun(_Req, UserData) ->
    lager:notice("TEST CLIENT2 req: ~p", [lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.


pid2bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin2pid(Bin) -> list_to_pid(binary_to_list(Bin)).
