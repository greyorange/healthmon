%% ----------------------------------------------------------------------------------------
%% @author Hritik Soni <hritik.s@greyorange.sg>
%% @doc gen_statem for health monitoring agent
%% @end
%% ----------------------------------------------------------------------------------------

-module(healthmon).

-behaviour(gen_statem).

-compile(export_all).

-include("include/healthmon.hrl").

-import(utils, [get_time_difference/2]).

%% TODO: Right now healthmon supports only one node
%% But can be easily extended to support multiple nodes
%% Use appmon pid to find node names properly using a map

%% TODO: cleanup crashed components that crashed long time back
%%  i.e. ideally crashes should keep occurring atleast every 30 secs
%%  for system to have detectable bad health

%% TODO: Include lager for better logging

-define (MAX_EXITED_PIDS, 1000).
-define (MAX_BAD_COMPS, 1000).
-define (EXITED_CLEANUP_THRESHOLD, 300). % in secs

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link() ->
    gen_statem:start_link({global, ?MODULE}, ?MODULE, [], []).


get_comp_graph() ->
    gen_statem:call({global, ?MODULE}, get_comp_graph).

% update_component_attributes(Name, AttrValList) ->
%     gen_statem:cast({global, ?MODULE}, {update_component_attributes, Name, AttrValList, #{}}).

patch_component(Name, AttrValList) ->
    gen_statem:cast({global, ?MODULE}, {patch_component, Name, AttrValList}).

get_component_tree_map() ->
    {ok, CompGraph} = get_comp_graph(),
    get_component_tree_map(CompGraph).

get_component_tree_map(CompGraph) ->
    Fun = 
        fun(_Vertex = {Name, _NS}) ->
            to_binary(Name)
        end,
    get_comp_map(CompGraph, Fun, {system, universal}).

get_component_name_map() ->
    {ok, CompGraph} = get_comp_graph(),
    Fun = 
        fun(Vertex) ->
            case mnesia:dirty_read(?COMPONENT_MODEL, Vertex) of
                [] -> to_binary(Vertex);
                [Comp] ->
                    {Name, _Namespace} = Comp#component.comp_name,
                    to_binary(Name)
            end
        end,
    get_comp_map(CompGraph, Fun, {system, universal}).

% register_comp({Name, Namespace}, Options) ->
    

% heartbeat(CompName) ->
    


%%%===================================================================
%%% gen_statem callbacks
%%%==================================================================

callback_mode() ->
    handle_event_function.

%% @private
%% @doc Initializes the server
init([]) ->
    lager:info("Starting healthmon"),
    InitState = #healthmon_state{},
    {ok, initializing, InitState, [{next_event, cast, {initialize}}]}.

%% @private

-spec handle_event(event_type(), any(), state_name(), #healthmon_state{}) -> state_function_result().


handle_event(cast, {initialize}, initializing, StateData) ->
    case mnesia:create_table(component,
        [{ram_copies, [node()]},
         {index, [type, health, pid]},
         {attributes, record_info(fields, component)}]) of
        {atomic, ok} -> ok;
        {aborted,{already_exists,component}} -> ok
    end,
    case ets:info(simple_cache_information_query_cache) of
        undefined ->
            simple_cache:init(information_query_cache);
        _ -> ok
    end,
    {ok, P} = appmon_info:start_link(node(), self(), []),
    CompGraph = digraph:new([acyclic]),
    digraph:add_vertex(CompGraph, {system, universal}),
    digraph:add_vertex(CompGraph, {node(), universal}),
    digraph:add_edge(CompGraph, {system, universal}, {node(), universal}),
    UpdatedState =
        StateData#healthmon_state{
            appmon = P,
            comp_graph = CompGraph
        },
    SystemComponent =
        #component{
            comp_name = {system, universal},
            node = undefined,
            type = system
        },
    NodeComponent =
        #component{
            comp_name = {node(), universal},
            type = node
        },
    mnesia:dirty_write(SystemComponent),
    mnesia:dirty_write(NodeComponent),
    appmon_info:app_ctrl(P, node(), true, []),
    {next_state, ready, UpdatedState,
        [{state_timeout, 10000, {fetch_component_tree}}]};

