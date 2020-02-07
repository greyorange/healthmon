%%%-------------------------------------------------------------------
%%% @author Hritik Soni
%%% @end
%%%-------------------------------------------------------------------
-module(healthmon_req_handler).

-behaviour(trails_handler).

-export([
         init/2,
         trails/0,
         terminate/3
        ]).

-import(utils, [to_binary/1]).

-include("../include/healthmon.hrl").

trails() ->
    [trails:trail("/healthmon/[...]", ?MODULE, [])].

%% @private
%% @doc Initializes the butler_mnesia_req_handler
-spec init(cowboy_req:req(),any()) -> {ok, cowboy_req:req(),any()}.
init(Req, Opts) ->
    handle(Req, Opts).

%% @private
%% @doc handles request to view  health monitor contents in html

-spec handle(cowboy_req:req(),_) -> {'ok',cowboy_req:req(),_}.

handle(Req, State) ->
    PathInfo = cowboy_req:path_info(Req),
    ParsedQs = cowboy_req:parse_qs(Req),
    case ets:info(simple_cache_information_query_cache) of
        undefined ->
            simple_cache:init(information_query_cache);
        _ -> ok
    end,
    CacheFlushInterval = application:get_env(healthmon, api_cache_flush_interval, 10000),
    {Body, Code} =
        case PathInfo of
            [<<"information">>] ->
                Health = proplists:get_value(<<"health">>, ParsedQs),
                AppName = proplists:get_value(<<"app">>, ParsedQs),
                OutputFun =
                    fun() ->
                        PossAppName =
                            case AppName of
                                undefined -> '_';
                                AppName -> binary_to_atom(AppName, utf8)
                            end,
                        MatchSpec =
                            case Health of
                                <<"bad">> ->
                                    [{#component{health = stuck, app_name = PossAppName, _='_'}, [], ['$_']},
                                    {#component{health = bad, app_name = PossAppName, _='_'}, [], ['$_']},
                                    {#component{health = crashed, app_name = PossAppName, _='_'}, [], ['$_']},
                                    {#component{health = starving, app_name = PossAppName, _='_'}, [], ['$_']}];
                                _ ->
                                    [{#component{app_name = PossAppName, _='_'}, [], ['$_']}]
                            end,    
                        CompRecs = mnesia:dirty_select(component, MatchSpec),
                        Output = [healthmon:get_component_information(CompRecs)],
                        {jsx:encode(Output), 200}
                    end,
                case simple_cache:get(information_query_cache,
                    CacheFlushInterval, ParsedQs, OutputFun) of
                        {error, notfound} ->
                            OutputFun();
                        Result ->
                            Result
                end;
            [<<"which_applications">>] ->
                OutputFun =
                    fun() ->
                        {ok, NodeData} = healthmon:get_node_data(),
                        Output = 
                            lists:foldl(
                                fun({AppMasterPid, _, {AppName, Description, Vsn}}, Acc) ->
                                    Acc#{to_binary(AppName) => 
                                            #{
                                                description => to_binary(Description),
                                                vsn => to_binary(Vsn),
                                                master_pid => to_binary(AppMasterPid)
                                            }
                                        }
                                end,
                                #{},
                            NodeData),
                        {jsx:encode(Output), 200}
                    end,
                case simple_cache:get(information_query_cache,
                    CacheFlushInterval, running_apps, OutputFun) of
                        {error, notfound} ->
                            OutputFun();
                        Result ->
                            Result
                end;
            _ -> {"NOT FOUND", 404}
        end,
    Req3 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req3, State}.
%% @private
%% @doc returns ok on termination of butler_docs_template_handler
-spec terminate(Reason::any(), Request::cowboy_req:req(), State::any()) ->
                  ok.

terminate(_Reason, _Req, _State) ->
    ok.
