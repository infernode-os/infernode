#!/bin/sh
#
# Regression test: Modifier Key Mouse Button Emulation
#
# This test verifies that the SDL3 backend properly emulates mouse buttons
# using modifier keys for single-button mice (e.g., macOS trackpads).
#
# Background:
#   macOS laptops and many users don't have three-button mice. Plan 9/Acme
#   and Inferno/Tk applications expect:
#     - Button 1 (left): select
#     - Button 2 (middle): execute
#     - Button 3 (right): search/look
#
#   The fix emulates these via modifier keys:
#     - Option + Left Click  = Button 2 (middle click)
#     - Command + Left Click = Button 3 (right click)
#
# See: emu/port/draw-sdl3.c map_buttons() function
#
# Test approach:
#   1. Verify map_buttons() helper function exists
#   2. Verify it checks for SDL_KMOD_ALT (Option key)
#   3. Verify it checks for SDL_KMOD_GUI (Command key)
#   4. Verify mouse event handlers use map_buttons()
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDL3_FILE="${SCRIPT_DIR}/../../emu/port/draw-sdl3.c"

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

echo "=== Modifier Key Mouse Emulation Regression Test ==="
echo "File: $SDL3_FILE"
echo ""

# Check file exists
if [ ! -f "$SDL3_FILE" ]; then
    printf "${RED}FAIL${NC}: draw-sdl3.c not found\n"
    exit 1
fi

# Test 1: map_buttons() helper function exists
check "map_buttons() function defined" \
    "grep -q 'map_buttons(Uint32' '$SDL3_FILE'"

# Test 2: Function checks Option key (SDL_KMOD_ALT)
check "Checks SDL_KMOD_ALT for Option key" \
    "grep -q 'SDL_KMOD_ALT' '$SDL3_FILE'"

# Test 3: Function checks Command key (SDL_KMOD_GUI)
check "Checks SDL_KMOD_GUI for Command key" \
    "grep -q 'SDL_KMOD_GUI' '$SDL3_FILE'"

# Test 4: Uses SDL_GetModState() for modifier detection
check "Uses SDL_GetModState() for modifier detection" \
    "grep -q 'SDL_GetModState()' '$SDL3_FILE'"

# Test 5: Option + click produces button 2 (middle)
check "Option + click produces button 2" \
    "grep -A2 'SDL_KMOD_ALT' '$SDL3_FILE' | grep -q 'buttons |= 2'"

# Test 6: Command + click produces button 3 (right)
check "Command + click produces button 3" \
    "grep -A2 'SDL_KMOD_GUI' '$SDL3_FILE' | grep -q 'buttons |= 4'"

# Test 7: Mouse motion handler uses map_buttons()
# map_buttons() now takes a state argument (event-tracked button mask) rather
# than polling, so match the function call by its opening paren.
check "SDL_EVENT_MOUSE_MOTION uses map_buttons()" \
    "awk '/SDL_EVENT_MOUSE_MOTION/,/break;/' '$SDL3_FILE' | grep -q 'map_buttons('"

# Test 8: Mouse button handler uses map_buttons()
check "SDL_EVENT_MOUSE_BUTTON uses map_buttons()" \
    "awk '/SDL_EVENT_MOUSE_BUTTON_DOWN/,/break;/' '$SDL3_FILE' | grep -q 'map_buttons('"

# Test 9: Function documentation mentions macOS/trackpad use case
check "Documentation mentions macOS single-button use case" \
    "grep -B10 'map_buttons(Uint32' '$SDL3_FILE' | grep -qi 'macos\|trackpad\|single-button'"

# Test 10: Physical middle/right buttons still work
check "Physical middle button preserved (MMASK)" \
    "grep -A30 'map_buttons(Uint32' '$SDL3_FILE' | grep -q 'SDL_BUTTON_MMASK'"

check "Physical right button preserved (RMASK)" \
    "grep -A30 'map_buttons(Uint32' '$SDL3_FILE' | grep -q 'SDL_BUTTON_RMASK'"

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
