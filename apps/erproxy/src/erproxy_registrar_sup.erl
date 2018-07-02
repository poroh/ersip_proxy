%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Registrar processes supervisor
%%

-module(erproxy_registrar_sup).

-behaviour(supervisor).

-export([start_link/0,
         start_process/2,
         init/1
        ]).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_process(SipMsg, Config) ->
    {ok, _Pid} = supervisor:start_child(?MODULE, [SipMsg, Config]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    SupFlags = #{strategy  => simple_one_for_one,
                 intensity => 1000,
                 period    => 1
                },
    ChildSpecs = [#{id      => erproxy_registrar,
                    start   => {erproxy_registrar, start_link, []},
                    restart => temporary
                   }
                 ],
    {ok, {SupFlags, ChildSpecs}}.
