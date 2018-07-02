%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Location database
%%

-module(erproxy_locationdb).

-export([lookup/1,
         update/2]).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%====================================================================
%% Types
%%====================================================================

-record(state, {mappings = #{} :: #{ersip_uri:uri() => bindings()}}).
-type bindings() :: #{ersip_uri:uri() => ersip_registrar_binding:binding()}.

%%====================================================================
%% API functions
%%====================================================================

lookup(AOR) ->
    gen_server:call(?MODULE, {lookup, AOR}).

update(AOR, {_Added, _Updated, _Removed} = UpdateDescr) ->
    gen_server:call(?MODULE, {update, AOR, UpdateDescr}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #state{}}.

handle_call({lookup, AOR}, _From, #state{mappings = Mappings} = State) ->
    case Mappings of
        #{AOR := BindingsMap} ->
            {_, Bindings} = lists:unzip(maps:to_list(BindingsMap)),
            {reply, {ok, Bindings}, State};
        _ ->
            {reply, {ok, []}, State}
    end;
handle_call({update, AOR, {Added, Updated, Removed}}, _From, #state{mappings = Mappings} = State) ->
    CurrentBindings0 =
        case Mappings of
            #{AOR := Bindings} ->
                Bindings;
            _ ->
               #{}
        end,
    CurrentBindings1 =
        lists:foldl(fun(AddedBinding, Acc) ->
                            Key = ersip_registrar_binding:contact_key(AddedBinding),
                            Acc#{Key => AddedBinding}
                    end,
                    CurrentBindings0,
                    Added),
    RemovedKeys = lists:map(fun ersip_registrar_binding:contact_key/1, Removed),
    CurrentBindings2 = maps:without(RemovedKeys, CurrentBindings1),
    CurrentBindings3 =
        lists:foldl(fun(UpdatedBinding, Acc) ->
                            Key = ersip_registrar_binding:contact_key(UpdatedBinding),
                            Acc#{Key => UpdatedBinding}
                    end,
                    CurrentBindings2,
                    Updated),

    case maps:size(CurrentBindings3) of
        0 ->
            {reply, ok, State#state{mappings = maps:without([AOR], Mappings)}};
        _ ->
            {reply, ok, State#state{mappings = Mappings#{AOR => CurrentBindings3}}}
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

%%====================================================================
%% internal implementation
%%====================================================================


