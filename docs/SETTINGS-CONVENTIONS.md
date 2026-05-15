# Settings conventions — extending `/dis/wm/settings`

This document is for contributors who want to add a new control to the Settings app (`appl/wm/settings.b` → `/dis/wm/settings.dis`) without inventing new patterns. Following it keeps the UI a thin shell over Plan-9-style file I/O and avoids one-off Limbo helpers accumulating in `settings.b`.

## The rule

**Settings reads files. Settings writes files. Settings does not exec shells, parse subprocess output, or contain per-setting state machines.**

A "setting" is some piece of host state — a config value, a daemon's on/off state, a routing decision. To make that state controllable from Settings, expose it as one or two files in the in-emu namespace, then teach `settings.b` to read/write those files.

The shape of the files depends on what kind of state it is.

## When state lives as a file → bind-mount

If the state already lives as a flat file on the host (a config file, a model name, a free-form URL), the simplest path is a **bind mount**.

Example: the existing `/lib/ndb/llm` file. The user's `$HOME/.infernode/lib/ndb/` is bind-mounted over `/lib/ndb` inside emu (`lib/sh/serve-profile`), so `settings.b` can `sys->open("/lib/ndb/llm", ...)` and do straight file I/O. No daemon, no special code.

This pattern fits when:
- The data is naturally a file.
- Reading or writing it doesn't have to trigger anything else.
- A simple `cat` / `echo > file` from a shell would do the same thing the GUI does.

The cost is one bind-mount line in a profile script. The benefit is that the file works the same way from a shell, from Settings, or from any other Limbo program.

## When state involves an action → synthetic FS

If changing the setting requires coordinated work — stop one daemon, start another, wait for health, then update a config file, with rollback on failure — a flat file isn't enough. Use a **synthetic 9P filesystem** served by a small Limbo daemon.

The shape is:

```
/<thing>/ctl       (rw)  write verbs that change state
/<thing>/status    (r)   read current live state
```

This is the same pattern `tools9p` already uses for `/tool/ctl` + `/tool/budget` + `/tool/tools`. Settings reads/writes those files with `sys->open` / `sys->read` / `sys->write`. The daemon serving the files decides what to do for each verb — usually it crosses to the host via `os(1)` for the side effect.

Use this pattern when:
- Changing the setting requires more than a single file write.
- Live state can drift from any stored config (e.g. someone manually started a daemon).
- Headless callers should be able to do the same thing as the GUI by writing to the same `ctl` file.

## The host-touching template

