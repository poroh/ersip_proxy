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
         server_trans_result/3,
         client_trans_result/2,
         start_link/2
        ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


%%%===================================================================
%%% Types
%%%===================================================================

-record(state, {server        :: pid(),       %% Server transaction
                server_ref    :: reference(), %% Server transaction monitor reference
                client        :: pid(),       %% Client transaction
                client_ref    :: reference(), %% Client transaction monitor reference
                sipmsg        :: ersip_sipmsg:sipmsg()
               }).

%%%===================================================================
%%% API
%%%===================================================================

request(SipMsg, ProxyOptions) ->
    %% First looking if SipMsg match any transaction
    case erproxy_trans:find_server_trans(SipMsg) of
        error ->
            %% If transaction has not been found start new stateful proxy process.
            lager:info("Transaction is not found creating new proxy process", []),
            erproxy_stateful_sup:start_proxy({sipmsg, SipMsg}, {options, ProxyOptions});

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

server_trans_result(no_ack, _, Pid) ->
    gen_server:cast(Pid, server_no_ack);
server_trans_result(SipMsg, ProxyOptions, Pid) ->
    gen_server:cast(Pid, {request, SipMsg, ProxyOptions}).

client_trans_result(timeout, Pid) ->
    lager:info("Client transaction timeout", []),
    gen_server:cast(Pid, client_timeout);
client_trans_result(SipMsg, Pid) ->
    lager:info("Client transaction result", []),
    gen_server:cast(Pid, {response, SipMsg}).

start_link(Message, ProxyOptions) ->
    gen_server:start_link(?MODULE, [Message, ProxyOptions], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([{sipmsg, SipMsg}, {options, ProxyOptions}]) ->
    lager:info("new stateful proxy process started", []),
    gen_server:cast(self(), {start, SipMsg, ProxyOptions}),
    {ok, #state{sipmsg = SipMsg}}.

handle_call(Request, _From, State) ->
    lager:error("Unexpected call ~p", [Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({start, SipMsg, ProxyOptions}, State) ->
    ACK = ersip_method:ack(),
    case ersip_sipmsg:method(SipMsg) of
        ACK ->
            %% There is no client transaction for ACK.  If the TU
            %% wishes to send an ACK, it passes one directly to the
            %% transport layer for transmission.
            OutReq = pass_message(SipMsg, ProxyOptions),
            erproxy_conn:send_request(OutReq),
            {stop, normal, SipMsg};
        _ ->
            State1 = start_server_trans(SipMsg, ProxyOptions, State),
            {noreply, State1}
    end;
handle_cast({request, SipMsg, ProxyOptions}, State) ->
    %% Pass message through the proxy
    OutReq = pass_message(SipMsg, ProxyOptions),
    State1 = start_client_trans(OutReq, ProxyOptions, State),
    {noreply, State1};
handle_cast({response, SipMsg}, #state{server = Pid} = State) ->
    lager:info("Sending response to the request intiator", []),
    erproxy_trans:send_response(SipMsg, Pid),
    {noreply, State};
handle_cast(server_no_ack, #state{} = State) ->
    lager:info("No ACK received by server transaction", []),
    {stop, State};
handle_cast(client_timeout, #state{server = Pid, sipmsg = Req} = State) ->
    lager:info("Sending response to the request intiator", []),
    %%   In some cases, the response returned by the transaction layer will
    %% not be a SIP message, but rather a transaction layer error.  When a
    %% timeout error is received from the transaction layer, it MUST be
    %% treated as if a 408 (Request Timeout) status code has been received.
    SipMsg = ersip_sipmsg:reply(408, Req),
    erproxy_trans:send_response(SipMsg, Pid),
    {noreply, State};
handle_cast(Request, State) ->
    lager:error("Unexpected cast ~p", [Request]),
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, _}, #state{server_ref = Ref} = State) ->
    {noreply, State};
handle_info({'DOWN', Ref, process, _, _}, #state{client_ref = Ref} = State) ->
    {stop, normal, State};
handle_info(Info, State) ->
    lager:error("Unexpected info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("Proxy: terminated with reason ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal implementation
%%%===================================================================

start_server_trans(SipMsg, ProxyOptions, #state{} = State) ->
    TUMFA = {?MODULE, server_trans_result, [ProxyOptions, self()]},
    %% Creating server transaction:
    {ok, Pid} = erproxy_trans_sup:start_server_trans(TUMFA, {SipMsg, ProxyOptions}),
    Ref = erlang:monitor(process, Pid),
    State#state{server = Pid, server_ref = Ref}.

start_client_trans(OutReq, ProxyOptions, State) ->
    TUMFA = {?MODULE, client_trans_result, [self()]},
    %% Creating server transaction:
    {ok, Pid} = erproxy_trans_sup:start_client_trans(TUMFA, {OutReq, ProxyOptions}),
    Ref = erlang:monitor(process, Pid),
    State#state{client = Pid, client_ref = Ref}.

pass_message(SipMsg, ProxyOptions) ->
    %% Pass message through the proxy
    SipMsg1 = ersip_proxy_common:process_route_info(SipMsg, ProxyOptions),
    Target = stateful_target(SipMsg1),
    lager:info("Forward message to target: ~s", [ersip_uri:assemble(Target)]),
    {SipMsg2, #{nexthop := NexthopURI}} = ersip_proxy_common:forward_request(Target, SipMsg1, ProxyOptions),
    lager:info("Nexthop is: ~s", [ersip_uri:assemble(NexthopURI)]),
    Branch = erproxy_branch:generate(),
    ersip_request:new(SipMsg2, Branch, NexthopURI).

stateful_target(SipMsg) ->
    URI = ersip_sipmsg:ruri(SipMsg),
    AOR = ersip_uri:make_key(URI),
    lager:info("Looking up for AOR: ~p", [AOR]),
    case erproxy_locationdb:lookup(AOR) of
        {ok, [Binding1|_]} ->
            lager:info("Found binding: ~p", [Binding1]),
            Contact = ersip_registrar_binding:contact(Binding1),
            ersip_hdr_contact:uri(Contact);
        {ok, []} ->
            lager:info("Binding not found", []),
            URI
    end.
