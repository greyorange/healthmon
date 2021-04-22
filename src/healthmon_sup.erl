-module(healthmon_sup).
-behaviour(supervisor3).

-export([start_link/0]).
-export([init/1, post_init/1]).

start_link() ->
	supervisor3:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	{ok, {{one_for_one, 1, 5}, get_enabled_children_specs()}}.

post_init([]) -> ignore.

get_healthmon_components() ->
	[healthmon_core, starvmon, crashmon, healthmon_instrumenter].

get_enabled_children_specs() ->
	get_enabled_children_specs(get_healthmon_components(), []).

get_enabled_children_specs([], Acc) -> Acc;

get_enabled_children_specs([healthmon_core | Rest], Acc) ->
	case application:get_env(healthmon, healthmon_core_enabled, false) of
		true ->
			AppmonWatcher = {appmon_watcher, {appmon_watcher, start_link, []},
				{permanent, 30}, 2000, worker, [appmon_watcher]},
			HealthMon = {healthmon, {healthmon, start_link, []},
				{permanent, 30}, 2000, worker, [healthmon]},
			get_enabled_children_specs(Rest, Acc ++ [AppmonWatcher, HealthMon]);
		false -> get_enabled_children_specs(Rest, Acc)
	end;

get_enabled_children_specs([starvmon | Rest], Acc) ->
	case application:get_env(healthmon, starvmon_enabled, true) of
		true ->
			HealthMonitor  = {health_monitor, {health_monitor, start_link, []},
				permanent, 2000, worker, [health_monitor]},
			get_enabled_children_specs(Rest, Acc ++ [HealthMonitor]);
		false -> get_enabled_children_specs(Rest, Acc)
	end;

get_enabled_children_specs([crashmon | Rest], Acc) ->
	case application:get_env(healthmon, crashmon_enabled, true) of
		true ->
			CrashMonitorSup = {crash_monitor_watcher_sup, {crash_monitor_watcher_sup, start_link, []},
				temporary, infinity, supervisor, [crash_monitor_watcher_sup]},
			get_enabled_children_specs(Rest, Acc ++ [CrashMonitorSup]);
		false -> get_enabled_children_specs(Rest, Acc)
	end;

get_enabled_children_specs([healthmon_instrumenter | Rest], Acc) ->
	case application:get_env(healthmon, healthmon_instrumenter_enabled, true) of
		true ->
			HealthmonInstrumenter  = {healthmon_instrumenter, {healthmon_instrumenter, start_link, []},
				{permanent, 30}, 2000, worker, [healthmon_instrumenter]},
			get_enabled_children_specs(Rest, Acc ++ [HealthmonInstrumenter]);
		false -> get_enabled_children_specs(Rest, Acc)
	end.
