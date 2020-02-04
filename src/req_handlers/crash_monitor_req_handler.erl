%%%-------------------------------------------------------------------
%%% @author Rajat singla
%%% @copyright (C) 2019, GreyOrange
%%% @doc Health Monitor User Interface
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(crash_monitor_req_handler).

-behaviour(trails_handler).

-export([
         init/2,
         trails/0,
         terminate/3
        ]).


trails() ->
    [trails:trail("/crash_monitor_report", ?MODULE, [])].

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
                CrashReport = station_recovery:get_crash_monitor_report(user_interface),
                {ok, B} = 'crash_monitor_report.html_dtl':render(
                            [
                             {dataList, CrashReport}
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
