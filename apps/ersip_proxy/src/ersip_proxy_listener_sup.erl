%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Stateless proxy worker supervisor
%%

-module(ersip_proxy_listener_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 5,
        period    => 10
    },
    Listeners  = application:get_env(ersip_proxy, listeners, []),
    ChildSpecs = [
        #{
            id    => Id,
            start => { ersip_proxy_listener, start_link, [ Config ] },
            type  => supervisor
        }
        || { Id, Config } <- Listeners
    ],
    { ok, { SupFlags, ChildSpecs } }.

%%====================================================================
%% Internal functions
%%====================================================================
