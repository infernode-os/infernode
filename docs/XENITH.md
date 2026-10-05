# Xenith - AI-Native Text Environment

Xenith is InferNode's default graphical user interface, a fork of the Acme editor optimized for AI agents and AI-human collaboration.

## Overview

Xenith maintains Acme's elegant text-based philosophy while adding capabilities specifically designed for AI integration:

- **9P Filesystem Interface** - Agents interact via standard file operations
- **Namespace Security** - Capability-based access control for AI containment
- **Observable Operations** - All agent activity visible to humans
- **Multimodal Support** - Text and images in the same environment
- **Dark Mode** - Plan 9's colours (`glenda`) for light, a measured dark theme (`xenith`), or any system theme

## Why Xenith for AI?

### The Filesystem is the API

Unlike JSON-RPC protocols (MCP) or REST APIs, Xenith exposes everything as files:

```
/mnt/xenith/
├── new                  # Create window (write returns ID)
├── focus                # Current focus window
└── <id>/
    ├── body             # Window text content
    ├── tag              # Title/command line
    ├── addr             # Text address (selection range)
    ├── ctl              # Control commands
    ├── event            # Event stream
    ├── colors           # Per-window theming
    └── image            # Image display control
```

An AI agent reads and writes files. No SDK required. No parsing required. LLMs understand filesystem operations naturally.

### Namespace-Based Security

Inferno®'s namespace model provides capability-based security:

```limbo
# Agent sees only what you bind:
sys->bind("/services/llm", "/llm", Sys->MREPL);
sys->bind("/tools/safe", "/tools", Sys->MREPL);
sys->bind("/tmp/scratch", "/scratch", Sys->MCREATE);
# Nothing else exists from agent's perspective
```

Benefits:
- **Explicit grants** - Agent cannot access unbounded resources
- **Observable** - Human sees all namespace bindings
- **Dynamic** - Grant or revoke capabilities at runtime
- **No escape** - Namespace boundary is enforced by kernel

### Human-AI Collaboration

Xenith windows are shared workspaces:

```
┌─ Source Code ─────────────┐   ┌─ Agent Dialog ────────────┐
│ func main() {             │   │ Human: Add error handling │
│   // Code here            │   │ Agent: I'll wrap this in  │
│ }                         │   │ a try-catch block...      │
└───────────────────────────┘   └───────────────────────────┘
```

- Human edits appear as events to the agent
- Agent modifications are visible immediately
- Middle-click executes commands (Acme-style)
- Both parties work on the same text

## Features

### Themes

Xenith takes its colours from the system theme (`/lib/lucifer/theme`,
the same files every InferNode program uses) and follows it live: write
a theme's name to `/lib/lucifer/theme/current`, or pick one in Settings,
and Xenith recolours within a second, on the desktop or off it.

The `Theme` command (type it in a tag and middle-click, like `Font`)
switches: `Theme halo` to a named theme, `Theme` alone to the next one
installed.

`-t name` pins a session to one theme instead, which the system's
switches then leave alone; `Theme` in a pinned session changes that
session only. `tools/xen` starts Xenith pinned to `xenith`, the dark
theme: Xenith's original Catppuccin Mocha, corrected against the reading
research (dark grey behind off-white, every colour read as text at 7:1
or better, selections bright enough to see with the text on them still
at body contrast; [THEME-RESEARCH.md](THEME-RESEARCH.md) gives the
evidence, the numbers and the sources).
`glenda` is Plan 9's own colours, acme's to the pixel, and the light
theme to prefer; `-t plan9` and `-t acme` name it too.

```sh
xenith               # follow the system theme
xenith -t xenith     # this session: the xenith theme
xenith -t glenda     # this session: Plan 9's acme, exactly
```

A theme maps onto Xenith by role: body from the theme's `edit*` colours,
tags from `header` and `text`, selections from `menuhilit`, frame borders
from `accent` and `border`, and the button 2, button 3 and modified
colours from `red`, `green` and `yellow`. Any colour can still be set
directly with environment variables, which win over the theme, as
`acme-*` do in acme:

```sh
xenith-bg-text-0='#1E1E2E'	# body background
xenith-fg-text-0='#CDD6F4'	# body text
```

### Fonts

Xenith reads in Go and Go Mono, the faces Bigelow & Holmes (Lucida's
designers) drew for the Go project: a humanist sans and a slab-serif
monospace with the same x-height, so `Font` switches between them
without the text changing size, and with the characters code confuses
(`Il1|`, `0O`, `5S`, `8B`) drawn apart. Noto Serif, chosen for an
x-height that matches theirs, is the serif.

They are set at 14 pixels to the em, which puts the x-height at about
0.17 degrees on a laptop at 50 cm: above the critical print size, below
which reading slows, of readers into their late sixties, with a margin
for light text on dark. Larger buys no speed, only fewer lines on the
screen. 16 and 18 are for a monitor further away, or older eyes.
[THEME-RESEARCH.md](THEME-RESEARCH.md) has the evidence for the faces
and the size.

| Font file | Face |
|---|---|
| `/fonts/combined/go.14.font` | Go: the default |
| `/fonts/combined/gomono.14.font` | Go Mono: the fixed-width font, `Font` toggles to it |
| `/fonts/combined/serif.14.font` | Noto Serif |

