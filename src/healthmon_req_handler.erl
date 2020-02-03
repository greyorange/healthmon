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

-include("include/healthmon.hrl").

trails() ->
    [trails:trail("/healthmon/information", ?MODULE, [])].

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
    Health = proplists:get_value(<<"health">>, ParsedQs),
    AppName = proplists:get_value(<<"app">>, ParsedQs),
    {Body, Code} =
        case PathInfo of
            undefined ->
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
                {jsx:encode(Output), 200};
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
