%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Stateless proxy worker supervisor
%%

-module(erproxy_dispatcher).

-export([new_request/1,
         new_response/2]).

%%====================================================================
%% API functions
%%====================================================================

new_request(Message) ->
    process_request(Message).


new_response(RecvVia, Message) ->
    process_response(RecvVia, Message).


%%====================================================================
%% Implementation
%%====================================================================

process_request(Message) ->
    case processing_type(Message) of
        {registrar, RegistrarConfig} ->
            registrar_request(Message, RegistrarConfig);
        {stateless, Options} ->
            stateless_request(Message, Options);
        {stateful, Options} ->
            stateful_request(Message, Options);
        {stateful_cancel, Options} ->
            stateful_cancel_request(Message, Options)
    end.

process_response(RecvVia, Message) ->
    case erproxy_stateful:response(RecvVia, Message) of
        ok ->
            ok;
        {error, _} ->
            ok;
        not_found ->
            stateless_response(RecvVia, Message)
    end.

processing_type(Message) ->
    ProxyOptions = #{to_tag => {tag, ersip_id:token(crypto:strong_rand_bytes(7))},
                     record_route_uri => erproxy_listener:uri(),
                     check_rroute_fun => fun erproxy_domain:is_own/1
                    },
    REGISTER = ersip_method:register(),
    CANCEL   = ersip_method:cancel(),
    case ersip_msg:get(method, Message) of
        REGISTER ->
            RegistrarConfig = ersip_registrar:new_config(any, #{}),
            {registrar, RegistrarConfig};
        CANCEL ->
            {stateful_cancel, #{proxy => ProxyOptions}};
        _ ->
            {stateful, #{proxy => ProxyOptions}}
    end.

stateless_request(Message, Options) ->
    ProxyOptions = maps:get(proxy, Options, #{}),
    case ersip_proxy_common:request_validation(Message, Options) of
        {ok, SipMsg} ->
            SipMsg1 = ersip_proxy_common:process_route_info(SipMsg, Options),
            Target = stateless_target(SipMsg1),
            lager:info("Forward message to target: ~s", [ersip_uri:assemble(Target)]),
            {SipMsg2, #{nexthop := NexthopURI}} = ersip_proxy_common:forward_request(Target, SipMsg1, ProxyOptions),
            lager:info("Nexthop is: ~s", [ersip_uri:assemble(NexthopURI)]),
            OutReq = ersip_request:new_stateless_proxy(SipMsg2, Target),
            erproxy_conn:send_request(OutReq);
        {reply, SipMsg2} ->
            lager:info("Message reply ~p", [SipMsg2]),
            spawn_link(fun() ->
                               erproxy_conn:send_response(SipMsg2)
                       end);
        {error, Reason} ->
            lager:warning("Error occured during processing: ~p", [Reason])
    end.

stateless_response(RecvVia, Message) ->
    case ersip_proxy_stateless:process_response(RecvVia, Message) of
        {forward, SipMsg} ->
            erproxy_conn:send_response(SipMsg);
        {drop, Reason} ->
            lager:warning("Cannot forward message: ~p", [Reason])
    end.

stateless_target(SipMsg) ->
    ersip_sipmsg:ruri(SipMsg).


stateful_request(Message, Options) ->
    case ersip_proxy_common:request_validation(Message, Options) of
        {ok, SipMsg} ->
            case erproxy_stateful:request(SipMsg, Options) of
                ok ->
                    ok;
                process_stateless ->
                    stateless_request(Message, Options)
            end;
        {reply, SipMsg2} ->
            lager:info("Message reply ~p", [SipMsg2]),
            spawn_link(fun() ->
                               erproxy_conn:send_response(SipMsg2)
                       end);
        {error, Reason} ->
            lager:warning("Error occured during processing: ~p", [Reason])
    end.

stateful_cancel_request(Message, Options) ->
    case erproxy_cancel_uas:process_cancel(Message) of
        ok ->
            ok;
        process_stateless ->
            stateless_request(Message, Options)
    end.

registrar_request(Message, RegistrarConfig) ->
    erproxy_registrar:process_register(Message, RegistrarConfig).



