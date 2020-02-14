%% ----------------------------------------------------------------------------------------
%% @author Hritik Soni <hritik.s@greyorange.sg>
%% @end
%% ----------------------------------------------------------------------------------------

-module(appmon_watcher).

-behaviour(gen_statem).

-compile(export_all).

-include("include/healthmon.hrl").

-record(state, {
    appmon
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link() ->
    gen_statem:start_link({global, ?MODULE}, ?MODULE, [], []).

get_appmon_pid() ->
    gen_statem:call({global, ?MODULE}, get_appmon_pid).

%%%===================================================================
%%% gen_statem callbacks
%%%==================================================================

callback_mode() ->
    handle_event_function.

%% @private
%% @doc Initializes the server
init([]) ->
    lager:debug("starting appmon_fetcher"),
    {ok, P} = appmon_info:start_link(node(), self(), []),
    InitState = #state{appmon = P},
    healthmon:update_appmon(P),
    {ok, ready, InitState}.

%% @private

handle_event({call, From}, get_appmon_pid, ready, StateData) ->
    {keep_state_and_data,
        [{reply, From, {ok, StateData#state.appmon}}]};

handle_event(EventType, Event, StateName, _StateData) ->
    io:format("Unhandled event: ~p of type: ~p received in state: ~p", [Event, EventType, StateName]),
    keep_state_and_data.

%% @private
%% @doc Opposite of init.
terminate(_Reason, _StateName, _State) ->
    ok.
