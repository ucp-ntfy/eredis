%%
%% eredis_client
%%
%% The client is implemented as a gen_server which keeps one socket
%% open to a single Redis instance. Users call us using the API in
%% eredis.erl.
%%
%% The client works like this:
%%  * When starting up, we connect to Redis with the given connection
%%     information, or fail.
%%  * Users calls us using gen_server:call, we send the request to Redis,
%%    add the calling process at the end of the queue and reply with
%%    noreply. We are then free to handle new requests and may reply to
%%    the user later.
%%  * We receive data on the socket, we parse the response and reply to
%%    the client at the front of the queue. If the parser does not have
%%    enough data to parse the complete response, we will wait for more
%%    data to arrive.
%%  * For pipeline commands, we include the number of responses we are
%%    waiting for in each element of the queue. Responses are queued until
%%    we have all the responses we need and then reply with all of them.
%%
-module(eredis_client).
-behaviour(gen_server).
-include("eredis.hrl").

%% API
-export([start_link/6, stop/1, select_database/2]).

-export([do_sync_command/2, authenticate/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
          host :: string() | undefined,
          port :: integer() | undefined,
          password :: binary() | undefined,
          database :: binary() | undefined,
          reconnect_sleep :: reconnect_sleep() | undefined,
          connect_timeout :: integer() | undefined,

          socket :: port() | undefined,
          parser_state :: #pstate{} | undefined,
          queue :: eredis_queue() | undefined
}).

-record(queued_request, {
    cmd_count = 1 :: pos_integer(),
    no_auth_count = 0 :: non_neg_integer(),
    from :: pid(),
    replies :: list() | undefined,
    request :: iolist()
}).

-define(AUTH_FLAG, authenticate).

%%
%% API
%%

-spec start_link(Host::list(),
                 Port::integer(),
                 Database::integer() | undefined,
                 Password::string(),
                 ReconnectSleep::reconnect_sleep(),
                 ConnectTimeout::integer() | undefined) ->
                        {ok, Pid::pid()} | {error, Reason::term()}.
start_link(Host, Port, Database, Password, ReconnectSleep, ConnectTimeout) ->
    gen_server:start_link(?MODULE, [Host, Port, Database, Password,
                                    ReconnectSleep, ConnectTimeout], []).


stop(Pid) ->
    gen_server:call(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Port, Database, Password, ReconnectSleep, ConnectTimeout]) ->
    State = #state{host = Host,
                   port = Port,
                   database = read_database(Database),
                   password = list_to_binary(Password),
                   reconnect_sleep = ReconnectSleep,
                   connect_timeout = ConnectTimeout,

                   parser_state = eredis_parser:init(),
                   queue = queue:new()},

    case connect(State) of
        {ok, NewState} ->
            {ok, NewState};
        {error, Reason} ->
            {stop, {connection_error, Reason}}
    end.

handle_call({request, Req}, From, State) ->
    do_request(Req, From, State);

handle_call({pipeline, Pipeline}, From, State) ->
    do_pipeline(Pipeline, From, State);

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.


