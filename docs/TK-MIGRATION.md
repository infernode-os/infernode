# Tk reintegration — migration guide

InferNode is moving its GUI apps off the bespoke native widget toolkit
(`module/widget.m` + `appl/lib/widget.b`) and back onto the classic
Inferno Tk toolkit, restyled to the brutalist "Brimstone" house look.
This is the working guide for that migration.

## Why / what

The native toolkit was the *replacement* for Tk. We are reverting to Tk
but keeping the flat, near-black, single-accent aesthetic the native
widgets established. The Tk **engine defaults** now carry that look (see
`libtk/colrs.c`), so migrated apps inherit it with no per-widget colours.

## The engine (already done)

- Tk (`$Tk` builtin + `libtk`) is re-enabled in the emu (`emu/*/emu`,
  `lib tk` + `mod tk`). The headless emu has an in-memory screen so
  `/dev/draw` — and therefore Tk — works without a display.
- `libtk/colrs.c` seeds every `TkEnv` with the Brimstone palette: surface
  `#080808`, text `#cccccc`, accent `#e8553a`, dim `#444444`, flat 1px
  borders (relief light/dark pinned to one border colour). Default font
  is `/fonts/combined/unicode.sans.14.font`.
- Window chrome (`appl/lib/titlebar.b`, `appl/lib/tkclient.b`) is
  brutalist: subdued frame, accent on focus, dark title strip.

## The app recipe

Replace `wmclient` + native widgets + manual `Draw` with `tkclient` + Tk
string commands:

```limbo
tkclient->init();
if(ctxt == nil) ctxt = tkclient->makedrawcontext();
(top, wmctl) := tkclient->toplevel(ctxt, "-width W -height H", "Title", Tkclient->Appl);
# build the UI with tk->cmd(top, "...")
tkclient->onscreen(top, nil);
tkclient->startinput(top, "kbd" :: "ptr" :: nil);
```

Event loop — let Tk own focus/editing/press-feedback; app actions arrive
on a **buffered** command channel:

```limbo
actch := chan[8] of string;
tk->namechan(top, actch, "act");
# button .b -command {send act save}   /   menu items: -command {send act <tok>}
for(;;) alt {
  c := <-wmctl or c = <-top.ctxt.ctl => tkclient->wmctl(top, c);
  k := <-top.ctxt.kbd               => handlekey(k);   # special keys, else tk->keyboard
  p := <-top.ctxt.ptr               => tk->pointer(top, *p);
  a := <-actch                      => handleaction(a);
}
```

Widget cheatsheet (all verified): `frame`, `label`, `button`, `entry`
(`-show *` for secrets), `checkbutton`/`radiobutton` (`-variable`),
`listbox` (+`scrollbar -command {.lb yview}`), `menu` (`add command`,
`post x y`), `text`, `image create bitmap` + `tk->putimage` + `label
-image`. Read state with `cget` / `.lb curselection` / `.e get` /
`variable v`. Theme-specific colours (accent, dim) read from `lucitheme`
and passed as `-foreground #rrggbbff`.

## Gotchas (learned empirically — mind these)

- **`-width`/`-height` are PIXELS, not characters** (unlike Tcl/Tk). A
  label `-width 10` clips to one glyph; reserve a pixel column (e.g.
  `-width 84`) for an aligned label column.
- **Action channels must be buffered.** A `send` fires inside the locked
  `tk->cmd`, so an unbuffered channel deadlocks. Use `chan[N]`.
- **No-window-manager busy-loop is a test artifact.** A full app's event
  loop spins on a ready ctl channel when run with no wm, holding the Dis
  VM. Don't try to spawn-and-snapshot a running app; render its command
  list instead (below). Under a real wm the channels block normally.
- Colours round-trip cleanly now (`cget -background` → `#080808ff`); if
  you see 16-hex-digit colours, the engine sign-extension fix regressed.

## Verifying a migration (do all of these)

1. **Compile**: `cd appl/wm && mk <app>.dis`.
2. **Smoke**: run it a few seconds; assert no `!`/`tk error` on stderr
   and graceful behaviour when a backing service is absent.
   `emu -c1 -r$PWD sh -c 'wm/<app>' 2>&1 | grep -i error`
3. **Visual**: replay the app's widget commands through the off-screen
   renderer and eyeball the PNG —
   `tools/tk-snapshot.sh layout.cmds out.png W H`
   (`tests/tkrender.b` builds a no-wm toplevel from a command list; no
   event loop, so no busy-wait.)
4. **Interaction / regression**: `tests/tk_test.b` covers the input
   paths (typed keys reach a focused entry, `.b invoke` fires commands,
   listbox/checkbutton/radiobutton state). Extend it for app-specific
   logic where practical.

## Status

| App | State |
|-----|-------|
| `wm/about` | migrated |
| `wm/keyring` | migrated |
| `wm/wallet`, `wm/settings` | form apps — same pattern as keyring |
| `wm/man`, `wm/editor`, `wm/shell` | text-widget apps |
| `wm/fractals`, `wm/matrix`, `wm/ftree` | canvas / custom draw |
| `charon/gui`, `matrix/*`, Lucifer core (`luciconv`/`lucipres`/`lucictx`) | pending |

When no app uses `widget.m` / `lucitheme`-via-widget anymore, delete
`module/widget.m`, `appl/lib/widget.b`, and their tests, and drop them
from the build + CI.
