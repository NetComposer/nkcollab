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

%% @doc Plugin implementing a SIP server and client
-module(nkmedia_sip_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_defaults/0, plugin_config/2, 
         plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([nkmedia_sip_invite/5]).
-export([nkmedia_sip_invite_ringing/2, nkmedia_sip_invite_rejected/1, 
         nkmedia_sip_invite_answered/2]).
-export([sip_get_user_pass/4, sip_authorize/3]).
-export([sip_register/2, sip_invite/2, sip_reinvite/2, sip_cancel/3, sip_bye/2]).
-export([nkmedia_call_resolve/4, nkmedia_call_invite/6, nkmedia_call_cancelled/3,
         nkmedia_call_answer/6, nkmedia_call_reg_event/4]).
-export([nkmedia_session_reg_event/4]).

-include_lib("nklib/include/nklib.hrl").
-include_lib("nksip/include/nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type continue() :: continue | {continue, list()}.

-record(sip_config, {
    registrar :: boolean(),
    domain :: binary(),
    force_domain :: boolean(),
    invite_to_not_registered :: boolean
}).



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nkmedia_call, nksip, nksip_registrar].


plugin_syntax() ->
    #{
        sip_registrar => boolean,
        sip_domain => binary,
        sip_registrar_force_domain => boolean,
        sip_invite_to_not_registered => boolean,
        sip_use_external_ip => boolean
    }.


plugin_defaults() ->
    #{
        sip_registrar => true,
        sip_domain => <<"nkmedia">>,
        sip_registrar_force_domain => true,
        sip_invite_to_not_registered => true,
        sip_use_external_ip => true
    }.


plugin_config(Config, _Service) ->
    #{
        sip_registrar := Registrar,
        sip_domain := Domain,
        sip_registrar_force_domain := Force,
        sip_invite_to_not_registered := External,
        sip_use_external_ip := ExtIp
    } = Config,
    Cache = #sip_config{
        registrar = Registrar,
        domain = Domain,
        force_domain = Force,
        invite_to_not_registered = External
    },
    Config2 = case ExtIp of
        true ->
            Ip = nklib_util:to_host(nkpacket_config_cache:ext_ip()),
            Config#{sip_local_host=>Ip};
        false ->
            Config
    end,
    {ok, Config2, Cache}.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA SIP (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA SIP (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================

%% @doc Called when a new SIP invite arrives
-spec nkmedia_sip_invite(nkservice:id(), binary(),
                         nkmedia:offer(), nksip:request(), nksip:call()) ->
    {ok, nklib:link()} | {rejected, nkservice:error()} | continue().

nkmedia_sip_invite(SrvId, Dest, Offer, _Req, _Call) ->
    Config = #{
        offer => Offer, 
        caller_link => {nkmedia_sip, self()},
        caller => #{info=>sip_native}
    },
    case nkmedia_call:start2(SrvId, Dest, Config) of
        {ok, CallId, CallPid} ->
            {ok, {nkmedia_call, CallId, CallPid}};
        {error, Error} ->
            lager:warning("NkMEDIA SIP call error: ~p", [Error]),
            {rejected, Error}
    end.




%% @doc Called when a SIP INVITE we are launching is ringing
-spec nkmedia_sip_invite_ringing(nklib:link(), nkmedia:answer()) ->
    ok.

nkmedia_sip_invite_ringing({nkmedia_call, CallId, _Pid}, Answer) ->
    nkmedia_call:ringing(CallId, {nkmedia_sip, self()}, Answer);

nkmedia_sip_invite_ringing(_Id, _Answer) ->
    ok.


%% @doc Called when a SIP INVITE we are launching has been rejected
-spec nkmedia_sip_invite_rejected(nklib:link()) ->
    ok.

nkmedia_sip_invite_rejected({nkmedia_call, CallId, _Pid}) ->
    nkmedia_call:rejected(CallId, {nkmedia_sip, self()});

nkmedia_sip_invite_rejected({nkmedia_session, SessId, _Pid}) ->
    nkmedia_session:stop(SessId, sip_rejected);

nkmedia_sip_invite_rejected(_Id) ->
    ok.


%% @doc Called when a SIP INVITE we are launching has been answered
-spec nkmedia_sip_invite_answered(nklib:link(), nkmedia:answer()) ->
    ok | {error, term()}.

nkmedia_sip_invite_answered({nkmedia_call, CallId, _Pid}, Answer) ->
    Callee = #{info=>nkmedia_sip},
    case nkmedia_call:accepted(CallId, {nkmedia_sip, self()}, Answer, Callee) of
        {ok, _Pid} -> 
            ok;
        {error, Error} ->
            {error, Error}
    end;

nkmedia_sip_invite_answered({nkmedia_session, SessId, _Pid}, Answer) ->
    case nkmedia_session:set_answer(SessId, Answer) of
        ok -> 
            lager:error("ANSWRED: ~p", [SessId]),
            ok;
        {error, Error} -> 
            lager:error("ANSWRED E: ~p", [SessId]),
            {error, Error}
    end;

nkmedia_sip_invite_answered(_Id, _Answer) ->
    {error, not_implemented}.

    


%% ===================================================================
%% Implemented Callbacks - Error
%% ===================================================================

%% @private See nkservice_callbacks
error_code(sip_bye)             -> {308001, "SIP Bye"};
error_code(sip_cancel)          -> {308002, "SIP Cancel"};
error_code(sip_no_sdp)          -> {308003, "SIP Missing SDP"};
error_code(sip_invite_error)    -> {308004, "SIP INVITE Error"};
error_code(sip_reply_error)     -> {308005, "SIP Reply Error"};
error_code(no_sip_data)         -> {308006, "No SIP Data"};
error_code(_) -> continue.




%% ===================================================================
%% Implemented Callbacks - nksip
%% ===================================================================


%% @private
sip_get_user_pass(_User, _Realm, _Req, _Call) ->
    true.


%% @private
sip_authorize(_AuthList, _Req, _Call) ->
    ok.


%% @private
sip_register(Req, Call) ->
    SrvId = nksip_call:srv_id(Call),
    Config = nkservice_srv:get_item(SrvId, config_nkmedia_sip),
    #sip_config{
        registrar = Registrar,
        domain = Domain,
        force_domain = Force
    } = Config,
    case Registrar of
        true ->
            case Force of
                true ->
                    Req2 = nksip_registrar_util:force_domain(Req, Domain),
                    {continue, [Req2, Call]};
                false ->
                    case nksip_request:meta(Req, to_domain) of
                        {ok, Domain} ->
                            {continue, [Req, Call]};
                        _ ->
                            {reply, forbidden}
                    end
            end;
        false ->
            {reply, forbidden}
    end.


