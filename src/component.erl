-module(component).

-compile(export_all).

-include("include/healthmon.hrl").

-import(healthmon, [get_bad_health_states/0,
    propagate_bad_health/2, propagate_good_health/2,
    get_standard_namespaces/0, component/1, add_vertex/3]).

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
    serialize_proplist(ZippedComp).

serialize_proplist(PList) ->
    lists:foldl(
        fun({Field, Val}, Acc) ->
            case Field of
                metadata when is_map(Val) ->
                    maps:merge(Acc, serialize_proplist(maps:to_list(Val)));
                Field when is_map(Val) ->
                    Acc#{
                        Field => serialize_proplist(maps:to_list(Val))
                    };
                comp_name ->
                    case Val of
                        undefined ->
                            Acc#{
                                    name => undefined,
                                    namespace => undefined %% TODO: Add metadata here automatically
                                };
                        {Name, Namespace} ->    
                            Acc#{
                                    name => serialize(Name),
                                    namespace => serialize(Namespace) %% TODO: Add metadata here automatically
                                }
                    end;
                update_time ->
                    Acc#{Field => Val};
                _ -> Acc#{Field => serialize(Val)}
            end
        end,
        #{},
        PList).


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

patch(Comp, AttrValList, CompGraph) when is_record(Comp, component) ->
    CompName = Comp#component.comp_name,
    case digraph:vertex(CompGraph, CompName) of
        false ->
            add_vertex(CompGraph, {system, universal}, CompName);
        _ -> ok
    end,
    AttrList = record_info(fields, ?COMPONENT_MODEL),
    UpdatedComp =
        lists:foldl(
            fun({Col, Value}, Acc) ->
                setelement(db_functions:get_index(Col, AttrList) + 1, Acc, Value)
            end,
        Comp,
        AttrValList),
    component:update(UpdatedComp, CompGraph);

patch(Name, AttrValList, CompGraph) ->
    Res = lists:map(
        fun(Namespace) ->
            mnesia:dirty_read(?COMPONENT_MODEL, {Name, Namespace})   
        end,
    get_standard_namespaces()),
    FlattenedResults = lists:flatten(Res),
    BaseComp =
        case FlattenedResults of
            [] -> %% assume global namespace
                component({Name, global});
            _ ->
                hd(FlattenedResults) %% return any existing one
        end,
    patch(BaseComp, AttrValList, CompGraph).

patch(Name, Namespace, AttrValList, CompGraph) ->
    BaseComp =
        case mnesia:dirty_read(?COMPONENT_MODEL, {Name, Namespace}) of
            [Comp] -> Comp;
            [] ->
                component({Name, Namespace}) %% TODO: add pid here, get from opts
        end,
    patch(BaseComp, AttrValList, CompGraph).

sort_by_updated_time(Comps) ->
    lists:sort(
        fun(CompA, CompB) ->
            CompA#component.update_time > 
                CompB#component.update_time
        end,
    Comps).

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