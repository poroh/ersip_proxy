%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% SIP Cancel UAS
%%

-module(erproxy_cancel_uas).

-export([process_cancel/1,
         trans_result/2
        ]).

%%====================================================================
%% API
%%====================================================================

process_cancel(Message) ->
    case ersip_uas:process_request(Message, allowed_methods(), #{}) of
        {reply, SipMsg} ->
            lager:info("Message reply ~p", [SipMsg]),
            spawn_link(fun() ->
                               erproxy_conn:send_response(SipMsg)
                       end),
            ok;
        {process, SipMsg} ->
            case erproxy_trans:find_server_trans(SipMsg) of
                error ->
                    %% If transaction has not been found:
                    %% 1. find matching transaction for request from cancel:
                    case erproxy_trans:find_server_cancel_trans(SipMsg) of
                        {ok, Trans} ->
                            %% If matched then start cancel transaction
                            start_server_trans(SipMsg, Trans),
                            ok;
                        error ->
                            %% If not matched then just act as stateless proxy in according to:
                            %%
                            %% If a response context is not found, the element does not have any
                            %% knowledge of the request to apply the CANCEL to.  It MUST statelessly
                            %% forward the CANCEL request (it may have statelessly forwarded the
                            %% associated request previously).
                            lager:info("Transaction is not found passing cancel as stateless proxy", []),
                            process_stateless
                    end;
                {ok, Trans} ->
                    %% If transaction is found then pass request to the
                    %% transaction
                    erproxy_trans:recv_request(SipMsg, Trans)
            end;
        {error, Error} ->
            lager:warning("Error occurred during CANCEL processing: ~p", [Error])
    end.

trans_result(SipMsg, Pid) ->
    Self = self(),
    proc_lib:spawn_link(fun() ->
                                case erproxy_trans:cancel_request(Pid) of
                                    {error, no_request} ->
                                        ReplySipMsg = ersip_sipmsg:reply(481, SipMsg),
                                        erproxy_trans:send_response(ReplySipMsg, Self);
                                    ok ->
                                        %% If a matching response context is found, the element MUST
                                        %% immediately return a 200 (OK) response to the CANCEL request.
                                        ReplySipMsg = ersip_sipmsg:reply(200, SipMsg),
                                        erproxy_trans:send_response(ReplySipMsg, Self)
                                end
                        end).

%%%===================================================================
%%% Helpers
%%%===================================================================

allowed_methods() ->
    ersip_method_set:new([ersip_method:cancel()]).

start_server_trans(SipMsg, TransToCancel) ->
    TUMFA = {?MODULE, trans_result, [TransToCancel]},
    %% Creating server transaction:
    {ok, _Pid} = erproxy_trans_sup:start_server_trans(TUMFA, {SipMsg, #{}}).
