%%%-------------------------------------------------------------------
%% @doc ersip_proxy top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(ersip_proxy_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 0,
        period    => 1
    },
    Supervisors = [
        ersip_proxy_listener_sup,
        ersip_proxy_stateless_sup
    ],
    ChildSpecs = [
        #{
            id    => Module,
            start => { Module, start_link, [] },
            type  => supervisor
        }
        || Module <- Supervisors
    ],
    { ok, { SupFlags, ChildSpecs } }.

%%====================================================================
%% Internal functions
%%====================================================================
