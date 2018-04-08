%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% One listener of SIP proxy
%%

-module(ersip_proxy_listener).

-behaviour(gen_server).

-export([ start_link/1 ]).

-export([ init/1,
          handle_call/3,
          handle_cast/2,
          handle_info/2,
          code_change/3,
          terminate/2
        ]).

-export([ listen_init/1 ]).

%%====================================================================
%% Types
%%====================================================================

-record(state, { listen_id,
                 config }).

%%====================================================================
%% API functions
%%====================================================================

start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Config) ->
    ok = nkpacket:register_protocol(ersip, ersip_proxy_conn),
    Address   = maps:get(address,   Config, "0.0.0.0"),
    Port      = maps:get(port,      Config, 5060),
    Transport = maps:get(transport, Config, udp),

    PortStr = integer_to_list(Port),
    TransportStr = atom_to_list(Transport),

    URI = "<ersip://" ++ Address ++ ":" ++ PortStr ++ ";transport=" ++ TransportStr ++ ">",
    lager:info("SIP protocol listener will be initailized at ~s:~s", [ Address, PortStr ]),
    { ok, ListenId } =
        nkpacket:start_listener(
          URI,
          #{ user  => self(),
             class => ersip,
             ws_proto => <<"sip">>
           }),
    State = #state{ listen_id = ListenId,
                    config = Config },
    { ok, State }.

handle_call(Request, _, State) ->
    lagger:error("Unexpected call: ~p", [ Request ]),
    { reply, ok, State }.

handle_cast(Request, State) ->
    lagger:error("Unexpected cast: ~p", [ Request ]),
    { noreply, State }.

handle_info(Request, State) ->
    lagger:error("Unexpected info: ~p", [ Request ]),
    { noreply, State }.

code_change(_, _, State) ->
    { noreply, State }.

terminate(_, _State) ->
    ok.


%%====================================================================
%% nkpacket callbacks
%%====================================================================

listen_init(NkPort) ->
    { ok, _Class, Pid } = nkpacket:get_user(NkPort),
    { ok, Pid }.
