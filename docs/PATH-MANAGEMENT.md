# Path Management Design

## The Problem

The Lucifer GUI and the Veltro agent bridge (lucibridge) run in **separate Inferno processes**
with **separate namespaces**. A `sys->bind()` call in one process does not affect the other.

When a user binds a host directory in the GUI context zone (e.g., `/Users/pdfinn/docs`),
the agent needs to see that directory under `/n/local/docs`. But:

- The GUI click handler runs in lucictx (in the lucifer process)
- The agent namespace is managed by lucibridge (in a separate process)
- There is no direct IPC channel between them

---

## Why tools9p Is the Intermediary

tools9p is a **shared 9P file server** — mounted at `/tool` in the shell's namespace before
either lucifer or lucibridge starts. Both processes inherit `/tool` from the shell, so both
can read and write to the same server.

This makes tools9p the natural "configuration bus" between the GUI and the agent bridge:

```
GUI (lucictx)         tools9p          Agent bridge (lucibridge)
     │                   │                     │
     │ "bindpath /foo"   │                     │
     │──────────────────►│                     │
     │                   │  /tool/paths        │
     │                   │  now lists /foo     │
     │                   │                     │  on next turn:
     │                   │◄────────────────────│  read /tool/paths
     │                   │                     │  applypathchanges()
     │                   │                     │  sys->bind("/foo", "/n/local/foo")
```

The alternative — direct IPC between lucifer and lucibridge — would require a new protocol
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
| `bindpath <path>` | Register a host path; lucibridge binds it on next turn |
| `unbindpath <path>` | Unregister a path; lucibridge unmounts it on next turn |

GUI and launcher code write to the trusted control alias to configure the
agent's capabilities. Restricted tool invocations see `/tool` but not the
generic control file.

---

## How applypathchanges() Works

At the start of each agent turn, lucibridge:

1. Reads `/tool/paths` — newline-separated list of registered paths
2. Compares to `appliedpaths` (what it bound last turn)
3. For newly added paths: `sys->bind(path, "/n/local/<basename>", MBEFORE)`
4. For removed paths: `sys->unmount(nil, "/n/local/<basename>")`
5. Updates `appliedpaths`

This is a pull model — lucibridge checks for changes at its own pace (start of each turn),
not on every write to `/tool/ctl`. This avoids races and is consistent with how tool
changes are applied (also pulled at turn start).

---

## Path Visibility in the Agent

After `applypathchanges()` binds `/Users/pdfinn/docs` into `/n/local/docs`, the agent
(running inside lucibridge's namespace after `FORKNS + restrictns`) can see:

```
/n/local/docs/     ← host directory
  file1.txt
  file2.pdf
  ...
```

The `read` tool can then access `/n/local/docs/file1.txt`. The `find` and `list` tools
work within `/n/local/docs`. The `write` tool can create files there (host paths are not
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
- Paths registered via `bindpath` are stored as strings only — tools9p does not
  bind them itself; lucibridge applies the namespace view in its own process
- The agent cannot register arbitrary paths: restricted invocations do not see
  `/tool/ctl`, and child provisioning narrows requested paths through the
  parent's existing path capabilities

---

## CLI Parity

Both Veltro CLI and lucibridge support the same path flags:

```sh
# CLI agent with specific paths:
veltro -t "read,list,write" -p "/Users/pdfinn/docs" "Summarize all .md files"

# GUI bridge with initial configuration:
lucibridge -t "read,list" -p "/Users/pdfinn/docs"
```

In both cases the paths are written through the trusted control alias as
`bindpath` commands, making them visible to the tool ecosystem and ensuring
`applypathchanges()` picks them up.
