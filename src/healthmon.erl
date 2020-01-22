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

%% TODO: Include lager for better logging

-define (MAX_REGISTERED_EXITED_PIDS, 1000).
-define (MAX_UNREGISTERED_EXITED_PIDS, 1000).
%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link() ->
    gen_statem:start_link({global, ?MODULE}, ?MODULE, [], []).


get_comp_graph() ->
    gen_statem:call({global, ?MODULE}, get_comp_graph).

    

get_component_tree_map() ->
    {ok, CompGraph} = get_comp_graph(),
    get_component_tree_map(CompGraph).

get_component_tree_map(CompGraph) ->
    Fun = 
        fun(Vertex) ->
            to_binary(Vertex)
        end,
    get_comp_map(CompGraph, Fun, system).

get_component_name_map() ->
    {ok, CompGraph} = get_comp_graph(),
    Fun = 
        fun(Vertex) ->
            case mnesia:dirty_select(component,
                [{#component{comp_key= Vertex,
                    comp_name = '$1', _='_'},
                        [], ['$1']}]) of
                [] -> to_binary(Vertex);
                Res -> to_binary(hd(Res))
            end
        end,
    get_comp_map(CompGraph, Fun, system).
%%%===================================================================
%%% gen_statem callbacks
%%%==================================================================

callback_mode() ->
    handle_event_function.

%% @private
%% @doc Initializes the server
init([]) ->
    io:format("Starting healthmon"),
    InitState = #healthmon_state{},
    {ok, initializing, InitState, [{next_event, cast, {initialize}}]}.

%% @private

-spec handle_event(event_type(), any(), state_name(), #healthmon_state{}) -> state_function_result().


handle_event(cast, {initialize}, initializing, StateData) ->
    case mnesia:create_table(component,
        [{ram_copies, [node()]},
         {index, [comp_name, type, health]},
         {attributes, record_info(fields, component)}]) of
        {atomic, ok} -> ok;
        {aborted,{already_exists,component}} -> ok
    end,
    {ok, P} = appmon_info:start_link(node(), self(), []),
    CompGraph = digraph:new([acyclic]),
    digraph:add_vertex(CompGraph, system),
    digraph:add_vertex(CompGraph, node()),
    digraph:add_edge(CompGraph, system, node()),
    UpdatedState =
        StateData#healthmon_state{
            appmon = P,
            comp_graph = CompGraph
        },
    SystemComponent =
        #component{
            comp_key = system,
            comp_name = system,
            type = system
        },
    NodeComponent =
        #component{
            comp_key = node(),
            comp_name = atom_to_list(node()),
            type = node
        },
    mnesia:transaction(fun() ->
        mnesia:write(SystemComponent),
        mnesia:write(NodeComponent) end),
    appmon_info:app_ctrl(P, node(), true, []),
    {next_state, ready, UpdatedState,
        [{state_timeout, 10000,
            {fetch_component_tree}}]};

