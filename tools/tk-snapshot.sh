#!/bin/bash
#
# tk-snapshot.sh CMDFILE OUTPNG [W H]
#
# Render a list of Tk commands off-screen (no window manager) and write a
# PNG, for visual regression checks of the brutalist Tk toolkit / app
# migrations. CMDFILE is one Tk command per line (# comments allowed).
#
# Runs tests/tkrender.dis inside the headless emulator (whose in-memory
# screen makes /dev/draw work without a display) and decodes the result
# with tools/p9img2png.py.
#
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMDFILE="$1"; OUTPNG="$2"; W="${3:-360}"; H="${4:-240}"
EMU="$ROOT/emu/Linux/o.emu"
[ -x "$EMU" ] || { echo "build the Linux emu first ($EMU)"; exit 1; }
# stage the command file inside the emu root
TMPC="$ROOT/.tksnap.cmds"
cp "$CMDFILE" "$TMPC"
"$EMU" -c1 -r"$ROOT" sh -c "/dis/tests/tkrender /.tksnap.cmds /.tksnap.img $W $H" 2>&1 | grep -vE 'fsqid' || true
python3 "$ROOT/tools/p9img2png.py" "$ROOT/.tksnap.img" "$OUTPNG"
rm -f "$TMPC" "$ROOT/.tksnap.img"
