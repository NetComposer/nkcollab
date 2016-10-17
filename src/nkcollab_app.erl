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

%% @doc NkCOLLAB OTP Application Module
-module(nkcollab_app).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(application).

-export([start/0, start/2, stop/1]).
-export([get/1, get/2, put/2, del/1]).
-export([get_env/1, get_env/2, set_env/2]).

-include("nkcollab.hrl").
-include_lib("nklib/include/nklib.hrl").

-define(APP, nkcollab).

%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts stand alone.
-spec start() -> 
    ok | {error, Reason::term()}.

start() ->
    case nklib_util:ensure_all_started(?APP, permanent) of
        {ok, _Started} ->
            ok;
        Error ->
            Error
    end.


%% @private OTP standard start callback
start(_Type, _Args) ->
    Syntax = #{
    },
    Defaults = #{
    },
    case nklib_config:load_env(?APP, Syntax, Defaults) of
        {ok, _} ->
            {ok, Vsn} = application:get_key(?APP, vsn),
            lager:info("NkCOLLAB v~s is starting", [Vsn]),
            nkcollab_sup:start_link();
        {error, Error} ->
            lager:error("Error parsing config: ~p", [Error]),
            error(Error)
    end.


%% @private OTP standard stop callback
stop(_) ->
    ok.


%% Configuration access
get(Key) ->
    nklib_config:get(?APP, Key).

get(Key, Default) ->
    nklib_config:get(?APP, Key, Default).

put(Key, Val) ->
    nklib_config:put(?APP, Key, Val).

del(Key) ->
    nklib_config:del(?APP, Key).



%% @private
get_env(Key) ->
    get_env(Key, undefined).


%% @private
get_env(Key, Default) ->
    case application:get_env(?APP, Key) of
        undefined -> Default;
        {ok, Value} -> Value
    end.


%% @private
set_env(Key, Value) ->
    application:set_env(?APP, Key, Value).

