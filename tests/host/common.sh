#!/bin/sh
# tests/host/common.sh — shared setup for host-side test scripts.
#
# Source from each test:
#     . "$(dirname "$0")/common.sh"
#
# Exports:
#     ROOT     — absolute path to the InferNode root (computed if unset or ".").
#     EMUHOST  — "MacOSX" on Darwin, "Linux" on Linux.
#     EMU      — $ROOT/emu/$EMUHOST/o.emu.
#
# On unsupported platforms the script exits 77 (skip), per run-tests.sh.

if [ -z "$ROOT" ] || [ "$ROOT" = "." ]; then
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi

case "$(uname -s)" in
    Darwin) EMUHOST=MacOSX ;;
    Linux)  EMUHOST=Linux  ;;
    *)      echo "SKIP: unsupported platform $(uname -s)"; exit 77 ;;
esac

EMU="$ROOT/emu/$EMUHOST/o.emu"

export ROOT EMUHOST EMU
