-module(router_metrics_report_prometheus).

-behaviour(gen_event).

-include("metrics.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ------------------------------------------------------------------
%% gen_event Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_event/2,
    handle_call/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    Port = application:get_env(router, router_metrics_report_prometheus_port, 3000),
    ElliOpts = [
        {callback, router_metrics_report_prometheus_handler},
        {callback_args, #{}},
        {port, Port}
    ],
    {ok, _Pid} = elli:start_link(ElliOpts),
    Metrics = maps:get(metrics, Args, []),
    lists:foreach(
        fun({Key, Meta, Desc}) ->
            declare_metric(Key, Meta, Desc)
        end,
        Metrics
    ),
    {ok, #state{}}.

handle_event({data, Key, Data, _MetaData}, State) when
    Key == ?SC_ACTIVE; Key == ?SC_ACTIVE_COUNT; Key == ?DC
->
    _ = prometheus_gauge:set(erlang:atom_to_list(Key), Data),
    {ok, State};
handle_event({data, Key, Data, MetaData}, State) when
    Key == ?ROUTING_OFFER;
    Key == ?ROUTING_PACKET;
    Key == ?PACKET_TRIP;
    Key == ?DECODED_TIME;
    Key == ?FUN_DURATION;
    Key == ?CONSOLE_API_TIME
->
    _ = prometheus_histogram:observe(erlang:atom_to_list(Key), MetaData, Data),
    {ok, State};
handle_event({data, Key, _Data, MetaData}, State) when Key == ?DOWNLINK ->
    _ = prometheus_counter:inc(erlang:atom_to_list(Key), MetaData),
    {ok, State};
handle_event({data, Key, Data, _MetaData}, State) when Key == ?WS ->
    _ = prometheus_boolean:set(erlang:atom_to_list(Key), Data),
    {ok, State};
handle_event({data, Key, Data, _MetaData}, State) when
    Key == ?SC_ACTIVE; Key == ?SC_ACTIVE_COUNT; Key == ?DC
->
    _ = prometheus_gauge:set(erlang:atom_to_list(Key), Data),
    {ok, State};
handle_event(_Msg, State) ->
    lager:debug("rcvd unknown evt msg: ~p", [_Msg]),
    {ok, State}.

handle_call(_Msg, State) ->
    lager:debug("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec declare_metric(atom(), list(), string()) -> any().
declare_metric(Key, Meta, Desc) when Key == ?SC_ACTIVE; Key == ?SC_ACTIVE_COUNT; Key == ?DC ->
    _ = prometheus_gauge:declare([
        {name, erlang:atom_to_list(Key)},
        {help, Desc},
        {labels, Meta}
    ]);
declare_metric(Key, Meta, Desc) when
    Key == ?ROUTING_OFFER;
    Key == ?ROUTING_PACKET;
    Key == ?PACKET_TRIP;
    Key == ?DECODED_TIME;
    Key == ?FUN_DURATION;
    Key == ?CONSOLE_API_TIME
->
    _ = prometheus_histogram:declare([
        {name, erlang:atom_to_list(Key)},
        {help, Desc},
        {labels, Meta},
        {buckets, [50, 100, 250, 500, 1000, 2000]}
    ]);
declare_metric(Key, Meta, Desc) when Key == ?DOWNLINK ->
    _ = prometheus_counter:declare([
        {name, erlang:atom_to_list(Key)},
        {help, Desc},
        {labels, Meta}
    ]);
declare_metric(Key, Meta, Desc) when Key == ?WS ->
    _ = prometheus_boolean:declare([
        {name, erlang:atom_to_list(Key)},
        {help, Desc},
        {labels, Meta}
    ]);
declare_metric(Key, _Meta, Desc) ->
    lager:warning("cannot declare unknown metric ~p / ~p", [Key, Desc]).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

metrics_test() ->
    ok = application:set_env(prometheus, collectors, [
        prometheus_boolean,
        prometheus_counter,
        prometheus_gauge,
        prometheus_histogram
    ]),
    {ok, _} = application:ensure_all_started(prometheus),
    {ok, Pid} = router_metrics:start_link(#{}),

    ?assertEqual(
        <<"0">>,
        extract_data(erlang:atom_to_list(?SC_ACTIVE_COUNT), prometheus_text_format:format())
    ),

    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?SC_ACTIVE, 1, []}),
    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?SC_ACTIVE_COUNT, 2, []}),
    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?DC, 3, []}),
    ok = router_metrics:routing_offer_observe(join, accepted, accepted, 4),
    Format = prometheus_text_format:format(),
    io:format(Format),
    ?assertEqual(
        <<"1">>,
        extract_data(erlang:atom_to_list(?SC_ACTIVE), prometheus_text_format:format())
    ),
    ?assertEqual(
        <<"2">>,
        extract_data(erlang:atom_to_list(?SC_ACTIVE_COUNT), prometheus_text_format:format())
    ),
    ?assertEqual(
        <<"3">>,
        extract_data(erlang:atom_to_list(?DC), prometheus_text_format:format())
    ),
    ?assertEqual(
        <<"4">>,
        extract_data(
            "router_device_routing_offer_duration_sum{type=\"join\",status=\"accepted\",reason=\"accepted\"}",
            prometheus_text_format:format()
        )
    ),

    gen_server:stop(Pid),
    application:stop(prometheus),
    ok.

extract_data(Key, Format) ->
    Base = "\n" ++ Key ++ " ",
    case re:run(Format, Base ++ "[0-9]*", [global]) of
        {match, [[{Pos, Len}]]} ->
            binary:replace(binary:part(Format, Pos, Len), erlang:list_to_binary(Base), <<>>);
        _ ->
            not_found
    end.

-endif.