handle_event(cast, {update_component_attributes, Name, AttrValList, Options}, ready, StateData) ->
    CompGraph = StateData#healthmon_state.comp_graph,
    AttrList = record_info(fields, ?COMPONENT_MODEL),
    BaseComp =
        case maps:get(namespace, Options, undefined) of
            undefined ->
                Res = lists:map(
                    fun(Namespace) ->
                        mnesia:dirty_read(?COMPONENT_MODEL, {Name, Namespace})   
                    end,
                get_standard_namespaces()),
                FlattenedResults = lists:flatten(Res),
                case FlattenedResults of
                    [] -> %% assume global namespace
                        component({Name, global});
                    _ ->
                        hd(FlattenedResults) %% return any existing one
                end;
            Namespace ->
                case mnesia:dirty_read(?COMPONENT_MODEL, {Name, Namespace}) of
                    [Comp] -> Comp;
                    [] ->
                        component({Name, Namespace}) %% TODO: add pid here, get from opts
                end
        end,
    CompName = BaseComp#component.comp_name,
    case digraph:vertex(CompGraph, CompName) of
        false ->
            add_vertex(CompGraph, {system, universal}, CompName);
        _ -> ok
    end,
    UpdatedComp =
        lists:foldl(
            fun({Col, Value}, Acc) ->
                setelement(db_functions:get_index(Col, AttrList) + 1, Acc, Value)
            end,
        BaseComp,
        AttrValList),
    component:update(UpdatedComp, CompGraph),
    keep_state_and_data;

