%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% One listener of SIP proxy
%%

-module(erproxy_listener).

-behaviour(gen_server).

-export([start_link/1,
         uri/0
        ]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2
        ]).

-export([listen_init/1]).

%%====================================================================
%% Types
%%====================================================================

-record(state, {listen_id,
                config,
                uri
               }).

%%====================================================================
%% API functions
%%====================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

uri() ->
    gen_server:call(?MODULE, get_uri).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Config) ->
    ok = nkpacket:register_protocol(ersip, erproxy_conn),
    Address   = maps:get(address,   Config, inet:ntoa(first_ipv4())),
    Port      = maps:get(port,      Config, 5060),
    Transport = maps:get(transport, Config, udp),

    PortStr = integer_to_list(Port),
    TransportStr = atom_to_list(Transport),

    URI = "<ersip://" ++ Address ++ ":" ++ PortStr ++ ";transport=" ++ TransportStr ++ ">",
    lager:info("SIP protocol listener will be initailized at ~s:~s", [Address, PortStr]),
    {ok, ListenId} =
        nkpacket:start_listener(
          URI,
          #{user  => self(),
            class => ersip,
            ws_proto => <<"sip">>
           }),
    URI0 = ersip_uri:make([{host, ersip_host:make(list_to_binary(Address))}, {port, Port}]),
    URI1 = ersip_uri:set_param(transport, ersip_transport:make(Transport), URI0),
    State = #state{listen_id = ListenId,
                   config = Config,
                   uri    = URI1
                  },
    {ok, State}.

handle_call(get_uri, _, #state{uri = URI} = State) ->
    {reply, URI, State};
handle_call(Request, _, State) ->
    lagger:error("Unexpected call: ~p", [Request]),
    {reply, ok, State}.

handle_cast(Request, State) ->
    lagger:error("Unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info(Request, State) ->
    lagger:error("Unexpected info: ~p", [Request]),
    {noreply, State}.

code_change(_, _, State) ->
    {noreply, State}.

terminate(_, _State) ->
    ok.


%%====================================================================
%% nkpacket callbacks
%%====================================================================

listen_init(NkPort) ->
    {ok, _Class, Pid} = nkpacket:get_user(NkPort),
    {ok, Pid}.


first_ipv4() ->
    NonLoopbackAndUp
        = lists:append(
            [proplists:get_all_values(addr, Attrs)
             || {ok, List} <- [inet:getifaddrs()],
                {_Name, Attrs} <- List,
                lists:member(up, proplists:get_value(flags, Attrs)),
                not lists:member(loopback, proplists:get_value(flags, Attrs))
            ]),
    IpV4 = [Addr || {_, _, _, _} = Addr <- NonLoopbackAndUp],
    hd(IpV4).
