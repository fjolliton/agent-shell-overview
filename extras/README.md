# agent-shell-overview extras

Optional add-ons built on the extension points of agent-shell-overview. Each
is a global minor mode, off until enabled. They are not on the `load-path` of
the package; add the directory to use them:

```elisp
(add-to-list 'load-path
             (expand-file-name "extras" (file-name-directory
                                         (locate-library "agent-shell-overview"))))
(require 'agent-shell-overview-crash)
(agent-shell-overview-crash-mode 1)
(require 'agent-shell-overview-memory)
(agent-shell-overview-memory-mode 1)
```

## Crash detection (agent-shell-overview-crash)

`agent-shell-overview-crash-mode` gives the shells whose agent crashed a state
of their own: Crashed, or OOM when earlyoom killed the agent for lack of
memory. Both ask for attention, before any other state, and stay until the
shell is reloaded. The tooltip of such a row gives the cause of the crash.
`M-r` in the overview, also "Reload all crashed" in its menu, asks once, then
restarts the agents of all the crashed shells and resumes their sessions, each
in a new shell buffer.

A crash is detected in two ways:

- The agent process died on its own. This works for any agent. A deliberate
  stop, as when a shell is killed or restarted, removes the process from the
  shell before it dies, so it never counts as a crash.
- A child process of the agent vanished. Claude's ACP adapter runs Claude Code
  as a child process; when that child dies, the adapter does not start it
  again and keeps running without answering, so the shell would seem idle
  forever. A periodic `ps` looks for the child of each agent; an agent seen
  with one, then without one in two samples in a row, has crashed. A single
  sample may fall between two children, and an agent just started, before its
  first child, is no crash. The child is Claude Code by default.

### Watching another agent's child process

To watch the child of another agent, find its command name as `ps` shows it.
Get the pid of the agent process, either with `M-:` in its shell buffer:

```elisp
(process-id (map-nested-elt agent-shell--state '(:client :process)))
```

or with `pgrep -f` and a part of the agent's command line. Then list its
children (Linux):

```sh
ps -o pid=,comm= --ppid PID
```

Set `agent-shell-overview-crash-child-command` to a regexp matching the
command name, anchored with `` \\` `` and `\\'` as the default is. On Linux, `ps`
cuts command names to 15 characters, so match what it prints. For a child
named `my-agent-cli`:

```elisp
(setq agent-shell-overview-crash-child-command "\\`my-agent-cli\\'")
```

The option is a single regexp for every agent. To watch the children of
several types of agent, match all their command names, for instance Claude
Code and `my-agent-cli`:

```elisp
(setq agent-shell-overview-crash-child-command
      "\\`\\(?:\\.?claude\\(?:-wrapped\\)?\\|my-agent-cli\\)\\'")
```

An agent with no child of a matching name is never taken for crashed this way;
the dead-process check still applies to it. Set the option to nil to turn this
check off, for instance when no agent you use has such a child; no `ps` runs
then:

```elisp
(setq agent-shell-overview-crash-child-command nil)
```

### Death message

When its child dies, an agent may write a line in its shell telling why.
`agent-shell-overview-crash-message-regexp` matches that line, and its first
group is the cause the tooltip shows. The default matches the line of Claude's
ACP adapter, `Claude Agent process died: ...`. For another agent, look in the
shell buffer of a crashed agent for the line it wrote, and set a regexp of it:

```elisp
(setq agent-shell-overview-crash-message-regexp "my-agent-cli exited: \\(.*\\)")
```

When no line matches, the tooltip gives how the crash was seen instead: the
exit status of the agent process, or the pid and command name of the child
that vanished.

### Out of memory

Once a crash is seen, `agent-shell-overview-crash-oom-command` runs once and
looks in the log of earlyoom for a line telling it killed the agent process,
or its child process when one was seen. Such a line turns the crash into an
OOM one. The default reads the last 15 minutes of the earlyoom unit with
`journalctl`, so it needs earlyoom running under systemd. A failure of the
command changes nothing.

For another setup, set a command whose output holds earlyoom's own lines, each
starting with `sending SIGTERM to process PID ` (or another signal), for
instance when earlyoom writes to a file of its own:

```elisp
(setq agent-shell-overview-crash-oom-command
      '("tail" "-n" "200" "/var/log/earlyoom.log"))
```

Set it to nil to disable the lookup:

```elisp
(setq agent-shell-overview-crash-oom-command nil)
```

### Sample interval

`agent-shell-overview-crash-sample-interval`, 10 by default, is the least
number of seconds between two samples of the child processes. Samples run on
the polling ticks of the overview, in the background, never two at a time.

### Requirements

`ps`, as on Linux and the BSDs. `journalctl` and earlyoom only for the OOM
lookup with its default command.

## Memory column (agent-shell-overview-memory)

`agent-shell-overview-memory-mode` adds a Mem column after the session title:
the memory each agent uses, as the summed RSS of the whole process tree of its
agent process, such as `850M`, `1.0G` or `12G`. The cell is empty when the
size is unknown, as for a killed shell or before the first sample.

`agent-shell-overview-memory-interval`, 10 by default, is the least number of
seconds between two samples, each a single `ps` run in the background on the
polling ticks of the overview.

The column can be moved with `agent-shell-overview-add-column`, which replaces
a column with the same function, here `agent-shell-overview-memory-column`.
For instance, to put it last, after the mode is enabled:

```elisp
(agent-shell-overview-add-column
 '("Mem" 5 agent-shell-overview-memory-column :right-align t :pad-right 2))
```

It needs a `ps` supporting `-o pid=,ppid=,rss=,comm=`, as on Linux and the
BSDs.
