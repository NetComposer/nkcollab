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

%% @doc Room Plugin API Syntax
-module(nkcollab_room_api_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([syntax/4]).

% -include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Syntax
%% ===================================================================

syntax(<<"create">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            class => atom,
            room_id => binary,
            backend => atom,
            bitrate => {integer, 0, none},
            audio_codec => {enum, [opus, isac32, isac16, pcmu, pcma]},
            video_codec => {enum , [vp8, vp9, h264]}
        },
        Defaults,
        [class|Mandatory]
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

syntax(<<"send_msg">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary,
            msg => map
        },
        Defaults,
        [room_id, msg|Mandatory]
    };

syntax(<<"get_all_msgs">>, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary
        },
        Defaults,
        [room_id|Mandatory]
    };

syntax(_Cmd, Syntax, Defaults, Mandatory) ->
    {Syntax, Defaults, Mandatory}.


