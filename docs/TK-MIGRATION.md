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
- **Dynamic images update in place.** libtk now carries a
  Tk_ImageChanged-style notification (`tkimgchanged`, `libtk/label.c`,
  called from `Tk_putimage`): when `tk->putimage` replaces the content
  of a named bitmap image, every label-family widget already bound to
  that image (`-image NAME`) re-runs its geometry and redraws. Before
  this, a `label -image frac` created against an empty `image create
  bitmap frac` kept its zero size and rendered blank when the image was
  filled later, so apps had to re-issue `configure -image` after each
  `putimage`. They no longer do. This is what makes the canvas-style
  apps (`wm/fractals`) display.
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
   event loop, so no busy-wait.) For a **dynamic image** app (off-screen
   `Draw` image fed in with `putimage`, which a static command list can't
   exercise), use `tests/tkimgrender.b`: it allocates an image, draws
   solid-colour bands into it the way a compute proc does, composites it
   with `putimage`, and snapshots — isolating the new display surface
   from the unchanged compute core.
   `emu -c1 -r$PWD sh -c '/tests/tkimgrender.dis out.p9 W H'`
4. **Interaction / regression**: `tests/tk_test.b` covers the input
   paths (typed keys reach a focused entry, `.b invoke` fires commands,
   listbox/checkbutton/radiobutton state). Extend it for app-specific
   logic where practical.

## Status

| App | State | Pattern |
|-----|-------|---------|
| `wm/about` | migrated | label + image |
| `wm/keyring` | migrated | form (entry/listbox/button/menu) |
| `wm/wallet` | migrated | form + dropdown + two-pane |
| `wm/man` | migrated | text viewer (text widget + tags) |
| `wm/fractals` | migrated | dynamic image (off-screen draw + putimage) |
| `wm/ftree` | migrated | tree as listbox (flattened visible nodes) |
| `wm/settings` | pending | form (largest; theme switcher) |
| `wm/editor`, `wm/shell` | pending | editable text widget |
| `wm/matrix` + `matrix/*` | pending (design) | composition engine |
| `charon/gui` (+`layout`/`common`) | pending | HTML render + chrome |
| Lucifer core (`luciconv`/`lucipres`/`lucictx`) | pending | mixed |

### Notes for the pending migrations (learned while scoping)

- **editor / shell — let Tk own the editing.** The `text` widget is a
  full editing surface here: `tk->keyboard` inserts at the `insert`
  mark, `.t get a b` / `.t delete a b` / `.t index insert` / `.t mark
  set insert L.C` / `.t tag add sel …` all work (verified in the
  headless harness). So both apps can drop their bespoke line-buffer +
  cursor + selection code and keep only a thin bridge: editor's 9P
  server is already decoupled from the UI through the `editreq` channel
  (`Rgetbody`/`Rsetbody`/`Rdoctl`/…), so point `getbodytext`/`setbodytext`
  at `.t get 1.0 {end - 1 chars}` / `.t delete 1.0 end; .t insert end`,
  and re-express the doc-ctl verbs (goto/find/replace/save) as text-widget
  index ops. Undo is the one piece with no native equivalent — keep the
  existing undo stack or gate it behind the widget.
- **settings — pure form, but big.** Nine category panels, each a column
  of the form widgets already proven (radio groups, entries, listboxes,
  checkbuttons, buttons). The only non-mechanical part is the dynamic
  relayout that today re-reads config on every click; with Tk holding
  widget state that whole `*_set`/click-preservation dance disappears.
  Build the live theme switch on `lucitheme` → re-emit each toplevel's
  palette (the `retheme` wmctl other migrated apps already send).
- **matrix — needs design, not a mechanical port.** Its display modules
  (`matrix/position-table`, `signal-feed`, …) implement a fixed
  `draw(dst: ref Image)` contract and are composited into Lucifer's
  presentation zone; they are not standalone widget apps. Moving them to
  Tk means changing the composition contract (host hands each module a
  Tk frame/subwindow instead of an image). Decide that before touching
  the modules; until then their only `widget.m` use is `Scrollbar`.

Verified empirically and reusable:
- forms: entry (`-show *` for secrets), listbox+scrollbar, button, menu
  (`post`, `add command -command {send act X}`), choicebutton dropdown
  (read with `getvalue`), `.b invoke`, typed keys into focused entry;
- text viewer: `text` widget tags (heading/bold/italic/link), `-wrap
  none`, `search -nocase`, `tag add a a+Nc`, `see`, `yview scroll/moveto`;
- tree view: flatten the visible nodes and render them as `listbox`
  rows (indent with spaces, prefix an expand/collapse marker); drive
  selection with `.lb curselection` / `selection set` / `see`, expand on
  `<Double-Button-1>`, and reuse the row text for the AI-context dump;
- menus post at the pointer via `bind <Button-3> {send act menu %X %Y}`,
  with each item carrying its own action verb (`-command {send act foo}`)
  so there is no positional index to keep in sync;
- a status strip that doubles as a prompt: pack a hidden `entry` into the
  status row on demand, `focus` it, and read it back on `<Key-\n>` (embed
  the Escape rune via `sprint "<Key-%c>" 16r1b` — `\x1b` isn't a Limbo
  string escape).

When no app uses `widget.m` / `lucitheme`-via-widget anymore, delete
`module/widget.m`, `appl/lib/widget.b`, and their tests, and drop them
from the build + CI.
