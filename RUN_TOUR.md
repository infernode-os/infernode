# Running the Veltro Tour

The tour is an interactive demonstration that runs **inside** InferNode, where Veltro (the AI agent) uses its native tools to walk you through the system.

## Quick Start (Lucia GUI)

The recommended way to experience the tour is through Lucia, the three-zone GUI. When Lucia launches, a welcome document loads in the presentation zone. From the conversation zone, say:

```
run the tour
```

Veltro will create artifacts in the presentation zone, launch apps, demonstrate tools, and guide you through the system interactively.

## Quick Start (Terminal / Xenith)

From the infernode directory, start the emulator headless:

```sh
# macOS
./emu/MacOSX/o.emu -c1 -r$PWD sh -l

# Linux
./emu/Linux/o.emu -c1 -r$PWD sh -l

# Windows (from an x64 Native Tools Command Prompt)
.\emu\Nt\o.emu.exe -c1 -r%CD% sh -l
```

`-c1` enables the JIT; `-r$PWD` uses the working tree as the Inferno® root. See
[QUICKSTART.md](QUICKSTART.md#running-for-development) for the full launch matrix.

Once inside Inferno, at the `;` prompt:

```sh
; veltro 'run the tour'
```

Or start the REPL and ask for the tour:

```sh
; repl
> run the tour
```

## What the Tour Demonstrates

The tour has twelve sections, in this order:

1. **Welcome** — What you are looking at
2. **The three zones** — Conversation, Presentation, and Context
3. **What is 9P and why files?** — The idea the rest of the system rests on
4. **Launching apps** — The fractal viewer, Mandelbrot/Julia, driven by the agent
5. **The text editor** — Collaborative editing in the presentation zone
6. **Your namespace** — Security and control: what Veltro can see, and how you change it
7. **Finding and reading files** — Code navigation with `find`, `read`, and `list`
8. **Persistence** — Memory across sessions
9. **Voice** — Text-to-speech and speech-to-text
10. **The host OS bridge** — Accessing the host system
11. **More capabilities** — A tour of the tools not covered in detail: `todo`, `plan`, `spawn`, `webfetch`, `websearch`, `git`, `diff`, `json`, `charon`
12. **Where to go from here** — Next steps

## Welcome Document

On first launch, Lucia displays `/lib/veltro/welcome.md` in the presentation zone. This introduces the three-zone layout, lists things to try, and invites the user to run the tour.

## Tour Location

The tour script is at: `/lib/veltro/demos/tour.txt`

Veltro reads this script and executes it interactively. The tools it invokes are
`present`, `say`, `memory`, `read`, `launch`, `gap`, `list`, `fractal`, `find`,
`exec`, and `editor`.

## Requirements

- InferNode emulator running
- For the GUI tour: Lucia active (recommended)
- For the terminal tour: Xenith or terminal mode
- Optional: speech system for text-to-speech (`say` tool)

## Notes

The tour is **interactive** — Veltro pauses between sections and asks if you want to continue, repeat, or skip ahead. It launches real apps, draws real fractals, and creates real artifacts. It's designed to be hands-on, not just informational.
