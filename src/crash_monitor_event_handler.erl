%% ----------------------------------------------------------------------
%% @author Rajat singla <rajat.s@greyorange.com>
%% @doc Manages hanlder to listen events send by error_logger.
%% @end
%% ----------------------------------------------------------------------

-module(crash_monitor_event_handler).

-behaviour(gen_event).

-include("include/healthmon.hrl").

-export([start_link/0]).
%% gen_server callbacks
-export([init/1,  handle_call/2, handle_event/2, terminate/2, code_change/3]).
-export([reset_ets/0, get_report/0, get_report/1, recordslist_to_json/1]).
-record(crash_monitor_state, {crash_map = #{}}).
-define(MAX_LENGTH, 1 bsl 32 - 1).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
init([]) ->
    process_flag(trap_exit, true),
    {ok, #crash_monitor_state{crash_map = #{}}}.

start_link() ->
    gen_server:start_link({global, crash_monitor}, ?MODULE, [], []).

handle_call(_Request, State) ->
    {ok, unknown_call, State}.

handle_event({error, _GL, {ErrorPid, Fmt, Args}}, CrashMonitorState) ->
    lager:debug("Crash detected in crash monitor"),
    case format_error_report(ErrorPid, Fmt, Args) of
        {Pid, Name, LastMsg, Md, Formatted, State} ->
            PidToRegister = list_to_binary(pid_to_list(Pid)),
            CrashDetail = list_to_binary(lists:flatten(Formatted)),
            notify_crashed_process(Pid, Name),
            RegisteredName = get_formatted_print(Name),
            TempReason = case Md of
                [{reason, Reason}, {line, Line}, {module, Module}, {function, Function}] ->
                    {Reason, Line, Module, Function, Name};
                [{reason, Reason}, {module, Module}, {function, Function}] ->
                    {Reason, Module, Function, Name};
                _ ->
                    {undefined, Name}
                end,
            CrashReason = list_to_binary(get_formatted_print(TempReason)),
            TimeStamp = calendar:universal_time(),
            LastEvent = get_formatted_print(LastMsg),
            FormattedState = re:replace(lists:flatten(io_lib:format("~p",[State])), "(\\s+\\s+)", " ", [global,{return,list}]),
            case ets:lookup(crash_map, CrashReason) of
                [] ->
                    Entry = #crash_entry{
                                reason = CrashReason,
                                pid = PidToRegister,
                                count = 1,
                                registered_name = list_to_binary(RegisteredName),
                                time_stamp = TimeStamp,
                                last_crash = CrashDetail,
                                metadata = list_to_binary(FormattedState),
                                last_event = list_to_binary(LastEvent)
                            },
                    ets:insert(crash_map, Entry),
                    logging_utils:log_metric(crash_map, 1, [{pid, Pid}, {registered_name, RegisteredName},
                        {last_crash, lists:flatten(Formatted)}, {matadata, State}, {last_event, LastEvent}]);
                [CrashEntry] ->
                    PreviousTimeInSec = calendar:datetime_to_gregorian_seconds(CrashEntry#crash_entry.time_stamp),
                    CurrentTimeInSec = calendar:datetime_to_gregorian_seconds(TimeStamp),
                    TimeDiff = CurrentTimeInSec - PreviousTimeInSec,
                    ResetTimer = application:get_env(butler_server, crash_reset_timer, 300),
                    NewCount =
                    case TimeDiff > ResetTimer of
                        true ->
                            1;
                        false ->
                            CrashEntry#crash_entry.count + 1
                    end,
                    Entry = #crash_entry{
                                reason = CrashReason,
                                pid = PidToRegister,
                                count = NewCount,
                                registered_name = list_to_binary(RegisteredName),
                                time_stamp = TimeStamp,
                                last_crash = CrashDetail,
                                metadata = list_to_binary(FormattedState),
                                last_event = list_to_binary(LastEvent)
                            },
                    ets:insert(crash_map, Entry),
                    logging_utils:log_metric(crash_map, NewCount, [{pid, Pid}, {registered_name, RegisteredName},
                        {last_crash, lists:flatten(Formatted)}, {matadata, State}, {last_event, LastEvent}])
            end;
        undefined ->
            ok
    end,
    {ok, CrashMonitorState};
handle_event(_Event, State) ->
    {ok, State}.

format_error_report(Pid, Fmt, Args) ->
    case {Fmt} of
        {"** Generic server " ++ _} ->
            %% gen_server terminate
            {Reason, Name, LastMsg, CrashState} = case Args of
                [N, Msg, State, R] ->
                    {R, N, Msg, State};
                [N, Msg, State, R, _Client] ->
                    %% OTP 20 crash reports where the client pid is dead don't include the stacktrace
                    {R, N, Msg, State};
                [N, Msg, State, R, _Client, _Stacktrace] ->
                    %% OTP 20 crash reports contain the pid of the client and stacktrace
                    {R, N, Msg, State}
            end,
            {Md, Formatted} = format_reason_md(Reason),
            {Pid, Name, LastMsg, Md, io_lib:format("gen_server ~w terminated with reason: ~s", [Name, Formatted]), CrashState};
        {"** State machine " ++ _} ->
            %% Check if the terminated process is gen_fsm or gen_statem
            %% since they generate the same exit message
            {Type, Name, StateName, CrashState, LastMsg, Reason} = case Args of
                [TName, Msg, TStateName, StateData, TReason] ->
                    {gen_fsm, TName, TStateName, StateData, Msg, TReason};
                %% Handle changed logging in gen_fsm stdlib-3.9 (TPid, ClientArgs)
                [TName, Msg, TPid, TStateName, StateData, TReason | _ClientArgs] when is_pid(TPid), is_atom(TStateName) ->
                    {gen_fsm, TName, TStateName, StateData, Msg, TReason};
                %% Handle changed logging in gen_statem stdlib-3.9 (ClientArgs)
                [TName, Msg, {TStateName, StateData}, _ExitType, TReason, _CallbackMode, Stacktrace | _ClientArgs] ->
                    {gen_statem, TName, TStateName, StateData, Msg, {TReason, Stacktrace}};
                [TName, Msg, _ExitType, TReason, _CallbackMode, Stacktrace | _ClientArgs] ->
                    {gen_statem, TName, undefined, undefined, Msg, {TReason, Stacktrace}};
                [TName, Msg, [{TStateName, StateData}], _ExitType, TReason, _CallbackMode, Stacktrace | _ClientArgs] ->
                    %% sometimes gen_statem wraps its statename/data in a list for some reason???
                    {gen_statem, TName, TStateName, StateData, Msg, {TReason, Stacktrace}}
            end,
            {Md, Formatted} = format_reason_md(Reason),
            {Pid, Name, LastMsg, Md, io_lib:format("~s ~w in state ~w terminated with reason: ~s", [Type, Name, StateName, Formatted]), CrashState};
        {"** gen_event handler" ++ _} ->
            %% gen_event handler terminate
            [ID, Name, Msg, CrashState, Reason] = Args,
            {Md, Formatted} = format_reason_md(Reason),
            {Pid, Name, Msg, Md, io_lib:format("gen_event ~w installed in ~w terminated with reason: ~s", [ID, Name, Formatted]), CrashState};
        {"** Cowboy handler" ++ _} ->
            %% Cowboy HTTP server error
            case Args of
                [Module, Function, Arity, _Request, CrashState] ->
                    %% we only get the 5-element list when its a non-exported function
                    Md = [{reason, Function}, {module, Module}, {function, Function}],
                    {Pid, [], [], Md, io_lib:format("Cowboy handler ~p terminated with reason: call to undefined function ~p:~p/~p",
                        [Module, Module, Function, Arity]), CrashState};
                [Module, Function, Arity, _Class, Reason | Tail] ->
                    %% any other cowboy error_format list *always* ends with the stacktrace
                    StackTrace = lists:last(Tail),
                    {Md, Formatted} = format_reason_md({Reason, StackTrace}),
                    {Pid, [], [], Md, io_lib:format("Cowboy handler ~p terminated in ~p:~p/~p with reason: ~s",
                        [Module, Module, Function, Arity, Formatted]), ""}
            end;
        {"Ranch listener " ++ _} ->
            %% Ranch errors
            case Args of
                %% Error logged by cowboy, which starts as ranch error
                [Ref, ConnectionPid, StreamID, RequestPid, Reason, StackTrace] ->
                    {Md, Formatted} = format_reason_md({Reason, StackTrace}),
                    {RequestPid, [], [], Md, io_lib:format("Cowboy stream ~p with ranch listener ~p and connection process ~p had its request process exit with reason: ~s",
                        [StreamID, Ref, ConnectionPid, Formatted]), ""};
                [Ref, _Protocol, _Worker, {[{reason, Reason}, {mfa, {Module, Function, Arity}}, {stacktrace, StackTrace} | _], _}] ->
                    {Md, Formatted} = format_reason_md({Reason, StackTrace}),
                    {Pid, [], [], Md, io_lib:format("Ranch listener ~p terminated in ~p:~p/~p with reason: ~s",
                        [Ref, Module, Function, Arity, Formatted]), ""};
                [Ref, _Protocol, _Worker, Reason] ->
                    {Md, Formatted} = format_reason_md(Reason),
                    {Pid, [], [], Md, io_lib:format("Ranch listener ~p terminated with reason: ~s",
                        [Ref, Formatted]), ""};
                [Ref, _Protocol, Ret] ->
                    %% ranch_conns_sup.erl module line 119-123 has three parameters error msg, log it.
                    {Md, Formatted} = format_reason_md(Ret),
                    {Pid, [], [], Md, io_lib:format("Ranch listener ~p terminated with result:~s",
                        [Ref, Formatted]), ""}
            end;
        {"webmachine error" ++ _} ->
            %% Webmachine HTTP server error
            [Path, Error] = Args,
            %% webmachine likes to mangle the stack, for some reason
            StackTrace = case Error of
                {error, {error, Reason, Stack}} ->
                    {Reason, Stack};
                _ ->
                    Error
            end,
            {Md, Formatted} = format_reason_md(StackTrace),
            {Pid, [], [], Md, io_lib:format("Webmachine error at path ~p : ~s",
                [Path, Formatted]), ""};
        _ ->
            lager:error("Undefined Event in crash monitor: ~p, ~p, ~p", [Pid, Fmt, Args]),
            undefined
    end.

get_formatted_print(V) ->
    try
        get_formatted_print_internal(V)
    catch
        _T:_C-> ""
    end.

get_formatted_print_internal([]) ->
    "";
get_formatted_print_internal(Pid) when is_pid(Pid) ->
    pid_to_list(Pid);
get_formatted_print_internal(Name) ->
    prettypr:format(erl_prettypr:best(erl_syntax:abstract(Name))).



%% @doc Faster than proplists, but with the same API as long as you don't need to
%% handle bare atom keys
get_value(Key, Value) ->
    get_value(Key, Value, undefined).

get_value(Key, List, Default) ->
    case lists:keyfind(Key, 1, List) of
        false -> Default;
        {Key, Value} -> Value
    end.

-spec format_reason_md(Stacktrace:: any()) -> {Metadata:: [{atom(), any()}], String :: list()}.
format_reason_md({'function not exported', [{M, F, A},MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {_, Formatted2} = format_mfa_md({M, F, length(A)}),
    {[{reason, 'function not exported'} | Md],
        ["call to undefined function ", Formatted2,
            " from ", Formatted]};
format_reason_md({'function not exported', [{M, F, A, _Props},MFA|_]}) ->
    %% R15 line numbers
    {Md, Formatted} = format_mfa_md(MFA),
    {_, Formatted2} = format_mfa_md({M, F, length(A)}),
    {[{reason, 'function not exported'} | Md],
        ["call to undefined function ", Formatted2,
            " from ", Formatted]};
format_reason_md({undef, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, undef} | Md],
        ["call to undefined function ", Formatted]};
format_reason_md({bad_return, {_MFA, {'EXIT', Reason}}}) ->
    format_reason_md(Reason);
format_reason_md({bad_return, {MFA, Val}}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, bad_return} | Md],
        ["bad return value ", print_val(Val), " from ", Formatted]};
format_reason_md({bad_return_value, Val}) ->
    {[{reason, bad_return}],
        ["bad return value: ", print_val(Val)]};
format_reason_md({{bad_return_value, Val}, MFA}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, bad_return_value} | Md],
        ["bad return value: ", print_val(Val), " in ", Formatted]};
