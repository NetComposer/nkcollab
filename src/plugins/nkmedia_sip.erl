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
-module(nkmedia_sip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([send_invite/5, hangup/1, answer/2, cancel/1]).
-export([register_incoming_link/2]).
-export([handle_to_link/1, dialog_to_link/1]).

% -define(OP_TIME, 15000).            % Maximum operation time
% -define(CALL_TIMEOUT, 30000).       % 


%% ===================================================================
%% Types
%% ===================================================================

-type invite_opts() ::
	#{
		body => binary(),
		from => nklib:user_uri(),
		pass => binary(),
		route => nklib:user_uri()
	}.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
%% Launches an asynchronous invite, from a session or call
%% To recognize events, 'Id' must be {nkmedia_session|nkmedia_call, Id}
%%
%% Stores in the current process 
%% - nkmedia_sip_dialog_to_link
%% - nkmedia_sip_link_to_dialog
%% - nkmedia_sip_link_to_handle
%%
-spec send_invite(nkservice:id(), nklib:user_uri(), nkmedia:offer(),
                  nklib:link(), invite_opts()) ->
	{ok, nklib:link()} | {error, term()}.

send_invite(Srv, Uri, #{sdp:=SDP}, Link, Opts) ->
    {ok, SrvId} = nkservice_srv:get_srv_id(Srv),
    Ref = make_ref(),
    Self = self(),
    Fun = fun
        ({req, _Req, _Call}) ->
            Self ! {Ref, self()};
        ({resp, Code, Resp, _Call}) when Code==180; Code==183 ->
            {ok, Body} = nksip_response:body(Resp),
            Answer = case nksip_sdp:is_sdp(Body) of
                true -> #{sdp=>nksip_sdp:unparse(Body)};
                false -> #{}
            end,
            SrvId:nkmedia_sip_invite_ringing(Link, Answer);
        ({resp, Code, _Resp, _Call}) when Code < 200 ->
            ok;
        ({resp, Code, _Resp, _Call}) when Code >= 300 ->
            lager:info("SIP reject code: ~p", [Code]),
            SrvId:nkmedia_sip_invite_rejected(Link);
        ({resp, _Code, Resp, _Call}) ->
            %% We are storing this in the session's process (Self)
            {ok, Body} = nksip_response:body(Resp),
            Dialog = register_outcoming_dialog(Resp, Link),
            case nksip_sdp:is_sdp(Body) of
                true ->
                    Answer = #{sdp=>nksip_sdp:unparse(Body)},
                    case SrvId:nkmedia_sip_invite_answered(Link, Answer) of
                        ok ->
                            ok;
                        Other ->
                            lager:warning("SIP error calling call answer: ~p", [Other]),
                            spawn(fun() -> nksip_uac:bye(Dialog, []) end)
                    end;
                false ->
                    lager:warning("SIP: missing SDP in response"),
                    spawn(fun() -> nksip_uac:bye(Dialog, []) end),
                    SrvId:nkmedia_sip_invite_rejected(Link)
            end
    end,
    lager:info("SIP calling ~s", [nklib_unparse:uri(Uri)]),
    SDP2 = nksip_sdp:parse(SDP),
    InvOpts1 = [async, {callback, Fun}, get_request, auto_2xx_ack, {body, SDP2}],
    InvOpts2 = case Opts of
        #{from:=From} -> [{from, From}|InvOpts1];
        _ -> InvOpts1
    end,
    InvOpts3 = case Opts of
        #{pass:=Pass} -> [{sip_pass, Pass}|InvOpts2];
        _ -> InvOpts2
    end,
    InvOpts4 = case Opts of
        #{proxy:=Proxy} -> [{route, Proxy}|InvOpts3];
        _ -> InvOpts3
    end,
    {async, Handle} = nksip_uac:invite(SrvId, Uri, InvOpts4),
    receive
        {Ref, Pid} ->
            register_outcoming_handle(Handle, Link, Pid),
            {ok, {nkmedia_sip, Pid}}
            % {ok, {nkmedia_sip_out, Link, Pid}}
    after
        5000 ->
            {error, sip_send_error}
    end.



%% @doc We have received a CANCEL, remove the handle (to avoid sending a reply)
-spec cancel(nklib:link()) ->
    ok.

cancel(Link) ->
    link_to_handle(Link, in),
    ok.


%% @doc Tries to send a BYE for a registered SIP
-spec hangup(nklib:link()) ->
    ok.

hangup(Link) ->
    case link_to_handle(Link, in) of
        {ok, Handle} ->
            nksip_request:reply(decline, Handle);
        not_found ->
            case link_to_handle(Link, out) of
                {ok, Handle} ->
                    nksip_uac:cancel(Handle, []);
                not_found ->
                    case link_to_dialog(Link) of
                        {ok, Dialog} ->
                            case nksip_uac:bye(Dialog, []) of
                                {ok, 200, []} ->
                                    ok;
                                Other ->
                                    lager:notice("~p: Invalid reply from SIP BYE: ~p", 
                                                  [?MODULE, Other])
                            end;
                        not_found ->
                            ok
                    end
            end
    end,
    ok.



-spec answer(nklib:link(), nkmedia:answer()) ->
    ok | {error, nkservice:error()}.

answer(Link, #{sdp:=SDP}) ->
    case link_to_handle(Link, in) of
        {ok, Handle} ->
            SDP2 = nksip_sdp:parse(SDP),
            case nksip_request:reply({answer, SDP2}, Handle) of
                ok ->
                    ok;
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, call_not_found}
    end;

answer(_Link, _) ->
    {error, missing_sdp}.



%% @doc Reigisters an incoming SIP, to map a link to the SIP process
-spec register_incoming_link(nksip:request(), nklib:link()) ->
    ok.

register_incoming_link(Req, Link) ->
    {ok, Handle} = nksip_request:get_handle(Req),
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    lager:info("Register incoming, SIP: ~p ~p ~p", [Link, Handle, self()]),
    true = nklib_proc:reg({nkmedia_sip_dialog_to_link, Dialog}, Link),
    true = nklib_proc:reg({nkmedia_sip_link_to_dialog, Link}, Dialog),
    true = nklib_proc:reg({nkmedia_sip_handle_to_link, Handle}, Link),
    true = nklib_proc:reg({nkmedia_sip_link_to_handle, in, Link}, Handle).


%% @private
register_outcoming_handle(Handle, Link, Pid) ->
    true = nklib_proc:reg({nkmedia_sip_link_to_handle, out, Link}, Handle, Pid).


%% @private
register_outcoming_dialog(Resp, Link) ->
    {ok, Dialog} = nksip_dialog:get_handle(Resp),
    nklib_proc:del({nkmedia_sip_link_to_handle, out, Link}),
    true = nklib_proc:reg({nkmedia_sip_dialog_to_link, Dialog}, Link),
    true = nklib_proc:reg({nkmedia_sip_link_to_dialog, Link}, Dialog),
    Dialog.


%% @doc
-spec handle_to_link(nksip:request()) ->
    {ok, nklib:link() | not_found}.

handle_to_link(Req) ->
    {ok, Handle} = nksip_request:get_handle(Req),
    case nklib_proc:values({nkmedia_sip_handle_to_link, Handle}) of
        [{Link, _}] -> 
            {ok, Link};
        [] ->
            lager:error("HANDLE FOR ~p not found", [Handle]),
            not_found
    end.


%% @doc
-spec link_to_handle(nklib:link(), in|out) ->
    {ok, binary()} | not_found.

link_to_handle(Link, Type) ->
    case nklib_proc:values({nkmedia_sip_link_to_handle, Type, Link}) of
        [{Handle, Pid}] -> 
            nklib_proc:del({nkmedia_sip_link_to_handle, Type, Link}, Pid),
            {ok, Handle};
        [] ->
            not_found
    end.


%% @doc
-spec dialog_to_link(nksip:request()) ->
    {ok, nklib:link() | not_found}.

dialog_to_link(Req) ->
    {ok, Dialog} = nksip_dialog:get_handle(Req),
    case nklib_proc:values({nkmedia_sip_dialog_to_link, Dialog}) of
        [{Link, _}] -> 
            {ok, Link};
        [] ->
            not_found
    end.


%% @doc
-spec link_to_dialog(nklib:link()) ->
    {ok, binary() | not_found}.

link_to_dialog(Link) ->
    case nklib_proc:values({nkmedia_sip_link_to_dialog, Link}) of
        [{Dialog, _}] -> 
            {ok, Dialog};
        [] ->
            not_found
    end.









