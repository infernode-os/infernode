#!/bin/sh
#
# build-ios-app.sh — assemble the InferNode iOS .app (hellaphone Phase 2b,
# B0: headless shell on the simulator).
#
# Pipeline:
#   1. archive emu objects into libemu.a (mk libemu, with -DEMU_NO_MAIN)
#   2. compile the UIKit entry point (emu/iOS/app/main_ios.m)
#   3. link the app executable against libemu.a + the Inferno C libs
#   4. assemble <App>.app: Info.plist, executable, and a bundled Inferno
#      root (dis/ tests/ lib/) staged under <App>.app/root
#   5. ad-hoc codesign (simulator needs no real identity)
#   6. install on the booted simulator
#   7. (--verify) launch it, capture the console, assert the test passed
#
# Simulator only for now — device builds need an Apple Development cert +
# provisioning profile (see emu/iOS/README.md, Phase B3).
#
# Prereqs: a Mac with Xcode, and the Inferno C libs already cross-built
# (run ./build-ios-arm64.sh first — it produces iOS/arm64/lib/*.a).
#
# Usage:
#   ./build-ios-arm64.sh          # once, to build the C libs
#   ./build-ios-app.sh            # build + install on the booted sim
#   ./build-ios-app.sh --verify   # the above, then launch + assert
#

set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

IOSSDK=${IOSSDK:-iphonesimulator}
IOSMIN=${IOSMIN:-14.0}
BUNDLE_ID=os.infernode.ios
APPDIR="$ROOT/iOS/arm64/InferNode.app"

VERIFY=0
for arg in "$@"; do
	case "$arg" in
		--verify) VERIFY=1 ;;
		*) echo "unknown arg: $arg" >&2; exit 1 ;;
	esac
done

echo "=== InferNode iOS app build (Phase 2b, B0 headless) ==="

# --- host / SDK checks --------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
	echo "ERROR: iOS builds require a macOS host." >&2; exit 1
fi
if [ "$IOSSDK" != "iphonesimulator" ]; then
	echo "ERROR: only iphonesimulator is wired up. Device builds need an" >&2
	echo "  Apple Development cert + provisioning profile (Phase B3)." >&2
	exit 1
fi
IOSTRIPLE=arm64-apple-ios${IOSMIN}-simulator
SDKPATH=$(xcrun --sdk "$IOSSDK" --show-sdk-path)
CLANG=$(xcrun --sdk "$IOSSDK" -f clang)

if [ ! -f "$ROOT/iOS/arm64/lib/lib9.a" ]; then
	echo "ERROR: Inferno C libs missing. Run ./build-ios-arm64.sh first." >&2
	exit 1
fi

# --- 1. libemu.a --------------------------------------------------------
echo "=== archiving libemu.a (emu objects, -DEMU_NO_MAIN) ==="
cd "$ROOT/emu/iOS"
rm -f *.o *.emu emu.root.h emu.root.c emu.root.s emu.c 2>/dev/null || true
mk -f mkfile-g IOSSDK="$IOSSDK" IOSTRIPLE="$IOSTRIPLE" IOSMIN="$IOSMIN" \
	EMUOPTIONS=-DEMU_NO_MAIN libemu >/dev/null || {
		echo "ERROR: libemu.a build failed" >&2; exit 1; }

# --- 2. compile the app entry point ------------------------------------
echo "=== compiling main_ios.m ==="
cd "$ROOT/emu/iOS/app"
"$CLANG" -c -target "$IOSTRIPLE" -isysroot "$SDKPATH" \
	-fobjc-arc -fmodules -O -g \
	-o main_ios.o main_ios.m || {
		echo "ERROR: main_ios.m compile failed" >&2; exit 1; }

# --- 3. link the app executable ----------------------------------------
echo "=== linking executable ==="
LIBDIR="$ROOT/iOS/arm64/lib"
INFERNO_LIBS="$LIBDIR/libemu.a \
	$LIBDIR/libinterp.a $LIBDIR/libmath.a $LIBDIR/libdraw.a \
	$LIBDIR/libmemlayer.a $LIBDIR/libmemdraw.a $LIBDIR/libkeyring.a \
	$LIBDIR/libsec.a $LIBDIR/libmp.a $LIBDIR/lib9.a"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
# shellcheck disable=SC2086
"$CLANG" -target "$IOSTRIPLE" -isysroot "$SDKPATH" \
	-o "$APPDIR/InferNode" \
	main_ios.o $INFERNO_LIBS \
	-framework UIKit -framework Foundation -framework CoreFoundation \
	-lpthread -lm || {
		echo "ERROR: app link failed" >&2; exit 1; }

# --- 4. assemble the bundle --------------------------------------------
echo "=== assembling $APPDIR ==="
cp "$ROOT/emu/iOS/app/Info.plist" "$APPDIR/Info.plist"
# Stage the Inferno root the app boots from (<App>.app/root). dis/ is the
# runtime (emuinit, sh, modules); tests/ has the compiled *_test.dis;
# lib/ carries the shell profile and friends.
mkdir -p "$APPDIR/root"
for d in dis tests lib; do
	[ -d "$ROOT/$d" ] && cp -R "$ROOT/$d" "$APPDIR/root/$d"
done

# --- 5. ad-hoc codesign (simulator needs no identity) ------------------
codesign --force --sign - --timestamp=none "$APPDIR" >/dev/null 2>&1 || {
	echo "WARNING: ad-hoc codesign failed (simulator may still run it)" >&2; }

echo "built: $APPDIR ($(du -sh "$APPDIR" | cut -f1))"

# --- 6. install on the booted simulator --------------------------------
if ! xcrun simctl list devices booted 2>/dev/null | grep -q '(Booted)'; then
	echo "No simulator booted. Boot one, then re-run:" >&2
	echo "  xcrun simctl boot 'iPhone 15'" >&2
	exit 0
fi
echo "=== installing on booted simulator ==="
xcrun simctl install booted "$APPDIR"
echo "installed $BUNDLE_ID"

if [ "$VERIFY" -eq 0 ]; then
	echo ""
	echo "Launch with console output:"
	echo "  xcrun simctl launch --console-pty booted $BUNDLE_ID"
	exit 0
fi

# --- 7. verify: launch, capture console, assert the test passed --------
echo "=== verifying (launch + assert hello_test passes) ==="
LOG=$(mktemp -t infernode-ios-verify)
# The headless app runs /tests/hello_test.dis then emu exits (which exits
# the app process), so --console-pty returns on its own; cap it anyway.
( xcrun simctl launch --console-pty --terminate-running-process booted "$BUNDLE_ID" \
	>"$LOG" 2>&1 ) &
LAUNCH_PID=$!
( sleep 60; kill "$LAUNCH_PID" 2>/dev/null ) &
WATCHDOG=$!
wait "$LAUNCH_PID" 2>/dev/null || true
kill "$WATCHDOG" 2>/dev/null || true

echo "--- captured console ---"
grep -vE '^$' "$LOG" | tail -20
echo "------------------------"
if grep -qE 'PASS|[0-9]+ passed' "$LOG"; then
	echo "VERIFY OK: hello_test ran inside the iOS app and passed."
	rm -f "$LOG"
	exit 0
else
	echo "VERIFY FAILED: expected test PASS output not found." >&2
	echo "  full log: $LOG" >&2
	exit 1
fi