format_reason_md({{badrecord, Record}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badrecord} | Md],
        ["bad record ", print_val(Record), " in ", Formatted]};
format_reason_md({{case_clause, Val}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, case_clause} | Md],
        ["no case clause matching ", print_val(Val), " in ", Formatted]};
format_reason_md({function_clause, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, function_clause} | Md],
        ["no function clause matching ", Formatted]};
format_reason_md({if_clause, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, if_clause} | Md],
        ["no true branch found while evaluating if expression in ", Formatted]};
format_reason_md({{try_clause, Val}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, try_clause} | Md],
        ["no try clause matching ", print_val(Val), " in ", Formatted]};
format_reason_md({badarith, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badarith} | Md],
        ["bad arithmetic expression in ", Formatted]};
format_reason_md({{badmatch, Val}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badmatch} | Md],
        ["no match of right hand value ", print_val(Val), " in ", Formatted]};
format_reason_md({emfile, _Trace}) ->
    {[{reason, emfile}],
        "maximum number of file descriptors exhausted, check ulimit -n"};
format_reason_md({system_limit, [{M, F, _}|_] = Trace}) ->
    Limit = case {M, F} of
        {erlang, open_port} ->
            "maximum number of ports exceeded";
        {erlang, spawn} ->
            "maximum number of processes exceeded";
        {erlang, spawn_opt} ->
            "maximum number of processes exceeded";
        {erlang, list_to_atom} ->
            "tried to create an atom larger than 255, or maximum atom count exceeded";
        {ets, new} ->
            "maximum number of ETS tables exceeded";
        _ ->
            {Str, _} = lager_trunc_io:print(Trace, 500),
            Str
    end,
    {[{reason, system_limit}], ["system limit: ", Limit]};
