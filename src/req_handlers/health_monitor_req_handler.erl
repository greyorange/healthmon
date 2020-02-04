%%%-------------------------------------------------------------------
%%% @author Ankit Varshney
%%% @copyright (C) 2019, GreyOrange
%%% @doc Health Monitor User Interface
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(health_monitor_req_handler).

-export([
         init/2,
         terminate/3
        ]).

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

    {Body, Code} =
        case PathInfo of
            undefined ->
                StarvingProcess = health_monitor:get_starved_process(#{<<"user_interface">> => true}),
                {ok, B} = 'starved_process.html_dtl':render(
                            [
                             {dataList, StarvingProcess}
                            ]),
                {B, 200};

            _ ->
                {"NOT FOUND", 404}
        end,
    Req3 = cowboy_req:reply(Code, #{}, Body, Req),
    {ok, Req3, State}.
%% @private
%% @doc returns ok on termination of butler_docs_template_handler
-spec terminate(Reason::any(), Request::cowboy_req:req(), State::any()) ->
                  ok.

terminate(_Reason, _Req, _State) ->
    ok.
