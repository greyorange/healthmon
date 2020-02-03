-module(component).

-compile(export_all).

-include("include/healthmon.hrl").

-import(healthmon, [get_bad_health_states/0,
    propagate_bad_health/2, propagate_good_health/2]).

-import(utils, [get_time_difference/2]).

recordslist_to_json(RecordsList) ->
    jsx:encode(recordslist_to_jsonable_term(RecordsList)).

recordslist_to_jsonable_term(RecordsList) ->
    lists:map(
        fun(Record) ->
            {serialize(Record#?MODULE.comp_name),
                to_jsonable_term(Record)}
        end,
        RecordsList).

to_json(Comp) ->
    jsx:encode(to_jsonable_term(Comp)).

to_jsonable_term(Comp) ->
    Fields = record_info(fields, ?MODULE),
    [_Tag | RawValues] = tuple_to_list(Comp),
    ZippedComp = lists:zip(Fields, RawValues),
    lists:foldl(
        fun({Field, Val}, Acc) ->
            case Field of
                comp_name ->
                    {Name, Namespace} = Val,
                    Acc#{
                            name => serialize(Name),
                            namespace => serialize(Namespace) %% TODO: Add metadata here automatically
                        };
                _ -> Acc#{Field => serialize(Val)}
            end
        end,
        #{},
        ZippedComp).

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
serialize({Val1, NS}) when is_pid(Val1) ->
    serialize({list_to_binary(pid_to_list(Val1)), NS});
serialize(Val) ->
    list_to_binary(prettypr:format(
        erl_prettypr:best(
            erl_syntax:abstract(Val)))).

update(UpdatedComp, CompGraph) ->
    mnesia:dirty_write(
        UpdatedComp#component{
            update_time = calendar:universal_time()
        }),
    case lists:member(UpdatedComp#component.health,
            get_bad_health_states()) of
        true -> propagate_bad_health(UpdatedComp, CompGraph);
        false -> propagate_good_health(UpdatedComp, CompGraph)
    end.

patch_metadata(Comp, Meta) ->
    UpdatedMetaData = maps:merge(Comp#component.metadata, Meta),
    UpdatedComp = Comp#component{metadata = UpdatedMetaData},
    mnesia:dirty_write(UpdatedComp).

is_updated_recently(Comp) ->
    ExitedCleanupThreshold = application:get_env(healthmon, exited_cleanup_threshold, 300),
    case get_time_difference(calendar:universal_time(), Comp#component.update_time) of
        TimeDiff when TimeDiff > ExitedCleanupThreshold ->
            %% TODO: Also do this cleanup to central app independent
            %% because crash logger can provide app name as undefined
            % mnesia:dirty_delete({component, Comp#component.comp_name}),
            % digraph:del_vertex(CompGraph, Comp#component.comp_name),
            false;
        _ -> true
    end.