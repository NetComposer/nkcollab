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

%% @doc Call management
-module(nkcollab_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/3, start_type/4, hangup/2, hangup_all/0]).
-export([ringing/2, ringing/3, accepted/4, candidate/3, rejected/2]).
-export([register/2, unregister/2, session_event/3]).
-export([find/1, get_all/0, get_call/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkCOLLAB Call ~s "++Txt, [State#state.id | Args])).

-include("../../include/nkcollab.hrl").
-include("../../include/nkcollab_call.hrl").
-include_lib("nkservice/include/nkservice.hrl").

-define(CALLER_FIELDS, [sdp_type, no_answer_trickle_ice, trickle_ice_timeout]).
-define(CALLEE_FIELDS, [sdp_type, no_offer_trickle_ice, trickle_ice_timeout]).

-define(DEFAULT_BACKEND, nkmedia_janus).


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().

-type dest() :: term().

-type dest_ext() ::
    #{
        dest => dest(),
        wait => integer(),                      %% secs
        ring => integer(),
        session_config => map()
    }.

-type caller() :: term().

-type callee() :: term().

-type callee_id() :: nklib:link().

-type callee_session_id() :: session_id().

% -type call_type() :: user | session | atom(). % Also nkcollab_verto, ...

-type session_id() :: nkmedia_session:id().

-type config() ::
    #{
        call_id => id(),                        % Optional
        backend => nkcollab:backend() | none,
        no_offer_trickle_ice => boolean(),      % Buffer candidates and insert in SDP
        no_answer_trickle_ice => boolean(),       
        trickle_ice_timeout => integer(),
        sdp_type => nkcollab:sdp_type(),
        caller => caller(),                     % Caller info
        caller_link => nklib:link(),
        register => nklib:link(),
        user_id => nkservice:user_id(),             % Informative only
        user_session => nkservice:user_session()    % Informative only
    }.


-type call() ::
    config() |
    #{
        srv_id => nkservice:id(),
        dest => dest(),
        callee => callee(),
        caller_session_id => session_id(),      % Generated if not included
        callee_link => nklib:link(),
        callee_session_id => callee_session_id()
    }.


-type event() :: 
    {ringing, callee()}                                                     | 
    {accepted, callee()}                                                    | 
    {hangup, nkservice:error()}                                             |
    {session_candidate, session_id(), nkmedia:candidate(), nklib:link()}    |
    {session_candidate_end, session_id(), nklib:link()}                     |
    {session_answer, session_id(), nkmedia:answer(), nklib:link()}          |
    {session_status, session_id(), atom(), map(), nklib:link()}             |
    {session_cancelled, session_id(), nklib:link()}.




%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call to a callee
%% - nkcollab_call_expand is called to get destinations from callee
%% - once we have all destinations, nkcollab_call_invite is called for each
%% - callees must call ringing, accepted, rejected
-spec start(nkservice:id(), dest(), config()) ->
    {ok, id(), pid()}.