format_reason_md({badarg, [MFA,MFA2|_]}) ->
    case MFA of
        {_M, _F, A, _Props} when is_list(A) ->
            %% R15 line numbers
            {Md, Formatted} = format_mfa_md(MFA2),
            {_, Formatted2} = format_mfa_md(MFA),
            {[{reason, badarg} | Md],
                ["bad argument in call to ", Formatted2, " in ", Formatted]};
        {_M, _F, A} when is_list(A) ->
            {Md, Formatted} = format_mfa_md(MFA2),
            {_, Formatted2} = format_mfa_md(MFA),
            {[{reason, badarg} | Md],
                ["bad argument in call to ", Formatted2, " in ", Formatted]};
        _ ->
            %% seems to be generated by a bad call to a BIF
            {Md, Formatted} = format_mfa_md(MFA),
            {[{reason, badarg} | Md],
                ["bad argument in ", Formatted]}
    end;
format_reason_md({{badarg, Stack}, _}) ->
    format_reason_md({badarg, Stack});
format_reason_md({{badarity, {Fun, Args}}, [MFA|_]}) ->
    {arity, Arity} = lists:keyfind(arity, 1, erlang:fun_info(Fun)),
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badarity} | Md],
        [io_lib:format("fun called with wrong arity of ~w instead of ~w in ",
                    [length(Args), Arity]), Formatted]};
