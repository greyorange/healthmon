-module(crash_monitor_watcher).

-behaviour(gen_server).

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
        code_change/3]).

-export([start_link/2]).

-record(state, {
        module :: atom(), %% handler to add on Sink (i.e. error_logger) that will listen to events send by sink
        sink :: pid() | atom() %% module that will send events to the installed handlers.
    }).

start_link(Sink, Module) ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [Sink, Module], []).

init([Sink, Module]) ->
    process_flag(trap_exit, true),
    install_handler(Sink, Module),
    {ok, #state{sink = Sink, module = Module}}.

handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({gen_event_EXIT, Module, normal}, #state{module = Module} = State) ->
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, shutdown}, #state{module = Module} = State) ->
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, {'EXIT', {kill_me, [_KillerHWM, KillerReinstallAfter]}}},
        #state{module = Module, sink = Sink} = State) ->
    %% Brutally kill the manager but stay alive to restore settings.
    %%
    %% SinkPid here means the gen_event process. Handlers *all* live inside the
    %% same gen_event process space, so when the Pid is killed, *all* of the
    %% pending log messages in its mailbox will die too.
    SinkPid = whereis(Sink),
    unlink(SinkPid),
    {message_queue_len, Len} = process_info(SinkPid, message_queue_len),
    error_logger:error_msg("Killing sink ~p, current message_queue_len:~p~n", [Sink, Len]),
    exit(SinkPid, kill),
    _ = timer:apply_after(KillerReinstallAfter, lager_app, start_handler, [Sink, Module]),
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, Reason}, #state{module = Module, sink = Sink} = State) ->
    case lager:log(error, self(), "Lager event handler ~p exited with reason ~s",
        [Module, error_logger_lager_h:format_reason(Reason)]) of
      ok ->
        install_handler(Sink, Module);
      {error, _} ->
        %% lager is not working, so installing a handler won't work
        ok
    end,
    {noreply, State};
handle_info(reinstall_handler, #state{module = Module, sink = Sink} = State) ->
    install_handler(Sink, Module),
    {noreply, State};
handle_info({reboot, Sink}, State) ->
    _ = lager_app:boot(Sink),
    {noreply, State};
handle_info(stop, State) ->
    {stop, normal, State};
handle_info({'EXIT', _Pid, killed}, #state{module = Module, sink = Sink} = State) ->
    Tmr = application:get_env(lager, killer_reinstall_after, 5000),
    _ = timer:apply_after(Tmr, lager_app, start_handler, [Sink, Module]),
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal
install_handler(Sink, lager_backend_throttle) ->
    %% The lager_backend_throttle needs to know to which sink it is
    %% attached, hence this admittedly ugly workaround. Handlers are
    %% sensitive to the structure of the configuration sent to `init',
    %% sadly, so it's not trivial to add a configuration item to be
    %% ignored to backends without breaking 3rd party handlers.
    install_handler2(Sink, lager_backend_throttle);
install_handler(Sink, Module) ->
    install_handler2(Sink, Module).

%% private
install_handler2(Sink, Module) ->
    case gen_event:add_sup_handler(Sink, Module, []) of
        ok ->
            lager:update_loglevel_config(Sink),
            ok;
        {error, {fatal, Reason}} ->
            %% tell ourselves to stop
            lager:debug("Can not install handler. Reason is : ~p", [Reason]),
            self() ! stop,
            ok;
        Error ->
            %% try to reinstall it later
            lager:debug("Error in installing handler : ~p", [Error]),
            erlang:send_after(5000, self(), reinstall_handler),
            ok
    end.
