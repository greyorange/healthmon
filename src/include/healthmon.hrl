-record(healthmon_state, {
    appmon,
    comp_graph
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


-type comp_type()             :: node | app | process | system.
-type comp_health()           :: unknown | good | bad | dead.

-type event_type()            :: gen_statem:event_type() | enter_specific.
-type event_name()            :: atom().
-type state_name()            :: atom().
-type state_function_result() :: gen_statem:event_handler_result(state_name()).
-type event_handler_result()  :: state_function_result().