handle_event(EventType, {fetch_component_tree}, ready, StateData) when
                EventType =:= state_timeout;
                EventType =:= cast ->
    appmon_info:app_ctrl(StateData#healthmon_state.appmon, node(), true, []),
    {keep_state_and_data,  [{state_timeout,
        10000, {fetch_component_tree}}]}; %%TODO: Move this timeout to app delivery

handle_event({call, From}, test, ready, StateData) ->
    Res = StateData#healthmon_state.comp_graph,
    {keep_state_and_data,
        [{reply, From, {ok, Res}}]};

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
            %% TODO: see if calling this again adds multiple vertices
            digraph:add_vertex(CompGraph, RootPid),
            %% TODO: If this edge already exists then don't add again
            OutNbs = digraph:out_neighbours(CompGraph, node()),
            case lists:member(RootPid, OutNbs) of
                true -> ok;
                false ->
                    digraph:add_edge(CompGraph, node(), RootPid)
            end,
            %% TODO: Adjust here node() properly using the appmon pid
            AppComponent =
                #component{
                    comp_key = RootPid,
                    comp_name = atom_to_list(AppName),
                    app_name = AppName,
                    type = app
                },
            mnesia:transaction(fun() ->
                mnesia:write(AppComponent) end);
        _ -> ok
    end,

    %% P2Name contains pid to name mappings for
    %% locally registered processes
    %% For globally registered processes, need to
    %% use the ets global_pid_names
    % CompInfo =
    %     #component{
    %         comp_key = AppName,
    %         comp_name = atom_to_binary(AppName, utf8),
    %         type = app
    %     },
    % CompInfos = StateData#healthmon_state.comp_infos,
    % CompInfosWithApp =
    %     CompInfos#{
    %         AppName => CompInfo
    %     },
    %% delete all existings comp infos with this app name first,
    %% otherwise could leak memory
    % FilteredCompInfos =
    %     remove_compinfos_for_app_processes(
    %         CompInfosWithApp, AppName),
    %% Updated compinfos with globally registered processes
    Fam = sofs:relation_to_family(sofs:relation(Links)),
    Name2P = maps:from_list([{Name,Pid} || {Pid,Name} <- P2Name]),
    %% We need Name2P because we still need to insert the pids in comp_info
    OrdDict = sofs:to_external(Fam),
    update_comp_graph(OrdDict, Name2P,
        CompGraph, AppName),
    % CurCompTree = StateData#healthmon_state.component_tree,
    % Use P2Name to update comp infos
    % UpdatedCompInfos =
    %     lists:foldl(
    %         fun({Pid, Name}, MapAcc) ->
    %             MapAcc#{
    %                 Pid =>
    %                     #component{
    %                         comp_key = Pid,
    %                         comp_name = list_to_binary(Name),
    %                         type = process,
    %                         health = good,
    %                         info = #{app_name => AppName}
    %                     }
    %             }
    %         end,
    %     FilteredCompInfos,
    %     P2Name),
    % UpdatedStateData =
    %     StateData#healthmon_state{
    %         component_tree = CurCompTree#{
    %                             AppName => AppTree
    %                         },
    %         comp_infos = FilteredCompInfos
    %     },
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
                    case digraph:vertex(CompGraph, ParentPid) of
                        false -> digraph:add_vertex(CompGraph, ParentPid);
                        _ -> ok
                    end,
                    
                    digraph:add_vertex(CompGraph, ChildPid),
                    add_edge_if_not_exists(CompGraph, ParentPid, ChildPid),
                    CompName = get_global_name(Child),
                    case mnesia:dirty_select(component,
                            [{#component{
                                comp_name = CompName,
                                    app_name = AppName,
                                    _='_'}, [], ['$_']}]) of
                        [] ->
                            Comp = #component{
                                comp_key = ChildPid,
                                comp_name = CompName,
                                app_name = AppName,
                                type = process
                            },
                            mnesia:transaction(fun() ->
                                mnesia:write(Comp) end);
                        [ExistingComp] -> 
                            OldPid = ExistingComp#component.comp_key,
                            case OldPid of
                                ChildPid ->
                                    UpdatedComp = ExistingComp#component{
                                        health = good
                                    }, %% maybe update comp_info here
                                    mnesia:transaction(fun() ->
                                        mnesia:write(UpdatedComp) end);
                                _ ->
                                    %% pid has changed
                                    %% maybe process was restarted
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
                                    digraph:del_vertex(CompGraph, OldPid),
                                    UpdatedComp = ExistingComp#component{
                                        comp_key = ChildPid,
                                        health = good
                                    },
                                    mnesia:transaction(fun() ->
                                        mnesia:delete({component, OldPid}),
                                        mnesia:write(UpdatedComp) end)
                            end;
                        _ExistingComps ->
                            %% This is probably the case when same name is used for multiple namespaces
                            Comp = #component{
                                comp_key = ChildPid,
                                comp_name = CompName,
                                app_name = AppName,
                                type = process
                            },
                            mnesia:transaction(fun() ->
                                mnesia:write(Comp) end)           
                    end
                    
                    %% Instead of adding children everytime, check if pids with 
                    %% same registered name exist, if yes then update the same entry both
                    %% in table as well as graph 
                end,
            Children)
        end,
    OrdDict),


    ExistingPids = mnesia:dirty_select(component,
                    [{#component{
                            comp_key = '$1',
                            app_name = AppName,
                            _='_'}, [], ['$1']}]),
    CurrentPids = lists:map(fun to_pid/1, maps:values(N2P)),
    DeadPids = ExistingPids -- CurrentPids,
    {RegPids, UnregPids} =
        lists:partition(
            fun(Pid) ->
                [Comp] =
                    mnesia:dirty_read(component, Pid),
                    case Comp#component.comp_name of
                        CompName when is_pid(CompName) ->
                            false;
                        _ -> true
                    end
            end,
        DeadPids),
    {ExitedRegPids, CleanupRegPids} =
        case length(RegPids) > ?MAX_REGISTERED_EXITED_PIDS of
            true ->
                lists:split(?MAX_REGISTERED_EXITED_PIDS, RegPids);
            false -> {RegPids, []}
        end,
    {ExitedUnregPids, CleanupUnregPids} =
        case length(UnregPids) > ?MAX_UNREGISTERED_EXITED_PIDS of
            true ->
                lists:split(?MAX_UNREGISTERED_EXITED_PIDS, UnregPids);
            false -> {UnregPids, []}
        end,
    lists:foreach(
        fun(Pid) ->
            [Comp] =
                mnesia:dirty_read(component, Pid),
            UpdatedComp =
                Comp#component{
                    health = exited
                },
            mnesia:transaction(fun() ->
                mnesia:write(UpdatedComp) end)
        end,
    ExitedRegPids ++ ExitedUnregPids),
    lists:foreach(
        fun(Pid) ->
            mnesia:transaction(fun() ->
                mnesia:delete({component, Pid}) end),
            digraph:del_vertex(CompGraph, Pid)
        end,
    CleanupRegPids ++ CleanupUnregPids).
    %% TODO: Remove entries from table (and graph) which are no longer in OrdDict
    %% Leave the registered ones (unless they exceed the specified threshold)
    %% This can be done by first collecting all the pids belonging to that app in table
    %% inside a set and then from it we can subtract the Pids coming from OrdDict
    %% This will give us exited/dead processes including both registered and un-regsitered ones 

