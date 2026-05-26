#!/bin/sh
#
# build-ios-app.sh — assemble + install the InferNode iOS .app on the
# simulator (hellaphone Phase 2b).
#
# Two modes:
#   headless (default, B0) — libemu links stubs-headless; the app boots
#     emu -c0 and runs the Limbo test runner. With --verify it launches,
#     captures the console, and asserts the tests passed.
#   --gui (B1.2) — libemu links the SDL3 backend; the app is bootstrapped
#     by SDL3 (UIKit + Metal) and boots the lucifer GUI. Launches and
#     screenshots (no PASS assertion — it's a GUI).
#
# Pipeline: archive libemu.a (mk libemu, -DEMU_NO_MAIN) -> compile the
# UIKit entry point -> link against libemu + the Inferno C libs (+ SDL3
# for --gui) -> assemble <App>.app with a bundled Inferno root under
# <App>.app/root -> ad-hoc codesign -> install on the booted simulator.
#
# Simulator only for now — device builds need an Apple Development cert +
# provisioning profile (see emu/iOS/README.md, Phase B3).
#
# Prereqs: a Mac with Xcode; the Inferno C libs cross-built
# (./build-ios-arm64.sh -> iOS/arm64/lib/*.a); and for --gui, SDL3
# cross-built (./build-sdl3-ios.sh -> ~/sdks/SDL3-ios-sim-arm64).
#
# Usage:
#   ./build-ios-arm64.sh          # once, to build the C libs
#   ./build-ios-app.sh --verify   # headless: build, install, assert PASS
#   ./build-sdl3-ios.sh           # once, for the GUI
#   ./build-ios-app.sh --gui      # GUI: build, install, launch, screenshot
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
GUI=0
for arg in "$@"; do
	case "$arg" in
		--verify) VERIFY=1 ;;
		--gui) GUI=1 ;;
		*) echo "unknown arg: $arg" >&2; exit 1 ;;
	esac
done

# Mode-specific knobs: which entry point, libemu backend, link flags,
# and which Inferno dirs to bundle as the root.
SDL3_PREFIX=${SDL3_PREFIX:-$HOME/sdks/SDL3-ios-sim-arm64}
if [ "$GUI" -eq 1 ]; then
	MODE="GUI (SDL3/Metal — lucifer)"
	APPSRC=main_ios_gui.m
	MK_GUI="GUIBACK=sdl3 SDL3_PREFIX=$SDL3_PREFIX"
	CC_EXTRA_INC="-I$SDL3_PREFIX/include"
	GUI_LINK="-L$SDL3_PREFIX/lib -lSDL3 \
		-framework Metal -framework QuartzCore -framework CoreGraphics \
		-framework CoreMedia -framework CoreVideo -framework CoreAudio \
		-framework AudioToolbox -framework AVFoundation -framework CoreBluetooth \
		-framework CoreMotion -framework GameController -framework OpenGLES \
		-weak_framework CoreHaptics"
	STAGE_DIRS="dis lib fonts"
else
	MODE="headless"
	APPSRC=main_ios.m
	MK_GUI=""
	CC_EXTRA_INC=""
	GUI_LINK=""
	STAGE_DIRS="dis tests lib"
fi

echo "=== InferNode iOS app build (Phase 2b) — $MODE ==="

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
if [ "$GUI" -eq 1 ] && [ ! -f "$SDL3_PREFIX/lib/libSDL3.a" ]; then
	echo "ERROR: SDL3 not found at $SDL3_PREFIX. Run ./build-sdl3-ios.sh first." >&2
	exit 1
fi

# --- 1. libemu.a --------------------------------------------------------
echo "=== archiving libemu.a (emu objects, -DEMU_NO_MAIN${MK_GUI:+, sdl3}) ==="
cd "$ROOT/emu/iOS"
find . -maxdepth 1 \( -name '*.o' -o -name 'o.emu' -o -name 'emu.root.*' -o -name 'emu.c' \) -delete 2>/dev/null || true
# shellcheck disable=SC2086
mk -f mkfile-g IOSSDK="$IOSSDK" IOSTRIPLE="$IOSTRIPLE" IOSMIN="$IOSMIN" \
	$MK_GUI EMUOPTIONS=-DEMU_NO_MAIN libemu >/dev/null || {
		echo "ERROR: libemu.a build failed" >&2; exit 1; }

