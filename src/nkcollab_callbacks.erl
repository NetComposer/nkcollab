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

%% @doc NkCOLLAB callbacks

-module(nkcollab_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([error_code/1]).
-export([api_cmd/2, api_syntax/4]).
-export([api_server_cmd/2]).

% -include("nkcollab.hrl").
-include_lib("nkservice/include/nkservice.hrl").
% -include_lib("nkmedia/include/nkmedia.hrl").




%% ===================================================================
%% Types
%% ===================================================================

% -type continue() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin callbacks
%%
%% These are used when NkCOLLAB is started as a NkSERVICE plugin
%% ===================================================================


plugin_deps() ->
    [nkmedia, nkmedia_fs, nkmedia_kms, nkmedia_janus].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkCOLLAB CORE (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkCOLLAB CORE (~p) stopping", [Name]),
    {ok, Config}.




%% ===================================================================
%% Error Codes
%% ===================================================================

%% @doc See nkservice_callbacks.erl
-spec error_code(term()) ->
	{integer(), binary()} | continue.

error_code(_) -> continue.




%% ===================================================================
%% API CMD
%% ===================================================================

%% @private
api_cmd(#api_req{class = <<"collab">>}=Req, State) ->
	#api_req{subclass=Sub, cmd=Cmd} = Req,
	nkcollab_api:cmd(Sub, Cmd, Req, State);

api_cmd(_Req, _State) ->
	continue.


%% @private
api_syntax(#api_req{class = <<"collab">>}=Req, Syntax, Defaults, Mandatory) ->
	#api_req{subclass=Sub, cmd=Cmd} = Req,
	nkcollab_api_syntax:syntax(Sub, Cmd, Syntax, Defaults, Mandatory);
	
api_syntax(_Req, _Syntax, _Defaults, _Mandatory) ->
	continue.



% ===================================================================
%% API Server Callbacks
%% ===================================================================

%% @private Launch class media (api_cmd/2 will be called)
api_server_cmd(#api_req{class = <<"collab">>}=Req, State) ->
	nkservice_api:launch(Req, State);
	
api_server_cmd(_Req, _State) ->
    continue.

