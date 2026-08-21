---
name: gui-test
description: Test and verify InferNode GUI work headlessly — boot Lucifer with no display, drive it through /mnt/ui, render Tk to PNG, screenshot a live session with scap, and inject synthetic input. Use whenever verifying GUI changes, writing GUI regression tests, or "checking whether it renders".
---

# Headless GUI testing

Contrary to older docs, the GUI is testable without a display. Four
harnesses; pick by goal:

| Goal | Harness |
|---|---|
| Assert a `/mnt/ui` contract: app launch, artifact routing, conversation flow | Full headless boot + driver script (below) |
| Fast `/mnt/ui` ctl semantics only | luciuisrv-only boot (~8 s) |
| "Does this widget/layout/theme render right" | `tools/tk-snapshot.sh` → PNG |
| Canvas/dynamic-image apps | `tests/tkimgrender.b` |
| Screenshot a live running desktop | `scap` + `tools/p9img2png.py` |
| Synthetic clicks/keystrokes | `/chan/uitest` (under `wm/wm`; routing into hosted Tk regions not yet verified) |
| Tk engine/widget API regression | `tests/tk_test.b` |

## Full headless Lucifer boot

Reference implementation: `tests/host/presentation_fileopen_test.sh`.

```sh
SDL_VIDEODRIVER=dummy timeout 85 "$EMU" -c1 \
    -pheap=1024m -pmain=1024m -pimage=1024m -g1024x768 -r"$ROOT" \
    /dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 50; $DRIVER" \
    </dev/null > "$LOG" 2>&1
```

Every element is load-bearing:
- `SDL_VIDEODRIVER=dummy` — windowless SDL. (This exact spelling; the
  underscored `SDL_VIDEO_DRIVER` appears only in a C comment.)
- `-g1024x768` — explicit geometry; the in-memory screen makes `/dev/draw`
  real with no display.
- `skiplogon=1` — bypasses `wm/logon`, which otherwise blocks on stdin
  until the timeout fires with an empty log. `noplumber=1` also exists.
- `run /lib/lucifer/boot.sh` — Inferno sh `run`, not POSIX `.`.
- The driver runs after the `sleep` in the boot's own shell, so it inherits
  `/chan` and `/mnt/ui`. Have it print `R_<NAME>_BEGIN`/`R_<NAME>_END`
  markers and extract sections host-side with `sed -n`/`grep` —
  deterministic, no pixels.

Driving through `/mnt/ui` (surface documented in the header of
`appl/cmd/luciuisrv.b`):

```sh
echo 'activity create Main' > /mnt/ui/ctl
echo 'create id=notes type=markdown label=Notes' > /mnt/ui/activity/0/presentation/ctl
echo 'center id=notes' > /mnt/ui/activity/0/presentation/ctl
echo 'role=human text=hello' > /mnt/ui/activity/0/conversation/ctl
cat /mnt/ui/activity/0/presentation/notes/type
```

Fast variant when you only need luciuisrv semantics:

```sh
./emu/MacOSX/o.emu -r. /dis/sh.dis -c "path=(/dis/veltro /dis/cmd /dis .); \
  luciuisrv; sleep 1; echo 'activity create Main' > /mnt/ui/ctl; \
  ls /mnt/ui/activity/0"
```

## Off-screen Tk render → PNG

```sh
tools/tk-snapshot.sh cmds.txt out.png 360 240
```

`cmds.txt` is one Tk command per line (`#` comments; `\n` becomes a real
newline). Internally: `tests/tkrender.b` builds a no-window-manager
toplevel and `writeimage`s it; `tools/p9img2png.py` decodes on the host.
The wrapper picks the platform emulator by `uname`; if an older checkout
errors about the Linux emu, run the two steps manually with
`emu/MacOSX/o.emu`.

Rules from `docs/TK-MIGRATION.md` (read its "Verifying a migration"
section): `-width`/`-height` are pixels, not characters; action channels
must be buffered or `send` inside `tk->cmd` deadlocks; render a full app's
command list rather than spawning the app (its event loop busy-spins with
no wm). Test under both themes by writing `brimstone` or `halo` to
`/lib/lucifer/theme/current` first. For canvas apps that draw into a
`Draw` image and `putimage` it, use `tests/tkimgrender.b`.

## Screenshot a live session — `scap`

`scap [outfile]` (default `/scap.img`) dumps the live display in Inferno
image format from inside a running emu — the only way to capture actual
rendered state of a full session:

```sh
SDL_VIDEODRIVER=dummy "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m \
  -g1024x768 -r"$PWD" /dis/sh.dis -l -c \
  "skiplogon=1; run /lib/lucifer/boot.sh & sleep 50; scap /tmp/shot.img"
python3 tools/p9img2png.py ~/.infernode/tmp/shot.img shot.png
```

Mind the decode path: under `sh -l` the profile binds `~/.infernode/tmp`
(and, after logon, `$home/tmp`) over `/tmp`, so the file lands there on
the host — NOT under `$ROOT/tmp`. (Verified end-to-end 2026-08-21: full
boot, scap, decode, correct 1024x768 render.)

Combine with a `/mnt/ui` driver before the `scap` call to screenshot a
specific app or state.

## Synthetic input — `/chan/uitest`

Under `wm/wm` (not lucifer), a file2chan driver accepts one command per
write: `ptr X Y BUTTONS` and `key RUNE` (decimal). Events enter the same
channels as real devices:

```sh
echo ptr 400 280 1 > /chan/uitest    # button 1 down
echo ptr 400 280 0 > /chan/uitest    # up
echo key 32 > /chan/uitest           # space
```

Its integration test is currently skipped pending verification of event
routing into hosted Tk regions — treat as available-but-unproven.

Also available: the Inferno sh Tk builtins (`man/1/sh-tk` — `load tk`,
`tk window`, `chan`/`send`) let a shell script create and drive Tk widgets
directly; currently unused by any test, but legitimate for harness work.

## Debugging a dev GUI session

Launch emu from a terminal (never the .app bundle for iteration) so
stdout/stderr stream; when the dev bundle is used, logs land in
`/tmp/infernode-dev.{out,err}`. GUI freezes with a live process are often
fd exhaustion — diagnose with `lsof` against the emu pid.
