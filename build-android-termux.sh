#!/bin/sh
#
# Phase 0 build driver for InferNode on Android via Termux.
#
# This is the "hellaphone" build -- InferNode targeting a mobile phone.
# For Phase 0 we piggyback on the emu/Linux/ target: Termux on ARM64
# Android is close enough to ARM64 Linux that we can bootstrap mk,
# build limbo, and produce a working o.emu without writing emu/Android/
# platform glue first.
#
# Output lands in $ROOT/Linux/arm64/ and $ROOT/emu/Linux/o.emu, mirroring
# the Linux ARM64 build exactly. Phase 1 will switch to SYSHOST=Android
# once emu/Android/ has real Bionic / NDK platform code.
#
# See:
#   docs/HELLAPHONE.md         user-facing setup, prereqs, troubleshooting
#   emu/Android/README.md      directory status and phase plan
#   INFR-107                   tracking epic
#
# Usage (run inside Termux on the device):
#   pkg install -y clang make binutils pkg-config which perl
#   ./build-android-termux.sh             # headless (recommended)
#   ./build-android-termux.sh sdl3        # SDL3 GUI (unlikely to work on Termux)
#

set -e

GUIMODE="${1:-headless}"

echo "=== InferNode Android/Termux Build (Phase 0) ==="
echo "GUI backend: $GUIMODE"
echo ""

# --- Termux sanity check ---------------------------------------------------
UNAME_O="$(uname -o 2>/dev/null || echo unknown)"
if [ -z "$PREFIX" ] || [ "$UNAME_O" != "Android" ]; then
    echo "WARNING: this script expects Termux on Android."
    echo "  Detected: \$PREFIX=$PREFIX, uname -o=$UNAME_O"
    echo "  Continuing anyway, but you probably want build-linux-arm64.sh instead."
    echo ""
fi

# --- Tool discovery --------------------------------------------------------
CC="${CC:-clang}"
if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: compiler '$CC' not found on PATH."
    echo "  In Termux:  pkg install clang"
    exit 1
fi

SH_BIN="$(command -v sh || true)"
if [ -z "$SH_BIN" ]; then
    echo "ERROR: sh not found on PATH."
    echo "  In Termux:  pkg install which"
    exit 1
fi
# InferNode's awk is a Limbo program (appl/cmd/awk.b -> dis/awk.dis); the
# Plan 9 mk bootstrap does not invoke a host awk, so we deliberately do
# NOT require one here. mkfiles/mkhost-Linux defines AWK=awk but no mkfile
# in the bootstrap reads $AWK.

for t in ar strip make; do
    if ! command -v "$t" >/dev/null 2>&1; then
        echo "WARNING: '$t' not on PATH (may be needed later)."
        echo "  In Termux:  pkg install binutils make"
    fi
done

# --- Environment -----------------------------------------------------------
# Phase 0 piggybacks on the Linux build: keep SYSHOST=Linux so the
# existing pipeline routes through emu/Linux/ and Linux/arm64/.
export ROOT="$(cd "$(dirname "$0")" && pwd)"
export SYSHOST=Linux
export SYSTARG=Linux
export OBJTYPE=arm64

mkdir -p "$ROOT/Linux/arm64/bin"
mkdir -p "$ROOT/Linux/arm64/lib"

export PATH="$ROOT/Linux/arm64/bin:$PATH"
export SHELL="$SH_BIN"
export SHELLNAME=sh

echo "ROOT=$ROOT"
echo "CC=$CC"
echo "SHELL=$SHELL"
echo ""

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
    echo "Warning: expected aarch64, got $ARCH. Build may not work."
    echo ""
fi

# Compiler flags. -DANDROID_TERMUX is a marker future C code can use to
# conditionally adjust Bionic-vs-glibc differences without forking files.
CFLAGS="-g -O -fno-strict-aliasing -fno-omit-frame-pointer -fcommon -fstack-protector-strong"
CFLAGS="$CFLAGS -I$ROOT/Linux/arm64/include -I$ROOT/utils/include -I$ROOT/include"
CFLAGS="$CFLAGS -DLINUX_ARM64 -DANDROID_TERMUX"

