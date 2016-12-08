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

-export([syntax/4, get_room_info/1, get_member_info/1]).

% -include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Syntax
%% ===================================================================

syntax(create, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            class => {enum, [sfu]},
            room_id => binary,
            backend => atom,
            timeout => {integer, 5, 24*60*60},
            audio_codec => {enum, [opus, isac32, isac16, pcmu, pcma]},
            video_codec => {enum , [vp8, vp9, h264]},
            bitrate => {integer, 0, none},
            meta => map
        },
        Defaults,
        Mandatory
    };

syntax(destroy, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{room_id => binary},
        Defaults,
        [room_id|Mandatory]
    };

syntax(get_list, Syntax, Defaults, Mandatory) ->
    {
        Syntax,
        Defaults, 
        Mandatory
    };

syntax(get_info, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{room_id => binary},
        Defaults, 
        [room_id|Mandatory]
    };

syntax(add_publish_session, Syntax, Defaults, Mandatory) ->
    {
        session_opts(Syntax),
        Defaults, 
        [room_id|Mandatory]
    };

syntax(add_listen_session, Syntax, Defaults, Mandatory) ->
    {
        session_opts(Syntax#{publisher_id => binary}),
        Defaults, 
        [room_id, publish_id|Mandatory]
    };

syntax(remove_session, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary,
            session_id => binary
        },
        Defaults, 
        [room_id, session_id|Mandatory]
    };

syntax(remove_member, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{room_id=>binary},
        Defaults, 
        [room_id|Mandatory]
    };

syntax(update_publisher, Syntax, Defaults, Mandatory) ->
    {
        session_opts(Syntax#{session_id=>binary}),
        Defaults,
        [room_id, session_id|Mandatory]
    };

syntax(update_meta, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary,
            session_id => binary
        },
        Defaults,
        [room_id, session_id|Mandatory]
    };

syntax(update_media, Syntax, Defaults, Mandatory) ->
    {
        media_opts(Syntax#{
            room_id => binary,
            session_id => binary
        }),
        Defaults,
        [room_id, session_id|Mandatory]
    };

syntax(send_broadcast, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary,
            member_id => integer,
            msg => map
        },
        Defaults,
        [room_id, member_id, msg|Mandatory]
    };

syntax(get_all_broadcasts, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary
        },
        Defaults,
        [room_id|Mandatory]
    };

syntax(set_answer, Syntax, Defaults, Mandatory) ->
    nkmedia_session_api_syntax:syntax(set_answer, Syntax, Defaults, Mandatory);

syntax(set_candidate, Syntax, Defaults, Mandatory) ->
    nkmedia_session_api_syntax:syntax(set_candidate, Syntax, Defaults, Mandatory);

syntax(set_candidate_end, Syntax, Defaults, Mandatory) ->
    nkmedia_session_api_syntax:syntax(set_candidate_end, Syntax, Defaults, Mandatory);

syntax(timelog, Syntax, Defaults, Mandatory) ->
    {
        Syntax#{
            room_id => binary,
            msg => binary,
            body => map
        },
        Defaults,
        [room_id, msg|Mandatory]
    };

syntax(_Cmd, Syntax, Defaults, Mandatory) ->
    {Syntax, Defaults, Mandatory}.



%% ===================================================================
%% Keys
%% ===================================================================


get_room_info(Room) ->
    Keys = [audio_codec, video_codec, bitrate, class, backend, meta, status],
    maps:with(Keys, Room).


get_member_info(Room) ->
    Keys = [user_id, role, meta],
    maps:with(Keys, Room).


%% ===================================================================
%% Internal
%% ===================================================================

session_opts(Syntax) ->
    Syntax#{
        room_id => binary,
        class => binary,
        device => binary,
        meta => map,

        offer => nkmedia_session_api_syntax:offer(),
        no_offer_trickle_ice => boolean,
        no_answer_trickle_ice => boolean,
        trickle_ice_timeout => {integer, 100, 30000},
        sdp_type => {enum, [webrtc, rtp]},    
        mute_audio => boolean,
        mute_video => boolean,
        mute_data => boolean,
        bitrate => {integer, 0, none}
    }.


media_opts(Data) ->
    Data#{
        mute_audio => boolean,
        mute_video => boolean,
        mute_data => boolean,
        bitrate => {integer, 0, none}
    }.
