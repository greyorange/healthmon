-module(component).

-compile(export_all).

-include("include/healthmon.hrl").

recordslist_to_json(RecordsList) ->
    jsx:encode(recordslist_to_jsonable_term(RecordsList)).

recordslist_to_jsonable_term(RecordsList) ->
    lists:map(
        fun(Record) ->
            {serialize(Record#?MODULE.comp_key),
                to_jsonable_term(Record)}
        end,
        RecordsList).

to_json(Comp) ->
    jsx:encode(to_jsonable_term(Comp)).

to_jsonable_term(Comp) ->
    Fields = record_info(fields, ?MODULE),
    [_Tag | RawValues] = tuple_to_list(Comp),
    lists:zip(Fields, lists:map(fun serialize/1, RawValues)).

serialize(Val) when is_pid(Val) ->
    list_to_binary(pid_to_list(Val));
serialize(Val) when is_atom(Val) ->
    Val;
serialize(Val) when is_map(Val) ->
    Val;
serialize(Val) when is_binary(Val) ->
    Val;
serialize(Val) when is_list(Val) ->
    list_to_binary(Val);
serialize(Val) ->
    list_to_binary(prettypr:format(
        erl_prettypr:best(
            erl_syntax:abstract(Val)))).