# --- Bootstrap mk ----------------------------------------------------------
if [ ! -x "$ROOT/Linux/arm64/bin/mk" ]; then
    echo "=== Bootstrapping mk build tool (with $CC) ==="

    echo "Building utils/libregexp..."
    cd "$ROOT/utils/libregexp"
    rm -f *.o libregexp.a
    for src in regcomp.c regerror.c regexec.c regsub.c regaux.c rregexec.c rregsub.c; do
        echo "  Compiling $src..."
        $CC $CFLAGS -I. -c "$src" -o "${src%.c}.o"
    done
    ar rcs libregexp.a *.o
    cp libregexp.a "$ROOT/Linux/arm64/lib/"

    echo "Building lib9..."
    cd "$ROOT/lib9"
    rm -f *.o lib9.a

    COMMON_SRC="convD2M.c convM2D.c convM2S.c convS2M.c fcallfmt.c qsort.c runestrlen.c strtoll.c rune.c"
    IMPORT_SRC="argv0.c charstod.c cistrcmp.c cistrncmp.c cistrstr.c cleanname.c create.c"
    IMPORT_SRC="$IMPORT_SRC dofmt.c dorfmt.c errfmt.c exits.c fmt.c fmtfd.c fmtlock.c fmtprint.c"
    IMPORT_SRC="$IMPORT_SRC fmtquote.c fmtrune.c fmtstr.c fmtvprint.c fprint.c getfields.c"
    IMPORT_SRC="$IMPORT_SRC nulldir.c pow10.c print.c readn.c rerrstr.c runeseprint.c runesmprint.c"
    IMPORT_SRC="$IMPORT_SRC runesnprint.c runevseprint.c seprint.c smprint.c snprint.c sprint.c"
    IMPORT_SRC="$IMPORT_SRC strdup.c strecpy.c sysfatal.c tokenize.c u16.c u32.c u64.c"
    IMPORT_SRC="$IMPORT_SRC utflen.c utfnlen.c utfrrune.c utfrune.c utfecpy.c vfprint.c vseprint.c vsmprint.c vsnprint.c"
    POSIX_SRC="dirstat-posix.c errstr-posix.c getuser-posix.c getwd-posix.c sbrk-posix.c isnan-posix.c"
    EXTRA_SRC="seek.c"

    for src in $COMMON_SRC $IMPORT_SRC $POSIX_SRC $EXTRA_SRC; do
        if [ -f "$src" ]; then
            echo "  Compiling $src..."
            $CC $CFLAGS -c "$src" -o "${src%.c}.o"
        fi
    done

    if [ -f "getcallerpc-Linux-arm64.S" ]; then
        echo "  Assembling getcallerpc-Linux-arm64.S..."
        $CC -c getcallerpc-Linux-arm64.S -o getcallerpc-Linux-arm64.o
    fi

    ar rcs lib9.a *.o
    cp lib9.a "$ROOT/Linux/arm64/lib/"

    echo "Building libbio..."
    cd "$ROOT/libbio"
    rm -f *.o libbio.a
    BIO_SRC="bbuffered.c bfildes.c bflush.c bgetrune.c bgetc.c bgetd.c binit.c boffset.c"
    BIO_SRC="$BIO_SRC bprint.c bputrune.c bputc.c brdline.c brdstr.c bread.c bseek.c bvprint.c bwrite.c"
    for src in $BIO_SRC; do
        echo "  Compiling $src..."
        $CC $CFLAGS -c "$src" -o "${src%.c}.o"
    done
    ar rcs libbio.a *.o
    cp libbio.a "$ROOT/Linux/arm64/lib/"

    echo "Building mk..."
    cd "$ROOT/utils/mk"
    rm -f *.o mk
    MK_COMMON="arc.c archive.c bufblock.c env.c file.c graph.c job.c lex.c main.c match.c mk.c parse.c recipe.c rule.c run.c shprint.c symtab.c var.c varsub.c word.c"
    MK_POSIX="Posix.c"
    MK_SHELL="sh.c"
    for src in $MK_COMMON $MK_POSIX $MK_SHELL; do
        echo "  Compiling $src..."
        $CC $CFLAGS -DROOT="\"$ROOT\"" -c "$src" -o "${src%.c}.o"
    done
    echo "  Linking mk..."
    $CC -fcommon -o mk *.o -L"$ROOT/Linux/arm64/lib" -lregexp -lbio -l9
    strip mk 2>/dev/null || true
    cp mk "$ROOT/Linux/arm64/bin/"
    cd "$ROOT"