get_ignored_apps() ->
    [kernel, ssl, inets].

get_global_name(Pid) ->
    case Pid of
        "port " ++_ -> Pid;
        Pid when is_list(Pid);
                 is_pid(Pid) ->
            Pid1 =
                case Pid of
                    "<" ++ _ ->
                        list_to_pid(Pid);
                    _ -> Pid
                end,    
                case ets:lookup(global_pid_names, Pid1) of
                    [{_, Name}] -> Name;
                    _ -> Pid1
                end;
        _ -> Pid
    end.

get_comp_map(CompGraph, Fun, Vertex) ->
    OutNbs = digraph:out_neighbours(CompGraph, Vertex),
    case OutNbs of
        [] -> #{Fun(Vertex) => #{}};
        _ ->
            ChildMap =
                lists:foldl(
                    fun(V1, Acc) ->
                        maps:merge(Acc,
                            get_comp_map(CompGraph, Fun, V1))
                    end,
                #{},
                OutNbs),
            #{Fun(Vertex) => ChildMap}
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

add_edge_if_not_exists(Graph, U, V) ->
    OutNbs = digraph:out_neighbours(Graph, U),
    case lists:member(V, OutNbs) of
        true -> ok;
        false ->
            digraph:add_edge(Graph, U, V)
    end.

to_pid(Pid) when is_pid(Pid) ->
    Pid;
to_pid(Pid) when is_list(Pid) ->
    list_to_pid(Pid).

get_component_information(CompRecs) ->
    {ok, CompGraph} = get_comp_graph(),
    SubGraph = digraph:new(),
    lists:foreach(
        fun(Comp) ->
            CompKey = Comp#component.comp_key,
            add_ancestry_to_graph(CompKey, SubGraph, CompGraph)
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