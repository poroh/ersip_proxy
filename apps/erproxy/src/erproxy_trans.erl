%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% SIP Transaction
%%

-module(erproxy_trans).

-behaviour(gen_server).

-export([start_link/3,
         find_server_trans/1,
         find_server_cancel_trans/1,
         find_client_trans/2,
         recv_request/2,
         recv_response/2,
         send_response/2,
         cancel_request/1
        ]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {trans       :: ersip_trans:trans(),
                tu_callback :: fun((ersip_sipmsg:sipmsg()) -> any())
               }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Type, TUCallback, Args) ->
    {Trans, SE} = create_transaction(Type, Args),
    State = #state{trans       = Trans,
                   tu_callback = TUCallback
                  },
    Id = ersip_trans:id(Trans),
    lager:info("Starting ~p transaction with id: ~p", [Type, Id]),
    gen_server:start_link({global, {?MODULE, Id}}, ?MODULE, [State, SE], []).

recv_request(InSipMsg, Pid) ->
    gen_server:cast(Pid, {received, InSipMsg}).

recv_response(SipMsg, Pid) ->
    gen_server:cast(Pid, {received, SipMsg}).

send_response(SipMsg, Pid) ->
    gen_server:cast(Pid, {send, SipMsg}).

-spec cancel_request(pid()) -> ok | {error, no_request}.
cancel_request(Pid) ->
    try
        gen_server:call(Pid, cancel_request)
    catch
        exit:{noproc, _} ->
            {error, no_request}
    end.

find_server_trans(InSipMsg) ->
    TransId = ersip_trans:server_id(InSipMsg),
    case global:whereis_name({?MODULE, TransId}) of
        undefined ->
            error;
        Pid when is_pid(Pid) ->
            {ok, Pid}
    end.

find_server_cancel_trans(CancelSipMsg) ->
    TransId = ersip_trans:server_cancel_id(CancelSipMsg),
    case global:whereis_name({?MODULE, TransId}) of
        undefined ->
            error;
        Pid when is_pid(Pid) ->
            {ok, Pid}
    end.

find_client_trans(RecvVia, SipMsg) ->
    TransId = ersip_trans:client_id(RecvVia, SipMsg),
    case global:whereis_name({?MODULE, TransId}) of
        undefined ->
            error;
        Pid when is_pid(Pid) ->
            {ok, Pid}
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([State, SE]) ->
    case process_se_list(SE, State) of
        {noreply, State1} ->
            {ok, State1};
        {stop, _State1} ->
            {stop, normal}
    end.

handle_call(cancel_request, _From, #state{tu_callback = CB} = State) ->
    case call_callback(CB, [cancel]) of
        ok ->
            {reply, ok, State};
        {error, noproc} ->
            {reply, {error, no_request}, State}
    end;
handle_call(Request, _From, State) ->
    lager:error("Unexpected call ~p", [Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({received, _SipMsg} = Ev, #state{trans = Trans} = State) ->
    {NewTrans, SE} = ersip_trans:event(Ev, Trans),
    cast_se(SE),
    {noreply, State#state{trans = NewTrans}};
handle_cast({send, _SipMsg} = Ev, #state{trans = Trans} = State) ->
    {NewTrans, SE} = ersip_trans:event(Ev, Trans),
    case process_se_list(SE, State#state{trans = NewTrans}) of
        {noreply, State1} ->
            {noreply, State1};
        {stop, State1} ->
            {stop, normal, ok, State1}
    end;
handle_cast({process_se, SEList}, State) ->
    process_se_list(SEList, State);
handle_cast(Request, State) ->
    lager:error("Unexpected cast ~p", [Request]),
    {noreply, State}.

handle_info({event, TimerEvent}, #state{trans = Trans} = State) ->
    {NewTrans, SE} = ersip_trans:event(TimerEvent, Trans),
    process_se_list(SE, State#state{trans = NewTrans});
handle_info(Info, State) ->
    lager:error("Unexpected info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("Terminated with reason ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

process_se_list([], State) ->
    {noreply, State};
process_se_list([SE | Rest], State) ->
    case process_se(SE, State) of
        {stop, NewState} ->
            {stop, normal, NewState};
        {continue, NewState} ->
            process_se_list(Rest, NewState)
    end.

process_se({tu_result, SipMsg}, #state{tu_callback = CB} = State) ->
    call_callback(CB, [SipMsg]),
    {continue, State};
process_se({set_timer, {Timeout, TimerEvent}}, State) ->
    erlang:send_after(Timeout, self(), {event, TimerEvent}),
    {continue, State};
process_se({clear_trans, timeout}, #state{tu_callback = CB} = State) ->
    call_callback(CB, [timeout]),
    {stop, State};
process_se({clear_trans, no_ack}, #state{tu_callback = CB} = State) ->
    call_callback(CB, [no_ack]),
    {stop, State};
process_se({clear_trans, Reason}, State) ->
    lager:info("Transaction is cleared: ~p", [Reason]),
    {stop, State};
process_se({send_request, OutReq}, State) ->
    erproxy_conn:send_request(OutReq),
    {continue, State};
process_se({send_response, SipMsg}, State) ->
    erproxy_conn:send_response(SipMsg),
    {continue, State}.

cast_se(SE) ->
    gen_server:cast(self(), {process_se, SE}).

create_transaction(client, {OutReq, Options}) ->
    ersip_trans:new_client(OutReq, Options);
create_transaction(server, {SipMsg, Options}) ->
    ersip_trans:new_server(SipMsg, Options).


call_callback(CB, Args) ->
    try
        case CB of
            {M, F, A} ->
                erlang:apply(M, F, Args ++ A);
            F when is_function(F) ->
                erlang:apply(F, Args)
        end
    catch
        Type:Error ->
            lager:error("Transaction user error: ~p:~p", [Type, {Error,  erlang:get_stacktrace()}])
    end.
