-module(healthmon_utils).

-compile(export_all).

-spec to_binary(term()) -> binary().
to_binary(Input) when is_atom(Input) ->
    atom_to_binary(Input, utf8);
to_binary(Input) when is_integer(Input) ->
    integer_to_binary(Input);
to_binary(Input) when is_float(Input) ->
    float_to_binary(Input, [{decimals, 10}, compact]);
to_binary(Input) when is_list(Input) ->
    list_to_binary(Input);
to_binary(Input) when is_pid(Input) ->
    list_to_binary(pid_to_list(Input));
to_binary(Input) ->
    Input.

-spec to_list(term()) -> list().
to_list(Value) when is_atom(Value) ->
    atom_to_list(Value);
to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_list(Value) when is_integer(Value) ->
    integer_to_list(Value);
to_list(Value) when is_pid(Value) ->
    pid_to_list(Value);
to_list(Value) when is_list(Value) ->
    Value.

-spec get_time_difference(calendar:datetime(), calendar:datetime()) -> number().
get_time_difference(X, Y) ->
    T1 = calendar:datetime_to_gregorian_seconds(X),
    T2 = calendar:datetime_to_gregorian_seconds(Y),
    T1 - T2.

-spec convert_to_string(any()) -> list().
convert_to_string(Input) ->
    Output =
        if
            is_integer(Input) ->
                integer_to_list(Input);
            is_atom(Input) ->
                atom_to_list(Input);
            is_binary(Input) ->
                binary_to_list(Input);
            is_float(Input) ->
                float_to_list(Input);
            is_bitstring(Input) ->
                bitstring_to_list(Input);
            is_pid(Input) ->
                pid_to_list(Input);
            is_tuple(Input) ->
                lists:flatten(io_lib:format("~p", [Input]));
            is_list(Input) ->
                case io_lib:char_list(Input) of
                    true ->
                        Input;
                    false ->
                        lists:flatten(io_lib:format("~p", [Input]))
                end;
            true ->
                lists:flatten(io_lib:format("~p", [Input]))
        end,
    Output.
