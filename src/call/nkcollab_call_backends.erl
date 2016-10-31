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

-module(nkcollab_call_backends).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_caller_session/4, start_callee_session/5, set_accepted/6]).

-include("nkcollab_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================


%% @private
start_caller_session(_CallId, _Config, none, Call) ->
    {none, Call};

start_caller_session(CallId, Config, Backend, #{srv_id:=SrvId, offer:=Offer}=Call) ->
    case Backend of
        p2p ->
            Config2 = Config#{
                backend => p2p, 
                offer => Offer,
                call_id => CallId
            },
            {ok, MasterId, Pid} = nkmedia_session:start(SrvId, p2p, Config2),
            {ok, MasterId, Pid, ?CALL(#{backend=>p2p}, Call)};
        nkmedia_janus ->
            Config2 = Config#{
                backend => nkmedia_janus, 
                offer => Offer,
                call_id => CallId
            },
            {ok, MasterId, Pid} = nkmedia_session:start(SrvId, proxy, Config2),
            {ok, MasterId, Pid, ?CALL(#{backend=>nkmedia_janus}, Call)};
        nkmedia_fs ->
            Config2 = Config#{
                backend => nkmedia_fs, 
                offer => Offer,
                call_id => CallId
            },
            {ok, MasterId, Pid} = nkmedia_session:start(SrvId, park, Config2),
            {ok, MasterId, Pid, ?CALL(#{backend=>nkmedia_fs}, Call)};
        nkmedia_kms ->
            Config2 = Config#{
                backend => nkmedia_kms, 
                offer => Offer,
                call_id => CallId
            },
            {ok, MasterId, Pid} = nkmedia_session:start(SrvId, park, Config2),
            {ok, MasterId, Pid, ?CALL(#{backend=>nkmedia_kms}, Call)};
        _ ->
            {error, unknown_backend, Call}
    end;

start_caller_session(_CallId, _Config, _Backend, Call) ->
    {error, missing_offer, Call}.


%% @private
start_callee_session(CallId, MasterId, Config, Backend, #{srv_id:=SrvId}=Call) ->
    case Backend of
        none ->
            {none, Call};
        p2p ->
            case Call of
                #{offer:=Offer} ->
                    Config2 = Config#{
                        backend => p2p,
                        offer => Offer,
                        peer_id => MasterId,
                        call_id => CallId,
                        no_offer_trickle_ice => true,
                        no_answer_trickle_ice => true
                    },
                    {ok, SlaveId, Pid} = nkmedia_session:start(SrvId, p2p, Config2),
                    {ok, SlaveId, Pid, Offer, Call};
                _ ->
                    {error, missing_offer, Call}
            end;
		nkmedia_janus ->
            case nkmedia_session:cmd(MasterId, get_type, #{}) of
                {ok, #{type:=proxy, backend:=nkmedia_janus}} ->
                    Config2 = Config#{
                        backend => nkmedia_janus,
                        peer_id => MasterId,
                        call_id => CallId
                    },
                    {ok, SlaveId, Pid} = nkmedia_session:start(SrvId, bridge, Config2),
                    case nkmedia_session:get_offer(SlaveId) of
                        {ok, Offer} ->
                            {ok, SlaveId, Pid, Offer, Call};
                        {error, Error} ->
                            {error, Error, Call}
                    end;
                _ ->
                    {error, incompatible_session, Call}
            end;
        nkmedia_fs ->
            Config2 = Config#{
                backend => nkmedia_fs,
                call_id => CallId
            },
            {ok, SlaveId, Pid} = nkmedia_session:start(SrvId, park, Config2),
            case nkmedia_session:get_offer(SlaveId) of
                {ok, Offer} ->
                    {ok, SlaveId, Pid, Offer, Call};
                {error, Error} ->
                    {error, Error, Call}
            end;
        nkmedia_kms ->
            Config2 = Config#{
                backend => nkmedia_kms,
                call_id => CallId
            },
            {ok, SlaveId, Pid} = nkmedia_session:start(SrvId, park, Config2),
            case nkmedia_session:get_offer(SlaveId) of
                {ok, Offer} ->
                    {ok, SlaveId, Pid, Offer, Call};
                {error, Error} ->
                    {error, Error, Call}
            end;
        _ ->
            {error, unknown_backend, Call}
    end.


%% @private
set_accepted(_CallId, _MasterId, _SlaveId, _Reply, none, Call) ->
    {ok, Call};

set_accepted(_CallId, MasterId, SlaveId, {answer, Answer}, Backend, Call) ->
    case Backend of
        p2p ->
            case nkmedia_session:set_answer(MasterId, Answer) of
                ok ->
                    {ok, Call};
                {error, Error} ->
                    {error, Error, Call}
            end;
        nkmedia_fs ->
            case nkmedia_session:set_answer(SlaveId, Answer) of
                ok ->
                    Opts = #{type=>bridge, peer_id=>MasterId},
                    case nkmedia_session:cmd(SlaveId, set_type, Opts) of
                        {ok, _} ->
                            {ok, Call};
                        {error, Error} ->
                            {error, Error, Call}
                    end;
                {error, Error} ->
                    {error, Error, Call}
            end;
        nkmedia_janus ->
            case nkmedia_session:set_answer(SlaveId, Answer) of
                ok ->
                    {ok, Call};
                {error, Error} ->
                    {error, Error, Call}
            end;
        nkmedia_kms ->
            case nkmedia_session:set_answer(SlaveId, Answer) of
                ok ->
                    Opts = #{type=>bridge, peer_id=>MasterId},
                    case nkmedia_session:cmd(SlaveId, set_type, Opts) of
                        {ok, _} ->
                            {ok, Call};
                        {error, Error} ->
                            {error, Error, Call}
                    end;
                {error, Error} ->
                    {error, Error, Call}
            end;
        _ ->
            {error, unknown_backend, Call}
    end;

set_accepted(_CallId, _MasterId, _SlaveId, _Reply, _Backend, Call) ->
    lager:error("Reply: ~p", [_Reply]),
    {error, invalid_reply, Call}.




