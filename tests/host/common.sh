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

if [ -z "${ROOT:-}" ] || [ "$ROOT" = "." ]; then
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
    riscv64)        OBJTYPE=riscv64 ;;
    *) echo "SKIP: unsupported arch $(uname -m)"; exit 77 ;;
esac

EMU="$ROOT/emu/$EMUHOST/o.emu"
BINDIR="$ROOT/$EMUHOST/$OBJTYPE/bin"
LIMBO="$BINDIR/limbo"

export ROOT EMUHOST OBJTYPE EMU BINDIR LIMBO

# timeout(1) where there is one; macOS has none, and an emu told to halt
# exits by itself, bounded then by the CI job's own timeout
with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$@"
    elif command -v perl >/dev/null 2>&1; then
        # macOS has no timeout(1); without one an emu that never
        # halts held a CI job to its 40-minute limit.  SIGALRM's
        # status is 142, which emu_timeout_ok does not accept.
        perl -e 'alarm shift; exec @ARGV or exit 127' "$@"
    else
        shift
        "$@"
    fi
}

# A TCP port on the loopback that nothing is listening on: the system's
# choice where there is python3, else a guess from the process id.  A
# test's own port, so that it need not clear anybody off a port it
# shares (the secstore tests killed whatever held 5356: another test's
# emulator, or the user's own).
freeport() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
    else
        echo $((20000 + $$ % 20000))
    fi
}

emu_timeout_ok() {
    case "$1" in
        0|124|137) return 0 ;;
        *) return 1 ;;
    esac
}
