%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% One listener of SIP proxy
%%

-module(erproxy_conn).

-export([send_request/2,
         send_response/3,
         conn_init/1,
         conn_parse/3,
         conn_encode/3,
         conn_handle_call/4
        ]).


%%%===================================================================
%%% API
%%%===================================================================


send_request(NextURI, OutReq) ->
    [{host, Host}, {port, Port}] = ersip_uri:get([host, port], NextURI),
    HostBin = iolist_to_binary(ersip_host:assemble(Host)),
    PortBin =
        case Port of
            undefined ->
                integer_to_binary(5060);
            _ ->
                integer_to_binary(Port)
        end,
    TransportBin =
        case ersip_uri:params(NextURI) of
            #{transport := Transport} ->
                ersip_transport:assemble(Transport);
            _ ->
                <<"udp">>
        end,
    URI = <<"<ersip:", HostBin/binary, ":", PortBin/binary, ";transport=", TransportBin/binary, ">">>,
    {ok, _Pid} =
        nkpacket:send(URI,
                      {request, OutReq},
                      #{udp_to_tcp => false,
                        udp_max_size => 9000,
                        class => ersip
                       }).

send_response(TargetVia, _RecvVia, SipMsg) ->
    Target =
        case ersip_response:target(TargetVia) of
            {reuse, FallbackTarget} ->
                lager:warning("Connection reuse now is not supported yet"),
                FallbackTarget;
            {direct, DirectTarget} ->
                DirectTarget
        end,
    lager:info("Sending response to ~p", [Target]),
    {Host, Port, Transport, _Opts} = Target,
    HostBin = iolist_to_binary(ersip_host:assemble(Host)),
    PortBin = integer_to_binary(Port),
    TransportBin = ersip_transport:assemble(Transport),
    URI = <<"<ersip:", HostBin/binary, ":", PortBin/binary, ";transport=", TransportBin/binary, ">">>,
    {ok, _Pid} =
        nkpacket:send(URI,
                      {response, SipMsg},
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
    {ok, SIPConn}.

conn_parse(Data, _NkPort, SIPConn) ->
    {NextSIPConn, SEList} = ersip_conn:conn_data(Data, SIPConn),
    lists:foreach(fun process_side_effect/1, SEList),
    case need_disconnect(SEList) of
        true ->
            {stop, normal, NextSIPConn};
        false ->
            {ok, NextSIPConn}
    end.

conn_encode({request, OutReq}, _NkPort, SIPConn) ->
    IOMsg = ersip_request:send_via_conn(OutReq, SIPConn),
    BinMSG = iolist_to_binary(IOMsg),
    lager:info("Sending request: ~n~s~n", [BinMSG]),
    {ok, BinMSG, SIPConn};
conn_encode({response, SipMsg}, _NkPort, SIPConn) ->
    RawMsg  = ersip_sipmsg:raw_message(SipMsg),
    BinMSG = ersip_msg:serialize_bin(RawMsg),
    lager:info("Sending response: ~n~s~n", [BinMSG]),
    {ok, BinMSG, SIPConn}.

conn_handle_call(Request, _From, _NkPort, SIPConn) ->
    lager:error("Unexpected request: ~p", [Request]),
    {ok, SIPConn}.

process_side_effect({bad_message, Data, Reason}) ->
    lager:warning("Bad message received: ~p: ~p", [Reason, Data]);
process_side_effect({new_request, RawMsg}) ->
    lager:info("New request received: ~n~s~n", [ersip_msg:serialize(RawMsg)]),
    erproxy_dispatcher:new_request(RawMsg);
process_side_effect({new_response, Via, RawMsg}) ->
    lager:info("New response received: ~n~s~n", [ersip_msg:serialize(RawMsg)]),
    erproxy_dispatcher:new_response(Via, RawMsg);
process_side_effect({disconnect, Error}) ->
    lager:info("Connection disconnect required: ~p", [Error]).

need_disconnect(SideEffects) ->
    lists:any(fun({disconnect, _}) ->
                      true;
                 (_) ->
                      false
              end,
              SideEffects).
