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

case "$(uname -m)" in
    x86_64)         OBJTYPE=amd64 ;;
    aarch64|arm64)  OBJTYPE=arm64 ;;
    *) echo "SKIP: unsupported arch $(uname -m)"; exit 77 ;;
esac

EMU="$ROOT/emu/$EMUHOST/o.emu"
BINDIR="$ROOT/$EMUHOST/$OBJTYPE/bin"
LIMBO="$BINDIR/limbo"

export ROOT EMUHOST OBJTYPE EMU BINDIR LIMBO

emu_timeout_ok() {
    case "$1" in
        0|124|137) return 0 ;;
        *) return 1 ;;
    esac
}
