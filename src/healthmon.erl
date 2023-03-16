%% ----------------------------------------------------------------------------------------
%% @author Hritik Soni <hritik.s@greyorange.sg>
%% @doc gen_statem for health monitoring agent
%% @end
%% ----------------------------------------------------------------------------------------

-module(healthmon).

-behaviour(gen_statem).

-compile(export_all).

-include("include/healthmon.hrl").

%% TODO: Right now healthmon supports only one node
%% But can be easily extended to support multiple nodes
%% Use appmon pid to find node names properly using a map

%% TODO: cleanup crashed components that crashed long time back
%% do this for all comps periodically 
%%  i.e. ideally crashes should keep occurring atleast every 30 secs
%%  for system to have detectable bad health

%% TODO: separate appmon related part from healthmon because a crash can destroy current graph

%% TODO: Include lager for better logging in the app itself and not rely on external people

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link() ->
    gen_statem:start_link({global, ?MODULE}, ?MODULE, [], []).


get_comp_graph() ->
    gen_statem:call({global, ?MODULE}, get_comp_graph).

get_node_data() ->
    gen_statem:call({global, ?MODULE}, get_node_data).

patch_component(Name, AttrValList) ->
    gen_statem:cast({global, ?MODULE}, {patch_component, Name, AttrValList}).

update_appmon(AppmonPid) ->
    gen_statem:cast({global, ?MODULE}, {update_appmon, AppmonPid}).

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
    CompGraph = digraph:new([acyclic]),
    digraph:add_vertex(CompGraph, {system, universal}),
    {ok, AppmonPid} = appmon_watcher:get_appmon_pid(),
    UpdatedState =
        StateData#healthmon_state{
            appmon = AppmonPid,
            comp_graph = CompGraph
        },
    SystemComponent =
        #component{
            comp_name = {system, universal},
            node = undefined,
            type = system
        },
    mnesia:dirty_write(SystemComponent),
    GCInterval = application:get_env(healthmon, gc_interval, 10000),
    {next_state, ready, UpdatedState,
        [{{timeout, refresher}, 5000, {fetch_component_tree}},
            {{timeout, gc}, GCInterval, {run_cleanup}}]};

