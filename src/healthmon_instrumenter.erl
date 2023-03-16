%% ----------------------------------------------------------------------------------------
%% @author Hritik Soni <hritik.s@greyorange.sg>
%% @doc gen_statem for healthmon instrumentation
%% @end
%% ----------------------------------------------------------------------------------------

-module(healthmon_instrumenter).

-behaviour(gen_statem).

-compile(export_all).

-include("include/healthmon.hrl").

-import(healthmon_utils, [to_list/1]).

%% @doc Starts the server
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link() ->
    gen_statem:start_link({global, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_statem callbacks
%%%==================================================================

callback_mode() ->
    handle_event_function.

%% @private
%% @doc Initializes the server
init([]) ->
    lager:info("starting healthmon instrumenter"),
    InstrumentInterval = application:get_env(healthmon, instrument_interval_ms, 60000),
    {ok, ready, #{},
        [{{timeout, instrument}, InstrumentInterval, {instrument}}]}.

%% @private
-spec handle_event(event_type(), any(), state_name(), #healthmon_state{}) -> state_function_result().

handle_event({timeout, instrument}, _, ready, _StateData) ->
    ProcessComps = mnesia:dirty_select(component,
        [{#component{
                type = process,
                _='_'}, [], ['$_']}]),
    WordSize = erlang:system_info(wordsize),
    lists:foreach(
        fun(#component{comp_name = {RegName, _},
                pid = Pid, health = Health, metadata = MD}) ->
            Fields =
                lists:foldl(
                    fun(MdEntry, FieldsAcc) ->
                        case MdEntry of
                            {message_queue_len, _} -> [MdEntry|FieldsAcc];
                            {total_heap_size, HeapSize} ->
                                [{total_heap_size_bytes, HeapSize * WordSize}|FieldsAcc];
                            {stack_size, StackSize} ->
                                [{stack_size_bytes, StackSize * WordSize}|FieldsAcc];
                            {reductions, _} -> [MdEntry|FieldsAcc];
                            _ -> FieldsAcc
                        end
                    end,
                [{reg_name, to_list(RegName)}, {pid, to_list(Pid)}],
                maps:to_list(MD)),
            Tags = [{health, Health}],
            logging_utils:log_event_v2(healthmon_vm_processes_info, Fields, Tags)
        end,
    ProcessComps),
    InstrumentInterval = application:get_env(healthmon, instrument_interval_ms, 60000),
    {keep_state_and_data,
        [{{timeout, instrument}, InstrumentInterval, {instrument}}]};

handle_event(EventType, Event, StateName, _StateData) ->
    io:format("Unhandled event: ~p of type: ~p received in state: ~p", [Event, EventType, StateName]),
    keep_state_and_data.

%% @private
%% @doc Opposite of init.
terminate(_Reason, _StateName, _State) ->
    ok.
