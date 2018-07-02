%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% SIP Transaction
%%

-module(erproxy_registrar).

-behaviour(gen_server).

-export([process_register/2,
         start_link/2,
         trans_result/2
        ]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


%%====================================================================
%% Types
%%====================================================================

-record(state, {trans :: pid(),
                trans_ref :: reference(),
                sipmsg   :: ersip_sipmsg:sipmsg(),
                config   :: ersip_registrar:config(),
                request  :: undefined | ersip_registrar:request()}).

%%%===================================================================
%%% API
%%%===================================================================

process_register(Message, RegistrarConfig) ->
    case ersip_uas:process_request(Message, allowed_methods(), #{}) of
        {reply, SipMsg} ->
            lager:info("Message reply ~p", [SipMsg]),
            spawn_link(fun() ->
                               erproxy_conn:send_response(SipMsg)
                       end);
        {process, SipMsg} ->
            case erproxy_trans:find_server_trans(SipMsg) of
                error ->
                    %% If transaction has not been found start new stateful proxy process.
                    lager:info("Transaction is not found creating new registrar request process", []),
                    erproxy_registrar_sup:start_process({sipmsg, SipMsg}, {regconfig, RegistrarConfig});
                {ok, Trans} ->
                    %% If transaction is found then pass request to the
                    %% transaction
                    erproxy_trans:recv_request(SipMsg, Trans)
            end;
        {error, Error} ->
            lager:warning("Error occurred during REGISTER processing: ~p", [Error])
    end.

trans_result(SipMsg, Pid) ->
    gen_server:cast(Pid, {request, SipMsg}).

start_link({sipmsg, _} = SipMsg, {regconfig, _} = RegistrarConfig) ->
    gen_server:start_link(?MODULE, [SipMsg, RegistrarConfig], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([{sipmsg, SipMsg}, {regconfig, RegistrarConfig}]) ->
    lager:info("register process started", []),
    gen_server:cast(self(), start),
    {ok, #state{config = RegistrarConfig, sipmsg = SipMsg}}.

handle_call(Request, _From, State) ->
    lager:error("Unexpected call ~p", [Request]),
    Reply = ok,
    {reply, Reply, State}.
handle_cast(start, #state{sipmsg = SipMsg} = State) ->
    State1 = start_server_trans(SipMsg, State),
    {noreply, State1};
handle_cast({request, SipMsg}, #state{config = RegistrarConfig} = State) ->
    {Request, SE} = ersip_registrar:new_request(SipMsg, RegistrarConfig),
    gen_server:cast(self(), SE),
    {noreply, State#state{request = Request}};
handle_cast({find_bindings, AOR}, #state{request = Request0} = State) ->
    lager:info("Looking up for AOR ~s bindings", [ersip_uri:assemble(AOR)]),
    {Request1, SE} = ersip_registrar:lookup_result(erproxy_locationdb:lookup(AOR), Request0),
    gen_server:cast(self(), SE),
    {noreply, State#state{request = Request1}};
handle_cast({update_bindings, AOR, UpdateDescr}, #state{request = Request0} = State) ->
    lager:info("Updating AOR ~s bindings", [ersip_uri:assemble(AOR)]),
    {Request1, SE} = ersip_registrar:update_result(erproxy_locationdb:update(AOR, UpdateDescr), Request0),
    gen_server:cast(self(), SE),
    {noreply, State#state{request = Request1}};
handle_cast({proxy, RURI}, #state{sipmsg = SipMsg, trans = Pid} = State) ->
    lager:error("Proxy to ~p: not supported yet", [RURI]),
    ReplySipMsg = ersip_sipmsg:reply(500, SipMsg),
    erproxy_trans:send_response(ReplySipMsg, Pid),
    {stop, normal, State};
handle_cast({reply, ReplySipMsg}, #state{trans = Pid} = State) ->
    erproxy_trans:send_response(ReplySipMsg, Pid),
    {stop, normal, State};


handle_cast(Request, State) ->
    lager:error("Unexpected cast ~p", [Request]),
    {noreply, State}.

handle_info(Info, State) ->
    lager:error("Unexpected info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("Terminated with reason ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Helpers
%%%===================================================================

allowed_methods() ->
    ersip_method_set:new([ersip_method:register()]).

start_server_trans(SipMsg, #state{} = State) ->
    TUMFA = {?MODULE, trans_result, [self()]},
    %% Creating server transaction:
    {ok, Pid} = erproxy_trans_sup:start_server_trans(TUMFA, {SipMsg, #{}}),
    Ref = erlang:monitor(process, Pid),
    State#state{trans = Pid, trans_ref = Ref}.