fi

echo ""
echo "=== mk available: $ROOT/Linux/arm64/bin/mk ==="
echo ""

MK="$ROOT/Linux/arm64/bin/mk"

# --- Core libs -------------------------------------------------------------
for lib in lib9 libbio libmp libsec libmath libfreetype libmemdraw libmemlayer libdraw; do
    if [ -d "$ROOT/$lib" ]; then
        echo "Building $lib..."
        cd "$ROOT/$lib"
        "$MK" install || { echo "ERROR: $lib build failed" >&2; exit 1; }
    fi
done

# --- Limbo compiler --------------------------------------------------------
echo ""
echo "=== Building Limbo compiler ==="
cd "$ROOT/limbo"
"$MK" install || { echo "ERROR: limbo build failed" >&2; exit 1; }
if [ ! -x "$ROOT/Linux/arm64/bin/limbo" ]; then
    echo "ERROR: limbo compiler not built!" >&2
    exit 1
fi
strip "$ROOT/Linux/arm64/bin/limbo" 2>/dev/null || true

# --- Libs that need limbo --------------------------------------------------
for lib in libinterp libkeyring; do
    if [ -d "$ROOT/$lib" ]; then
        echo "Building $lib..."
        cd "$ROOT/$lib"
        "$MK" install || { echo "ERROR: $lib build failed" >&2; exit 1; }
    fi
done

# --- Emulator --------------------------------------------------------------
echo ""
echo "=== Building emulator ($GUIMODE) ==="
cd "$ROOT/emu/Linux"
rm -f *.o *.emu emu.root.h emu.root.c emu.root.s 2>/dev/null || true

if [ "$GUIMODE" = "headless" ]; then
    "$MK" -f mkfile-g || { echo "ERROR: emulator build failed" >&2; exit 1; }
else
    rm -f emu.c errstr.h 2>/dev/null || true
    "$MK" || { echo "ERROR: emulator build failed" >&2; exit 1; }
fi

# --- Limbo applications ----------------------------------------------------
echo ""
echo "=== Building Limbo applications ==="
for d in appl/lib appl/cmd appl/wm appl/cmd/sh appl/veltro; do
    if [ -d "$ROOT/$d" ]; then
        echo "  $d"
        cd "$ROOT/$d"
        "$MK" install || echo "WARNING: some modules in $d failed"
    fi
done

# --- Summary ---------------------------------------------------------------
echo ""
echo "=== Build Summary ==="
if [ -x "$ROOT/emu/Linux/o.emu" ]; then
    echo "SUCCESS: emulator at $ROOT/emu/Linux/o.emu"
    ls -la "$ROOT/emu/Linux/o.emu"
    echo ""
    echo "Run (headless, drops into Inferno shell):"
    echo "  $ROOT/emu/Linux/o.emu -c1 -r$ROOT sh -l"
    echo ""
    echo "Smoke test from the Inferno shell:"
    echo "  cat /dev/sysname"
    echo "  echo hello from inferno on a phone"
    echo ""
    echo "If that works, Phase 0 is done. Attach output to INFR-107."
else
    echo "FAIL: o.emu not found. See errors above."
    exit 1
fi
