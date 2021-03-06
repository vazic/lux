%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Copyright 2012-2015 Tail-f Systems AB
%%
%% See the file "LICENSE" for information on usage and redistribution
%% of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(lux_interpret).

-include("lux.hrl").

-export([interpret_commands/3,
         default_istate/1,
         parse_iopts/2,
         config_type/1,
         set_config_val/5
        ]).
-export([opt_dispatch_cmd/1,
         lookup_macro/2,
         flush_logs/1]).

interpret_commands(Script, Cmds, Opts) ->
    I = default_istate(Script),
    I2 = I#istate{commands = Cmds, orig_commands = shrinked},
    try
        case parse_iopts(I2, Opts) of
            {ok, I3} ->
                LogDir = I3#istate.log_dir,
                Base = filename:basename(Script),
                ExtraLogs = filename:join([LogDir, Base ++ ".extra.logs"]),
                ExtraDict = "LUX_EXTRA_LOGS=" ++ ExtraLogs,
                GlobalDict = [ExtraDict | I3#istate.global_dict],
                I4 = I3#istate{global_dict = GlobalDict},
                Config = config_data(I4),
                case filelib:ensure_dir(LogDir) of
                    ok ->
                        ConfigFd =
                            lux_log:open_config_log(LogDir, Script, Config),
                        Progress = I4#istate.progress,
                        LogFun = I4#istate.log_fun,
                        Verbose = true,
                        case lux_log:open_event_log(LogDir, Script, Progress,
                                                    LogFun, Verbose) of
                            {ok, EventLog, EventFd} ->
                                Docs = docs(I4#istate.orig_file, Cmds),
                                eval(I4, Progress, Verbose, LogFun,
                                     EventLog, EventFd, ConfigFd, Docs);
                            {error, FileReason} ->
                                internal_error(I4,
                                               file:format_error(FileReason))
                        end;
                    {error, FileReason} ->
                        internal_error(I4, file:format_error(FileReason))
                end;
            {error, ParseReason} ->
                internal_error(I2, ParseReason)
        end
    catch
        error:FatalReason ->
            internal_error(I2, {'EXIT', FatalReason});
        Class:Reason ->
            internal_error(I2, {'EXIT', {fatal_error, Class, Reason}})
    end.

eval(OldI, Progress, Verbose, LogFun, EventLog, EventFd, ConfigFd, Docs) ->
    NewI = OldI#istate{event_log_fd =  {Verbose, EventFd},
                       config_log_fd = {Verbose, ConfigFd}},
    Flag = process_flag(trap_exit, true),
    try
        lux_log:safe_format(Progress, LogFun, undefined,
                            "~s~s\n",
                            [?TAG("script"),
                             NewI#istate.file]),
        lux_log:safe_format(Progress, LogFun, undefined,
                            "~s~s\n",
                            [?TAG("event log"), EventLog]),
        lux_utils:progress_write(Progress, ?TAG("progress")),
        ReplyTo = self(),
        Interpret =
            fun() ->
                    lux_debug:start_link(OldI#istate.debug_file),
                    Res = interpret_init(NewI),
                    lux:trace_me(70, 'case', shutdown, []),
                    unlink(ReplyTo),
                    ReplyTo ! {done, self(), Res},
                    exit(shutdown)
            end,
        Pid = spawn_link(Interpret),
        %% Poor mans hibernate
        ShrinkedI =
            NewI#istate{commands     = shrinked,
                        macro_dict   = shrinked,
                        global_dict  = shrinked,
                        builtin_dict = shrinked,
                        system_dict  = shrinked},
        garbage_collect(),
        wait_for_done(ShrinkedI, Pid, Docs)
    after
        process_flag(trap_exit, Flag),
        lux_log:close_event_log(EventFd),
        file:write(ConfigFd, "\n"), file:close(ConfigFd) % Don't care of failure
    end.

internal_error(I, ReasonTerm) ->
    ReasonBin = list_to_binary(io_lib:format("Internal error: ~p\n",
                                             [ReasonTerm])),
    fatal_error(I, ReasonBin).

fatal_error(I, ReasonBin) when is_binary(ReasonBin) ->
    FullLineNo = full_lineno(I, I#istate.latest_cmd, I#istate.cmd_stack),
    double_ilog(I, "~sERROR ~s\n",
                [?TAG("result"),
                 binary_to_list(ReasonBin)]),
    {error, I#istate.file, I#istate.log_dir, FullLineNo, ReasonBin}.

parse_iopts(I, [{Name, Val} | T]) when is_atom(Name) ->
    case parse_iopt(I, Name, Val) of
        {ok, I2} ->
            parse_iopts(I2, T);
        {error, Reason} ->
            {error, Reason}
    end;
parse_iopts(I, []) ->
    File = filename:absname(I#istate.file),
    case I#istate.shell_wrapper of
        "" -> ShellWrapper = undefined;
        ShellWrapper -> ok
    end,
    I2 = I#istate{file = File,
                  orig_file = File,
                  shell_wrapper = ShellWrapper,
                  log_dir = filename:absname(I#istate.log_dir)},
    {ok, I2}.

parse_iopt(I, Name, Val) when is_atom(Name) ->
    case config_type(Name) of
        {ok, Pos, Types} ->
            set_config_val(Name, Val, Types, Pos, I);
        {error, Reason} ->
            {error, Reason}
    end.

config_type(Name) ->
    case Name of
        debug  ->
            {ok, #istate.debug, [{atom, [true, false]}]};
        debug_file  ->
            {ok, #istate.debug_file, [string, {atom, [undefined]}]};
        skip ->
            {ok, #istate.skip, [{env_list, [string]}]};
        skip_unless ->
            {ok, #istate.skip_unless, [{env_list, [string]}]};
        require ->
            {ok, #istate.require, [{env_list, [string]}]};
        config_dir ->
            {ok, #istate.config_dir, [string]};
        progress ->
            {ok, #istate.progress,
             [{atom, [silent, brief, doc, compact, verbose]}]};
        log_dir ->
            {ok, #istate.log_dir, [string]};
        log_fun->
            {ok, #istate.log_fun, [{function, 1}]};
        log_fd->
            {ok, #istate.summary_log_fd, [io_device]};
        multiplier ->
            {ok, #istate.multiplier, [{integer, 0, infinity}]};
        suite_timeout ->
            {ok, #istate.suite_timeout, [{integer, 0, infinity},
                                         {atom, [infinity]}]};
        case_timeout ->
            {ok, #istate.case_timeout, [{integer, 0, infinity},
                                        {atom, [infinity]}]};
        flush_timeout ->
            {ok, #istate.flush_timeout, [{integer, 0, infinity}]};
        poll_timeout ->
            {ok, #istate.poll_timeout, [{integer, 0, infinity}]};
        timeout ->
            {ok, #istate.timeout, [{integer, 0, infinity},
                                   {atom, [infinity]}]};
        cleanup_timeout ->
            {ok, #istate.cleanup_timeout, [{integer, 0, infinity},
                                           {atom, [infinity]}]};
        shell_wrapper ->
            {ok, #istate.shell_wrapper, [string,
                                         {atom, [undefined]}]};
        shell_cmd ->
            {ok, #istate.shell_cmd, [string]};
        shell_args ->
            {ok, #istate.shell_args, [{reset_list, [string]}]};
        shell_prompt_cmd ->
            {ok, #istate.shell_prompt_cmd, [string]};
        shell_prompt_regexp ->
            {ok, #istate.shell_prompt_regexp, [string]};
        var ->
            {ok, #istate.global_dict, [{env_list, [string]}]};
        _ ->
            {error, lists:concat(["Bad argument: ", Name])}
    end.

set_config_val(Name, Val, [Type | Types], Pos, I) ->
    try
        case Type of
            string when is_list(Val) ->
                Val2 = expand_vars(I, Val, error),
                {ok, setelement(Pos, I, Val2)};
            binary when is_binary(Val) ->
                Val2 = expand_vars(I, Val, error),
                {ok, setelement(Pos, I, Val2)};
            binary when is_list(Val) ->
                Val2 = expand_vars(I, Val, error),
                set_config_val(Name, list_to_binary(Val2), [Type], Pos, I);
            {atom, Atoms} when is_atom(Val) ->
                true = lists:member(Val, Atoms),
                {ok, setelement(Pos, I, Val)};
            {atom, _Atoms} when is_list(Val) ->
                set_config_val(Name, list_to_atom(Val), [Type], Pos, I);
            {function, Arity} when is_function(Val, Arity) ->
                {ok, setelement(Pos, I, Val)};
            {integer, infinity, infinity} when is_integer(Val) ->
                {ok, setelement(Pos, I, Val)};
            {integer, infinity, Max}
              when is_integer(Val), is_integer(Max), Val =< Max ->
                {ok, setelement(Pos, I, Val)};
            {integer, Min, infinity}
              when is_integer(Val), is_integer(Min), Val >= Min ->
                {ok, setelement(Pos, I, Val)};
            {integer, Min, Max}
              when is_integer(Val), is_integer(Min), is_integer(Max),
                   Val >= Min, Val =< Max ->
                {ok, setelement(Pos, I, Val)};
            {integer, _Min, _Max} when is_list(Val) ->
                set_config_val(Name, list_to_integer(Val), [Type], Pos, I);
            {env_list, SubTypes} when is_list(SubTypes) ->
                set_config_val(Name, Val, SubTypes, Pos, I);
            {reset_list, SubTypes} when is_list(SubTypes) ->
                set_config_val(Name, Val, SubTypes, Pos, I);
            io_device ->
                {ok, setelement(Pos, I, Val)}
        end
    catch
        throw:{no_such_var, BadName} ->
            {error, lists:concat(["Bad argument: ", Name, "=", Val,
                                  "; $", BadName, " is not set"])};
        _:_ ->
            set_config_val(Name, Val, Types, Pos, I)
    end;
set_config_val(Name, Val, [], _Pos, _I) ->
    {error, lists:concat(["Bad argument: ", Name, "=", Val])}.

wait_for_done(I, Pid, Docs) ->
    receive
        {suite_timeout, SuiteTimeout} ->
            %% double_ilog(I, "\n~s~p\n",
            %%             [?TAG("suite timeout"),
            %%              SuiteTimeout]),
            Pid ! {suite_timeout, SuiteTimeout},
            case wait_for_done(I, Pid, Docs) of
                {ok, File, CaseLogDir, _Summary, FullLineNo, _Events} ->
                    ok;
                {error, File, CaseLogDir, FullLineNo, _} ->
                    ok
            end,
            {error, File, CaseLogDir, FullLineNo, <<"suite_timeout">>};
        {done, Pid, Res} ->
            lux_utils:progress_write(I#istate.progress, "\n"),
            case Res of
                {ok, I2} ->
                    handle_done(I, I2, Docs);
                {error, ReasonBin, I2} ->
                    I3 = post_ilog(I2, Docs),
                    fatal_error(I3, ReasonBin)
            end;
        {'EXIT', _Pid, Reason} ->
            I2 = post_ilog(I, Docs),
            internal_error(I2, {'EXIT', Reason})
    end.

handle_done(I, I2, Docs) ->
    I3 = post_ilog(I2, Docs),
    File = I3#istate.file,
    Results = I3#istate.results,
    case lists:keyfind('EXIT', 1, Results) of
        false ->
            case lists:keyfind(fail, #result.outcome, Results) of
                false ->
                    Reason = I3#istate.cleanup_reason,
                    if
                        Reason =:= normal;
                        Reason =:= success ->
                            print_success(I3, File, Results);
                        true ->
                            LatestCmd = I3#istate.latest_cmd,
                            CmdStack = I3#istate.cmd_stack,
                            R = #result{outcome    = fail,
                                        latest_cmd = LatestCmd,
                                        cmd_stack  = CmdStack,
                                        expected   = success,
                                        extra      = undefined,
                                        actual     = Reason,
                                        rest       = fail},
                            print_fail(I, File, Results, R)
                    end;
                #result{outcome = fail} = Fail ->
                    print_fail(I, File, Results, Fail)
            end;
        {'EXIT', Reason} ->
            internal_error(I3, {'EXIT', Reason})
    end.

print_success(I, File, Results) ->
    double_ilog(I, "~sSUCCESS\n", [?TAG("result")]),
    LatestCmd = I#istate.latest_cmd,
    FullLineNo = integer_to_list(LatestCmd#cmd.lineno),
    {ok, File, I#istate.log_dir, success, FullLineNo, Results}.

print_fail(I0, File, Results,
           #result{outcome    = fail,
                   latest_cmd = LatestCmd,
                   cmd_stack  = CmdStack,
                   expected   = Expected,
                   extra      = _Extra,
                   actual     = Actual,
                   rest       = Rest}) ->
    I = I0#istate{progress = silent},
    FullLineNo = full_lineno(I, LatestCmd, CmdStack),
    ResStr = double_ilog(I, "~sFAIL at ~s:~s\n",
                         [?TAG("result"), File, FullLineNo]),
    io:format("~s", [ResStr]),
    io:format("expected\n\t~s\n",
              [simple_to_string(Expected)]),
    double_ilog(I, "expected\n\"~s\"\n",
                [lux_utils:to_string(Expected)]),
    case Actual of
        <<"fail pattern matched ",    _/binary>> ->
            io:format("actual ~s\n\t~s\n",
                      [Actual, simple_to_string(Rest)]),
            double_ilog(I, "actual ~s\n\"~s\"\n",
                        [Actual, lux_utils:to_string(Rest)]);
        <<"success pattern matched ", _/binary>> ->
            io:format("actual ~s\n\t~s\n",
                      [Actual, simple_to_string(Rest)]),
            double_ilog(I, "actual ~s\n\"~s\"\n",
                        [Actual, lux_utils:to_string(Rest)]);
        _ when is_atom(Actual) ->
            io:format("actual ~p\n\t~s\n",
                      [Actual, simple_to_string(Rest)]),
            double_ilog(I, "actual ~p\n\"~s\"\n",
                        [Actual, lux_utils:to_string(Rest)]);
        _ when is_binary(Actual) ->
            io:format("actual error\n\t~s\n",
                      [simple_to_string(Actual)]),
            double_ilog(I, "actual error\n\"~s\"\n",
                        [lux_utils:to_string(Actual)])
    end,
    {ok, File, I#istate.log_dir, fail, FullLineNo, Results}.

full_lineno(I, #cmd{lineno = LineNo, type = Type}, CmdStack) ->
    RevFile = lux_utils:filename_split(I#istate.file),
    FullStack = [{RevFile, LineNo, Type} | CmdStack],
    lux_utils:pretty_full_lineno(FullStack).

flush_logs(I) ->
    flush_summary_log(I),
    multisync(I, flush).

flush_summary_log(#istate{summary_log_fd=undefined}) ->
    ok;
flush_summary_log(#istate{summary_log_fd=SummaryFd}) ->
    file:sync(SummaryFd).

post_ilog(#istate{logs = Logs, config_log_fd = {_, ConfigFd}} = I, Docs) ->
    lux_log:close_config_log(ConfigFd, Logs),
    log_doc(I, Docs),
    ilog(I, "\n", []),
    LogFun =
        fun(Bin) ->
                console_write(binary_to_list(Bin)),
                (I#istate.log_fun)(Bin),
                Bin
        end,
    I#istate{progress = silent,log_fun = LogFun}.

docs(File, OrigCmds) ->
    Fun =
        fun(#cmd{type = doc, arg = Arg}, _RevFile, _CmdStack, Acc)
           when tuple_size(Arg) =:= 2 ->
                [Arg | Acc];
           (_, _RevFile, _FileStack, Acc) ->
                Acc
        end,
    lists:reverse(lux_utils:foldl_cmds(Fun, [], File, [], OrigCmds)).

log_doc(#istate{log_fun = LogFun}, Docs) ->
    Prefix = list_to_binary(?TAG("doc")),
    Fun =
        fun({Level, Doc}) ->
                Tabs = list_to_binary(lists:duplicate(Level-1, $\t)),
                LogFun(<<Prefix/binary, Tabs/binary, Doc/binary, "\n">>)
        end,
    lists:foreach(Fun, Docs).

simple_to_string(Atom) when is_atom(Atom) ->
    simple_to_string(atom_to_list(Atom));
simple_to_string(Bin) when is_binary(Bin) ->
    simple_to_string(binary_to_list(Bin));
simple_to_string([$\r | T]) ->
    simple_to_string(T);
simple_to_string([$\n | T]) ->
    [$\n, $\t | simple_to_string(T)];
simple_to_string([$\\, $\R | T]) ->
    [$\n, $\t | simple_to_string(T)];
simple_to_string([Char | T]) when is_integer(Char) ->
    [Char | simple_to_string(T)];
simple_to_string([H | T]) ->
    simple_to_string(H) ++ simple_to_string(T);
simple_to_string([]) ->
    [].

config_data(I) ->
    [
     {script,          [string],               I#istate.file},
     {debug,                                   I#istate.debug},
     {debug_file,                              I#istate.debug_file},
     {skip,                                    I#istate.skip},
     {skip_unless,                             I#istate.skip_unless},
     {require,                                 I#istate.require},
     {progress,                                I#istate.progress},
     {log_dir,                                 I#istate.log_dir},
     {multiplier,                              I#istate.multiplier},
     {suite_timeout,                           I#istate.suite_timeout},
     {case_timeout,                            I#istate.case_timeout},
     {flush_timeout,                           I#istate.flush_timeout},
     {poll_timeout,                            I#istate.poll_timeout},
     {timeout,                                 I#istate.timeout},
     {cleanup_timeout,                         I#istate.cleanup_timeout},
     {shell_wrapper,                           I#istate.shell_wrapper},
     {shell_cmd,                               I#istate.shell_cmd},
     {shell_args,                              I#istate.shell_args},
     {shell_prompt_cmd,                        I#istate.shell_prompt_cmd},
     {shell_prompt_regexp,                     I#istate.shell_prompt_regexp},
     {var,                                     I#istate.global_dict},
     {builtin,         [{env_list, [string]}], I#istate.builtin_dict},
     {system_env,      [{env_list, [string]}], I#istate.system_dict}
    ].

interpret_init(I) ->
    Ref = safe_send_after(I, I#istate.case_timeout, self(),
                          {case_timeout, I#istate.case_timeout}),
    OrigCmds = I#istate.commands,
    I2 =
        I#istate{macros = collect_macros(I, OrigCmds),
                 blocked = false,
                 has_been_blocked = false,
                 want_more = true,
                 old_want_more = undefined,
                 orig_commands = OrigCmds},
    I4 =
        case I2#istate.debug orelse I2#istate.debug_file =/= undefined of
            false ->
                I2;
            true ->
                DebugState = {attach, temporary},
                {_, I3} = lux_debug:cmd_attach(I2, [], DebugState),
                io:format("\nDebugger for lux. Try help or continue.\n",
                          []),
                I3
        end,
    try
        Res = interpret_loop(I4),
        {ok, Res}
    catch
        throw:{error, Reason, I5} ->
            {error, Reason, I5}
    after
        safe_cancel_timer(Ref)
    end.

collect_macros(#istate{file = File, orig_file = OrigFile}, OrigCmds) ->
    Collect =
        fun(Cmd, _RevFile, _CmdStack, Acc) ->
                case Cmd of
                    #cmd{type = macro,
                         arg = {macro, Name, _ArgNames,
                                _FirstLineNo, _LastLineNo, _Body}} ->
                        [#macro{name = Name,
                                file = File, cmd = Cmd} | Acc];
                    _ ->
                        Acc
                end
        end,
    lux_utils:foldl_cmds(Collect, [], OrigFile, [], OrigCmds).

interpret_loop(#istate{mode = stopping,
                       shells = [],
                       active_shell = undefined} = I) ->
    %% Stop main
    I;
interpret_loop(#istate{commands = [], call_level = CallLevel} = I)
  when CallLevel > 1 ->
    %% Stop include
    I2 = multisync(I, wait_for_expect),
    %% Check for stop and down before popping the cmd_stack
    sync_return(I2);
interpret_loop(I) ->
    Timeout = timeout(I),
    receive
        {debug_call, Pid, Cmd, CmdState} ->
            I2 = lux_debug:eval_cmd(I, Pid, Cmd, CmdState),
            interpret_loop(I2);
        stopped_by_user ->
            %% Ordered to stop by user
            ilog(I, "~s(~p): stopped_by_user\n",
                 [I#istate.active_name, (I#istate.latest_cmd)#cmd.lineno]),
            I2 = prepare_stop(I, dummy_pid, {fail, stopped_by_user}),
            interpret_loop(I2);
        {stop, Pid, Res} ->
            %% One shell has finished. Stop the others if needed
            I2 = prepare_stop(I, Pid, Res),
            interpret_loop(I2);
        {more, Pid, _Name} ->
            if
                Pid =/= I#istate.active_shell#shell.pid ->
                    %% ilog(I, "~s(~p): ignore_more \"~s\"\n",
                    %%      [I#istate.active_name,
                    %%       (I#istate.latest_cmd)#cmd.lineno,
                    %%       Name]),
                    interpret_loop(I);
                I#istate.blocked, not I#istate.want_more ->
                    %% Block more
                    I2 = I#istate{old_want_more = true},
                    interpret_loop(I2);
                not I#istate.blocked, I#istate.old_want_more =:= undefined ->
                    dlog(I, ?dmore, "want_more=true (got more)", []),
                    I2 = I#istate{want_more = true},
                    interpret_loop(I2)
            end;
        {submatch_dict, _From, SubDict} ->
            I2 = I#istate{submatch_dict = SubDict},
            interpret_loop(I2);
        {'DOWN', _, process, Pid, Reason} ->
            I2 = prepare_stop(I, Pid, {'EXIT', Reason}),
            interpret_loop(I2);
        {TimeoutType, TimeoutMillis} when TimeoutType =:= suite_timeout;
                                          TimeoutType =:= case_timeout ->
            I2 = premature_stop(I, TimeoutType, TimeoutMillis),
            interpret_loop(I2);
        Unexpected ->
            lux:trace_me(70, 'case', internal_error,
                         [{interpreter_got, Unexpected}]),
            exit({interpreter_got, Unexpected})
    after multiply(I, Timeout) ->
            I2 = opt_dispatch_cmd(I),
            interpret_loop(I2)
    end.

timeout(I) ->
    if
        I#istate.want_more,
        not I#istate.blocked ->
            0;
        true ->
            infinity
    end.

premature_stop(I, TimeoutType, TimeoutMillis) when I#istate.has_been_blocked ->
    lux:trace_me(70, 'case', TimeoutType, [{ignored, TimeoutMillis}]),
    ilog(I, "~s(~p): ~p (ignored)\n",
         [I#istate.active_name, (I#istate.latest_cmd)#cmd.lineno, TimeoutType]),
    io:format("WARNING: Ignoring ~p"
              " as the script has been attached by the debugger.\n",
              [TimeoutType]),
    I;
premature_stop(I, TimeoutType, TimeoutMillis) ->
    lux:trace_me(70, 'case', TimeoutType, [{premature, TimeoutMillis}]),
    Seconds = TimeoutMillis div timer:seconds(1),
    Multiplier = I#istate.multiplier / 1000,
    ilog(I, "~s(~p): ~p (~p seconds * ~.3f)\n",
         [I#istate.active_name, (I#istate.latest_cmd)#cmd.lineno,
          TimeoutType,
          Seconds,
          Multiplier]),
    case I#istate.mode of
        running ->
            %% The test case (or suite) has timed out.
            prepare_stop(I, dummy_pid, {fail, TimeoutType});
        cleanup ->
            %% Timeout during cleanup

            %% Initiate stop by sending shutdown to all shells.
            multicast(I, {shutdown, self()}),
            I#istate{mode = stopping, cleanup_reason = TimeoutType};
        stopping ->
            %% Shutdown has already been sent to the shells.
            %% Continue to collect their states.
            I
    end.

sync_return(I) ->
    receive
        {stop, Pid, Res} ->
            %% One shell has finished. Stop the others if needed
            I2 = prepare_stop(I, Pid, Res),
            sync_return(I2);
        {'DOWN', _, process, Pid, Reason} ->
            I2 = prepare_stop(I, Pid, {'EXIT', Reason}),
            sync_return(I2)
    after 0 ->
            I
    end.

opt_dispatch_cmd(#istate{commands = Cmds, want_more = WantMore} = I) ->
    case Cmds of
        [#cmd{lineno = CmdLineNo} = Cmd | Rest] when WantMore ->
            case lux_debug:check_break(I, CmdLineNo) of
                {dispatch, I2} ->
                    I3 = I2#istate{commands = Rest, latest_cmd = Cmd},
                    dispatch_cmd(I3, Cmd);
                {wait, I2} ->
                    %% Encountered a breakpoint - wait for user to continue
                    I2
            end;
        [_|_] ->
            %% Active shell is not ready for more commands yet
            I;
        [] ->
            %% End of script
            CallLevel = call_level(I),
            if
                CallLevel > 1 ->
                    I;
                I#istate.mode =:= stopping ->
                    %% Already stopping
                    I;
                true ->
                    %% Initiate stop by sending end_of_script to all shells.
                    multicast(I, {end_of_script, self()}),
                    I#istate{mode = stopping}
            end
    end.

dispatch_cmd(I,
             #cmd{lineno = LineNo,
                  type = Type,
                  arg = Arg} = Cmd) ->
    %% io:format("~p\n", [Cmd]),
    lux:trace_me(60, 'case', Type, [Cmd]),
    case Type of
        comment ->
            I;
        variable ->
            {Scope, Var, Val} = Arg,
            case safe_expand_vars(I, Val) of
                {ok, Val2} ->
                    QuotedVal = quote_val(Val2),
                    ilog(I, "~s(~p): ~p \"~s=~s\"\n",
                         [I#istate.active_name, LineNo, Scope, Var, QuotedVal]),
                    VarVal = lists:flatten([Var, $=, Val2]),
                    case Scope of
                        my ->
                            Dict = [VarVal | I#istate.macro_dict],
                            I#istate{macro_dict = Dict};
                        local when I#istate.active_shell =:= undefined ->
                            throw_error(I, <<"The command must be executed"
                                             " in context of a shell">>);
                        local ->
                            add_active_var(I, VarVal);
                        global ->
                            I2 = add_active_var(I, VarVal),
                            Shells =
                                [S#shell{dict = [VarVal | S#shell.dict]} ||
                                    S <- I#istate.shells],
                            GlobalDict = [VarVal | I#istate.global_dict],
                            I2#istate{shells = Shells,
                                      global_dict = GlobalDict}
                    end;
                {no_such_var, BadName} ->
                    no_such_var(I, Cmd, LineNo, BadName)
            end;
        send_lf when is_binary(Arg) ->
            expand_send(I, Cmd, <<Arg/binary, "\n">>);
        send when is_binary(Arg) ->
            expand_send(I, Cmd, Arg);
        expect when is_atom(Arg) ->
            shell_eval(I, Cmd);
        expect when is_tuple(Arg) ->
            Cmd2 = compile_regexp(I, Cmd, Arg),
            shell_eval(I#istate{latest_cmd = Cmd2}, Cmd2);
        fail when is_tuple(Arg) ->
            Cmd2 = compile_regexp(I, Cmd, Arg),
            shell_eval(I#istate{latest_cmd = Cmd2}, Cmd2);
        success when is_tuple(Arg) ->
            Cmd2 = compile_regexp(I, Cmd, Arg),
            shell_eval(I#istate{latest_cmd = Cmd2}, Cmd2);
        sleep ->
            Secs = parse_int(I, Arg, Cmd),
            Cmd2 = Cmd#cmd{arg = Secs},
            shell_eval(I#istate{latest_cmd = Cmd2}, Cmd2);
        progress ->
            case safe_expand_vars(I, Arg) of
                {ok, String} ->
                    Cmd2 = Cmd#cmd{arg = String},
                    shell_eval(I#istate{latest_cmd = Cmd2}, Cmd2);
                {no_such_var, BadName} ->
                    no_such_var(I, Cmd, LineNo, BadName)
            end;
        change_timeout ->
            Millis =
                case Arg of
                    "" ->
                        I#istate.timeout;
                    "infinity" ->
                        infinity;
                    SecsStr ->
                        Secs = parse_int(I, SecsStr, Cmd),
                        timer:seconds(Secs)
                end,
            Cmd2 = Cmd#cmd{arg = Millis},
            shell_eval(I#istate{latest_cmd = Cmd2}, Cmd2);
        doc ->
            {Level, Doc} = Arg,
            Indent = lists:duplicate((Level-1)*4, $\ ),
            ilog(I, "~s(~p): doc \"~s~s\"\n",
                 [I#istate.active_name, LineNo, Indent, Doc]),
            case I#istate.progress of
                doc -> io:format("\n~s~s\n", [Indent, Doc]);
                _   -> ok
            end,
            I;
        config ->
            {config, Var, Val} = Arg,
            ilog(I, "~s(~p): config \"~s=~s\"\n",
                 [I#istate.active_name, LineNo, Var, Val]),
            I;
        cleanup ->
            lux_utils:progress_write(I#istate.progress, "c"),
            ilog(I, "~s(~p): cleanup\n",
                 [I#istate.active_name, LineNo]),
            multicast(I, {eval, self(), Cmd}),
            I2 = multisync(I, immediate),
            NewMode =
                case I2#istate.mode of
                    stopping -> stopping;
                    _OldMode -> cleanup
                end,
            I3 = inactivate_shell(I2, I2#istate.want_more),
            Zombies = [S#shell{health = zombie} || S <- I3#istate.shells],
            I4 = I3#istate{mode = NewMode,
                           timeout = I3#istate.cleanup_timeout,
                           shells = Zombies},
            Suffix =
                case call_level(I4) of
                    1 -> "";
                    N -> integer_to_list(N)
                end,
            ShellCmd = Cmd#cmd{type = shell, arg = "cleanup" ++ Suffix},
            ensure_shell(I4, ShellCmd);
        shell ->
            ensure_shell(I, Cmd);
        include ->
            {include, InclFile, FirstLineNo, LastLineNo, InclCmds} = Arg,
            ilog(I, "~s(~p): include_file \"~s\"\n",
                 [I#istate.active_name, LineNo, InclFile]),
            eval_include(I, LineNo, FirstLineNo, LastLineNo,
                         InclFile, InclCmds, Cmd);
        macro ->
            I;
        invoke ->
            case lookup_macro(I, Cmd) of
                {ok, NewCmd, MatchingMacros} ->
                    invoke_macro(I, NewCmd, MatchingMacros);
                {error, BadName} ->
                    E = list_to_binary(["Variable $", BadName, " is not set"]),
                    ilog(I, "~s(~p): ~s\n",
                         [I#istate.active_name, LineNo, E]),
                    OrigLine = Cmd#cmd.orig,
                    throw_error(I, <<OrigLine/binary, " ", E/binary>>)
            end;
        loop ->
            {loop, Name, ItemStr, LineNo, LastLineNo, Body} = Arg,
            case safe_expand_vars(I, ItemStr) of
                {ok, NewItemStr} ->
                    ilog(I, "~s(~p): loop items \"~s\"\n",
                         [I#istate.active_name, LastLineNo, NewItemStr]),
                    Items = string:tokens(NewItemStr, " "),
                    NewArgs = {loop, Name, Items, LineNo, LastLineNo, Body},
                    eval_loop(I, Cmd#cmd{arg = NewArgs});
                {no_such_var, BadName} ->
                    no_such_var(I, Cmd, LineNo, BadName)
            end;
        _ ->
            %% Send next command to active shell
            shell_eval(I, Cmd)
    end.

quote_val(IoList) ->
    Replace = fun({From, To}, Acc) ->
                      re:replace(Acc, From, To, [global, {return, binary}])
              end,
    Map = [{<<"\r">>, <<"\\\\r">>},
           {<<"\n">>, <<"\\\\n">>}],
    lists:foldl(Replace, IoList, Map).

shell_eval(I, Cmd) ->
    dlog(I, ?dmore, "want_more=false (send ~p)", [Cmd#cmd.type]),
    cast(I, {eval, self(), Cmd}),
    I#istate{want_more = false}.

eval_include(OldI, InclLineNo, FirstLineNo, LastLineNo,
             InclFile, InclCmds, InclCmd) ->
    DefaultFun = get_eval_fun(),
    eval_body(OldI, InclLineNo, FirstLineNo, LastLineNo,
              InclFile, InclCmds, InclCmd, DefaultFun).

get_eval_fun() ->
    fun(I) when is_record(I, istate) -> interpret_loop(I) end.

eval_body(OldI, InvokeLineNo, FirstLineNo, LastLineNo, CmdFile, Body,
          #cmd{type = Type} = Cmd, Fun) ->
    lux_utils:progress_write(OldI#istate.progress, "("),
    Enter =
        fun() ->
                ilog(OldI, "file_enter ~p ~p ~p ~p\n",
                     [InvokeLineNo, FirstLineNo, LastLineNo, CmdFile])
        end,
    OldStack = OldI#istate.cmd_stack,
    Current = {lux_utils:filename_split(CmdFile), InvokeLineNo, Type},
    NewStack = [Current | OldStack],
    BeforeI = OldI#istate{call_level = call_level(OldI) + 1,
                          file = CmdFile,
                          latest_cmd = Cmd,
                          cmd_stack = NewStack,
                          commands = Body},
    BeforeI2 = switch_cmd(before, BeforeI, NewStack, Cmd, Enter),
    try
        AfterI = Fun(BeforeI2),
        lux_utils:progress_write(AfterI#istate.progress, ")"),
        AfterExit =
            fun() ->
                    catch ilog(AfterI, "file_exit ~p ~p ~p ~p\n",
                               [InvokeLineNo, FirstLineNo, LastLineNo,
                                CmdFile])
            end,
        AfterI2 = switch_cmd('after', AfterI, OldStack, Cmd, AfterExit),
        NewI = AfterI2#istate{call_level = call_level(OldI),
                              file = OldI#istate.file,
                              latest_cmd = OldI#istate.latest_cmd,
                              cmd_stack = OldI#istate.cmd_stack,
                              commands = OldI#istate.commands},
        if
            NewI#istate.cleanup_reason =:= normal ->
                %% Everything OK - no cleanup needed
                NewI;
            OldI#istate.cleanup_reason =:= normal ->
                %% New cleanup initiated in body - continue on this call level
                goto_cleanup(NewI, NewI#istate.cleanup_reason);
            true ->
                %% Already cleaning up when we started eval of body
                NewI
        end
    catch
        Class:Reason ->
            lux_utils:progress_write(OldI#istate.progress, ")"),
            BeforeExit =
                fun() ->
                        catch ilog(BeforeI2, "file_exit ~p ~p ~p ~p\n",
                                   [InvokeLineNo, FirstLineNo, LastLineNo,
                                    CmdFile])
                end,
            _ = switch_cmd('after2', BeforeI2, OldStack, Cmd, BeforeExit),
            erlang:raise(Class, Reason, erlang:get_stacktrace())
    end.

call_level(#istate{call_level = CallLevel}) ->
    CallLevel.

lookup_macro(I, #cmd{arg = {invoke, Name, ArgVals}} = Cmd) ->
    case safe_expand_vars(I, Name) of
        {ok, NewName} ->
            Macros = [M || M <- I#istate.macros,
                           M#macro.name =:= NewName],
            NewArgs = {invoke, NewName, ArgVals},
            {ok, Cmd#cmd{arg = NewArgs}, Macros};
        {no_such_var, BadName} ->
            {error, BadName}
    end.

invoke_macro(I,
             #cmd{arg = {invoke, Name, ArgVals},
                  lineno = LineNo} = InvokeCmd,
             [#macro{name = Name,
                     file = File,
                     cmd = #cmd{arg = {macro, Name, ArgNames, FirstLineNo,
                                       LastLineNo, Body}} = MacroCmd}]) ->
    OldMacroDict = I#istate.macro_dict,
    MacroDict = macro_dict(I, ArgNames, ArgVals, InvokeCmd),
    ilog(I, "~s(~p): invoke_~s \"~s\"\n",
         [I#istate.active_name,
          LineNo,
          Name,
          lists:flatten([[M, " "] || M <- MacroDict])]),

    BeforeI = I#istate{macro_dict = MacroDict, latest_cmd = InvokeCmd},
    DefaultFun = get_eval_fun(),
    AfterI = eval_body(BeforeI, LineNo, FirstLineNo,
                       LastLineNo, File, Body, MacroCmd, DefaultFun),

    AfterI#istate{macro_dict = OldMacroDict};
invoke_macro(I, #cmd{arg = {invoke, Name, _Values}}, []) ->
    BinName = list_to_binary(Name),
    throw_error(I, <<"No such macro: ", BinName/binary>>);
invoke_macro(I, #cmd{arg = {invoke, Name, _Values}}, [_|_]) ->
    BinName = list_to_binary(Name),
    throw_error(I, <<"Ambiguous macro: ", BinName/binary>>).

macro_dict(I, [Name | Names], [Val | Vals], Invoke) ->
    case safe_expand_vars(I, Val) of
        {ok, Val2} ->
            [lists:flatten([Name, $=, Val2]) |
             macro_dict(I, Names, Vals, Invoke)];
        {no_such_var, BadName} ->
            no_such_var(I, Invoke, Invoke#cmd.lineno, BadName)
    end;
macro_dict(_I, [], [], _Invoke) ->
    [];
macro_dict(I, _Names, _Vals, #cmd{arg = {invoke, Name, _}, lineno = LineNo}) ->
    BinName = list_to_binary(Name),
    BinLineNo = list_to_binary(integer_to_list(LineNo)),
    Reason = <<"at ", BinLineNo/binary,
               ": Argument mismatch in macro: ", BinName/binary>>,
    throw_error(I, Reason).

compile_regexp(_I, Cmd, reset) ->
    Cmd;
compile_regexp(I, Cmd, {endshell, RegExp}) ->
    Cmd2 = compile_regexp(I, Cmd, {regexp, RegExp}),
    {mp, RegExp2, MP2} = Cmd2#cmd.arg,
    Cmd2#cmd{arg = {endshell, RegExp2, MP2}};
compile_regexp(_I, Cmd, {verbatim, _Verbatim}) ->
    Cmd;
compile_regexp(_I, Cmd, {mp, _RegExp, _MP}) ->
    Cmd;
compile_regexp(I, Cmd, {template, Template}) ->
    case safe_expand_vars(I, Template) of
        {ok, Verbatim} ->
            Cmd#cmd{arg = {verbatim, Verbatim}};
        {no_such_var, BadName} ->
            no_such_var(I, Cmd, Cmd#cmd.lineno, BadName)
    end;
compile_regexp(I, Cmd, {regexp, RegExp}) ->
    case safe_expand_vars(I, RegExp) of
        {ok, RegExp2} ->
            RegExp3 = lux_utils:normalize_newlines(RegExp2),
            Opts = [multiline, {newline, anycrlf}],
            case re:compile(RegExp3, Opts) of
                {ok, MP3} ->
                    Cmd#cmd{arg = {mp, RegExp3, MP3}};
                {error, {Reason, _Pos}} ->
                    BinErr = list_to_binary(["Syntax error: ", Reason,
                                             " in regexp '", RegExp3, "'"]),
                    throw_error(I, BinErr)
            end;
        {no_such_var, BadName} ->
            no_such_var(I, Cmd, Cmd#cmd.lineno, BadName)
    end.

expand_send(I, Cmd, Arg) ->
    case safe_expand_vars(I, Arg) of
        {ok, Arg2} ->
            Cmd2 = Cmd#cmd{arg = Arg2},
            shell_eval(I#istate{latest_cmd = Cmd2}, Cmd2);
        {no_such_var, BadName} ->
            no_such_var(I, Cmd, Cmd#cmd.lineno, BadName)
    end.

no_such_var(I, Cmd, LineNo, BadName) ->
    E = list_to_binary(["Variable $", BadName, " is not set"]),
    ilog(I, "~s(~p): ~s\n", [I#istate.active_name, LineNo, E]),
    OrigLine = Cmd#cmd.orig,
    throw_error(I, <<OrigLine/binary, " ", E/binary>>).

parse_int(I, Chars, Cmd) ->
    case safe_expand_vars(I, Chars) of
        {ok, Chars2} ->
            try
                list_to_integer(Chars2)
            catch
                error:_ ->
                    BinErr =
                        list_to_binary(["Syntax error at line ",
                                        integer_to_list(Cmd#cmd.lineno),
                                        ": '", Chars2, "' integer expected"]),
                    throw_error(I, BinErr)
            end;
        {no_such_var, BadName} ->
            no_such_var(I, Cmd, Cmd#cmd.lineno, BadName)
    end.

eval_loop(OldI, #cmd{arg = {loop,Name,Items,First,Last,Body}} = LoopCmd) ->
    DefaultFun = get_eval_fun(),
    LoopStack = [continue | OldI#istate.loop_stack],
    NewI = eval_body(OldI#istate{loop_stack = LoopStack}, First, First, First,
                     OldI#istate.file, Body, LoopCmd,
                     fun(I) ->
                             do_eval_loop(I, Name, Items, First, Last, Body,
                                          LoopCmd, DefaultFun, 1)
                     end),
    NewI#istate{loop_stack = tl(NewI#istate.loop_stack)}.

do_eval_loop(OldI, _Name, _Items, _First, _Last, _Body, _LoopCmd, _LoopFun, _N)
  when hd(OldI#istate.loop_stack) =:= break ->
    %% Exit the loop
    OldI;
do_eval_loop(OldI, Name, Items, First, Last, Body, LoopCmd, LoopFun, N)
  when hd(OldI#istate.loop_stack) =:= continue ->
    case pick_item(Items) of
        {item, Item, Rest} ->
            LoopVar = lists:flatten([Name, $=, Item]),
            MacroDict = [LoopVar|OldI#istate.macro_dict],
            BeforeI = OldI#istate{macro_dict = MacroDict,
                                  latest_cmd = LoopCmd},
            SyntheticLineNo = -N,
            AfterI = eval_body(BeforeI, SyntheticLineNo, First, Last,
                               BeforeI#istate.file, Body, LoopCmd,
                               fun(I) ->
                                       ilog(I, "~s(~p): loop \"~s\"\n",
                                            [I#istate.active_name,
                                             First,
                                             LoopVar]),
                                       LoopFun(I)
                               end),
            do_eval_loop(AfterI, Name, Rest, First, Last, Body, LoopCmd,
                         LoopFun, N+1);
        endloop ->
            ilog(OldI, "~s(~p): endloop \"~s\"\n",
                 [OldI#istate.active_name, Last, Name]),
            OldI
    end.

pick_item([Item|Items]) ->
    Pred = fun(Char) -> Char =/= $. end,
    {Before, After} = lists:splitwith(Pred, Item),
    case After of
        [] ->
            {item, Item, Items};
        [$., $. | After2] ->
            try
                From = list_to_integer(Before),
                To   = list_to_integer(After2),
                Seq =
                    if
                        From =< To ->
                            lists:seq(From, To);
                        true ->
                            lists:reverse(lists:seq(To, From))
                    end,
                [NewItem|NewItems] = [integer_to_list(I) || I <- Seq],
                {item, NewItem, NewItems ++ Items}
            catch
                _:_ ->
                    {item, Item, Items}
            end
    end;
pick_item([]) ->
    endloop.

prepare_stop(#istate{results = Acc} = I, Pid, Res) ->
    %% Handle stop procedure
    {CleanupReason, Res3} = prepare_result(I, Res),
    NewLevel =
        case Res3#result.actual of
            internal_error -> ?dmore;
            _              -> I#istate.debug_level
        end,
    I2 = I#istate{results = [Res3 | Acc],
                  debug_level = NewLevel}, % Activate debug after first error
    {ShellName, I3} = delete_shell(I2, Pid),
    lux:trace_me(50, 'case', stop,
                 [{mode, I3#istate.mode},
                  {stop, ShellName, Res3#result.outcome, Res3#result.actual},
                  {active_shell, I3#istate.active_shell},
                  {shells, I3#istate.shells},
                  Res3]),
    case I3#istate.mode of
        running ->
            multicast(I3, {relax, self()}),
            goto_cleanup(I3, CleanupReason);
        cleanup when Res#result.outcome =:= relax -> % Orig outcome
            I3; % Continue with cleanup
        cleanup ->
            %% Initiate stop by sending shutdown to the remaining shells.
            multicast(I3, {shutdown, self()}),
            I3#istate{mode = stopping};
        stopping ->
            %% Shutdown has already been sent to the other shells.
            %% Continue to collect their states if needed.
            I3
    end.

prepare_result(#istate{latest_cmd = LatestCmd,
                       cmd_stack = CmdStack,
                       cleanup_reason = OrigCleanupReason},
               Res) ->
    {CleanupReason, Res2} =
        case Res of
            #result{outcome = shutdown} ->
                {OrigCleanupReason, Res};
            #result{outcome = relax} ->
                {OrigCleanupReason, Res#result{outcome = shutdown}};
            #result{outcome = NewOutcome} ->
                {NewOutcome, Res};
            {'EXIT', {error, FailReason}} ->
                Expected = lux_utils:cmd_expected(LatestCmd),
                {fail,
                 #result{outcome    = fail,
                         latest_cmd = LatestCmd,
                         cmd_stack  = CmdStack,
                         expected   = Expected,
                         extra      = undefined,
                         actual     = FailReason,
                         rest       = fail}};
            {fail, FailReason} ->
                Expected = lux_utils:cmd_expected(LatestCmd),
                {fail,
                 #result{outcome    = fail,
                         latest_cmd = LatestCmd,
                         cmd_stack  = CmdStack,
                         expected   = Expected,
                         extra      = undefined,
                         actual     = FailReason,
                         rest       = fail}}
        end,
    Res3 =
        case Res2 of
            #result{actual = <<"fail pattern matched ", _/binary>>} ->
                Res2#result{latest_cmd = LatestCmd,
                            cmd_stack = CmdStack};
            #result{actual = <<"success pattern matched ", _/binary>>} ->
                Res2#result{latest_cmd = LatestCmd,
                            cmd_stack = CmdStack};
            _ ->
                Res2
        end,
    {CleanupReason, Res3}.

goto_cleanup(OldI, CleanupReason) ->
    lux:trace_me(50, 'case', goto_cleanup, [{reason, CleanupReason}]),
    LineNo = integer_to_list((OldI#istate.latest_cmd)#cmd.lineno),
    NewLineNo =
        case OldI#istate.results of
            [#result{actual= <<"fail pattern matched ", _/binary>>}|_] ->
                "-" ++ LineNo;
            [#result{actual= <<"success pattern matched ", _/binary>>}|_] ->
                "+" ++ LineNo;
            [#result{outcome = success}|_] ->
                "";
            _ ->
                LineNo
        end,
    lux_utils:progress_write(OldI#istate.progress, NewLineNo),

    %% Ensure that the cleanup does not take too long time
    safe_send_after(OldI, OldI#istate.case_timeout, self(),
                    {case_timeout, OldI#istate.case_timeout}),
    dlog(OldI, ?dmore, "want_more=true (goto_cleanup)", []),
    do_goto_cleanup(OldI, CleanupReason, LineNo).

do_goto_cleanup(I, CleanupReason, LineNo) ->
    case I#istate.cmd_stack of
        []                    -> Context = main;
        [{_, _, Context} | _] -> ok
    end,
    %% Fast forward to (optional) cleanup command
    CleanupFun = fun(#cmd{type = Type}) -> Type =/= cleanup end,
    CleanupCmds = lists:dropwhile(CleanupFun, I#istate.commands),
    case CleanupCmds of
        [#cmd{lineno = CleanupLineNo} | _] ->
            ilog(I, "~s(~s): goto cleanup at line ~p\n",
                 [I#istate.active_name, LineNo, CleanupLineNo]);
        [] ->
            ilog(I, "~s(~s): no cleanup\n",
                 [I#istate.active_name, LineNo])
    end,
    NewMode =
        if
            I#istate.mode =/= stopping ->
                cleanup;
            Context =:= main ->
                %% Initiate stop by sending shutdown to the remaining shells.
                multicast(I, {shutdown, self()}),
                stopping;
            true ->
                stopping
        end,
    LoopStack = [break || _ <- I#istate.loop_stack], % Break active loops
    I#istate{mode = NewMode,
             loop_stack = LoopStack,
             cleanup_reason = CleanupReason,
             want_more = true,
             commands = CleanupCmds}.

delete_shell(I, Pid) ->
    ActiveShell = I#istate.active_shell,
    OldShells = I#istate.shells,
    case lists:keyfind(Pid, #shell.pid, [ActiveShell | OldShells]) of
        false ->
            {Pid, I};
        #shell{ref = Ref, name = Name} ->
            erlang:demonitor(Ref, [flush]),
            if
                Pid =:= ActiveShell#shell.pid ->
                    I2 = inactivate_shell(I, I#istate.want_more),
                    {Name, I2#istate{shells = OldShells}};
                true ->
                    NewShells = lists:keydelete(Pid, #shell.pid, OldShells),
                    {Name, I#istate{shells = NewShells}}
            end
    end.

multicast(#istate{shells = OtherShells, active_shell = undefined}, Msg) ->
    multicast(OtherShells, Msg);
multicast(#istate{shells = OtherShells, active_shell = ActiveShell}, Msg) ->
    multicast([ActiveShell | OtherShells], Msg);
multicast(Shells, Msg) when is_list(Shells) ->
    lux:trace_me(50, 'case', multicast, [{shells, Shells}, Msg]),
    Send = fun(#shell{pid = Pid} = S) -> trace_msg(S, Msg), Pid ! Msg, Pid end,
    lists:map(Send, Shells).

cast(#istate{active_shell = undefined} = I, _Msg) ->
    throw_error(I, <<"The command must be executed in context of a shell">>);
cast(#istate{active_shell = #shell{pid =Pid}, active_name = Name}, Msg) ->
    trace_msg(#shell{name=Name}, Msg),
    Pid ! Msg,
    Pid.

trace_msg(#shell{name = Name}, Msg) ->
    lux:trace_me(50, 'case', Name, element(1, Msg), [Msg]).

multisync(I, Msg) when Msg =:= flush;
                       Msg =:= immediate;
                       Msg =:= wait_for_expect ->
    Pids = multicast(I, {sync, self(), Msg}),
    lux:trace_me(50, 'case', waiting,
                 [{active_shell, I#istate.active_shell},
                  {shells, I#istate.shells},
                  Msg]),
    I2 = wait_for_reply(I, Pids, sync_ack, undefined, infinity),
    lux:trace_me(50, 'case', collected, []),
    I2.

wait_for_reply(I, [Pid | Pids], Expect, Fun, FlushTimeout) ->
    receive
        {Expect, Pid} ->
            wait_for_reply(I, Pids, Expect, Fun, FlushTimeout);
        {Expect, Pid, Expected} when Expect =:= expected, Pids =:= [] ->
            Expected;
        {stop, SomePid, Res} ->
            I2 = prepare_stop(I, SomePid, Res),
            wait_for_reply(I2, [Pid|Pids], Expect, Fun, FlushTimeout);
        {'DOWN', _, process, Pid, Reason} ->
            opt_apply(Fun),
            shell_crashed(I, Pid, Reason);
        {TimeoutType, TimeoutMillis} when TimeoutType =:= suite_timeout;
                                          TimeoutType =:= case_timeout ->
            I2 = premature_stop(I, TimeoutType, TimeoutMillis),
            wait_for_reply(I2, [], Expect, Fun, 500);
        IgnoreMsg when FlushTimeout =/= infinity ->
            lux:trace_me(70, 'case', ignore_msg, [{interpreter_got,IgnoreMsg}]),
            io:format("\nWARNING: Interpreter got: ~p\n", [IgnoreMsg]),
            wait_for_reply(I, [Pid|Pids], Expect, Fun, FlushTimeout)
    after FlushTimeout ->
            I
    end;
wait_for_reply(I, [], _Expect, _Fun, _FlushTimeout) ->
    I.

opt_apply(Fun) when is_function(Fun) ->
    Fun();
opt_apply(_Fun) ->
    ignore.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Control a shell

ensure_shell(I, #cmd{arg = ""}) ->
    %% No name. Inactivate the shell
    inactivate_shell(I, I#istate.want_more);
ensure_shell(I, #cmd{lineno = LineNo, arg = Name} = Cmd) ->
    case safe_expand_vars(I, Name) of
        {ok, Name2} when I#istate.active_shell#shell.name =:= Name2 ->
            %% Keep active shell
            I;
        {ok, Name2} ->
            I2 = I#istate{want_more = false},
            case lists:keyfind(Name2, #shell.name, I2#istate.shells) of
                false ->
                    %% New shell
                    shell_start(I2, Cmd#cmd{arg = Name2});
                Shell ->
                    %% Existing shell
                    shell_switch(I2, Cmd, Shell)
            end;
        {no_such_var, BadName} ->
            no_such_var(I, Cmd, LineNo, BadName)
    end.

shell_start(I, #cmd{arg = Name} = Cmd) ->
    I2 = change_active_mode(I, Cmd, suspend),
    I3 = inactivate_shell(I2, I2#istate.want_more),
    case safe_expand_vars(I3, "$LUX_EXTRA_LOGS") of
        {ok, ExtraLogs} ->
            case lux_shell:start_monitor(I3, Cmd, Name, ExtraLogs) of
                {ok, I4} ->
                    %% Wait for some shell output
                    Wait = Cmd#cmd{type = expect,
                                   arg = {regexp, <<".+">>}},
                    %% Set the prompt (after the rc files has ben run)
                    CmdStr = list_to_binary(I4#istate.shell_prompt_cmd),
                    Prompt = Cmd#cmd{type = send_lf,
                                     arg = CmdStr},
                    %% Wait for the prompt
                    CmdRegExp = list_to_binary(I4#istate.shell_prompt_regexp),
                    Sync = Cmd#cmd{type = expect,
                                   arg = {regexp, CmdRegExp}},
                    Cmds = [Wait, Prompt, Sync | I4#istate.commands],
                    dlog(I4, ?dmore, "want_more=false (shell_start)", []),
                    I4#istate{commands = Cmds};
                {error, I4, Pid, Reason} ->
                    shell_crashed(I4, Pid, Reason)
            end;
        {no_such_var, BadName} ->
            no_such_var(I3, Cmd, Cmd#cmd.lineno, BadName)
    end.

shell_switch(OldI, Cmd, #shell{health = alive, name = NewName} = NewShell) ->
    %% Activate shell
    I2 = change_active_mode(OldI, Cmd, suspend),
    I3 = inactivate_shell(I2, I2#istate.want_more),
    NewShells = lists:keydelete(NewName, #shell.name, I3#istate.shells),
    NewI = I3#istate{active_shell = NewShell,
                     active_name = NewName,
                     shells = NewShells
                    },
    change_active_mode(NewI, Cmd, resume);
shell_switch(OldI, _Cmd, #shell{name = Name, health = zombie}) ->
    ilog(OldI, "~s(~p): zombie shell at cleanup\n",
         [Name, (OldI#istate.latest_cmd)#cmd.lineno]),
    throw_error(OldI, list_to_binary(Name ++ " is a zombie shell")).

inactivate_shell(#istate{active_shell = undefined} = I, _WantMore) ->
    I;
inactivate_shell(#istate{active_shell = ActiveShell, shells = Shells} = I,
                 WantMore) ->
    I#istate{active_shell = undefined,
             active_name = "lux",
             want_more = WantMore,
             shells = [ActiveShell | Shells]}.

change_active_mode(I, Cmd, NewMode)
  when is_pid(I#istate.active_shell#shell.pid) ->
    Pid = cast(I, {change_mode, self(), NewMode, Cmd, I#istate.cmd_stack}),
    wait_for_reply(I, [Pid], change_mode_ack, undefined, infinity);
change_active_mode(I, _Cmd, _NewMode) ->
    %% No active shell
    I.

switch_cmd(_When, #istate{active_shell = undefined} = I,
           _CmdStack, _NewCmd, Fun) ->
    Fun(),
    I;
switch_cmd(When, #istate{active_shell = #shell{pid = Pid}} = I,
           CmdStack, NewCmd, Fun) ->
    Pid = cast(I, {switch_cmd, self(), When, NewCmd, CmdStack, Fun}),
    wait_for_reply(I, [Pid], switch_cmd_ack, Fun, infinity).

shell_crashed(I, Pid, Reason) when Pid =:= I#istate.active_shell#shell.pid ->
    I2 = inactivate_shell(I, I#istate.want_more),
    shell_crashed(I2, Pid, Reason);
shell_crashed(I, Pid, Reason) ->
    I2 = prepare_stop(I, Pid, {'EXIT', Reason}),
    What =
        case lists:keyfind(Pid, #shell.pid, I2#istate.shells) of
            false -> ["Process ", io_lib:format("~p", [Pid])];
            Shell -> ["Shell ", Shell#shell.name]
        end,
    Error =
        case Reason of
            {error, ErrBin} ->
                ErrBin;
            _ ->
                list_to_binary( [What, " crashed: ",
                                 io_lib:format("~p\n~p", [Reason, ?stack()])])
        end,
    throw_error(I2, Error).

safe_expand_vars(I, Bin) ->
    MissingVar = error,
    try
        {ok, expand_vars(I, Bin, MissingVar)}
    catch
        throw:{no_such_var, BadName} ->
            {no_such_var, BadName}
    end.

expand_vars(#istate{active_shell  = Shell,
                    submatch_dict = SubDict,
                    macro_dict    = MacroDict,
                    global_dict   = OptGlobalDict,
                    builtin_dict  = BuiltinDict,
                    system_dict   = SystemDict},
            Val,
            MissingVar) ->
    case Shell of
        #shell{dict = LocalDict} -> ok;
        undefined                -> LocalDict = OptGlobalDict
    end,
    Dicts = [SubDict, MacroDict, LocalDict, BuiltinDict, SystemDict],
    lux_utils:expand_vars(Dicts, Val, MissingVar).

add_active_var(#istate{active_shell = undefined} = I, _VarVal) ->
    I;
add_active_var(#istate{active_shell = Shell} = I, VarVal) ->
    LocalDict = [VarVal | Shell#shell.dict],
    Shell2 = Shell#shell{dict = LocalDict},
    I#istate{active_shell = Shell2}.

double_ilog(#istate{progress = Progress, log_fun = LogFun, event_log_fd = Fd},
            Format,
            Args) ->
    Bin = lux_log:safe_format(silent, LogFun, undefined, Format, Args),
    lux_log:safe_write(Progress, LogFun, Fd, Bin).

ilog(#istate{progress = Progress, log_fun = LogFun, event_log_fd = Fd},
     Format,
     Args)->
    lux_log:safe_format(Progress, LogFun, Fd, Format, Args).

dlog(I, Level, Format, Args) when I#istate.debug_level >= Level ->
    ilog(I, "~s(~p): debug2 \"" ++ Format ++ "\"\n",
         [I#istate.active_name, (I#istate.latest_cmd)#cmd.lineno] ++ Args);
dlog(_I, _Level, _Format, _Args) ->
    ok.

console_write(String) ->
    io:format("~s", [String]).

safe_send_after(State, Timeout, Pid, Msg) ->
    case multiply(State, Timeout) of
        infinity   -> infinity;
        NewTimeout -> erlang:send_after(NewTimeout, Pid, Msg)
    end.

safe_cancel_timer(Timer) ->
    case Timer of
        infinity  -> undefined;
        undefined -> undefined;
        Ref       -> erlang:cancel_timer(Ref)
    end.

multiply(#istate{multiplier = Factor}, Timeout) ->
    case Timeout of
        infinity ->
            infinity;
        _ ->
            lux_utils:multiply(Timeout, Factor)
    end.

default_istate(File) ->
    #istate{file = filename:absname(File),
            log_fun = fun(Bin) -> console_write(binary_to_list(Bin)), Bin end,
            shell_wrapper = default_shell_wrapper(),
            builtin_dict = lux_utils:builtin_dict(),
            system_dict = lux_utils:system_dict()}.

default_shell_wrapper() ->
    Wrapper = filename:join([code:priv_dir(?APPLICATION), "bin", "runpty"]),
    case filelib:is_regular(Wrapper) of
        true  -> Wrapper;
        false -> undefined
    end.

throw_error(#istate{active_shell = ActiveShell, shells = Shells} = I, Reason)
  when is_binary(Reason) ->
    lux:trace_me(50, 'case', error,
                 [{active_shell, ActiveShell}, {shells, Shells}, Reason]),
    %% Exit all shells before the interpreter is exited
    Sig= shutdown,
    Send =
        fun(#shell{name = Name, pid = Pid}) ->
                lux:trace_me(50, 'case', Name, Sig, [{'EXIT', Sig}]),
                exit(Pid, Sig)
        end,
    lists:map(Send, Shells),
    throw({error, Reason, I}).