format_reason_md({noproc, MFA}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, noproc} | Md],
        ["no such process or port in call to ", Formatted]};
format_reason_md({{badfun, Term}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badfun} | Md],
        ["bad function ", print_val(Term), " in ", Formatted]};
format_reason_md({Reason, [{M, F, A}|_]}) when is_atom(M), is_atom(F), is_integer(A) ->
    {Md, Formatted} = format_reason_md(Reason),
    {_, Formatted2} = format_mfa_md({M, F, A}),
    {Md, [Formatted, " in ", Formatted2]};
format_reason_md({Reason, [{M, F, A, Props}|_]}) when is_atom(M), is_atom(F), is_integer(A), is_list(Props) ->
    %% line numbers
    {Md, Formatted} = format_reason_md(Reason),
    {_, Formatted2} = format_mfa_md({M, F, A, Props}),
    {Md, [Formatted, " in ", Formatted2]};
format_reason_md(Reason) ->
    {Str, _} = lager_trunc_io:print(Reason, 500),
    {[], Str}.

-spec format_mfa_md(any()) -> {[{atom(), any()}], list()}.
format_mfa_md({M, F, A}) when is_list(A) ->
    {FmtStr, Args} = format_args(A, [], []),
    {[{module, M}, {function, F}], io_lib:format("~w:~w(" ++ FmtStr ++ ")", [M, F | Args])};