Each is also built at 16 and 18 (`go.16.font`, `serif.18.font`, ...).
`Font` with a file name sets a window's font (`Font
/fonts/combined/serif.14.font`), and `-f` and `-F` (or the `xenith-font`
and `xenith-Font` environment variables) set the two defaults:

```sh
xenith -f /fonts/combined/serif.14.font		# serif by default
xenith -f /fonts/combined/go.16.font -F /fonts/combined/gomono.16.font	# larger
```

Characters the faces lack fall back to DejaVu. `tools/gen-text-fonts.py`
regenerates the bitmaps from the TrueType sources (Go's are in
`fonts/go`; the script says where to fetch Noto Serif's).

### Opening host files

`tools/xen file ...` runs Xenith by itself, dark and filling the emu
window, on files from the host; Exit ends the instance. See [XEN.md](XEN.md).

### Image Display

Xenith supports inline image display (PNG, PPM formats):

```bash
# Load image in window
echo 'image /path/to/diagram.png' > /mnt/xenith/1/ctl

# Query image info
cat /mnt/xenith/1/image
# Returns: /path/to/diagram.png 800 600

# Clear image, return to text
echo 'clearimage' > /mnt/xenith/1/ctl
```

Useful for AI-generated visualizations, charts, and diagrams.

### Event Streams

Agents can monitor user activity:

```limbo
fd := sys->open("/mnt/xenith/1/event", Sys->OREAD);
for(;;) {
    n := sys->read(fd, buf, len buf);
    # Event format: "type origin q0 q1 flags length text"
    # React to user edits, selections, commands
}
```

Event types include insertions, deletions, selections, and command executions.

## Built-in Editor (`wm/editor`)

InferNode includes a standalone text editor with a modern feature set, accessible both from the GUI and via 9P for agent control.

### Features

- **Undo / Redo** — Ctrl-Z / Ctrl-Y with separate undo and redo stacks
- **Find & Replace** — Ctrl-F (find), Ctrl-H (find & replace), with wrap-around and replace-all
- **Selection** — Double-click selects word, triple-click selects line (400ms detection window)
- **Keyboard shortcuts** — Unix cursor navigation (Ctrl-A/E/K/U), macOS Cmd shortcuts mapped to control chars
- **Status bar** — Shows file path, line/column, dirty indicator, search state

### 9P IPC Interface

The editor mounts a 9P filesystem for programmatic control, used by the Veltro `editor` tool:

```
/edit/
├── ctl              Global: open <path>, new, quit
├── index            List of open document IDs
└── {id}/
    ├── body         Document text (read/write)
    ├── ctl          Per-doc: save, saveas, goto, find, insert, delete, replace, replaceall
    ├── addr         Cursor position (read: "line col", write: set position)
    └── event        Blocking read for events (modified, opened, quit)
```

### Agent Integration

The Veltro `editor` tool uses IPC to let agents read, edit, and navigate open documents:

```sh
# Agent opens a file
echo 'open /appl/cmd/hello.b' > /edit/ctl

# Agent reads the document
cat /edit/1/body

# Agent inserts text at line 5, column 1
echo 'insert 5 1 # new comment' > /edit/1/ctl

# Agent finds and replaces
echo 'replaceall oldvar	newvar' > /edit/1/ctl    # tab-separated
```

## Architecture

### Comparison with Acme

| Aspect | Acme | Xenith |
|--------|------|--------|
| Colors | Hardcoded pastels | 20+ customizable + dark theme |
| Images | Text only | PNG/PPM display |
| Per-window UI | Standard | Custom color schemes |
| AI focus | Generic editor | Agent-friendly design |
| Code size | ~16K lines | ~21K lines |

### Key Modules

| Module | Purpose |
|--------|---------|
| `xenith.b` | Main entry, theming |
| `fsys.b` | 9P filesystem interface |
| `exec.b` | Command execution |
| `asyncio.b` | Async I/O primitives |
| `imgload.b` | Image loading (PNG/PPM) |
| `wind.b` | Window management |
| `text.b` | Text editing |

## Usage

### Starting Xenith

```bash
# From InferNode
xenith

# With the dark theme
xenith -t xenith

# With a specific font
xenith -f /fonts/combined/serif.14.font
```

### Agent Interaction Example

```python
# Pseudocode for an AI agent

# 1. Create a window
write("/mnt/xenith/new/ctl", "scratch")
# Returns window ID, e.g., "3"

# 2. Write content
write("/mnt/xenith/3/body", "Analysis results:\n...")

# 3. Read user selection
selection = read("/mnt/xenith/3/rdsel")

# 4. Monitor events
for event in read_stream("/mnt/xenith/3/event"):
    if event.type == "insert":
        # User added text, respond...
```

### Mouse Chords (Acme Heritage)

- **B1 (Left)** - Select text
- **B2 (Middle)** - Execute selection as command
- **B3 (Right)** - Search/look up selection

## Design Philosophy

Xenith follows the principle: **"Minimal mechanism, maximal capability."**

From the Plan 9 tradition:
- Everything is a file
- Text is the universal interface
- Composition over configuration
- Small, sharp tools

Applied to AI:
- Filesystem operations are universal
- Observable beats opaque
- Human remains in control
- Capabilities are explicit

## Future Directions

Planned enhancements (see `IDEAS.md`):

- **Graphics languages** — `pic`, `grap` for diagrams
- **Audio support** — Voice I/O via `/dev/audio`
- **Structured data** — JSON/tree viewers
- **Token accounting** — LLM cost tracking

## See Also

### Learning Acme

Xenith inherits Acme's interaction model. These resources explain the fundamentals:

- [A Tour of Acme](https://www.youtube.com/watch?v=dP1xVpMPn8M) - Russ Cox's video tutorial (recommended starting point)
- [Acme homepage](http://acme.cat-v.org) - Documentation, resources, and community
- [Acme: A User Interface for Programmers](http://doc.cat-v.org/plan_9/4th_edition/papers/acme/) - Rob Pike's original paper

### Xenith-Specific

- `appl/xenith/DESIGN.md` - Detailed design rationale
- `appl/xenith/IDEAS.md` - Feature roadmap
- `appl/xenith/IMAGE.md` - Image implementation details

## License

MIT License (as per InferNode)
