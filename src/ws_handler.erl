-module(ws_handler).

-export([init/2]).
-export([websocket_handle/3]).
-export([websocket_info/3]).

-record(state, {
          user_id,
          user_data,
          exchanges = [],
          queues = []
}).

init(Req, _Opts) ->
    {cowboy_websocket, Req, #state{exchanges=dict:new(), queues=dict:new()}}.

websocket_handle({text, Data}, Req, State) ->
    Msg = jsx:decode(Data),
    StateNew = process_message(Msg, State),
    {ok, Req, StateNew};
websocket_handle(_Data, Req, State) ->
    {ok, Req, State}.

websocket_info({presence_response, Msg}, Req, State) ->
    io:format("presence response ~p ~n", [Msg]),
    {reply, {text, Msg}, Req, State};
websocket_info({received_message, Msg, exchange, _ExchangeName}, Req, State) ->
    {reply, {text, Msg}, Req, State};
websocket_info({timeout, _Ref, Msg}, Req, State) ->
    {reply, {text, Msg}, Req, State};
websocket_info(_Info, Req, State) ->
    {ok, Req, State}.

process_message([{<<"joinexchange">>, ExchangeName}], State = #state{exchanges=Exs, queues=Qs, user_id=UserId}) ->
    {ok, ExchangePid} = supervisor:start_child(msg_exchange_sup, [ExchangeName, UserId, self()]),
    {ok, QueuePid} = supervisor:start_child(msg_queue_sup, [ExchangeName, UserId, self()]),
    % TODO: add only once
    State#state{exchanges = dict:store(ExchangeName, ExchangePid, Exs), queues = dict:store(ExchangeName, QueuePid, Qs)};

process_message([{<<"send">>, Message}, {<<"exchange">>, ExchangeName}], State = #state{exchanges=Exs, user_id=UserId, user_data=UserData}) ->
    % TODO: make robust
    {ok, ExchangePid} = dict:find(ExchangeName, Exs),
    gen_server:call(ExchangePid, {send, jsx:encode([{<<"message">>, Message},
                                                    {<<"exchange">>, ExchangeName}, 
                                                    {<<"user_id">>, UserId},
                                                    {<<"user_data">>, UserData}
                                                   ])}),
    State;

process_message([{<<"presence">>, ExchangeName}], State = #state{exchanges=Exs}) ->
    case dict:find(ExchangeName, Exs) of
        error -> ok;
        {ok, _} ->
            {UsersPub, UsersSub} = presence_serv:presence(ExchangeName),
            self() ! {presence_response, jsx:encode([{<<"publishers">>, UsersPub},
                                                     {<<"subscribers">>, UsersSub},
                                                     {<<"exchange">>, ExchangeName}
                                                    ])}
    end,
    State;

process_message([{<<"authenticate">>, AssumedUserId},{<<"token">>, Token}], State ) ->
    {ok, AuthenticateUrl} = application:get_env(carotene, authenticate_url),
    io:format("User id ~p, Token ~p~n", [AssumedUserId, Token]),
    {ok, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} = httpc:request(post, {AuthenticateUrl, [], "application/x-www-form-urlencoded", "user_id="++binary_to_list(AssumedUserId)++"&token="++binary_to_list(Token)}, [], []),
    io:format("Authenticate response: ~p~n", [Body]),
    AuthResult = jsx:decode(binary:list_to_bin(Body)),
    {UserID, UserData} = case AuthResult of
                             [{<<"authenticated">>, <<"true">>}, {<<"userdata">>, ResUserData}] -> {AssumedUserId, ResUserData};
                             _ -> {undefined, undefined}
                         end,
    State#state{user_id = UserID, user_data = UserData};

process_message(_, State) ->
    io:format("unknown message~n"),
    State .