# --- 2. compile the app entry point ------------------------------------
echo "=== compiling $APPSRC ==="
cd "$ROOT/emu/iOS/app"
APPOBJ=${APPSRC%.m}.o
# shellcheck disable=SC2086
"$CLANG" -c -target "$IOSTRIPLE" -isysroot "$SDKPATH" \
	-fobjc-arc -fmodules -O -g $CC_EXTRA_INC \
	-o "$APPOBJ" "$APPSRC" || {
		echo "ERROR: $APPSRC compile failed" >&2; exit 1; }

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
	"$APPOBJ" $INFERNO_LIBS \
	-framework UIKit -framework Foundation -framework CoreFoundation \
	$GUI_LINK -lpthread -lm || {
		echo "ERROR: app link failed" >&2; exit 1; }

# --- 4. assemble the bundle --------------------------------------------
echo "=== assembling $APPDIR (root: $STAGE_DIRS) ==="
cp "$ROOT/emu/iOS/app/Info.plist" "$APPDIR/Info.plist"

# App icon (INFR-149): compile the asset catalog into the bundle and
# merge actool's CFBundleIcons keys into Info.plist. Best-effort — a
# failure here must not break the build (the app just ships iconless).
ICON_CATALOG="$ROOT/emu/iOS/app/Assets.xcassets"
if [ -d "$ICON_CATALOG" ]; then
	ICON_PARTIAL=$(mktemp -t infernode-appicon-XXXXXX.plist)
	if xcrun actool "$ICON_CATALOG" \
			--compile "$APPDIR" \
			--app-icon AppIcon \
			--platform "$IOSSDK" \
			--minimum-deployment-target "$IOSMIN" \
			--target-device iphone --target-device ipad \
			--output-partial-info-plist "$ICON_PARTIAL" \
			--output-format human-readable-text >/dev/null 2>&1; then
		/usr/libexec/PlistBuddy -c "Merge $ICON_PARTIAL" "$APPDIR/Info.plist" >/dev/null 2>&1 \
			&& echo "app icon: compiled AppIcon into bundle" \
			|| echo "WARNING: app-icon plist merge failed (app will be iconless)" >&2
	else
		echo "WARNING: actool failed — app ships without a custom icon" >&2
	fi
	rm -f "$ICON_PARTIAL"
fi
# Stage the Inferno root the app boots from (<App>.app/root). dis/ is the
# runtime (emuinit, sh, modules); tests/ has the compiled *_test.dis;
# lib/ carries the shell profile + lucifer boot; fonts/ feeds the GUI.
mkdir -p "$APPDIR/root"
for d in $STAGE_DIRS; do
	[ -d "$ROOT/$d" ] && cp -R "$ROOT/$d" "$APPDIR/root/$d"
done
# Mountpoint dirs the boot mounts/binds onto (/n via mntgen, /tmp, /usr,
# /mnt). macOS gets these from the full repo it boots from; the bundle
# must supply them or `mount {mntgen} /n` (and the /usr,/tmp binds) fail
# and the GUI never comes up. Empty is fine — they're mounted/written over.
for d in n tmp usr mnt; do
	mkdir -p "$APPDIR/root/$d"
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
xcrun simctl install booted "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install booted "$APPDIR"
echo "installed $BUNDLE_ID"

# --- GUI: launch + screenshot (no PASS to assert — it's a GUI) ---------
if [ "$GUI" -eq 1 ]; then
	echo "=== launching GUI (watch it with: open -a Simulator) ==="
	xcrun simctl launch --terminate-running-process booted "$BUNDLE_ID" >/dev/null 2>&1 || true
	SHOT=${TMPDIR:-/tmp}/infernode-ios-gui.png
	echo "    booting lucifer (-c0 interpreter — give it ~30s)…"
	sleep 30
	xcrun simctl io booted screenshot "$SHOT" >/dev/null 2>&1 \
		&& echo "screenshot: $SHOT" || echo "(screenshot failed)"
	echo ""
	echo "The SDL3/Metal window is up. Lucifer won't fully render yet —"
	echo "the read-only bundle root blocks /n (writable-state work, B1.2 cont.)."
	echo "Open the Simulator to watch live:  open -a Simulator"
	exit 0
fi

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
