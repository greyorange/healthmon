%% ----------------------------------------------------------------------------------------
%% @author Hritik Soni <hritik.s@greyorange.sg>
%% @doc gen_statem for health monitoring agent
%% @end
%% ----------------------------------------------------------------------------------------

-module(healthmon).

-behaviour(gen_statem).

-compile(export_all).

-include("include/healthmon.hrl").

%%%===================================================================
%%% API
%%%===================================================================

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
    lager:debug("starting healthmon"),
    InitState = #healthmon_state{},
    {ok, initializing, InitState, [{next_event, cast, {initialize}}]}.

%% @private

-spec handle_event(event_type(), any(), state_name(), #healthmon_state{}) -> state_function_result().

%% @doc Initializes the agent with the current rack
%% Also retrieves persistes incoming orders to state from db
handle_event(cast, {initialize}, initializing, StateData) ->
    {next_state, ready, StateData};

handle_event({call, From}, _Message, ready, _StateData) ->
    {keep_state_and_data,
        [{reply, From, {error, not_handled}}]};

handle_event({call, From}, _Message, _StateName, _StateData) ->
    {keep_state_and_data,
        [{reply, From, {error, not_ready}}]};

handle_event(EventType, Event, StateName, _StateData) ->
    lager:warning("Unhandled event: ~p of type: ~p received in state: ~p", [Event, EventType, StateName]),
    keep_state_and_data.

%% @private
%% @doc Opposite of init.
terminate(_Reason, _StateName, _State) ->
    ok.
