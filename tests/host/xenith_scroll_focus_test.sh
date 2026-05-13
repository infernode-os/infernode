#!/bin/sh
#
# Regression test: Xenith UI Improvements
#
# This test verifies the Xenith UI improvements for macOS trackpad usability:
#   1. SDL3 scroll wheel events handled in sdl3_mainloop() using tracked mouse position
#   2. Focus-follows-mouse - window under cursor gets focus
#   3. Scroll-anywhere - scroll wheel works anywhere in window, scrolls body
#   4. Acme-style variable scroll speed on scrollbar
#
# Background:
#   macOS trackpads require scroll wheel events to work properly in the
#   SDL3 backend. Additionally, Acme-style focus-follows-mouse and
#   scroll-anywhere behaviors improve usability.
#
# Test approach:
#   Verify presence of key code patterns that implement each feature.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDL3_FILE="${SCRIPT_DIR}/../../emu/port/draw-sdl3.c"
XENITH_FILE="${SCRIPT_DIR}/../../appl/xenith/xenith.b"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

passed=0
failed=0

check() {
    desc="$1"
    if eval "$2"; then
        printf "${GREEN}PASS${NC}: %s\n" "$desc"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: %s\n" "$desc"
        failed=$((failed + 1))
    fi
}

echo "=== Xenith UI Improvements Regression Test ==="
echo ""

# Check files exist
if [ ! -f "$SDL3_FILE" ]; then
    printf "${RED}FAIL${NC}: draw-sdl3.c not found\n"
    exit 1
fi
if [ ! -f "$XENITH_FILE" ]; then
    printf "${RED}FAIL${NC}: xenith.b not found\n"
    exit 1
fi

echo "--- SDL3 Scroll Wheel Events ---"
echo "File: $SDL3_FILE"
echo ""

# Test 1: SDL_EVENT_MOUSE_WHEEL handled in sdl3_mainloop
check "SDL_EVENT_MOUSE_WHEEL case exists in sdl3_mainloop()" \
    "awk '/sdl3_mainloop/,/^}/' '$SDL3_FILE' | grep -q 'SDL_EVENT_MOUSE_WHEEL'"

# Test 2: Scroll wheel uses tracked mouse position (mouse_x, mouse_y)
check "Scroll wheel uses tracked mouse position (mouse_x, mouse_y)" \
    "awk '/SDL_EVENT_MOUSE_WHEEL/,/break;/' '$SDL3_FILE' | grep -q 'mouse_x, mouse_y'"

# Test 3: Scroll up generates button 8
check "Scroll up sends button 8 (mousetrack(8,...))" \
    "awk '/SDL_EVENT_MOUSE_WHEEL/,/break;/' '$SDL3_FILE' | grep -q 'mousetrack(8,'"

# Test 4: Scroll down generates button 16
check "Scroll down sends button 16 (mousetrack(16,...))" \
    "awk '/SDL_EVENT_MOUSE_WHEEL/,/break;/' '$SDL3_FILE' | grep -q 'mousetrack(16,'"

echo ""
echo "--- Xenith Focus-Follows-Mouse ---"
echo "File: $XENITH_FILE"
echo ""

# Test 5: Focus-follows-mouse comment exists
check "Focus-follows-mouse feature comment exists" \
    "grep -q 'Focus-follows-mouse' '$XENITH_FILE'"

# Test 6: Updates activewin when mouse enters
check "Updates dat->activewin for focus-follows-mouse" \
    "grep -q 'dat->activewin = t.w' '$XENITH_FILE'"

# Test 7: Updates activecol when mouse enters
check "Updates activecol for focus-follows-mouse" \
    "grep -A5 'Focus-follows-mouse' '$XENITH_FILE' | grep -q 'activecol = t.col'"

echo ""
echo "--- Xenith Scroll-Anywhere ---"
echo ""

# Test 8: Scroll-anywhere comment exists
check "Scroll-anywhere feature comment exists" \
    "grep -q 'scroll window body from anywhere' '$XENITH_FILE'"

# Test 9: Uses w.body for scrolling (not t)
# Window-body extraction sits inside a larger conditional block; widen the
# window so the assertions don't drift on minor restructures.
check "Scroll-anywhere targets w.body (not current text)" \
    "grep -A20 'scroll window body from anywhere' '$XENITH_FILE' | grep -q 'w.body.typex'"

# Test 10: Sets w.body.eq0 for scroll anywhere
check "Scroll-anywhere sets w.body.eq0" \
    "grep -A20 'scroll window body from anywhere' '$XENITH_FILE' | grep -q 'w.body.eq0'"

echo ""
echo "--- Xenith Acme-Style Variable Scroll Speed ---"
echo ""

# Test 11: Variable scroll speed comment exists
check "Acme-style variable scroll comment exists" \
    "grep -q 'Acme-style variable speed' '$XENITH_FILE'"

# Test 12: Calculates offset in scrollbar (uses integer math)
check "Calculates mouse offset in scrollbar (integer math)" \
    "grep -A15 'Acme-style variable speed' '$XENITH_FILE' | grep -q 'offset :='"

# Test 13: Uses offset to calculate number of lines
check "Calculates nlines based on offset (1-10 range)" \
    "grep -A15 'Acme-style variable speed' '$XENITH_FILE' | grep -q 'nlines :='"

# Test 14: Uses typex for scrolling
check "Uses typex() for variable scroll" \
    "grep -A25 'Acme-style variable speed' '$XENITH_FILE' | grep -q 't.typex(but'"

# Test 15: Uses while loop for variable speed
check "Uses while loop for variable scroll amount" \
    "grep -A25 'Acme-style variable speed' '$XENITH_FILE' | grep -q 'while(i < nlines)'"

# Test 16: Variable scroll integrated in Body scrollbar handling
check "Variable scroll checks scroll wheel buttons" \
    "grep -B3 'Acme-style' '$XENITH_FILE' | grep -q 'mouse.buttons & (8|16)'"

echo ""
echo "--- Channel and Module Integration ---"
echo ""

GUI_FILE="${SCRIPT_DIR}/../../appl/xenith/gui.b"
WMCLIENT_FILE="${SCRIPT_DIR}/../../appl/lib/wmclient.b"

# Test 17: gui.b uses dat->cmouse for channel creation
check "gui.b creates channel via dat->cmouse" \
    "grep -q 'dat->cmouse = chan of ref' '$GUI_FILE'"

# Test 18: gui.b sends to dat->cmouse
check "gui.b sends events to dat->cmouse" \
    "grep -q 'dat->cmouse <-= p' '$GUI_FILE'"

# Test 19: xenith.b receives from dat->cmouse
check "xenith.b receives from dat->cmouse in mousetask" \
    "grep -q '<-dat->cmouse' '$XENITH_FILE'"

# Test 20: wmclient passes through scroll wheel events
check "wmclient passes through scroll wheel events (buttons 8|16)" \
    "grep -q 'p.buttons & (8|16)' '$WMCLIENT_FILE'"

echo ""
echo "=== Results ==="
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
    printf "${RED}TEST FAILED${NC}\n"
    exit 1
else
    printf "${GREEN}ALL TESTS PASSED${NC}\n"
    exit 0
fi