%% @private
sip_invite(Req, Call) ->
    SrvId = nksip_call:srv_id(Call),
    Config = nkservice_srv:get_item(SrvId, config_nkmedia_sip),
    #sip_config{domain = DefDomain} = Config,
    {ok, AOR} = nksip_request:meta(aor, Req),
    {_Scheme, User, Domain} = AOR,
    Dest = case Domain of
        DefDomain -> User;
        _ -> <<User/binary, $@, Domain/binary>>
    end,
    {ok, Body} = nksip_request:meta(body, Req),
    Offer = case nksip_sdp:is_sdp(Body) of
        true -> #{sdp=>nksip_sdp:unparse(Body), sdp_type=>rtp};
        false -> #{}
    end,
    case SrvId:nkmedia_sip_invite(SrvId, Dest, Offer, Req, Call) of
        {ok, Link} ->
            nkmedia_sip:register_incoming_link(Req, Link),
            noreply;
        {reply, Reply} ->
            {reply, Reply};
        {rejected, Reason} ->
            lager:notice("SIP invite rejected: ~p", [Reason]),
            {reply, decline}
    end.
        

%% @private
sip_reinvite(_Req, _Call) ->
    {reply, decline}.


%% @private
sip_cancel(InviteReq, _Request, _Call) ->
    case nkmedia_sip:handle_to_link(InviteReq) of
        {ok, {nkmedia_call, CallId, _}=Link} ->
            nkmedia_sip:cancel(Link),
            nkmedia_call:hangup(CallId, sip_cancel);
        {ok, {nkmedia_session, SessId, _}=Link} ->
            nkmedia_sip:cancel(Link),
            nkmedia_session:stop(SessId, sip_cancel);
        _Other ->
            lager:notice("Received SIP CANCEL for unknown call/session")
    end,
    continue.


%% @private Called when a BYE is received from SIP
sip_bye(Req, _Call) ->
    case nkmedia_sip:dialog_to_link(Req) of
        {ok, {nkmedia_call, CallId, _}} ->
            nkmedia_call:hangup(CallId, sip_bye);
        {ok, {nkmedia_session, SessId, _}} ->
            nkmedia_session:stop(SessId, sip_bye);
        _Other ->
            lager:notice("Received SIP BYE for unknown call/session")
    end,
	continue.



%% ===================================================================
%% Implemented Callbacks - Call
%% ===================================================================