start(Srv, Dest, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{srv_id=>SrvId, dest=>Dest},
            {CallId, Config3} = nkmedia_util:add_id(call_id, Config2, call),
            {ok, Pid} = gen_server:start(?MODULE, [Config3], []),
            {ok, CallId, Pid};
        not_found ->
            {error, service_not_found}
    end.




%% @doc Equivalent to start/3, but understands prefixes:
%% - p2p:XXX the backend is set to 'p2p'
%% - sip:XXX the backend is set to janus, and sdp_type is fixed (for caller session)
%% -
%%
-spec start_type(nkservice:id(), atom(), dest(), config()) ->
    {ok, id(), pid()}.

start_type(Srv, Type, Dest, Config) ->
    case Dest of
        <<"none", Dest2/binary>> ->
            Config2 = Config#{backend=>none};
        <<"p2p", Dest2/binary>> ->
            Config2 = Config#{backend=>p2p};
        <<"sip", Dest2/binary>> ->
            Config2 = Config#{backend=>nkmedia_janus, sdp_type=>rtp};
        <<"fs", Dest2/binary>> ->
            Config2 = Config#{backend=>nkmedia_fs};
        <<"kms", Dest2/binary>> ->
            Config2 = Config#{backend=>nkmedia_kms};
        Dest2 ->
            Config2 = Config#{backend=>?DEFAULT_BACKEND}
    end,
    case Dest2 of
        <<":", Dest3/binary>> -> ok;
        <<"-", Dest3/binary>> -> ok;
        Dest3 -> ok
    end,
    start(Srv, {Type, Dest3}, Config2).


%% @doc Called by the invited process
-spec ringing(id(), callee_id() | callee_session_id()) ->
    ok | {error, term()}.

ringing(CallId, CalleeId) ->
    ringing(CallId, CalleeId, #{}).


%% @doc Called by the invited process
-spec ringing(id(), callee_id() | callee_session_id(), callee()) ->
    ok | {error, term()}.

ringing(CallId, CalleeId, Callee) when is_map(Callee) ->
    do_call(CallId, {ringing, CalleeId, Callee}).


%% @doc Called by the invited process
-spec accepted(id(), callee_id() | callee_session_id(), 
               {offer, nkmedia:offer()} | {answer, nkmedia:answer()} | none,
               callee()) ->    
    ok | {error, term()}.

accepted(CallId, CalleeId, Reply, Callee) when is_map(Callee) ->
    do_call(CallId, {accepted, CalleeId, Reply, Callee}).


%% @doc Called by the invited process
-spec candidate(id(), callee_id() | callee_session_id(), nkcollab:candidate()) ->
    ok | {error, term()}.

candidate(CallId, CalleeId, Candidate) ->
    do_cast(CallId, {candidate, CalleeId, Candidate}).


%% @doc Called by the invited process
-spec rejected(id(), callee_id() | callee_session_id()) ->
    ok | {error, term()}.

rejected(CallId, CalleeId) ->
    do_cast(CallId, {rejected, CalleeId}).


%% @doc
-spec hangup(id(), nkservice:error()) ->
    ok | {error, term()}.

hangup(CallId, Reason) ->
    do_cast(CallId, {hangup, Reason}).


%% @private
hangup_all() ->
    lists:foreach(fun({CallId, _Pid}) -> hangup(CallId, 16) end, get_all()).


%% @doc Registers a process with the call
-spec register(id(), nklib:link()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(CallId, Link) ->
    do_call(CallId, {register, Link}).


%% @doc Registers a process with the call
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkservice:error()}.

unregister(CallId, Link) ->
    do_call(CallId, {unregister, Link}).


%% @private
-spec session_event(id(), session_id(), nkmedia_session:event()) ->
    ok | {error, term()}.
session_event(CallId, SessId, Event) ->
    do_cast(CallId, {session_event, SessId, Event}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).
 

%% @doc
-spec get_call(id()) ->
    {ok, call()} | {error, term()}.

get_call(CallId) ->
    do_call(CallId, get_call).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(invite, {
    pos :: integer(),
    dest :: dest(),
    ring :: integer(),
    launched :: boolean(),
    timer :: reference(),
    link :: nklib:link(),
    session_id :: session_id(),
    session_config :: nkmedia_session:config(),
    offer :: nkmedia:offer()
}).

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    backend :: nmedia:backend() | none,
    links :: nklib_links:links(),
    caller_link :: nklib:link(),
    callee_link :: nklib:link(),
    caller_session_id :: session_id(),
    callee_session_id :: session_id(),
    invites = [] :: [#invite{}],
    pos = 0 :: integer(),
    stop_reason = false :: false | nkservice:error(),
    call :: call()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{srv_id:=SrvId, call_id:=CallId, dest:=Dest}=Call]) ->
    nklib_proc:put(?MODULE, CallId),
    nklib_proc:put({?MODULE, CallId}),  
    CallerLink = maps:get(caller_link, Call, undefined),
    Backend = maps:get(backend, Call, none),
    State1 = #state{
        id = CallId, 
        srv_id = SrvId,
        backend = Backend,
        links = nklib_links:new(),
        caller_link = CallerLink,
        call = Call
    },
    ?LLOG(info, "starting to ~p (~p, ~p)", [Dest, Backend, self()], State1),
    State2 = case CallerLink of
        undefined ->
            State1;
        _ ->
            links_add(CallerLink, caller_link, State1)
    end,
    State3 = case Call of
        #{register:=Link} -> 
            links_add(Link, reg, State2);
        _ ->
            State2
    end,
    gen_server:cast(self(), start_caller_session),
    handle(nkcollab_call_init, [CallId], State3).


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({ringing, Id, Callee}, _From, State) ->
    case find_invite_by_id(Id, State) of
        {ok, #invite{}} ->
            {reply, ok, event({ringing, Callee}, State)};
        not_found ->
            {reply, {error, invite_not_found}, State} 
    end;

handle_call({accepted, Id, Reply, Callee}, _From, State) ->
    lager:error("REPLY: ~p", [Reply]),
    case find_invite_by_id(Id, State) of
        {ok, #invite{session_id=CalleeSessId}=Inv} ->
            ?LLOG(info, "accepted from ~p", [Id], State),
            #state{
                id = CallId, 
                backend = Backend,
                caller_session_id = CallerSessId, 
                call = Call
            } = State,
            State2 = State#state{call=?CALL(#{callee=>Callee}, Call)},
            Args = [CallId, CallerSessId, CalleeSessId, Reply, Backend],
            case handle(nkcollab_call_set_accepted, Args, State2) of
                {ok, State3} ->
                    State4 = do_accepted(Inv, State3),
                    State5 = event({accepted, Callee}, State4),
                    {reply, {ok, self()}, State5};
                {error, Error, State3} ->
                    hangup(self(), Error),
                    {reply, {error, Error}, State3}
            end;
        not_found ->
            ?LLOG(info, "rejected accepted from ~p", [Id], State),
            {reply, {error, invite_not_found}, State}
    end;

handle_call(get_call, _From, #state{call=Call}=State) -> 
    {reply, {ok, Call}, State};

handle_call({register, Link}, _From, State) ->
    ?LLOG(info, "proc registered (~p)", [Link], State),
    State2 = links_add(Link, reg, State),
    {reply, {ok, self()}, State2};

handle_call({unregister, Link}, _From, State) ->
    ?LLOG(info, "proc unregistered (~p)", [Link], State),
    State2 = links_remove(Link, State),
    {reply, ok, State2};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(get_links, _From, #state{links=Links}=State) ->
    {reply, Links, State};

handle_call(Msg, From, State) -> 
    handle(nkcollab_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(start_caller_session, #state{id=CallId, backend=Backend, call=Call}=State) ->
    Config1 = maps:with(?CALLER_FIELDS, Call),
    Config2 = Config1#{register=>{nkcollab_call, CallId, self()}},
    case handle(nkcollab_call_start_caller_session, [CallId, Config2,  Backend], State) of
        {ok, SessId, Pid, #state{call=Call2}=State2} ->
            State3 = State2#state{
                caller_session_id = SessId, 
                call = ?CALL(#{caller_session_id=>SessId}, Call2)
            },
            State4 = links_add(SessId, caller_session_id, Pid, State3),
            do_start(State4);
        {none, State2} ->
            do_start(State2);
        {error, Error, State2} ->
            do_hangup(Error, State2)
    end;

handle_cast({candidate, Id, Candidate}, State) ->
    case State of
        #state{caller_link=Id, caller_session_id=SessId} ->
            nkmedia_session:candidate(SessId, Candidate);
        #state{caller_session_id=Id} ->
            nkmedia_session:candidate(Id, Candidate);
        #state{callee_link=Id, callee_session_id=SessId} ->
            nkmedia_session:candidate(SessId, Candidate);
        #state{callee_session_id=Id} ->
            nkmedia_session:candidate(Id, Candidate);
        _ ->
            ?LLOG(warning, "received candidate for unknown peer", [], State),
            hangup(self(), unknown_peer)
    end,
    {noreply, State};

handle_cast({rejected, Id}, State) ->
    case find_invite_by_id(Id, State) of
        {ok, #invite{pos=Pos}} ->
            remove_invite(Pos, call_rejected, State);
        not_found ->
            {noreply, State}
    end;

% The session has launched a candidate for the backend
handle_cast({session_event, SessId, Event}, State) ->
    do_session_event(SessId, Event, State);

handle_cast({hangup, Reason}, State) ->
    ?LLOG(info, "external hangup: ~p", [Reason], State),
    do_hangup(Reason, State);

handle_cast(Msg, State) -> 
    handle(nkcollab_call_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({launch_out, Pos}, State) ->
    case find_invite_by_pos(Pos, State) of
        {ok, #invite{launched=false, ring=Ring}=Out} ->
            Timer = erlang:send_after(1000*Ring, self(), {ring_timeout, Pos}),
            launch_out(Out#invite{timer=Timer}, State);
        {ok, Out} ->
            launch_out(Out, State);
        not_found ->
            % The call should have been removed because of timeout
            {noreply, State}
    end;

handle_info({ring_timeout, Pos}, State) ->
    case find_invite_by_pos(Pos, State) of
        {ok, #invite{dest=Dest}} ->
            ?LLOG(info, "call ring timeout for ~p (~p)", [Dest, Pos], State),
            remove_invite(Pos, ring_timeout, State);
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, State) ->
    case links_down(Ref, State) of
        {ok, Link, Data, State2} ->
            case Reason of
                normal ->
                    ?LLOG(info, "linked ~p down (normal)", [Link], State);
                _ ->
                    ?LLOG(notice, "linked ~p down (~p)", [Link, Reason], State)
            end,
            case Data of
                caller_link ->
                    do_hangup(caller_stopped, State2);
                caller_session_id ->
                    do_hangup(caller_stopped, State2);
                callee_link ->
                    case State of
                        #state{callee_link=Link} ->
                            do_hangup(callee_stopped, State2);
                        _ ->
                            rejected(self(), Link),
                            {noreply, State2}
                    end;
                callee_session_id ->
                    case State of
                        #state{callee_session_id=Link} ->
                            do_hangup(callee_stopped, State2);
                        _ ->
                            rejected(self(), Link),
                            {noreply, State2}
                    end;
                reg ->
                    do_hangup(registered_down, State2)
            end;
        not_found ->
            handle(nkcollab_call_handle_info, [Msg], State)
    end;

handle_info(Msg, #state{}=State) -> 
    handle(nkcollab_call_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    #state{caller_session_id=Caller, callee_session_id=Callee, stop_reason=Stop} = State,
    Stop2 = case Stop of
        false ->
            Ref = nklib_util:uid(),
            ?LLOG(notice, "terminate error ~s: ~p", [Ref, Reason], State),
            {internal_error, Ref};
        _ ->
            Stop
    end,
    stop_session(Caller, Stop2),
    stop_session(Callee, Stop2),
    State2 = cancel_all(State),
    timer:sleep(100),
    % Give time for registrations to success
    State3 = event({hangup, Stop2}, State2),
    {ok, _State4} = handle(nkcollab_call_terminate, [Reason], State3),
    % Wait to receive events before receiving DOWN
    timer:sleep(100),
    ok.


% ===================================================================
%% Internal
%% ===================================================================

%% @private
do_start(#state{call=#{dest:=Dest}}=State) ->
    {ok, ExtDests, State2} = handle(nkcollab_call_expand, [Dest, []], State),
    State3 = launch_invites(ExtDests, State2),
    #state{invites=Invs} = State3,
    Dests = [D2 || #invite{dest=D2} <- Invs],
    ?LLOG(notice, "resolved invites for ~p: ~p", [Dest, Dests], State),
    {noreply, State3}.

%% @private Generate data and launch messages
-spec launch_invites(callee() | [dest_ext()], State) ->
    State.

launch_invites([], #state{invites=Invs}=State) ->
    case length(Invs) of
        0 -> 
            hangup(self(), no_destination);
        _ -> 
            ok
    end,        
    State;

launch_invites([#{dest:=Dest}=DestEx|Rest], #state{invites=Invs, pos=Pos}=State) ->
    Wait = case maps:find(wait, DestEx) of
        {ok, Wait0} -> Wait0;
        error -> 0
    end,
    Ring = case maps:find(ring, DestEx) of
        {ok, Ring0} -> min(Ring0, ?MAX_RING_TIMEOUT);
        error -> ?DEF_RING_TIMEOUT
    end,
    Inv = #invite{
        pos = Pos,
        dest = Dest, 
        ring = Ring, 
        launched = false,
        session_config = maps:get(session_config, DestEx, #{})
    },
    case Wait of
        0 -> self() ! {launch_out, Pos};
        _ -> erlang:send_after(1000*Wait, self(), {launch_out, Pos})
    end,
    launch_invites(Rest, State#state{invites=[Inv|Invs], pos=Pos+1});

launch_invites(Callee, State) ->
    launch_invites([#{dest=>Callee}], State).


%% @private
launch_out(Inv, #state{id=CallId, call=Call}=State) ->
    case start_callee_session(Inv, State) of
        {ok, #invite{dest=Dest, session_id=SessId, offer=Offer}=Inv2, State2} ->
            Data = lists:flatten([
                case SessId of
                    undefined -> [];
                    _ -> {session_id, SessId}
                end,
                case Offer of
                    undefined -> [];
                    _ -> {offer, Offer}
                end,
                case maps:find(caller, Call) of
                    {ok, Caller} -> {caller, Caller};
                    errror -> []
                end
            ]),
            Args = [CallId, Dest, maps:from_list(Data)],
            case handle(nkcollab_call_invite, Args, State2) of
                {ok, Link, State3} ->
                    launched_out(Inv2, Link, State3);
                {retry, Secs, State3} ->
                    launched_retry(Inv2, Secs, State3);
                {remove, State3} ->
                    #invite{pos=Pos, dest=Dest} = Inv,
                    ?LLOG(notice, "removing out ~p (~p)", [Dest, Pos], State),
                    remove_invite(Pos, call_rejected, State3)
            end;
        {error, Error, State2} ->
            ?LLOG(notice, "error generating session: ~p", [Error], State2),
            #invite{pos=Pos} = Inv,
            remove_invite(Pos, call_error, State2)
    end.


%% @private
launched_out(#invite{pos=Pos, dest=Dest}=Inv, Link, State) ->
    ?LLOG(info, "launched out ~p (~p) from ~p", [Dest, Pos, Link], State),
    Inv2 = Inv#invite{launched=true, link=Link},
    State2 = store_invite(Inv2, State),
    State3 = links_add(Link, callee_link, State2),
    {noreply, State3}.


%% @private
launched_retry(Inv, Secs, State) ->
    #invite{pos=Pos, dest=Dest} = Inv, 
    ?LLOG(notice, "retrying out ~p (~p, ~p secs)", [Dest, Pos, Secs], State),
    erlang:send_after(1000*Secs, self(), {launch_out, Pos}),
    {noreply, State}.


%% @private
start_callee_session(#invite{session_id=undefined}=Inv, State) ->
    #invite{session_config=Config} = Inv,
    #state{id=CallId, backend=Backend, caller_session_id=CallerSessId} = State,
    Config1 = maps:with(?CALLEE_FIELDS, Config),
    Config2 = Config1#{register=>{nkcollab_call, CallId, self()}},
    Args = [CallId, CallerSessId, Config2, Backend],
    case handle(nkcollab_call_start_callee_session, Args, State) of
        {ok, CalleeSessId, Pid, Offer, State2} ->
            State3 = links_add(CalleeSessId, callee_session_id, Pid, State2),
            Inv2 = Inv#invite{session_id=CalleeSessId, offer=Offer},
            {ok, Inv2, store_invite(Inv2, State3)};
        {none, State2} ->
            {ok, Inv, State2};
        {error, Error, State2} ->
            {error, Error, State2}
    end;

start_callee_session(Inv, State) ->
    {ok, Inv, State}.


%% @private
do_accepted(Inv, #state{call=Call}=State) ->
    #invite{
        pos = Pos, 
        link = CalleeLink, 
        session_id = CalleeSessId
    } = Inv,
    State2 = cancel_all_but(Pos, State),
    Call2 = ?CALL_RM(offer, Call),
    State3 = State2#state{
        callee_link = CalleeLink,
        callee_session_id = CalleeSessId, 
        call = ?CALL(#{callee_session_id=>CalleeSessId}, Call2)
    },
    links_add(CalleeLink, callee_link, State3).


% The session has launched a candidate for the backend
do_session_event(SessId, {candidate, Candidate}, State) ->
    State2 = case find_sess_id(SessId, State) of
        {caller, Link} ->
            event({session_candidate, SessId, Candidate, Link}, State);
        {callee, Link} ->
            event({session_candidate, SessId, Candidate, Link}, State);
        {invite, Link} ->
            event({session_candidate, SessId, Candidate, Link}, State);
        not_found ->
            ?LLOG(notice, "received unexpected session candidate: ~p", 
                  [SessId], State),
            State
    end,
    {noreply, State2};

% If the caller session has an answer, call callback
do_session_event(SessId, {answer, Answer}, State) ->
    State2 = case find_sess_id(SessId, State) of
        {caller, Link} ->
            event({session_answer, SessId, Answer, Link}, State);
        _ ->
            State
    end,
    {noreply, State2};

do_session_event(SessId, {destroyed, _Reason}, State) ->
    case find_sess_id(SessId, State) of
        {caller, _} ->
            do_hangup(caller_stopped, State);
        {callee, _} ->
            do_hangup(callee_stopped, State);
        {invite, _} ->
            rejected(self(), SessId),
            {noreply, State};
        not_found ->
            {noreply, State}
    end;

do_session_event(SessId, {status, Status, Meta}, State) ->
    State2 = case find_sess_id(SessId, State) of
        {_Type, Link} ->
            % lager:warning("Status for ~s (~p): ~p", [SessId, Type, Status]),
            event({session_status, SessId, Status, Meta, Link}, State);
        not_found ->
            State
    end,
    {noreply, State2};

do_session_event(_SessId, _Event, State) ->
    {noreply, State}.



%% @private
find_invite_by_pos(Pos, #state{invites=Invs}) ->
   case lists:keyfind(Pos, #invite.pos, Invs) of
        #invite{} = Inv -> {ok, Inv};
        false -> not_found
    end.


%% @private
find_invite_by_id(Id, #state{invites=Invs}) ->
   case lists:keyfind(Id, #invite.session_id, Invs) of
        #invite{} = Inv -> 
            {ok, Inv};
        false ->
            case lists:keyfind(Id, #invite.link, Invs) of
                #invite{} = Inv -> 
                    {ok, Inv};
                false ->
                    not_found
            end
    end.


%% @private
remove_invite(Pos, Reason, #state{invites=Invs}=State) ->
    case lists:keytake(Pos, #invite.pos, Invs) of
        {value, #invite{pos=Pos}=Inv, Invs2} ->
            stop_session(Inv, Reason),
            case Invs2 of
                [] ->
                    ?LLOG(info, "all invites removed", [], State),
                    do_hangup(no_answer, State#state{invites=[]});
                _ ->
                    ?LLOG(info, "removed invite (~p)", [Pos], State),
                    {noreply, State#state{invites=Invs2}}
            end;
        false ->
            {noreply, State}
    end.


%% @private
cancel_all(State) ->
    cancel_all_but(-1, State).


%% @private
cancel_all_but(Except, #state{invites=Invs}=State) ->
    State2 = lists:foldl(
        fun(Inv, AccState) ->
            #invite{pos=Pos, timer=Timer, session_id=SessId, link=Link} = Inv,
            nklib_util:cancel_timer(Timer),
            case Pos of
                Except -> 
                    AccState;
                _ -> 
                    event({session_cancelled, SessId, Link}, AccState)
            end
        end,
        State,
        Invs),
    State2#state{invites=[]}.


%% @private
find_sess_id(SessId, State) ->
    case State of
        #state{caller_session_id=SessId, caller_link=Link} ->
            {caller, Link};
        #state{callee_session_id=SessId, callee_link=Link} ->
            {callee, Link};
         _ ->
            case find_invite_by_id(SessId, State) of
                {ok, #invite{link=Link}} ->
                    {invite, Link};
                not_found ->
                    not_found
            end
    end.


%% @private
do_hangup(Reason, State) ->
    {stop, normal, State#state{stop_reason=Reason}}.


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {answer, Link, _Ans} ->
            ?LLOG(info, "sending 'event': ~p", [{answer, <<"sdp">>, Link}], State);
        _ ->
            ?LLOG(info, "sending 'event': ~p", [Event], State)
    end,
    State2 = links_fold(
        fun(Link, _Data, AccState) -> reg_event(Event, Link, AccState) end,
        State,
        State),
    {ok, State3} = handle(nkcollab_call_event, [Id, Event], State2),
    State3.


%% @private
reg_event(Event, Link, #state{id=Id}=State) ->
    {ok, State2} = handle(nkcollab_call_reg_event, [Id, Link, Event], State),
    State2.


%% @private
stop_session(#invite{session_id=SessId}, Reason) when is_binary(SessId)->
    stop_session(SessId, Reason);

stop_session(SessId, Reason) when is_binary(SessId) ->
    nkmedia_session:stop(SessId, Reason);

stop_session(_Inv, _Reason) ->
    ok.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.call).


%% @private
do_call(CallId, Msg) ->
    do_call(CallId, Msg, 5000).


%% @private
do_call(CallId, Msg, Timeout) ->
    case find(CallId) of
        {ok, Pid} -> nkservice_util:call(Pid, Msg, Timeout);
        not_found -> {error, call_not_found}
    end.


%% @private
do_cast(CallId, Msg) ->
    case find(CallId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, call_not_found}
    end.

%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(CallId) ->
    case nklib_proc:values({?MODULE, CallId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
links_add(Link, Data, State) ->
    Pid = nklib_links:get_pid(Link),
    links_add(Link, Data, Pid, State).


%% @private
links_add(Link, Data, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, Data, Pid, Links)}.


%% @private
links_remove(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Link, Links)}.


%% @private
links_down(Ref, #state{links=Links}=State) ->
    case nklib_links:down(Ref, Links) of
        {ok, Link, Data, Links2} -> 
            {ok, Link, Data, State#state{links=Links2}};
        not_found -> 
            not_found
    end.


%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold_values(Fun, Acc, Links).


%% @private
store_invite(#invite{pos=Pos}=Inv, #state{invites=Invs}=State) ->
    Invs2 = lists:keystore(Pos, #invite.pos, Invs, Inv),
    State#state{invites=Invs2}.
    


