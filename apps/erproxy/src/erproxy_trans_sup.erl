%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Transactions supervisor
%%

-module(erproxy_trans_sup).

-behaviour(supervisor).

-export([start_link/0,
         start_server_trans/2,
         start_client_trans/2,
         init/1
        ]).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_server_trans(TUCallback, Args) ->
    {ok, _Pid} = supervisor:start_child(?MODULE, [server, TUCallback, Args]).

start_client_trans(TUCallback, Args) ->
    {ok, _Pid} = supervisor:start_child(?MODULE, [client, TUCallback, Args]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    SupFlags = #{
        strategy  => simple_one_for_one,
        intensity => 1000,
        period    => 1
    },
    ChildSpecs = [
        #{
            id      => erproxy_trans,
            start   => {erproxy_trans, start_link, []},
            restart => temporary
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
