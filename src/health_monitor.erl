%% ----------------------------------------------------------------------
%% @author Ankit Varshney <ankit.v@greyorange.com>
%% @doc This Module is used to detect the "Starving" Condition  of modules
%%      for which they require to inform health monitor that they are moving in/out in a starving state.
%% @end
%% ----------------------------------------------------------------------

-module(health_monitor).

-behaviour(gen_server).

-export([start_link/0, enter_in_starvation/2, exit_from_starvation/1, exit_from_starvation/2, get_starved_process/0, get_starved_process/1]).
%% gen_server callbacks
-export([init/1, handle_cast/2, handle_call/3, terminate/2, code_change/3, handle_info/2]).

-define(SERVER, ?MODULE).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
init([]) ->
    erlang:send_after(30000, self(), check_starved_processes),
    {ok, #{}}.

start_link() ->
    gen_server:start_link({global, ?SERVER}, ?MODULE, [], []).

%% This function is used when any module enters in starving state.
-spec enter_in_starvation(pid(), map()) -> ok.
enter_in_starvation(PId, Details) ->
    DateTime = erlang:timestamp(),
    case erlang:process_info(PId, registered_name) of
        undefined ->
            lager:info(" Wrong Pid Provided ~p ",[PId]);
        _ ->
            Pname = case ets:lookup(global_pid_names, PId) of
                        [{PId, Name}] -> list_to_binary(logging_utils:convert_to_string(Name));
                        [] -> ""
                    end,
            gen_server:cast({global, health_monitor}, {starved_register, PId, Pname, Details, DateTime})
    end,
    ok.
%% This function is used when any module exit from starving state.
-spec exit_from_starvation(pid()) -> ok.
exit_from_starvation(PId) ->
    exit_from_starvation(PId, exit).

%% This function is used when any module crashed in starving state.
-spec exit_from_starvation(pid(), atom()) -> ok.
exit_from_starvation(PId, ExitReason) ->
    DateTime = erlang:timestamp(),
    gen_server:cast({global, health_monitor}, {starved_unregister, PId, ExitReason, DateTime}),
    ok.

%% This function is used to get details of module which enters in starving state.
-spec get_starved_process() -> list(map()).
get_starved_process() ->
    get_starved_process(#{}).

%% This function is used to get details of module which enters in starving state.
-spec get_starved_process(map()) -> list(map()).
get_starved_process(OptionMap) ->
    lager:info("Option map in get_starved_process ~p", [OptionMap]),
    StarvedProcessList = case {maps:get(<<"process_name">>, OptionMap, none), maps:get(<<"is_starved">>, OptionMap, none)} of
                            {none, none} ->
                                ets:match_object(health_monitor, {'_', {'_', '_', '_', '_'}});
                            {ProcessName, none} ->
                                ets:match_object(health_monitor, {'_', {ProcessName, '_', '_', '_'}});
                            {none, IsStarved} ->
                                IsStarvedValue = case is_binary (IsStarved) of
                                                    true ->
                                                        binary_to_atom(IsStarved, utf8);
                                                    _ ->
                                                        IsStarved
                                                end,
                                ets:match_object(health_monitor, {'_', {'_', '_', '_', IsStarvedValue}});
                            {ProcessName, IsStarved} ->
                                IsStarvedValue = case is_binary (IsStarved) of
                                                    true ->
                                                        binary_to_atom(IsStarved, utf8);
                                                    _ ->
                                                        IsStarved
                                                 end,
                                ets:match_object(health_monitor, {'_', {ProcessName, '_', '_', IsStarvedValue}})
                          end,
    case maps:get(<<"user_interface">>, OptionMap, false) of
        false ->
            lists:map(fun(ProcessData) ->
                {Pid, {PidName, Details, Time, StarvedFlag}} = ProcessData,
                FormattedTime = iso8601:format(Time),
                #{<<"pid">> => list_to_binary(pid_to_list(Pid)), <<"registered_name">> => PidName,
                <<"details">> => Details, <<"is_starved">> => StarvedFlag, <<"starvation_from">> => FormattedTime}
            end, StarvedProcessList);
        true ->
            lists:map(fun(ProcessData) ->
                {Pid, {PidName, Details, Time, StarvedFlag}} = ProcessData,
                FormattedTime = iso8601:format(Time),
                #{<<"pid">> => list_to_binary(pid_to_list(Pid)), <<"registered_name">> => logging_utils:convert_to_string(PidName),
                <<"details">> => logging_utils:convert_to_string(Details), <<"is_starved">> => logging_utils:convert_to_string(StarvedFlag),
                <<"starvation_from">> => logging_utils:convert_to_string(FormattedTime)}
            end, StarvedProcessList)
    end.

%% @private
%% @doc Handles cast messages.

handle_cast({starved_register, PId, PidName, Details, Time}, State) ->
    lager:info("starved register event From PID ~p ProcessName ~p Details ~p Time ~p",[PId, PidName, Details, Time]),
    % StarvedProcessTuple {process_name, Detais, starvation_from, is_starved}
    StarvedProcessTuple = {PidName, Details, Time, false},
    ets:insert(health_monitor, {PId, StarvedProcessTuple}),
    {noreply, State};

handle_cast({starved_unregister, PId, ExitReason, Time}, State) ->
    lager:debug("starved exit event From PID ~p Details ~p Time ~p",[PId, ExitReason, Time]),
    case ets:lookup(health_monitor, PId) of
        [] ->
            lager:info("Exit Starvation Event From Unknown Process ~p at ~p ~n",[PId, Time]);
        [{PId, _PidData}] ->
            % {PidName, Details, StarvedFrom, _IsStarved} = PidData,
            % StarvedTime = common_fsm_utils:round_off_float(timer:now_diff(Time, StarvedFrom)/1000000, 2),
            % InfluxData = [{pid, PId}, {registered_name, PidName}, {details, Details}, {event_name, ExitReason}],
            % logging_utils:log_metric(health_monitor, StarvedTime, InfluxData),
            ets:delete(health_monitor, PId)
    end,
    {noreply, State}.

%% @private
%% @doc Handles info messages.
handle_info(check_starved_processes, State) ->
    CurTime = erlang:timestamp(),
    StarvationThreshold = application:get_env(butler_server, starvation_threshold, 60),
    ets:foldl(
            fun({Pid, StarvedProcessTuple}, Acc) ->
                {PidName, Details, Time, IsStarved} = StarvedProcessTuple,
                StarvingTime = (timer:now_diff(CurTime, Time)/1000000), % in seconds
                    case StarvingTime > StarvationThreshold of
                        true ->
                            case IsStarved of
                                false ->
                                    ets:update_element(health_monitor, Pid, [{2, {PidName, Details, Time, true}}]),
                                    Acc;
                                _ ->
                                        Acc
                            end;
                        false ->
                                Acc
                    end
            end, [], health_monitor),
     erlang:send_after(30000, self(), check_starved_processes),
    {noreply, State}.



%% @private

handle_call(Message, _From, State) ->
    lager:info("Un-handled call Message: ~p", [Message]),
    {reply, {error, nothandled}, State}.


%% @doc Opposite of init.
-spec terminate(Reason :: any(), State :: #{}) -> any().
terminate(_Reason, _State) ->
    lager:warning("Health Monitor Stopped"),
    ok.

%% @private
%% @doc Convert process state when code is changed
-spec code_change(OldVsn :: any(), State :: #{}, Extra :: any()) -> {ok, NewState :: #{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
