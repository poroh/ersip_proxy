%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Stateful proxy server
%%

-module(erproxy_stateful).

-behaviour(gen_server).

-export([request/2,
         response/2,
         trans_result/3,
         start_link/2
        ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%%===================================================================
%%% Types
%%%===================================================================

-record(state, {proxy       :: ersip_proxy:stateful(),
                trans = #{} :: #{term() => pid()},
                sip_options :: ersip:sip_options()
               }).

%%%===================================================================
%%% API
%%%===================================================================

request(SipMsg, Options) ->
    %% First looking if SipMsg match any transaction
    case erproxy_trans:find_server_trans(SipMsg) of
        error ->
            %% If transaction has not been found start new stateful proxy process.
            ACK = ersip_method:ack(),
            case ersip_sipmsg:method(SipMsg) of
                ACK ->
                    lager:info("ACK method does not match any transaction: process stateless", []),
                    process_stateless;
                _ ->
                    lager:info("Transaction is not found creating new proxy process", []),
                    {ok, _} = erproxy_stateful_sup:start_proxy({sipmsg, SipMsg}, {options, Options}),
                    ok
            end;
        {ok, Trans} ->
            %% If transaction is found then pass request to the
            %% transaction
            erproxy_trans:recv_request(SipMsg, Trans)
    end.

response(RecvVia, Message) ->
    case ersip_sipmsg:parse(Message, [cseq]) of
        {ok, SipMsg} ->
            case erproxy_trans:find_client_trans(RecvVia, SipMsg) of
                error ->
                    %% If transaction has not been found start new stateful proxy process.
                    lager:info("Transaction is not found for response", []),
                    not_found;
                {ok, Trans} ->
                    erproxy_trans:recv_response(SipMsg, Trans),
                    ok
            end;
        {error, _} = Error ->
            lager:warning("Cannot parse response: ~p", [Error]),
            Error
    end.

trans_result(no_ack, _Id, _Pid) ->
    %% just ignore...
    ok;
trans_result(timeout, Id, Pid) ->
    gen_server:cast(Pid, {trans_result, Id, timeout});
trans_result(cancel, _Id, Pid) ->
    try
        gen_server:call(Pid, cancel)
    catch
        exit:{noproc, _} ->
            {error, noproc}
    end;
trans_result(SipMsg, Id, Pid) ->
    lager:info("Transaction ~p result", [Id]),
    gen_server:cast(Pid, {trans_result, Id, SipMsg}).

start_link(Message, ProxyOptions) ->
    gen_server:start_link(?MODULE, [Message, ProxyOptions], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([{sipmsg, SipMsg}, {options, Options}]) ->
    lager:info("New stateful proxy process started", []),
    ProxyOptions = maps:get(proxy, Options, #{}),
    SIPOptions   = maps:get(sip, Options, #{}),
    {Stateful, SE} = ersip_proxy:new_stateful(SipMsg, ProxyOptions),
    State = #state{proxy = Stateful,
                   sip_options = SIPOptions},
    gen_server:cast(self(), {process_se, SE}),
    {ok, State}.

handle_call(cancel, _From, #state{proxy = Stateful0} = State) ->
    lager:info("Canceling request", []),
    {Stateful, SE} = ersip_proxy:cancel(Stateful0),
    case process_se(SE, State#state{proxy = Stateful}) of
        stop ->
            {stop, normal, ok, State};
        {continue, State1} ->
            {reply, ok, State1}
    end;
handle_call(Request, _From, State) ->
    lager:error("Unexpected call ~p", [Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({trans_result, Id, Result}, #state{proxy = Stateful0} = State) ->
    %% Pass message through the proxy
    lager:info("Proxy: Transaction ~p result", [Id]),
    {Stateful, SE} = ersip_proxy:trans_result(Id, Result, Stateful0),
    case process_se(SE, State#state{proxy = Stateful}) of
        stop ->
            {stop, normal, State};
        {continue, State1} ->
            {noreply, State1}
    end;
handle_cast({process_se, SE}, #state{} = State) ->
    case process_se(SE, State) of
        stop ->
            {stop, normal, State};
        {continue, State1} ->
            {noreply, State1}
    end;
handle_cast(Request, State) ->
    lager:error("Proxy: Unexpected cast ~p ~p", [Request, State]),
    {noreply, State}.

handle_info({'DOWN', _, process, Pid, _}, #state{trans = T, proxy = Stateful0} = State) ->
    case T of
        #{Pid := Id} ->
            {Stateful, SE} = ersip_proxy:trans_finished(Id, Stateful0),
            case process_se(SE, State#state{proxy = Stateful}) of
                stop ->
                    {stop, normal, State};
                {continue, State1} ->
                    {noreply, State1}
            end;
        _ ->
            {noreply, State}
    end;
handle_info({event, TimerEvent}, #state{proxy = Stateful} = State) ->
    {Stateful1, SE} = ersip_proxy:timer_fired(TimerEvent, Stateful),
    case process_se(SE, State#state{proxy = Stateful1}) of
        stop ->
            {stop, normal, State};
        {continue, State1} ->
            {noreply, State1}
    end;
handle_info(Info, State) ->
    lager:error("Proxy: Unexpected info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("Proxy: terminated with reason ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal implementation
%%%===================================================================

process_se([], State) ->
    {continue, State};
process_se([{create_trans, {Type, Id, OutReq}} | Rest], #state{trans = T, sip_options = SIPOptions} = State) ->
    TUMFA = {?MODULE, trans_result, [Id, self()]},
    {ok, Pid} =
        case Type of
            client ->
                erproxy_trans_sup:start_client_trans(TUMFA, {OutReq, SIPOptions});
            server ->
                erproxy_trans_sup:start_server_trans(TUMFA, {OutReq, SIPOptions})
        end,
    process_se(Rest, State#state{trans = T#{Id => Pid, Pid => Id}});
process_se([{response, {TransId, SipMsg}} | Rest], #state{trans = T} = State) ->
    #{TransId := Pid} = T,
    erproxy_trans:send_response(SipMsg, Pid),
    process_se(Rest, State);
process_se([{select_target, RURI} | Rest], #state{proxy = Stateful} = State) ->
    Targets = stateful_target(RURI),
    {Stateful1, SE} = ersip_proxy:forward_to(Targets, Stateful),
    State1 = State#state{proxy = Stateful1},
    process_se(Rest ++ SE, State1);
process_se([{set_timer, {Timeout, TimerEvent}} | Rest], #state{} = State) ->
    erlang:send_after(Timeout, self(), {event, TimerEvent}),
    process_se(Rest, State);
process_se([{stop, _}|_], #state{}) ->
    stop.

stateful_target(RURI) ->
    DomainType =
        case erproxy_domain:is_own(RURI) of
            true ->
                home;
            false ->
                foreign
        end,
    stateful_target(RURI, DomainType).

stateful_target(RURI, foreign) ->
    lager:info("Forward to foreign domain: ~s", [ersip_uri:assemble(RURI)]),
    [RURI];
stateful_target(RURI, home) ->
    AOR = ersip_uri:make_key(RURI),
    lager:info("Looking up for AOR: ~p", [AOR]),
    {ok, Bindings} = erproxy_locationdb:lookup(AOR),
    lager:info("Found bindings: ~p", [Bindings]),
    [begin
         Contact = ersip_registrar_binding:contact(Binding),
         ersip_hdr_contact:uri(Contact)
     end
     || Binding <- Bindings].
