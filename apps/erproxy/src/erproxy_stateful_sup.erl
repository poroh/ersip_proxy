%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Stateful proxy supervisor
%%

-module(erproxy_stateful_sup).

-behaviour(supervisor).

-export([start_link/0,
         start_proxy/2,
         init/1
        ]).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_proxy(SipMsg, ProxyOptions) ->
    {ok, _Pid} = supervisor:start_child(?MODULE, [SipMsg, ProxyOptions]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    SupFlags = #{strategy  => simple_one_for_one,
                 intensity => 1000,
                 period    => 1
                },
    ChildSpecs = [#{id      => erproxy_stateful,
                    start   => {erproxy_stateful, start_link, []},
                    restart => temporary
                   }
                 ],
    {ok, {SupFlags, ChildSpecs}}.
