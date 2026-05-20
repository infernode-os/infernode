#!/bin/sh
#
# check-android-safearea.sh — verify InfernodeSDLActivity still has
# the safe-area inset handling.
#
# Background: Android 15 (targetSdk=35) renders activities edge-to-edge
# by default. Without the manual inset handling we added in INFR-115,
# Lucifer's SDLSurface overlaps the status bar (top) and gesture / nav
# bar (bottom). Some well-meaning future refactor might delete the
# OnApplyWindowInsetsListener thinking "the system handles this now" —
# this lint says no, it doesn't, leave the code in.
#
# We check for the three pieces that together make the fix work:
#   1. setDecorFitsSystemWindows(...)  — opts the activity in to
#                                        edge-to-edge so the system
#                                        bars are a transparent overlay.
#   2. setOnApplyWindowInsetsListener  — listens for the actual bar
#                                        heights from the platform.
#   3. setPadding(...) inside that listener — translates the insets
#                                              into SurfaceView size.
#
# If any of the three vanishes without a follow-up that proves the
# layout still works, the visual regression returns.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/android-app/app/src/main/java/io/infernode/InfernodeSDLActivity.kt"

if [ ! -f "$F" ]; then
	echo "::error::expected file $F not found"
	exit 1
fi

missing=""
grep -q 'setDecorFitsSystemWindows' "$F" || missing="$missing setDecorFitsSystemWindows"
grep -q 'setOnApplyWindowInsetsListener' "$F" || missing="$missing setOnApplyWindowInsetsListener"
grep -q 'setPadding' "$F" || missing="$missing setPadding"

if [ -n "$missing" ]; then
	echo "::error file=android-app/app/src/main/java/io/infernode/InfernodeSDLActivity.kt::Safe-area handling for the SDL surface is gone — missing:$missing. See INFR-115, docs/HELLAPHONE.md."
	echo "::error::Android 15 / targetSdk=35 needs this to keep Lucifer inside the safe rectangle. Restoring the SDLActivity defaults will overlap the status bar and gesture / nav bar."
	exit 1
fi

echo "android-safearea lint: OK"
