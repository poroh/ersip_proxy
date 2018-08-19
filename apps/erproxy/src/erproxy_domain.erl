%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Stateless proxy worker supervisor
%%

-module(erproxy_domain).

-export([is_own/1]).

%%%===================================================================
%%% API
%%%===================================================================

is_own(CheckURI) ->
    MyURI  = erproxy_listener:uri(),
    uri_transport_equal(CheckURI, MyURI).

%%%===================================================================
%%% Internal Implementation
%%%===================================================================

uri_transport_equal(URI1, URI2) ->
    uri_transport(URI1) == uri_transport(URI2).

uri_transport(URI) ->
    {host, Host} = ersip_uri:get(host, URI),
    {port, Port} = ersip_uri:get(port, URI),
    Transport =
        case ersip_uri:params(URI) of
            #{transport := T} ->
                T;
            _ ->
                ersip_transport:make(udp)
        end,
    {ersip_host:make_key(Host), Port, Transport}.
