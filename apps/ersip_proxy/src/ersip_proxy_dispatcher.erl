%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Stateless proxy worker supervisor
%%

-module(ersip_proxy_dispatcher).

-export([new_message/1]).


%%====================================================================
%% API functions
%%====================================================================

new_message(Message) ->
    case ersip_msg:get(type, Message) of
        request ->
            process_request(Message);
        response ->
            process_response(Message)
    end.


%%====================================================================
%% Implementation
%%====================================================================

process_request(Message) ->
    case processing_type(Message) of
        {stateless, ProxyOptions} ->
            processing_stateless(Message, ProxyOptions)
    end.

process_response(_Message) ->
    ok.

processing_type(_Message) ->
    {stateless, #{}}.

processing_stateless(Message, ProxyOptions) ->
    case ersip_proxy_common:request_validation(Message, ProxyOptions) of
        {ok, SipMsg} ->
            SipMsg1 = ersip_proxy_common:process_route_info(SipMsg, ProxyOptions),
            Target = stateless_target(SipMsg1),
            lager:info("Forward message to target: ~s", [ersip_uri:assemble(Target)]),
            {SipMsg2, #{nexthop := NexthopURI}} = ersip_proxy_common:forward_request(Target, SipMsg1, ProxyOptions),
            ersip_proxy_conn:send(NexthopURI, SipMsg2);
        {reply, SipMsg} ->
            lager:info("Message reply ~p", [SipMsg]);
        {error, Reason} ->
            lager:warning("Error occured during processing: ~p", [Reason])
    end.

stateless_target(_SipMsg) ->
    ersip_uri:make(<<"sip:192.168.100.11:5060">>).
