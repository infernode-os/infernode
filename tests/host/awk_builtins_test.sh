#!/bin/sh
# tests/host/awk_builtins_test.sh — regression tests for INFR-37/38/39/40.
#
# Covers awk built-ins that were broken when awk.dis became buildable
# again (INFR-23 / PR #53):
#   INFR-37 split() with /regex/ separator
#   INFR-38 sub()/gsub() dropping the suffix after the last match
#   INFR-39 match() returning RSTART=0/RLENGTH=-1 for actual matches
#   INFR-40 int() rounding away from zero instead of truncating

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emulator not built at $EMU (build with build-linux-amd64.sh)"
    exit 77
fi
if [ ! -f "$ROOT/dis/awk.dis" ]; then
    echo "SKIP: dis/awk.dis not found"
    exit 77
fi

PASS=0
FAIL=0
FAILED_CASES=""

# Run an awk program inside emu and compare against an expected line.
# emu exits via SIGKILL after BEGIN finishes, so its exit code is unreliable
# and the parent shell normally prints "Killed" to stderr; we silence the
# subshell's stderr (via `exec 2>/dev/null`) and only assert on stdout.
check() {
    name=$1; want=$2; prog=$3
    got=$(exec 2>/dev/null; "$EMU" -r"$ROOT" /dis/awk.dis "$prog" | tr -d '\r')
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
        printf '  PASS  %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_CASES="$FAILED_CASES\n    $name\n      got:  $got\n      want: $want"
        printf '  FAIL  %s\n        got:  %s\n        want: %s\n' "$name" "$got" "$want"
    fi
}

echo "=== INFR-37: split() with regex separator ==="
check "split-regex digits"        "4 a b c d" \
    'BEGIN { n = split("a1b22c333d", a, /[0-9]+/); print n, a[1], a[2], a[3], a[4] }'
check "split-regex char class"    "3 foo bar baz" \
    'BEGIN { n = split("foo, bar; baz", a, /[,;] +/); print n, a[1], a[2], a[3] }'
check "split-string single char"  "4 a b c d" \
    'BEGIN { n = split("a,b,c,d", a, ","); print n, a[1], a[2], a[3], a[4] }'
check "split-multichar string"    "3 a b c" \
    'BEGIN { n = split("a::b::c", a, "::"); print n, a[1], a[2], a[3] }'
check "split-whitespace default"  "3 alpha beta gamma" \
    'BEGIN { n = split("  alpha   beta  gamma  ", a); print n, a[1], a[2], a[3] }'

echo
echo "=== INFR-38: sub()/gsub() suffix preservation ==="
check "sub middle"                "heLlo" \
    'BEGIN { s = "hello"; sub("l", "L", s); print s }'
check "gsub all"                  "heLLo" \
    'BEGIN { s = "hello"; gsub("l", "L", s); print s }'
check "sub at start"              "Yello" \
    'BEGIN { s = "hello"; sub("h", "Y", s); print s }'
check "sub at end"                "heyy" \
    'BEGIN { s = "heyx"; sub("x", "y", s); print s }'
check "sub no match"              "hello" \
    'BEGIN { s = "hello"; sub("z", "X", s); print s }'
check "gsub multiple non-adjacent" "fXXbar" \
    'BEGIN { s = "foobar"; gsub("o", "X", s); print s }'
check "sub regex literal arg"     "heLlo" \
    'BEGIN { s = "hello"; sub(/l/, "L", s); print s }'
check "gsub regex literal arg"    "heLLo" \
    'BEGIN { s = "hello"; gsub(/l/, "L", s); print s }'
check "sub & expansion"           "[hi] there" \
    'BEGIN { s = "hi there"; sub("hi", "[&]", s); print s }'
check "gsub & expansion"          "[a]b[c]" \
    'BEGIN { s = "abc"; gsub(/[ac]/, "[&]", s); print s }'
check "sub returns count 1"       "1 heLlo" \
    'BEGIN { s = "hello"; n = sub("l", "L", s); print n, s }'
check "gsub returns count 2"      "2 heLLo" \
    'BEGIN { s = "hello"; n = gsub("l", "L", s); print n, s }'

echo
echo "=== INFR-39: match() returns RSTART/RLENGTH ==="
check "match middle"              "3 2" \
    'BEGIN { match("abcdef", /cd/); print RSTART, RLENGTH }'
check "match at start"            "1 3" \
    'BEGIN { match("abcdef", /^abc/); print RSTART, RLENGTH }'
check "match at end"              "4 3" \
    'BEGIN { match("abcdef", /def/); print RSTART, RLENGTH }'
check "match no match"            "0 -1" \
    'BEGIN { match("abcdef", /xy/); print RSTART, RLENGTH }'
check "match dynamic string"      "3 2" \
    'BEGIN { p = "cd"; match("abcdef", p); print RSTART, RLENGTH }'
check "match returns RSTART"      "3" \
    'BEGIN { print match("abcdef", /cd/) }'

echo
echo "=== INFR-40: int() truncates toward zero ==="
check "int positive fraction"     "3" 'BEGIN { print int(3.7) }'
check "int negative fraction"     "-3" 'BEGIN { print int(-3.7) }'
check "int small positive"        "0" 'BEGIN { print int(0.4) }'
check "int small negative"        "0" 'BEGIN { print int(-0.4) }'
check "int zero"                  "0" 'BEGIN { print int(0) }'
check "int positive integer"      "3" 'BEGIN { print int(3.0) }'
check "int negative integer"      "-3" 'BEGIN { print int(-3.0) }'
check "int acceptance row"        "3 -3 0 0 0" \
    'BEGIN { print int(3.7), int(-3.7), int(0), int(0.4), int(-0.4) }'

echo
echo "============================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "============================================"

if [ $FAIL -gt 0 ]; then
    printf 'Failed cases:%b\n' "$FAILED_CASES"
    exit 1
fi
exit 0