For settings that have to mutate **host** state (start/stop a systemd user unit, edit a file in `$HOME` that isn't bind-mounted, run a host binary), keep the Limbo side a thin shell over a single host bash tool. Three pieces:

1. **Host bash tool** at the repo root (sibling of `serve-llm.sh`). Owns all the systemctl + filesystem + curl work. Has subcommands like `status`, `set <target>`, `health`. Callable from any shell over SSH — that's the headless code path.

2. **In-emu Limbo daemon** in `appl/cmd/`. Serves `/<thing>/ctl` and `/<thing>/status`. For each verb received on `ctl`, validates it against a whitelist, then calls `os <hostbin> <verb>` via `Sh->system`. For each read of `status`, calls `os <hostbin> status` and returns the output.

3. **Settings extension** in `appl/wm/settings.b`. Adds a widget (radio, checkbox, textfield) whose state is read from `/<thing>/status` at panel-open time. On Apply, writes the matching verb to `/<thing>/ctl`. Nothing else.

The daemon is the "trust boundary" — it's what enforces the whitelist of allowed verbs. The GUI never invents a verb; the host bash never sees an unvalidated one. A shell user writing to `/<thing>/ctl` goes through the same validation as the GUI.

## Worked example: `llmctl` / `llmctl9p` / settings LLM panel

The first instance of this pattern is the local-LLM backend switcher. It serves three purposes:
- Lets a user pick between Ollama and SGLang for the local backend.
- Updates the in-emu config (`/lib/ndb/llm`) so other in-emu daemons dial the right URL.
- Stops and starts host systemd user units (mutually exclusive — only one local backend resident at a time).

Layering:

```
                  ┌────────────────────────────────────────────┐
                  │  dis/wm/settings.dis                       │
                  │    on Apply:                               │
                  │      write "set sglang" to /llm/ctl        │
                  │    on panel open:                          │
                  │      read /llm/status                      │
                  └────────────────┬───────────────────────────┘
                                   │ Sys file I/O
                                   ▼
                  ┌────────────────────────────────────────────┐
                  │  /dis/llmctl9p.dis  (in-emu daemon)        │
                  │    validates verb against whitelist        │
                  │    Sh->system("os llmctl <verb>")          │
                  └────────────────┬───────────────────────────┘
                                   │ os(1) crosses to host
                                   ▼
                  ┌────────────────────────────────────────────┐
                  │  llmctl  (host bash, repo root)            │
                  │    systemctl --user stop/start             │
                  │    curl for health probe                   │
                  │    edit $HOME/.infernode/lib/ndb/llm       │
                  └────────────────────────────────────────────┘
```

Files (read each for the template):

| Layer | File | Why this shape |
|---|---|---|
| Host | `llmctl` | Single point of authority over systemctl + ndb. Subcommands; rollback on failure. POSIX-friendly bash with `set -euo pipefail`. |
| In-emu | `appl/cmd/llmctl9p.b` | Serves `/llm/{ctl,status}` via styxservers + nametree. Verb whitelist. Synchronous `os` call (host work may take ~60s — settings should spawn the write off-thread for that case). |
| Settings | `appl/wm/settings.b` (CatLLM region) | Reads `/llm/status` for the radio default. Writes "set X" to `/llm/ctl` on Apply. ~80 lines of additions; no new state machines. |
| Test | `tests/host/llmctl_test.sh` | PATH-mocked systemctl + curl; exercises the bash tool without touching real backends. |

## Anti-patterns to avoid

- **Embedding subprocess parsing in `settings.b`.** If you find yourself writing `Sh->system` in `settings.b` and parsing its stdout, the work belongs in a daemon serving a `ctl`/`status` pair instead.
- **One ctl-file with magic verbs that fan out to many subsystems.** Each subsystem gets its own `<thing>/{ctl,status}`. They compose well — settings.b just touches multiple files.
- **Skipping the host tool and `os`-ing directly from the daemon.** The host bash tool is what lets headless shell users do the same thing (over SSH or otherwise). Without it the GUI is the only entry point.
- **`Conflicts=` between daemon units that the switcher manages.** systemd will then unexpectedly stop one when the other starts — the switcher is supposed to own that ordering. Use plain `After=` for ordering, not `Conflicts=`.
- **Long blocking work in a `Twrite` reply without surfacing it.** If the host action takes more than ~2s, surface a "switching…" flashstatus in the GUI before the write, or refactor to a worker channel.

## Checklist for adding a new settings control

- [ ] What kind of state is this — flat file, or coordinated action?
- [ ] If flat file: is there already a bind-mount that puts it inside the in-emu namespace? If not, add one in the appropriate profile (`lib/sh/profile`, `lib/sh/serve-profile`, or wherever the session starts).
- [ ] If action: write the host bash tool first (subcommands + rollback). Add a test under `tests/host/`.
- [ ] Write the in-emu Limbo daemon (`appl/cmd/<thing>9p.b`). Whitelist the verbs. Compile-check with `limbo -I$ROOT/module appl/cmd/<thing>9p.b`.
- [ ] Add the daemon to `appl/cmd/mkfile`'s `TARG=` list so `mk install` picks it up.
- [ ] Add a `mount {<thing>9p ...} /<thing>` line in the appropriate profile.
- [ ] Extend `appl/wm/settings.b`: state vars, layout block (under the right category), draw, click handler, apply handler. Read `/<thing>/status` on layout for the default.
- [ ] Document the new setting at the top of `settings.b`'s comment block.

## Where this fits in the bigger picture

The Settings app is the user-facing entry point for InferNode configuration. The synthetic-FS pattern keeps it loosely coupled to the rest of the system: any subsystem that exposes a `ctl`/`status` pair becomes settable from the GUI without changing settings.b's core, and any subsystem that doesn't need GUI exposure just keeps its files on disk.

The headless story comes for free: every `ctl` file is writable from `echo "..." > /<thing>/ctl` in any shell. Test scripts, automation, and SSH-driven workflows all use the same surface as the GUI.

When in doubt, copy the `llmctl` / `llmctl9p` / settings.b CatLLM triple and rename. It is the canonical worked example.