format_mfa_md({M, F, A}) when is_integer(A) ->
    {[{module, M}, {function, F}], io_lib:format("~w:~w/~w", [M, F, A])};
format_mfa_md({M, F, A, Props}) when is_list(Props) ->
    case get_value(line, Props) of
        undefined ->
            format_mfa_md({M, F, A});
        Line ->
            {Md, Formatted} = format_mfa_md({M, F, A}),
            {[{line, Line} | Md], [Formatted, io_lib:format(" line ~w", [Line])]}
    end;
format_mfa_md([{M, F, A}| _]) ->
    %% this kind of weird stacktrace can be generated by a uncaught throw in a gen_server
    format_mfa_md({M, F, A});
format_mfa_md([{M, F, A, Props}| _]) when is_list(Props) ->
    %% this kind of weird stacktrace can be generated by a uncaught throw in a gen_server
    %% TODO we might not always want to print the first MFA we see here, often it is more helpful
    %% to print a lower one, but it is hard to programatically decide.
    format_mfa_md({M, F, A, Props});
format_mfa_md(Other) ->
    {[], io_lib:format("~w", [Other])}.

format_args([], FmtAcc, ArgsAcc) ->
    {string:join(lists:reverse(FmtAcc), ", "), lists:reverse(ArgsAcc)};
format_args([H|T], FmtAcc, ArgsAcc) ->
    {Str, _} = lager_trunc_io:print(H, ?MAX_LENGTH),
    format_args(T, ["~s"|FmtAcc], [Str|ArgsAcc]).

print_val(Val) ->
    {Str, _} = lager_trunc_io:print(Val, ?MAX_LENGTH),
    Str.

-spec reset_ets() -> true | false.
reset_ets() ->
    lager:debug("Reseting ets table for crash monitor"),
    ets:delete_all_objects(crash_map).

-spec get_report() -> list().
get_report() ->
    ets:tab2list(crash_map).

notify_crashed_process(Pid, Name) when is_pid(Pid) ->
    health_monitor:exit_from_starvation(Pid, crashed),
    healthmon:patch_component(Name, [{health, crashed}]).

%% @doc will take proplist as input having varibales on basis of which crash report will be generated
-spec get_report(list()) -> list().
get_report(Propist) ->
    Pid = proplists:get_value(<<"pid">>, Propist, '_'),
    RegisteredName = proplists:get_value(<<"registered_name">>, Propist, '_'),
    Count = proplists:get_value(<<"count">>, Propist, '_'),
    ets:match_object(crash_map, {crash_entry, '_', convert_to_binary(Pid),
        convert_to_integer(Count), convert_to_binary(RegisteredName), '_', '_', '_', '_'}).

convert_to_integer(Input) when is_binary(Input) andalso Input =/= '_' ->
    binary_to_integer(Input);
convert_to_integer(Input) ->
    Input.

convert_to_binary(Input) when Input =/= '_' ->
    utils:to_binary(Input);
convert_to_binary(Input) ->
    Input.

to_jsonable_term(TP) ->
    Fields = record_info(fields, crash_entry),
    [_Tag | Values] = tuple_to_list(TP),
    lists:zip(Fields, Values).

recordslist_to_json(RecordsList) ->
    RecListJsonableTerm = lists:map(
        fun(Record) ->
            to_jsonable_term(Record)
        end,
        RecordsList),
    jsx:encode(RecListJsonableTerm).

%% @private
%% @doc Opposite of init.
-spec terminate(Reason :: any(), State :: #crash_monitor_state{}) -> any().
terminate(Reason, _State) ->
    lager:warning("Crash Monitor Stopped ~p", [Reason]),
    ok.

%% @private
%% @doc Convert process state when code is changed
-spec code_change(OldVsn :: any(), State :: #crash_monitor_state{}, Extra :: any()) ->
                         {ok, NewState :: #crash_monitor_state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