handle_cast({request, Req}, State) ->
    case do_request(Req, undefined, State) of
        {reply, _Reply, State1} ->
            {noreply, State1};
        {noreply, State1} ->
            {noreply, State1}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Receive data from socket, see handle_response/2. Match `Socket' to
%% enforce sanity.
handle_info({tcp, Socket, Bs}, #state{socket = Socket} = State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, handle_response(Bs, State)};

handle_info({tcp, Socket, _}, #state{socket = OurSocket} = State)
  when OurSocket =/= Socket ->
    %% Ignore tcp messages when the socket in message doesn't match
    %% our state. In order to test behavior around receiving
    %% tcp_closed message with clients waiting in queue, we send a
    %% fake tcp_close message. This allows us to ignore messages that
    %% arrive after that while we are reconnecting.
    {noreply, State};

handle_info({tcp_error, _Socket, _Reason}, State) ->
    %% This will be followed by a close
    {noreply, State};

%% Socket got closed, for example by Redis terminating idle
%% clients. If desired, spawn of a new process which will try to reconnect and
%% notify us when Redis is ready. In the meantime, we can respond with
%% an error message to all our clients.
handle_info({tcp_closed, _Socket}, #state{reconnect_sleep = no_reconnect,
                                          queue = Queue} = State) ->
    reply_all({error, tcp_closed}, Queue),
    %% If we aren't going to reconnect, then there is nothing else for
    %% this process to do.
    {stop, normal, State#state{socket = undefined}};

handle_info({tcp_closed, _Socket}, #state{queue = Queue} = State) ->
    Self = self(),
    spawn(fun() -> reconnect_loop(Self, State) end),

    %% tell all of our clients what has happened.
    reply_all({error, tcp_closed}, Queue),

    %% Throw away the socket and the queue, as we will never get a
    %% response to the requests sent on the old socket. The absence of
    %% a socket is used to signal we are "down"
    {noreply, State#state{socket = undefined, queue = queue:new()}};

%% Redis is ready to accept requests, the given Socket is a socket
%% already connected and authenticated.
handle_info({connection_ready, Socket}, #state{socket = undefined} = State) ->
    {noreply, State#state{socket = Socket}};

%% eredis can be used in Poolboy, but it requires to support a simple API
%% that Poolboy uses to manage the connections.
handle_info(stop, State) ->
    {stop, shutdown, State};

handle_info(_Info, State) ->
    {stop, {unhandled_message, _Info}, State}.

terminate(_Reason, State) ->
    case State#state.socket of
        undefined -> ok;
        Socket    -> gen_tcp:close(Socket)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec do_request(Req::iolist(), From::pid(), #state{}) ->
                        {noreply, #state{}} | {reply, Reply::any(), #state{}}.
%% @doc: Sends the given request to redis. If we do not have a
%% connection, returns error.
do_request(_Req, _From, #state{socket = undefined} = State) ->
    {reply, {error, no_connection}, State};

do_request(Req, From, State) ->
    case gen_tcp:send(State#state.socket, Req) of
        ok ->
            Request = #queued_request{from = From, request = Req},
            NewQueue = queue:in(Request, State#state.queue),
            {noreply, State#state{queue = NewQueue}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec do_pipeline(Pipeline::pipeline(), From::pid(), #state{}) ->
                         {noreply, #state{}} | {reply, Reply::any(), #state{}}.
%% @doc: Sends the entire pipeline to redis. If we do not have a
%% connection, returns error.
do_pipeline(_Pipeline, _From, #state{socket = undefined} = State) ->
    {reply, {error, no_connection}, State};

do_pipeline(Pipeline, From, State) ->
    case gen_tcp:send(State#state.socket, Pipeline) of
        ok ->
            Request = #queued_request{
                cmd_count = length(Pipeline),
                from = From,
                replies = [],
                request = Pipeline
            },
            NewQueue = queue:in(Request, State#state.queue),
            {noreply, State#state{queue = NewQueue}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

resend_request(#state{socket = Socket, queue = Queue} = State) ->
    {{value, Item}, NewQueue} = queue:out(Queue),
    #queued_request{
        request = Request,
        cmd_count = CmdCount,
        no_auth_count = NoAuthCount
    } = Item,

    % Current NOAUTH is not counted yet, that's why +1.
    if CmdCount == NoAuthCount + 1 ->
        gen_tcp:send(Socket, Request),
        State#state{
            queue = queue:in(Item#queued_request{no_auth_count = 0}, NewQueue)
        };
    true ->
        NewItem = Item#queued_request{no_auth_count = NoAuthCount + 1},
        State#state{queue = queue:in_r(NewItem, NewQueue)}
    end.

handle_noauth(#state{socket = Socket, queue = Queue} = State, undefined) ->
    send_authenticate(Socket, get_redis_password()),
    put(?AUTH_FLAG, in_process),
    resend_request(State#state{queue = queue:in(?AUTH_FLAG, Queue)});
handle_noauth(State, _) ->
    resend_request(State).

handle_noauth(State) ->
    handle_noauth(State, get(?AUTH_FLAG)).

-spec handle_response(Data::binary(), State::#state{}) -> NewState::#state{}.
%% @doc: Handle the response coming from Redis. This includes parsing
%% and replying to the correct client, handling partial responses,
%% handling too much data and handling continuations.
handle_response(Data, #state{parser_state = ParserState,
                             queue = Queue} = State) ->

    case eredis_parser:parse(ParserState, Data) of
        {error,<<"NOAUTH Authentication required.">>, NewParserState} ->
            handle_noauth(State#state{parser_state = NewParserState});
        {error,<<"NOAUTH Authentication required.">>, Rest, NewParserState} ->
            NewState = handle_noauth(State#state{parser_state = NewParserState}),
            handle_response(Rest, NewState);
        %% Got complete response, return value to client
        {ReturnCode, Value, NewParserState} ->
            NewQueue = reply({ReturnCode, Value}, Queue),
            State#state{parser_state = NewParserState,
                        queue = NewQueue};

        %% Got complete response, with extra data, reply to client and
        %% recurse over the extra data
        {ReturnCode, Value, Rest, NewParserState} ->
            NewQueue = reply({ReturnCode, Value}, Queue),
            handle_response(Rest, State#state{parser_state = NewParserState,
                                              queue = NewQueue});

        %% Parser needs more data, the parser state now contains the
        %% continuation data and we will try calling parse again when
        %% we have more data
        {continue, NewParserState} ->
            State#state{parser_state = NewParserState}
    end.

%% @doc: Sends a value to the first client in queue. Returns the new
%% queue without this client. If we are still waiting for parts of a
%% pipelined request, push the reply to the the head of the queue and
%% wait for another reply from redis.
reply(Value, Queue) ->
    case queue:out(Queue) of
        {{value, ?AUTH_FLAG}, NewQueue} ->
            put(?AUTH_FLAG, undefined),
            case Value of
                {ok, _} ->
                    NewQueue;
                _ ->
                    % we can't authenticate, so what to do?
                    throw({?MODULE, ?LINE, Value})
            end;
        {{value, {1, From}}, NewQueue} ->
            safe_reply(From, Value),
            NewQueue;
        {{value, {1, From, Replies}}, NewQueue} ->
            safe_reply(From, lists:reverse([Value | Replies])),
            NewQueue;
        {{value, {N, From, Replies}}, NewQueue} when N > 1 ->
            queue:in_r({N - 1, From, [Value | Replies]}, NewQueue);
        {{value, #queued_request{cmd_count = 1, from = From, replies = undefined}}, NewQueue} ->
            safe_reply(From, Value),
            NewQueue;
        {{value, #queued_request{cmd_count = 1, from = From, replies = Replies}}, NewQueue} ->
            safe_reply(From, lists:reverse([Value | Replies])),
            NewQueue;
        {{value, #queued_request{cmd_count = N, request = [_|Req]} = Request}, NewQueue} when N > 1 ->
            Replies = Request#queued_request.replies,
            Tmp = Request#queued_request{
                cmd_count = N -1,
                replies = [Value|Replies],
                request = Req
            },
            queue:in_r(Tmp, NewQueue);
        {empty, Queue} ->
            %% Oops
            error_logger:info_msg("Nothing in queue, but got value from parser~n"),
            throw(empty_queue)
    end.

%% @doc Send `Value' to each client in queue. Only useful for sending
%% an error message. Any in-progress reply data is ignored.
-spec reply_all(any(), eredis_queue()) -> ok.
reply_all(Value, Queue) ->
    case queue:peek(Queue) of
        empty ->
            ok;
        {value, Item} ->
            safe_reply(receipient(Item), Value),
            reply_all(Value, queue:drop(Queue))
    end.

