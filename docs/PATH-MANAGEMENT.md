# Path Management Design

## The Problem

The Lucia GUI and the Veltro agent (veltrosrv, started by lucibridge) run in **separate
Inferno processes** with **separate namespaces**. A `sys->bind()` call in one process does
not affect the other.

When a user binds a host directory in the GUI context zone (e.g., `/Users/pdfinn/docs`),
the agent needs to see that directory (`/n/local/Users/pdfinn/docs`). But:

- The GUI click handler runs in lucictx (in the lucifer process)
- The agent runs in veltrosrv, which restricted its own namespace before serving; its tool
  calls run in tools9p, each in a namespace restricted for that call
- There is no direct IPC channel between them

---

## Why tools9p Is the Intermediary

tools9p is a **shared 9P file server** — mounted at `/tool` in the shell's namespace before
either lucifer or lucibridge starts. Both processes inherit `/tool` from the shell, as does
the veltrosrv that lucibridge starts, so all of them read and write the same server.

This makes tools9p the natural "configuration bus" between the GUI and the agent:

```
GUI (lucictx)         tools9p                  Agent (veltrosrv)
     │                   │                            │
     │ "bindpath /foo"   │                            │
     │──────────────────►│                            │
     │                   │  /tool/paths               │
     │                   │  now lists /foo            │
     │                   │                            │  on next turn:
     │                   │◄───────────────────────────│  read /tool/paths,
     │                   │                            │  update system prompt
     │                   │  each tool call:           │
     │                   │  applynsrestriction()      │
     │                   │  exposes /foo              │
```

The alternative — direct IPC between lucifer and the agent — would require a new protocol
channel, whereas tools9p already exists and is already a shared medium.

---

## The Unified Model

tools9p manages both tools AND paths for the same reason: both are "what the agent can
access". The trusted control alias (`/mnt/toolctl*`) handles capability
configuration outside the restricted agent namespace:

| Command | Effect |
|---------|--------|
| `add <name>` | Activate a tool; LLM receives its schema on next turn |
| `remove <name>` | Deactivate a tool; LLM loses its schema on next turn |
| `bindpath <path>` | Register a path; tools9p exposes it to every later tool call |
| `unbindpath <path>` | Unregister a path; later tool calls no longer see it |

GUI and launcher code write to the trusted control alias to configure the
agent's capabilities. Restricted tool invocations see `/tool` but not the
generic control file.

---

## How Path Changes Are Applied

- **tools9p** applies the namespace restriction per tool call (`asyncexec()` →
  `applynsrestriction()`), using the registered paths at call time, so a path bound after
  the server started is visible to the next call.
- **veltrosrv** re-reads `/tool/paths` at the start of each turn and rebuilds the system
  prompt when it changed, so the model is told about the new path.
- **lucibridge** `applypathchanges()` only mirrors `/tool/paths` into the context zone:
  it diffs against the last-seen content, binds a path that is not under `/n/local/` and
  not already in its namespace at `/n/local/<basename>` in its own namespace, and pushes
  `resource upsert`/`resource remove` to the activity's context ctl.

This is a pull model — changes are picked up at the start of a turn or call, not on every
write to the control file.

---

## Path Visibility in the Agent

Once `/n/local/Users/pdfinn/docs` is registered, a tool call (running in tools9p after
`FORKNS + restrictns`) can see:

```
/n/local/Users/pdfinn/docs/     ← host directory
  file1.txt
  file2.pdf
  ...
```

The `read` tool can then access `/n/local/Users/pdfinn/docs/file1.txt`. The `find` and
`list` tools work within that directory. The `write` tool can create files there (host paths are not
read-only by default).

---

## Naming: Why Not "agentcfg9p"?

The name "tools9p" was chosen when tool management was the only function. Adding path
management kept the unified model under the same server rather than splitting into two.
The name reflects the server's origin; the broader role is documented here.

A future rename to `agentcfg9p` or `capsrv9p` (capability server) would be accurate
but is not a priority.

---

## Security Properties

- Tool invocations run in a restricted namespace after `applynsrestriction()`
- They can only access paths named by the current tool capability set
- Paths registered via `bindpath` are stored as strings; tools9p exposes them only in
  each tool call's restricted namespace
- The agent cannot register arbitrary paths: restricted invocations do not see
  `/tool/ctl`, and child provisioning narrows requested paths through the
  parent's existing path capabilities

---

## CLI Parity

Veltro CLI and lucibridge both take `-p`; each passes it to the veltrosrv it starts
(`veltro -t` means extended thinking, not tools):

```sh
# CLI agent with specific paths:
veltro -p /n/local/Users/pdfinn/docs "Summarize all .md files"

# GUI bridge with initial configuration:
lucibridge -t read,list -p /n/local/Users/pdfinn/docs
```

In both cases veltrosrv writes the paths through the trusted control alias as
`bindpath` commands, making them visible in `/tool/paths` and to every later tool call.
