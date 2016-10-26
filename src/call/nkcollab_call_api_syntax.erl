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

%% @doc Call Plugin API Syntax
-module(nkcollab_call_api_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([call_fields/0, syntax/4]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Syntax
%% ===================================================================

%% @private
call_fields() ->
    [
        call_id, 
        type,
        no_offer_trickle_ice,
        no_answer_trickle_ice,
        trickle_ice_timeout,
        sdp_type,
        backend,
        user_id,
        user_session,
        caller,
        callee
    ].


syntax(<<"create">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            type => atom,
            callee => any,
            caller => any,
            backend => atom,
            no_offer_trickle_ice => boolean,
            no_answer_trickle_ice => boolean,
            trickle_ice_timeout => {integer, 1, none},
            offer => nkmedia_api_syntax:offer(),
            sdp_type => {enum, [webrtc, rtp]},
            events_body => any
        },
        Defaults,
        [callee_id|Mandatory]
    };

syntax(<<"ringing">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            callee => map
        },
        Defaults,
        [call_id|Mandatory]
    };


syntax(<<"accepted">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            callee => map,
            answer => nkmedia_api_syntax:answer(),
            subscribe => boolean,
            events_body => any
        },
        Defaults,
        [call_id|Mandatory]
    };

syntax(<<"rejected">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary
        },
        Defaults,
        [call_id|Mandatory]
    };

syntax(<<"set_candidate">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            sdpMid => binary,
            sdpMLineIndex => integer,
            candidate => binary
        },
        Defaults#{sdpMid=><<>>},
        [call_id, sdpMLineIndex, candidate|Mandatory]
    };

syntax(<<"set_candidate_end">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary
        },
        Defaults,
        [call_id|Mandatory]
    };

syntax(<<"hangup">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            call_id => binary,
            reason => binary
        },
        Defaults,
        [call_id|Mandatory]
    };


syntax(<<"get_info">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{call_id => binary},
        Defaults,
        [call_id|Mandatory]
    };

syntax(<<"get_list">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax,
        Defaults,
        Mandatory
    };
    
syntax(_Cmd, Syntax, Defaults, Mandatory) ->
    {Syntax, Defaults, Mandatory}.