receipient({_, From}) ->
    From;
receipient({_, From, _}) ->
    From;
receipient(#queued_request{from = From}) ->
    From.

safe_reply(undefined, _Value) ->
    ok;
safe_reply(From, Value) ->
    gen_server:reply(From, Value).

%% @doc: Helper for connecting to Redis, authenticating and selecting
%% the correct database. These commands are synchronous and if Redis
%% returns something we don't expect, we crash. Returns {ok, State} or
%% {SomeError, Reason}.
connect(State) ->
    case gen_tcp:connect(State#state.host, State#state.port,
                         ?SOCKET_OPTS, State#state.connect_timeout) of
        {ok, Socket} ->
            case authenticate(Socket, get_redis_password()) of
                ok ->
                    case select_database(Socket, State#state.database) of
                        ok ->
                            {ok, State#state{socket = Socket}};
                        {error, Reason} ->
                            {error, {select_error, Reason}}
                    end;
                {error, Reason} ->
                    {error, {authentication_error, Reason}}
            end;
        {error, Reason} ->
            {error, {connection_error, Reason}}
    end.

select_database(_Socket, undefined) ->
    ok;
select_database(_Socket, <<"0">>) ->
    ok;
select_database(Socket, Database) ->
    do_sync_command(Socket, ["SELECT", " ", Database, "\r\n"]).

get_redis_password() ->
    case application:get_env(eredis_cluster, pass_file) of
        undefined ->
            undefined;
        {ok, PassFile} ->
            case file:read_file(PassFile) of
                {ok, Pass} -> Pass;
                _ -> undefined
            end
    end.

send_authenticate(Socket, Password) ->
    AuthCmd = eredis:create_multibulk([<<"AUTH">>, Password]),
    gen_tcp:send(Socket, AuthCmd).

authenticate(_Socket, undefined) ->
    ok;
authenticate(Sock, Pass) ->
    {ok, Opts} = inet:getopts(Sock, [active]),
    ok = inet:setopts(Sock, [{active, false}]),
    Result = case send_authenticate(Sock, Pass) of
        ok ->
            case gen_tcp:recv(Sock, 0) of
                {ok, <<"+OK\r\n">>} -> ok;
                {ok, <<"-ERR Client sent AUTH, but no password is set\r\n">>} -> ok;
                {ok, Err} -> {error, Err};
                Err -> Err
            end;
        Err ->
            Err
    end,
    ok = inet:setopts(Sock, Opts),
    Result.

%% @doc: Executes the given command synchronously, expects Redis to
%% return "+OK\r\n", otherwise it will fail.
do_sync_command(Socket, Command) ->
    ok = inet:setopts(Socket, [{active, false}]),
    case gen_tcp:send(Socket, Command) of
        ok ->
            %% Hope there's nothing else coming down on the socket..
            case gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT) of
                {ok, <<"+OK\r\n">>} ->
                    ok = inet:setopts(Socket, [{active, once}]),
                    ok;
                Other ->
                    {error, {unexpected_data, Other}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc: Loop until a connection can be established, this includes
%% successfully issuing the auth and select calls. When we have a
%% connection, give the socket to the redis client.
reconnect_loop(Client, #state{reconnect_sleep = ReconnectSleep} = State) ->
    case catch(connect(State)) of
        {ok, #state{socket = Socket}} ->
            gen_tcp:controlling_process(Socket, Client),
            Client ! {connection_ready, Socket};
        {error, _Reason} ->
            timer:sleep(ReconnectSleep),
            reconnect_loop(Client, State);
        %% Something bad happened when connecting, like Redis might be
        %% loading the dataset and we got something other than 'OK' in
        %% auth or select
        _ ->
            timer:sleep(ReconnectSleep),
            reconnect_loop(Client, State)
    end.

read_database(undefined) ->
    undefined;
read_database(Database) when is_integer(Database) ->
    list_to_binary(integer_to_list(Database)).
