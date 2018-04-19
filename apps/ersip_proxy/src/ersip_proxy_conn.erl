%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% One listener of SIP proxy
%%

-module(ersip_proxy_conn).

-export([send/2,
         conn_init/1,
         conn_parse/3,
         conn_encode/3,
         conn_handle_call/4
        ]).


%%%===================================================================
%%% API
%%%===================================================================


send(NextURI, SipMsg) ->
    [{host, Host}, {port, Port}] = ersip_uri:get([host, port], NextURI),
    HostBin = iolist_to_binary(ersip_host:assemble(Host)),
    PortBin = integer_to_binary(Port),
    TransportBin =
        case ersip_uri:params(NextURI) of
            #{ transport := Transport } ->
                ersip_transport:to_binary(Transport);
            _ ->
                <<"udp">>
        end,
    URI = <<"<ersip:", HostBin/binary, ":", PortBin/binary, ";transport=", TransportBin/binary, ">">>,
    {ok, _Pid} =
        nkpacket:send(URI,
                      SipMsg,
                      #{udp_to_tcp => false,
                        class => ersip
                       }).

%%%===================================================================
%%% nkpacket_protocol callbaks
%%%===================================================================

conn_init(NkPort) ->
    {ok, {?MODULE, Transport, LocalIP, LocalPort}} = nkpacket:get_local(NkPort),
    {ok, {?MODULE, Transport, RemoteIP, RemotePort}} = nkpacket:get_remote(NkPort),
    SIPTransport = ersip_transport:make(Transport),
    SIPConn = ersip_conn:new(LocalIP, LocalPort, RemoteIP, RemotePort, SIPTransport, #{source_id => NkPort}),
    lager:info("New connection is established with remote ~s:~p via ~p",
               [inet:ntoa(RemoteIP), RemotePort,
                Transport
               ]),
    { ok, SIPConn }.

conn_parse(Data, _NkPort, SIPConn) ->
    { NextSIPConn, SE } = ersip_conn:conn_data(Data, SIPConn),
    lists:foreach(fun process_side_effect/1, SE),
    case need_disconnect(SE) of
        true ->
            {stop, normal, NextSIPConn};
        false ->
            {ok, NextSIPConn}
    end.

conn_encode(SipMsg, _NkPort, SIPConn) ->
    SIPConn1 = SIPConn,
    Branch = ersip_proxy_stateless:branch(SipMsg),
    RawMsg  = ersip_sipmsg:raw_message(SipMsg),
    RawMsg1 = ersip_conn:add_via(RawMsg, Branch, SIPConn),
    BinMSG = ersip_msg:serialize_bin(RawMsg1),
    lager:info("Sending message: ~n~s~n", [BinMSG]),
    {ok, BinMSG, SIPConn1}.

conn_handle_call(Request, _From, _NkPort, SIPConn) ->
    lager:error("Unexpected request: ~p", [ Request ]),
    {ok, SIPConn}.

process_side_effect({ bad_message, Data, Reason }) ->
    lager:warning("Bad message received: ~p: ~p", [Reason, Data]);
process_side_effect({ new_message, RawMsg }) ->
    lager:info("New message received: ~n~s~n", [ersip_msg:serialize(RawMsg)]),
    ersip_proxy_dispatcher:new_message(RawMsg);
process_side_effect({ disconnect, Error }) ->
    lager:info("Connection disconnect required: ~p", [Error]).

need_disconnect(SideEffects) ->
    lists:any(fun({disconnect, _}) ->
                      true;
                 (_) ->
                      false
              end,
              SideEffects).