handle_event(cast, {patch_component, Name, AttrValList}, ready, StateData) ->
    component:patch(Name, AttrValList, StateData#healthmon_state.comp_graph),
    keep_state_and_data;

handle_event(EventType, {fetch_component_tree}, ready, StateData) when
                EventType =:= state_timeout;
                EventType =:= cast ->
    appmon_info:app_ctrl(StateData#healthmon_state.appmon, node(), true, []),
    {keep_state_and_data,  [{state_timeout,
        10000, {fetch_component_tree}}]}; %%TODO: Move this timeout to app delivery

handle_event({call, From}, get_comp_graph, ready, StateData) ->
    {keep_state_and_data,
        [{reply, From, {ok, StateData#healthmon_state.comp_graph}}]};

handle_event({call, From}, _Message, ready, _StateData) ->
    {keep_state_and_data,
        [{reply, From, {error, not_handled}}]};

handle_event({call, From}, _Message, _StateName, _StateData) ->
    {keep_state_and_data,
        [{reply, From, {error, not_ready}}]};

handle_event(info, {delivery, _, app_ctrl, _Node, NodeData}, _StateName, StateData) ->
    lists:foreach(
        fun({_, AppName, _}) ->
            case lists:member(AppName, get_ignored_apps()) of
                true -> ok;
                _ ->
                    appmon_info:app(StateData#healthmon_state.appmon,
                                        AppName, true, [])
            end
        end,
    NodeData),
    keep_state_and_data;

handle_event(info, {delivery, _, app, AppName, AppData}, _StateName, StateData) ->
    % io:format("A:~p, ~p", [AppName, is_atom(AppName)]),
    {Root, P2Name, Links, _XLinks0} = AppData,
    RootPid = list_to_pid(Root),
    CompGraph = StateData#healthmon_state.comp_graph,
    case digraph:vertex(CompGraph, RootPid) of
        false ->
            RegName = get_registered_name(RootPid),
            %% TODO: see if calling this again adds multiple vertices
            digraph:add_vertex(CompGraph, RegName),
            %% TODO: If this edge already exists then don't add again
            add_edge_if_not_exists(CompGraph, {node(), universal}, RegName),
            AppComponent =
                #component{
                    pid = RootPid,
                    comp_name = RegName,
                    app_name = AppName,
                    type = app
                },
                mnesia:dirty_write(AppComponent);
        _ -> ok
    end,

    %% P2Name contains pid to name mappings for
    %% locally registered processes
    %% For globally registered processes, need to
    %% use the ets global_pid_names
    %% Updated compinfos with globally registered processes
    Fam = sofs:relation_to_family(sofs:relation(Links)),
    Name2P = maps:from_list([{Name,Pid} || {Pid,Name} <- P2Name]),
    %% We need Name2P because we still need to insert the pids in comp_info
    OrdDict = sofs:to_external(Fam),
    update_comp_graph(OrdDict, Name2P,
        CompGraph, AppName),
    {keep_state, StateData};

handle_event(EventType, Event, StateName, _StateData) ->
    io:format("Unhandled event: ~p of type: ~p received in state: ~p", [Event, EventType, StateName]),
    keep_state_and_data.

%% @private
%% @doc Opposite of init.
terminate(_Reason, _StateName, _State) ->
    {atomic, ok} = mnesia:delete_table(component),
    ok.


update_comp_graph(OrdDict, N2P, CompGraph, AppName) ->
%% traverse through the OrdDict and update compinfos and comp_graph
%% since OrdDict already has everything in name form for locally registered processes,
%% all we need to do is to check if they are registered in global namespace
    lists:foreach(
        fun({Parent, Children}) ->
            lists:foreach(
                fun("port " ++_) -> ok; %% skip ports
                (Child) ->
                    %% if N2P doesn't contain the parent
                    %% then there will be a crash
                    %% Need to make sure we get a proper pid here
                    ParentPid = to_pid(maps:get(Parent, N2P)),
                    ChildPid = to_pid(maps:get(Child, N2P)),
                    %% if parent doesn't exist, then create it
                    ParentName = get_registered_name(Parent),
                    add_component(CompGraph,
                        #component{
                            comp_name = ParentName,
                            app_name = AppName,
                            pid = ParentPid
                        }),
                    ChildName = get_registered_name(Child),
                    Comp =
                        case mnesia:dirty_read(component, ChildName) of
                            [] ->
                                add_vertex(CompGraph, ParentName, ChildName),
                                component(ChildName, AppName);
                            [ExistingComp] ->
                                replace_parent(CompGraph, ChildName, ParentName),
                                ExistingComp#component{
                                    pid = ChildPid,
                                    app_name = AppName
                                }
                        end,
                    component:update(Comp, CompGraph)
                    %% Instead of adding children everytime, check if pids with 
                    %% same registered name exist, if yes then update the same entry both
                    %% in table as well as graph 
                end,
            Children)
        end,
    OrdDict),

    %% Cleanup Pids
    ExistingAppComps = mnesia:dirty_select(component,
                    [{#component{
                            app_name = AppName,
                            _='_'}, [], ['$_']}]),
    
    CurrentPids = lists:map(fun to_pid/1, maps:values(N2P)),
    CurrentPidSet = sets:from_list(CurrentPids),
    {ExitedComps, CrashedComps} =
        lists:foldl(
            fun(Comp, {ExCompsAcc, CrCompsAcc}) ->
                    case lists:member(Comp#component.health, get_bad_health_states()) of 
                        true ->
                            propagate_bad_health(Comp, CompGraph),
                            {ExCompsAcc, [Comp|CrCompsAcc]};
                        false ->
                            case sets:is_element(Comp#component.pid, CurrentPidSet) of
                                true ->
                                    %% update component metadata
                                    ProcessInfoKeys = [message_queue_len, current_function,
                                        total_heap_size, stack_size, reductions],
                                    MetaPropList = process_info(Comp#component.pid, ProcessInfoKeys),
                                    component:patch_metadata(Comp, maps:from_list(MetaPropList)),
                                    {ExCompsAcc, CrCompsAcc};
                                false ->
                                    mnesia:dirty_write(Comp#component{health = exited}),
                                    {[Comp|ExCompsAcc], CrCompsAcc}
                            end
                    end
            end,
        {[], []},
        ExistingAppComps),
    {ExitedCompsRecent, ExCompsStale} =
        lists:partition(
            fun component:is_updated_recently/1,
        ExitedComps),
    {CrashedCompsRecent, CrCompsStale} =
        lists:partition(
            fun component:is_updated_recently/1,
        CrashedComps),
        %% TODO: Merge this in above select clause
    {_Comps, CleanupComps} =
        case length(ExitedCompsRecent) > ?MAX_EXITED_PIDS of
            true ->
                SortedComps =
                    component:sort_by_updated_time(ExitedCompsRecent),
                lists:split(?MAX_EXITED_PIDS, SortedComps);
            false -> {ExitedCompsRecent, []}
        end,
    MaxCrashedComps = application:get_env(healthmon, max_crashed_comps, 5000),
    {_, CleanupCrComps} = %% sort by updated time here and above as well maybe
        case length(CrashedCompsRecent) > MaxCrashedComps of
            true ->
                SortedCrComps =
                    component:sort_by_updated_time(CrashedCompsRecent),
                lists:split(MaxCrashedComps, SortedCrComps);
            false -> {CrashedCompsRecent, []}
        end,
    lists:foreach(
        fun(Comp) ->
            mnesia:dirty_delete({component, Comp#component.comp_name}),
            digraph:del_vertex(CompGraph, Comp#component.comp_name)
        end,
    CleanupComps ++ CleanupCrComps ++ ExCompsStale ++ CrCompsStale).
    %% TODO: Cleanup entries from table (and graph) which are no longer in OrdDict wisely
        %% to keep number of components to a bounded limit 

    %% Leave the registered ones (unless they exceed the specified threshold)
    %% This can be done by first collecting all the pids belonging to that app in table
    %% inside a set and then from it we can subtract the Pids coming from OrdDict
    %% This will give us exited/dead processes including both registered and un-regsitered ones 

get_ignored_apps() ->
    [kernel, ssl, inets].

get_registered_name(Pid) ->
    case Pid of
        Pid when is_pid(Pid) ->
            get_global_name(Pid);    
        Pid when is_list(Pid)  ->
            case Pid of
                "<" ++ _ ->
                    Pid1 = list_to_pid(Pid),
                    get_global_name(Pid1);
                _ -> {Pid, local}
            end;
        _ -> {Pid, local}
    end.

get_global_name(Pid) -> 
    case ets:lookup(global_pid_names, Pid) of
        [{_, Name}] -> {Name, global};
        _ -> {Pid, undefined}
    end.

component(Name) ->
    #component{
        comp_name = Name
    }.

component(Name, AppName) ->
    #component{
        comp_name = Name,
        app_name = AppName
    }.

get_crashed_components() ->
    mnesia:dirty_select(component,
        [{#component{health = crashed, _='_'}, [], ['$_']}]).

get_components_by_name(Name) ->
    mnesia:dirty_select(component,
        [{#component{comp_name = Name, _='_'}, [], ['$_']}]).

get_comp_map(CompGraph, Fun, Vertex) ->
    [Comp] = mnesia:dirty_read(component, Vertex),
    Attributes = component:to_jsonable_term(Comp),
    OutNbs = digraph:out_neighbours(CompGraph, Vertex),
    case OutNbs of
        [] -> 
            #{
                <<"name">> => Fun(Vertex),
                <<"attributes">> => Attributes
            };
        _ ->
            ChildMap =
                lists:map(
                    fun(V1) ->
                        get_comp_map(CompGraph, Fun, V1)
                    end,
                OutNbs),
            #{
                <<"name">> => Fun(Vertex),
                <<"children">> => ChildMap,
                <<"attributes">> => Attributes
            }
    end.

to_binary(Input) when is_atom(Input) ->
    atom_to_binary(Input, utf8);
to_binary(Input) when is_pid(Input) ->
    list_to_binary(pid_to_list(Input));
to_binary(Input) when is_integer(Input) ->
    integer_to_binary(Input);
to_binary(Input) when is_float(Input) ->
    float_to_binary(Input, [{decimals, 10}, compact]);
to_binary(Input) when is_list(Input) ->
    list_to_binary(Input);
to_binary(Input) ->
    list_to_binary(
        prettypr:format(
            erl_prettypr:best(
                erl_syntax:abstract(Input)))).

add_component(CompGraph, Comp) ->
    Name = Comp#component.comp_name,
    case digraph:vertex(CompGraph, Name) of
        false -> digraph:add_vertex(CompGraph, Name);
        _ -> ok
    end,
    case mnesia:dirty_read(?COMPONENT_MODEL, Name) of
        [] -> mnesia:dirty_write(Comp);
        _ -> ok
    end.

add_component(CompGraph, ParentCompName, Comp) ->
    Name = Comp#component.comp_name,
    add_vertex(CompGraph, ParentCompName, Name),
    case mnesia:dirty_read(?COMPONENT_MODEL, Name) of
        [] -> mnesia:dirty_write(Comp);
        _ -> ok
    end.

add_vertex(CompGraph, U, V) ->
    case digraph:vertex(CompGraph, V) of
        false ->
            digraph:add_vertex(CompGraph, V);
        _ -> ok
    end,
    add_edge_if_not_exists(CompGraph, U, V).

replace_parent(CompGraph, ChildV, ParentV) ->
    case digraph:vertex(CompGraph, ChildV) of
        false ->
            digraph:add_vertex(CompGraph, ChildV),
            digraph:add_edge(CompGraph, ParentV, ChildV);
        _ ->
            Edges = digraph:in_edges(CompGraph, ChildV),
            digraph:del_edges(CompGraph, Edges)
    end,
    digraph:add_edge(CompGraph, ParentV, ChildV).

add_edge_if_not_exists(Graph, U, V) ->
    OutNbs = digraph:out_neighbours(Graph, U),
    case lists:member(V, OutNbs) of
        true -> ok;
        false ->
            digraph:add_edge(Graph, U, V)
    end.

rename_vertex(CompGraph, OldPid, ChildPid) ->
    digraph:add_vertex(CompGraph, ChildPid),
    lists:foreach(
        fun(Vertex) ->
            add_edge_if_not_exists(CompGraph, ChildPid, Vertex)
        end,
        digraph:out_neighbours(CompGraph, OldPid)
    ),
    lists:foreach(
        fun(Vertex) ->
            add_edge_if_not_exists(CompGraph, Vertex, ChildPid)
        end,
        digraph:in_neighbours(CompGraph, OldPid)
    ),
    digraph:del_vertex(CompGraph, OldPid).

to_pid(Pid) when is_pid(Pid) ->
    Pid;
to_pid(Pid) when is_list(Pid) ->
    list_to_pid(Pid).

propagate_bad_health(Comp, CompGraph) ->
    CompName = Comp#component.comp_name,
    case digraph:in_neighbours(CompGraph, CompName) of
        [] -> ok;
        Nbs ->
            lists:foreach(
                fun(ParV) ->
                    [ParComp] = mnesia:dirty_read(component, ParV), 
                    case lists:member(ParComp#component.health,
                            get_bad_health_states()) of
                        true -> ok;
                        false ->
                            UpdatedComp = ParComp#component{health = bad},
                            mnesia:dirty_write(UpdatedComp),
                            propagate_bad_health(ParComp, CompGraph)
                    end
                end,
                Nbs)
    end.

propagate_good_health(Comp, CompGraph) ->
    UpdatedComp = Comp#component{health = good},
    mnesia:dirty_write(UpdatedComp),
    CompName = Comp#component.comp_name,
    case digraph:in_neighbours(CompGraph, CompName) of
        [] -> ok;
        Nbs ->
            lists:foreach(
                fun(ParV) ->
                    [ParComp] = mnesia:dirty_read(component, ParV), 
                    case ParComp#component.health of
                        good -> ok;
                        _ ->
                            Siblings = digraph:out_neighbours(CompGraph, ParV),
                            case lists:all(
                                fun(Sibling) ->
                                    [SibComp] = mnesia:dirty_read(component, Sibling),
                                    SibComp#component.health =:= good
                                end,
                            Siblings) of
                                true ->
                                    propagate_good_health(ParComp, CompGraph);
                                false -> ok
                            end
                    end
                end,
                Nbs)
    end.


get_standard_namespaces() ->
    [local, global, universal].

get_bad_health_states() ->
    [bad, crashed, stuck, starving].

get_component_information(CompRecs) ->
    {ok, CompGraph} = get_comp_graph(),
    SubGraph = digraph:new(),
    lists:foreach(
        fun(Comp) ->
            add_ancestry_to_graph(Comp#component.comp_name, SubGraph, CompGraph)
        end,
    CompRecs),
    get_component_tree_map(SubGraph).

add_ancestry_to_graph(K, G, S) ->
    case digraph:vertex(G, K) of
        false ->
            digraph:add_vertex(G, K),
            case digraph:in_neighbours(S, K) of
                [] -> ok;
                Nbs ->
                    lists:foreach(
                        fun(V) ->
                            add_ancestry_to_graph(V, G, S),
                            digraph:add_edge(G, V, K)
                        end,
                        Nbs)
            end;
        _ -> ok
    end.