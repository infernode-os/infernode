# Lucia

**Purpose:** User and operator guide for Lucia, InferNode's desktop UI — a three-zone tiling environment for AI-assisted work.

> Looking for the production-readiness audit (P0/P1/P2 issues)? See [LUCIA-EVALUATION.md](LUCIA-EVALUATION.md). This document is the user-facing guide.

## What it is

Lucia is a fullscreen Limbo application that splits the display into three vertical zones:

```
+----------------+--------------------+----------------+
| Conversation   |   Presentation     |   Context      |
|     ~30%       |       ~45%         |     ~25%       |
|                |                    |                |
| chat with the  | artifacts:         | resources,     |
| agent;         | docs, code, PDF,   | knowledge      |
| send/voice/    | mermaid, images,   | gaps, running  |
| reset; tiles   | and live apps      | tasks, tool    |
| with buttons   | (editor, shell,    | toggles        |
|                | fractal, charon)   |                |
+----------------+--------------------+----------------+
| header bar: logo · activity label · status · accent  |
+------------------------------------------------------+
```

The agent (Veltro, via `lucibridge`) drives the right- and centre-zones by writing to a synthetic 9P filesystem mounted at `/mnt/ui`. Everything you see is a file, and everything the agent does is a write.

## Launching

### macOS / generic

```sh
./run-lucia.sh
```

### Linux

```sh
./run-lucia-linux.sh
./run-lucia-linux.sh -g 1920x1080      # custom geometry
```

Both scripts:

1. Set memory limits: `-pheap=512m -pmain=512m -pimage=512m`.
2. Start `luciuisrv` (the UI 9P filesystem at `/mnt/ui`).
3. Create the `Main` activity.
4. Start `speech9p` (TTS/STT, mounted at `/n/speech`).
5. Start `tools9p` (tool registry at `/tool` with the default capability budget — see below).
6. Start `lucibridge` (the agent loop) in the background.
7. Create a `taskboard` artifact in the presentation zone.
8. Run `lucifer` (the window owner).

The LLM backend (`llmsrv`) is started by `lib/sh/profile` from `sh -l`, so the launch script does not start it directly. Set `ANTHROPIC_API_KEY` in the host environment before launching; the profile provisions it into factotum.

### What you need

- A built emulator (`emu/MacOSX/o.emu` or `emu/Linux/o.emu`) with SDL3 GUI support.
- `ANTHROPIC_API_KEY` exported in the host shell (otherwise AI features stay dark; the UI still renders).

## The three zones

### Conversation (`luciconv.b`, left ~30%)

- Chat history with the agent.
- Text input field at the bottom.
- Tag bar at the top: **Send · Voice · Clear · Reset · Delete**.
- Renders interactive **dialogue tiles** and **forms** — messages can carry buttons; clicking one writes the option text back to the conversation as a user message.
- All keyboard input across the screen routes here, regardless of which zone the mouse is over.

### Presentation (`lucipres.b`, centre ~45%)

Hosts artifacts. Each artifact is a tab. Supported types:

| Type        | Renders                                |
|-------------|-----------------------------------------|
| `text`      | plain text                              |
| `code`      | syntax-highlighted source               |
| `markdown`  | rendered markdown                       |
| `doc`       | markdown with layout                    |
| `mermaid`   | mermaid diagrams → SVG                  |
| `pdf`       | PDF viewer with page navigation         |
| `image`     | raster images (PNG, JPEG, GIF)          |
| `app`       | a live app window (editor, shell, fractal, charon) |
| `taskboard` | kanban-style task cards                 |

A small `wmsrv` runs inside `lucifer.b` (the `preswmloop`) so app artifacts get a real `wmclient` window and behave like normal Inferno® apps.

### Context (`lucictx.b`, right ~25%)

- **Resources** — files and URLs the agent has surfaced.
- **Gaps** — things the agent flagged as missing (knowledge, files, capabilities).
- **Tasks** — in-flight background work.
- **Tool toggles** — enable/disable tools at runtime; reflects bindings in `/tool`.

## Components (source layout)

The internal module names use the `luci-` prefix; this is an implementation detail and not a user-facing brand.

| File (in `appl/cmd/`) | Role |
|-----------------------|------|
| `lucifer.b`     | Main window owner. Header bar, separators, mouse routing, mini wmsrv for the presentation zone, font and theme loading. |
| `luciconv.b`    | Conversation zone implementation. |
| `lucictx.b`     | Context zone implementation; mounts `/tool` for tool discovery. |
| `lucipres.b`    | Presentation zone implementation; renderer registry and app lifecycle. |
| `luciuisrv.b`   | 9P server backing `/mnt/ui`. Activities, conversation, presentation, context — all UI state lives here. |
| `lucibridge.b`  | Agent bridge. Reads user input from `/mnt/ui/activity/N/conversation/input`, runs the Veltro tool loop, writes responses back. |
| `lucitheme.b`   | Theme loader and colour lookup. |

## Filesystem map

Lucia stitches together several 9P services. Once the UI is up, you can `cat` any of these from a shell.

