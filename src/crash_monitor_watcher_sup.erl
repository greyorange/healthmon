-module(crash_monitor_watcher_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Callbacks
-export([init/1]).

start_link() ->
    supervisor:start_link({global, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 10, 60},
            [
                {crash_monitor_watcher, {crash_monitor_watcher, start_link, [error_logger, crash_monitor_event_handler]},
                        permanent, 5000, worker, [crash_monitor_watcher]}
                ]}}.
