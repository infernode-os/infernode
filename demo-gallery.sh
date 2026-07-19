#!/bin/bash
#
# demo-gallery.sh — the widget-gallery crystallisation, self-contained.
# Opens the Tk widget review gallery: engine defaults beside the
# proposed flat/padded InferNode treatment.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
[ -x "$EMU" ] || { echo "no emu at $EMU"; exit 1; }

exec "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g900x700 -r"$ROOT" \
  wm/wm sh -c "wm/matrix -g 800x600 /lib/matrix/compositions/widget-gallery & sleep 100000"
