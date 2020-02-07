-record(healthmon_state, {
    appmon,
    comp_graph,
    node_data
}).

-define(COMPONENT_MODEL, component).

%% For processes, the component key is the process id in string
%% For applications, it is the pid of the application master
%% TODO: Add fields - node so that {comp_name, node} can be classified as unique 
-record(component, {
    comp_name                                   :: {term(), term()},
    app_name,
    node = node(),
    pid,
    type = process                              :: comp_type(),
    health = good                               :: comp_health(),
    metadata = #{}                              :: map(),
    update_time = calendar:universal_time()     :: calendar:datetime()     
}).

-record(crash_entry, {
    reason = undefined           :: binary() | undefined,  %% reason of crash in tuple form saved in binary format
    pid = undefined              :: binary() | undefined,  %% crash process pid saved in binary format
    count = 0                    :: integer(),             %% manage count of same crash
    registered_name = undefined  :: binary() | undefined,  %% registered name of crashed process saved in binary format
    time_stamp = undefined       :: calendar:datetime() | undefined, %% calendar universal time
    last_crash = undefined       :: any(), %% last crash
    metadata = undefined       :: any(), %% last state while crash
    last_event = undefined       :: any() %% last event to process
}).


-type comp_type()             :: node | app | process | system.
-type comp_health()           :: unknown | good | bad | dead.

-type event_type()            :: gen_statem:event_type() | enter_specific.
-type event_name()            :: atom().
-type state_name()            :: atom().
-type state_function_result() :: gen_statem:event_handler_result(state_name()).
-type event_handler_result()  :: state_function_result().