%% @private
nkmedia_call_resolve(Callee, Type, Acc, Call) when Type==sip; Type==all ->
    #{srv_id:=SrvId} = Call,
    Config = nkservice_srv:get_item(SrvId, config_nkmedia_sip),
    #sip_config{invite_to_not_registered=DoExt} = Config,
    Uris1 = case DoExt of
        true ->
            % We allowed calling to not registered SIP endpoints
            case nklib_parse:uris(Callee) of
                error -> 
                    lager:info("Invalid SIP URI: ~p", [Callee]),
                    [];
                Parsed -> 
                    [U || #uri{scheme=S}=U <- Parsed, S==sip orelse S==sips]
            end;
        false ->
            []
    end,
    {User, Domain} = case binary:split(Callee, <<"@">>) of
        [User0, Domain0] -> {User0, Domain0};
        [User0] -> {User0, Config#sip_config.domain}
    end,
    Uris2 = nksip_registrar:find(SrvId, sip, User, Domain) ++
            nksip_registrar:find(SrvId, sips, User, Domain),
    Dests= [
        #{dest=>{nkmedia_sip, U}, session_config=>#{sdp_type=>rtp}} 
        || U <- Uris1++Uris2
    ],
    {continue, [Callee, Type, Acc++Dests, Call]};

nkmedia_call_resolve(_Callee, _Type, _Acc, _Call) ->
    continue.


%% @private Called when a call want to INVITE a SIP endpoint
nkmedia_call_invite(CallId, {nkmedia_sip, Uri}, _SessId, Offer, _Caller, Call) ->
    #{srv_id:=SrvId} = Call,
    Link =  {nkmedia_call, CallId, self()},
    case nkmedia_sip:send_invite(SrvId, Uri, Offer, Link, []) of
        {ok, SipLink} -> 
            {ok, SipLink, Call};
        {error, Error} ->
            lager:error("error sending SIP: ~p", [Error]),
            {remove, Call}
    end;

nkmedia_call_invite(_CallId, _Dest, _SessId, _Offer, _Caller, _Call) ->
    continue.


%% @private
nkmedia_call_answer(CallId, {nkmedia_sip, _Pid}, _SessId, Answer, _Callee, Call) ->
    case nkmedia_sip:answer({nkmedia_call, CallId, self()}, Answer) of
        ok ->
           {ok, Call};
        {error, Error} ->
            lager:error("Error in SIP answer: ~p", [Error]),
            {error, Error, Call}
    end;

nkmedia_call_answer(_CallId, _Link, _SessId, _Answer, _Callee, _Call) ->
    continue.


%% @private
nkmedia_call_cancelled(CallId, {nkmedia_sip, _Pid}, _Call) ->
    % We should not block the call
    Self = self(),
    spawn(fun() -> nkmedia_sip:hangup({nkmedia_call, CallId, Self}) end),
    continue;

nkmedia_call_cancelled(_CallId, _Link, _Call) ->
    continue.


%% @private
nkmedia_call_reg_event(CallId, {nkmedia_sip, _Pid}, {hangup, _Reason}, _Call) ->
    Self = self(),
    spawn(fun() -> nkmedia_sip:hangup({nkmedia_call, CallId, Self}) end),
    continue;

nkmedia_call_reg_event(_CallId, _Link, _Event, _Call) ->
    continue.


%% ===================================================================
%% Implemented Callbacks - Session
%% ===================================================================


%% @private
nkmedia_session_reg_event(SessId, {nkmedia_sip, _}, {answer, Answer}, _Session) ->
    case maps:get(backend_role, _Session) of
        offerer ->
            %% We generated the offer and INVITEd to someone, so the answer is
            %% from ours
            ok;
        offeree ->
            %% We received an OFFER in an INVITE, and now have an answer and must
            %% send the 200 back
            case nkmedia_sip:answer({nkmedia_session, SessId, self()}, Answer) of
                ok ->
                   ok;
                {error, Error} ->
                    nkmedia_session:stop(self(), sip_answer),
                    lager:error("Error in SIP reply: ~p", [Error])
            end
    end,
    continue;

nkmedia_session_reg_event(SessId, {nkmedia_sip, _}, {stop, _Reason}, _Session) ->
    Self = self(),
    % We should not block the session
    spawn(fun() -> nkmedia_sip:hangup({nkmedia_session, SessId, Self}) end),
    continue;

nkmedia_session_reg_event(_SessId, _Link, _Event, _Session) ->
    continue.


%% ===================================================================
%% Internal
%% ===================================================================

