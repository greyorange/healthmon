-record(healthmon_state, {
    process_tree = undefined
}).

-type event_type()            :: gen_statem:event_type() | enter_specific.
-type event_name()            :: atom().
-type state_name()            :: atom().
-type state_function_result() :: gen_statem:event_handler_result(state_name()).
-type event_handler_result()  :: state_function_result().