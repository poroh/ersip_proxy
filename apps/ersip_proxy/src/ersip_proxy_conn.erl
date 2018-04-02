%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% One listener of SIP proxy
%%

-module(ersip_proxy_conn).

-export([ conn_init/1,
          conn_parse/3
        ]).


%%%===================================================================
%%% nkpacket_protocol callbaks
%%%===================================================================

conn_init(NkPort) ->
    { ok, { ?MODULE, Transport, LocalIP, LocalPort } } = nkpacket:get_local(NkPort),
    { ok, { ?MODULE, Transport, RemoteIP, RemotePort } } = nkpacket:get_remote(NkPort),
    SIPTransport = ersip_transport:make(Transport),
    SIPConn = ersip_conn:new(LocalIP, LocalPort, RemoteIP, RemotePort, SIPTransport, #{ source_id => NkPort }), 
    lager:info("New connection is established from ~s:~p via ~p", 
               [ inet:ntoa(RemoteIP), RemotePort,
                 Transport 
               ]),
    { ok, SIPConn }.

conn_parse(Data, _NkPort, SIPConn) ->
    { NextSIPConn, SE } = ersip_conn:conn_data(Data, SIPConn),
    lists:foreach(fun process_side_effect/1, SE),
    case need_disconnect(SE) of
        true ->
            { stop, normal, NextSIPConn };
        false ->
            { ok, NextSIPConn }
    end.

process_side_effect({ bad_message, Data, Reason }) ->
    lager:warning("Bad message received: ~p: ~p", [ Reason, Data ]);
process_side_effect({ new_message, RawMsg }) ->
    ersip_proxy_dispatcher:new_message(RawMsg);
process_side_effect({ disconnect, Error }) ->
    lager:info("Connection disconnect required: ~p", [ Error ]).

need_disconnect(SideEffects) ->
    lists:any(fun({ disconnect, _ }) ->
                      true;
                 (_) ->
                      false
              end,
              SideEffects).
