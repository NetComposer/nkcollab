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

%% @doc NkCOLLAB external API
-module(nkcollab_api_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([syntax/4]).



%% ===================================================================
%% Syntax
%% ===================================================================

syntax(<<"create">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            class => {enum, [sfu]},
            room_id => binary,
            backend => backend(),
            bitrate => {integer, 0, none},
            audio_codec => {enum, [opus, isac32, isac16, pcmu, pcma]},
            video_codec => {enum , [vp8, vp9, h264]}
        },
        Defaults#{class=>sfu},
        Mandatory
    };

syntax(<<"destroy">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{room_id => binary},
        Defaults,
        [room_id|Mandatory]
    };

syntax(<<"get_list">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{service => fun nkservice_api:parse_service/1},
        Defaults, 
        Mandatory
    };

syntax(<<"get_info">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{room_id => binary},
        Defaults, 
        [room_id|Mandatory]
    };

%% @private
syntax(<<"add_member">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			room_id => binary,
			role => {enum, [publisher, listener]},
	        peer_id => binary,
			wait_reply => boolean,
			member_id => binary,
			offer => nkmedia_api_syntax:offer(),
        	no_offer_trickle_ice => atom,
        	no_answer_trickle_ice => atom,
        	trickle_ice_timeout => {integer, 100, 30000},
			backend => backend(),
			events_body => any,
			wait_timeout => {integer, 1, none},
			ready_timeout => {integer, 1, none},
			mute_audio => boolean,
        	mute_video => boolean,
        	mute_data => boolean,
        	bitrate => integer
		},
		Defaults,
		[room_id, role|Mandatory]
	};

syntax(<<"remove_member">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			room_id => binary,
			member_id => binary
		},
		Defaults,
		[room_id, member_id|Mandatory]
	};

syntax(<<"set_answer">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			room_id => binary,
			member_id => binary,
			answer => nkmedia_api_syntax:answer()
		},
		Defaults,
		[room_id, member_id, answer|Mandatory]
	};

syntax(<<"get_answer">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			room_id => binary,
			member_id => binary
		},
		Defaults,
		[room_id, member_id|Mandatory]
	};

syntax(<<"set_candidate">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			room_id => binary,
			member_id => binary,
			sdpMid => binary,
			sdpMLineIndex => integer,
			candidate => binary
		},
		Defaults#{sdpMid=><<>>},
		[room_id, member_id, sdpMLineIndex, candidate|Mandatory]
	};

syntax(<<"set_candidate_end">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			room_id => binary,
			member_id => binary
		},
		Defaults,
		[room_id, member_id|Mandatory]
	};

syntax(<<"update_media">>, Syntax, Defaults, Mandatory) ->
	{
		Syntax#{
			room_id => binary,
			member_id => binary,
			mute_audio => boolean,
			mute_video => boolean,
			mute_data => boolean,
			bitrate => integer
		},
		Defaults,
		[room_id, member_id|Mandatory]
	};

syntax(_Cmd, Syntax, Defaults, Mandatory) ->
	{Syntax, Defaults, Mandatory}.



%% @private
backend() ->
	{enum, [nkmedia_janus, nkmedia_kms, nkmedia_fs]}.