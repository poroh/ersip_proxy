
-module(erproxy_branch).

-export([start_link/0,
         generate/0
        ]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%====================================================================
%% Types
%%====================================================================
-define(MAX_CACHE_SIZE, 10000).

-record(state, {lru = erl_lru:new(?MAX_CACHE_SIZE)}).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

generate() ->
    gen_server:call(?MODULE, generate).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #state{}}.

handle_call(generate, From, #state{lru = LRU} = State) ->
    Branch = ersip_branch:make_random(7),
    case erl_lru:has_key(Branch, LRU) of
        true ->
            handle_call(generate, From, State);
        false ->
            {reply, Branch, State#state{lru = erl_lru:push(Branch, any, LRU)}}
    end;
handle_call(Request, _From, State) ->
    lager:error("Unexpected call ~p", [Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(Request, State) ->
    lager:error("Unexpected cast ~p", [Request]),
    {noreply, State}.

handle_info(Info, State) ->
    lager:error("Unexpected info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("Terminated with reason ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