| Mount        | Server      | What lives there |
|--------------|-------------|------------------|
| `/mnt/ui`      | luciuisrv   | All UI state. `/mnt/ui/ctl` to create/delete activities; `/mnt/ui/activity/N/{conversation,presentation,context}` for each zone. |
| `/mnt/llm`     | llmsrv      | LLM sessions. `/mnt/llm/new` clones a fresh session; each `/mnt/llm/N/` exposes `ask`, `stream`, `model`, `thinking`, `system`, `compact`, `context`. |
| `/n/speech`  | speech9p    | `say` (write text → TTS), `hear` (write `start`, then read transcription), `voices`, `ctl`. |
| `/tool`      | tools9p     | Tool registry. `/tool/tools` lists tools; `/tool/paths` lists exposed host paths; `/tool/ctl` toggles state. |
| `/n/local`   | (lucibridge)| Read-only host paths plus per-activity writable directories. |

### Activities

An **activity** is a conversation session. The launch script creates `Main` (id `0`); you can add more via:

```
; echo activity create Sidebar > /mnt/ui/ctl
```

Each activity is rooted at `/mnt/ui/activity/N/` with three subtrees mirroring the zones. Multiple activities can run; the header bar shows the focused one.

### Driving the UI from the shell

The presentation zone's control file is `/mnt/ui/activity/N/presentation/ctl`. Examples:

```
; echo 'create id=notes type=markdown label=Notes' > /mnt/ui/activity/0/presentation/ctl
; echo 'create id=todo  type=taskboard label=Tasks' > /mnt/ui/activity/0/presentation/ctl
; echo 'destroy id=notes'                          > /mnt/ui/activity/0/presentation/ctl
```

This is the same surface the agent uses — so anything Veltro does, you can do by hand.

## Voice

Click **Voice** in the conversation zone:

1. `luciconv` spawns a `voiceworker` goroutine.
2. The worker writes `start` to `/n/speech/hear` (speech9p) and reads the transcription (30-second timeout).
3. On success, the transcribed text is written to `/mnt/ui/activity/N/conversation/input` as a user message.
4. The agent's reply can optionally be read back by writing it to `/n/speech/say`.

`speech9p` is started by the launch script; it ships with InferNode and runs entirely inside the emulator.

## Themes

Themes live in `lib/lucifer/theme/`:

```
lib/lucifer/theme/
├── current        # one line: name of the active theme
├── brimstone      # default dark theme (key/value, hex colours)
└── halo           # alternate
```

Theme files are flat `key value` pairs (`#` comments allowed). The launch script writes `brimstone` to `current` if no theme is selected. Custom themes go alongside; `lucitheme.m` defines about 80 colour keys (core UI, conversation, code, editor, mermaid, menu, window chrome). Missing keys fall back to Brimstone defaults — partial themes are fine.

To switch:

```sh
echo halo > lib/lucifer/theme/current
# restart Lucia
```

## The default tool budget

`tools9p` is started with these capabilities (see `run-lucia*.sh`):

```
-b read,list,find,search,grep,write,edit,exec,launch,spawn,diff,json,http,
   git,memory,todo,plan,websearch,mail,keyring,present,gap
```

The `-b` list is the **delegation budget** — the maximum a parent agent can hand to a `spawn`'d child. The trailing positional args are the tools loaded for the bridge agent itself. To run more locked down, edit the launch script and remove tools.

For details on what each tool does and how capability attenuation works, see [VELTRO.md](VELTRO.md) and [appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md).

## Multiple activities, scripted setup

You can pre-populate Lucia at launch by appending commands to the launch command in `run-lucia*.sh`. Example: open the Veltro tour artifact and a fractal app on startup.

```
echo 'create id=tour    type=markdown   label=Tour'   > /mnt/ui/activity/0/presentation/ctl
echo 'create id=fractal type=app app=fractal label=Fractal' > /mnt/ui/activity/0/presentation/ctl
```

Anything you can write through `/mnt/ui/...` from a normal shell works at startup too.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Blank black window, no header | `lucitheme` failed to load (corrupted `.dis`, missing file). | Rebuild: `cd appl/cmd && mk lucitheme.dis`. See [LUCIA-EVALUATION.md §P0.1](LUCIA-EVALUATION.md). |
| `ANTHROPIC_API_KEY not set` warning | Host env var missing | `export ANTHROPIC_API_KEY=sk-ant-…` and relaunch. |
| Voice button does nothing for 30s | `speech9p` not running, or no host audio access | Check `/n/speech` exists; on Linux confirm PulseAudio/PipeWire is reachable from the emulator. |
| `link typecheck` errors at startup | Stale `.dis` after a `git pull` | `./hooks/install.sh` (one-time) or `cd appl/cmd && mk install`. |
| Apps fail to launch in the presentation zone | `MAXAPPSLOTS` (16) exhausted | Restart Lucia. Tracked as a known issue in [LUCIA-EVALUATION.md §P0.2](LUCIA-EVALUATION.md). |
| Header shows no activity label | `nslistener` isn't seeing `status`/`label` events | Confirm `luciuisrv` is running: `ps | grep luciuisrv`. |

## See also

- [USER-MANUAL.md](USER-MANUAL.md) — namespace and host-integration basics.
- [VELTRO.md](VELTRO.md) — the agent system that drives Lucia.
- [XENITH.md](XENITH.md) — the AI-native text environment used inside the presentation zone.
- [LUCIA-EVALUATION.md](LUCIA-EVALUATION.md) — production-readiness audit (P0/P1/P2 issues).
- [DIALOGUE-TILES.md](DIALOGUE-TILES.md) — interactive dialogue/form tile reference.
- [appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md) — namespace isolation model.
