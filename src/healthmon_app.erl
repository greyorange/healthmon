-module(healthmon_app).
-behaviour(application).

-export([start/2, start/0]).
-export([stop/1]).

start() ->
	healthmon_sup:start_link().

start(_Type, _Args) ->
	healthmon_sup:start_link().

stop(_State) ->
	ok.
