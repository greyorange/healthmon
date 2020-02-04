-module(healthmon_sup).
-behaviour(supervisor3).

-export([start_link/0]).
-export([init/1, post_init/1]).

start_link() ->
	supervisor3:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	HealthMon = {healthmon, {healthmon, start_link, []},
			{permanent, 30}, 2000, worker, [healthmon]},
	HealthMonitor  = {health_monitor, {health_monitor, start_link, []},
		permanent, 2000, worker, [health_monitor]},
	CrashMonitorSup = {crash_monitor_watcher_sup, {crash_monitor_watcher_sup, start_link, []},
		temporary, infinity, supervisor, [crash_monitor_watcher_sup]},
	Procs = [HealthMon, HealthMonitor, CrashMonitorSup],
	{ok, {{one_for_one, 1, 5}, Procs}}.

post_init([]) -> ignore.