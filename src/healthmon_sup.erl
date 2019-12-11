-module(healthmon_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	HealthMon = {healthmon, {healthmon, start_link, []},
			permanent, 2000, supervisor, [healthmon]},
	Procs = [HealthMon],
	{ok, {{one_for_one, 1, 5}, Procs}}.