handle_event(cast, {patch_component, Name, AttrValList}, ready, StateData) ->
    component:patch(Name, AttrValList, StateData#healthmon_state.comp_graph),
    keep_state_and_data;

handle_event(cast, {update_appmon, AppmonPid}, _, StateData) ->
    {keep_state, StateData#healthmon_state{appmon = AppmonPid}};

handle_event({timeout, refresher}, {fetch_component_tree}, ready, StateData) ->
    CompGraph = StateData#healthmon_state.comp_graph,
    digraph:add_vertex(CompGraph, {node(), universal}),
    add_edge_if_not_exists(CompGraph, {system, universal}, {node(), universal}),
    NodeComponent =
        #component{
            comp_name = {node(), universal},
            type = node
        },
    component:update(NodeComponent, CompGraph,
        #{update_source => appmon, propagate_health => true}),
    appmon_info2:app_ctrl(StateData#healthmon_state.appmon, node(), true, []),
    AppmonRefreshInterval = application:get_env(healthmon, appmon_refresh_interval, 30000),
    {keep_state_and_data,
        [{{timeout, refresher}, AppmonRefreshInterval, {fetch_component_tree}}]}; %%TODO: Move this timeout to app delivery

%% TODO: This cleanup can run in a separate process
handle_event({timeout, gc}, {run_cleanup}, ready, StateData) ->
    ProcessComps = mnesia:dirty_select(component,
                    [{#component{
                            type = process,
                            _='_'}, [], ['$_']}]),
    CompGraph = StateData#healthmon_state.comp_graph,
    lists:foreach(
        fun(Comp) ->
            CompName = Comp#component.comp_name,
            CleanupThreshold =
                case component:is_name_regd(CompName) of
                    true -> application:get_env(healthmon, regd_cleanup_threshold, 300);
                    false -> application:get_env(healthmon, regd_cleanup_threshold, 60)
                end,
            case component:is_updated_recently(Comp, CleanupThreshold) of
                true -> ok;
                false ->
                    mnesia:dirty_delete({component, CompName}),
                    digraph:del_vertex(CompGraph, Comp#component.comp_name)
                    %% TODO: use update api here so that health can be properly propagated
                    %% Since during refresh health propragation is already done hence not necessary
            end
        end,
    ProcessComps),
    CrashedUnknownComps = mnesia:dirty_select(component,
                    [{#component{
                            type = process,
                            app_name = undefined,
                            health = crashed,
                            _='_'}, [], ['$_']}]),
    MaxUnknownCrashedProcesses = application:get_env(healthmon, max_unknown_crashed_processes, 100),
    {_Comps, CleanupComps} =
        case length(CrashedUnknownComps) > MaxUnknownCrashedProcesses of
            true ->
                SortedComps =
                    component:sort_by_updated_time(CrashedUnknownComps),
                lists:split(MaxUnknownCrashedProcesses, SortedComps);
            false -> {CrashedUnknownComps, []}
        end,
    lists:foreach(
        fun(Comp) ->
            mnesia:dirty_delete({component, Comp#component.comp_name}),
            digraph:del_vertex(CompGraph, Comp#component.comp_name)
        end,
        CleanupComps),
    GCInterval = application:get_env(healthmon, gc_interval, 10000),
    {keep_state_and_data,  [{{timeout, gc}, GCInterval, {run_cleanup}}]};

handle_event({call, From}, get_comp_graph, ready, StateData) ->
    {keep_state_and_data,
        [{reply, From, {ok, StateData#healthmon_state.comp_graph}}]};

handle_event({call, From}, get_node_data, ready, StateData) ->
    {keep_state_and_data,
        [{reply, From, {ok, StateData#healthmon_state.node_data}}]};

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
                    appmon_info2:app(StateData#healthmon_state.appmon,
                                        AppName, true, [])
            end
        end,
    NodeData),
    {keep_state, StateData#healthmon_state{node_data = NodeData}};

%% TODO: Cleanup apps as well along with processes
handle_event(info, {delivery, _, app, AppName,
                {Root, P2Name, Links, _XLinks0}}, _StateName, StateData) when Root =/= "" ->
    RootPid = list_to_pid(Root),
    CompGraph = StateData#healthmon_state.comp_graph,
    RegName = get_registered_name(RootPid),
    digraph:add_vertex(CompGraph, RegName),
    add_edge_if_not_exists(CompGraph, {node(), universal}, RegName),
    AppComponent =
        case mnesia:dirty_read(component, RegName) of
            [] ->
                #component{
                    pid = RootPid,
                    comp_name = RegName,
                    app_name = AppName,
                    type = process
                };
            [ExistingComp] ->
                ExistingComp#component{
                    pid = RootPid,
                    app_name = AppName
                }
        end,
    component:update(AppComponent, CompGraph,
            #{update_source => appmon, propagate_health => true}),

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
                    component:update(Comp, CompGraph,
                            #{update_source => appmon, propagate_health => true})
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
                                    case process_info(Comp#component.pid, ProcessInfoKeys) of
                                        undefined -> ok;
                                        MetaPropList ->
                                            component:patch_metadata(Comp, maps:from_list(MetaPropList))
                                    end,
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
    MaxExitedPids = application:get_env(healthmon, max_exited_pids, 1000),
    {_Comps, CleanupComps} =
        case length(ExitedCompsRecent) > MaxExitedPids of
            true ->
                SortedComps =
                    component:sort_by_updated_time(ExitedCompsRecent),
                lists:split(MaxExitedPids, SortedComps);
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
        _ ->
            get_gproc_name(Pid)
    end.

get_gproc_name(Pid) when is_pid(Pid) ->
    {gproc, KV} = gproc:info(Pid, {gproc,{n, '_', '_'}}),
    case KV of
        [] -> {Pid, global};
        KV ->
            {{n, _, Name}, _} = hd(KV),
            {Name, gproc}
    end;

get_gproc_name(Pid) -> {Pid, global}.


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
                                    SibComp#component.health =:= good orelse
                                        SibComp#component.health =:= exited
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
    [local, global, gproc, universal].

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