#!/bin/sh
# tools/flawfinder-filter.py: what the security workflow takes out of
# Flawfinder's SARIF before code scanning sees it, and what it leaves.
#
# Flawfinder matches names.  Code scanning tracks each match as an alert,
# counts it as new whenever its line changes, and fails a pull request on
# one whose level is error.  Matches that are wrong by construction here
# (lib9's strecpy and getwd, which take their bounds; an array named
# access; results below the --minlevel the workflow asks for, which the
# SARIF writer ignores; fixed arrays' declarations) failed pull requests
# that had only moved a line.
#
# On a SARIF file of the test's own: those are dropped, each with its
# reason counted, and a strcpy, an access() call, an atoi and a getenv
# are kept.  Where flawfinder is installed, a C file with one of each is
# scanned and filtered, so that a new release naming its rules otherwise
# is noticed; and the tree itself has no result at level error (each one
# the tree had was a bounded strcpy idiom, rewritten with its length).
# The workflow runs the filter where this test names it.
# No emulator needed.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

PY=$(command -v python3 2>/dev/null)
if [ -z "$PY" ]; then
	echo "SKIP: no python3"
	exit 0
fi
FILTER=$ROOT/tools/flawfinder-filter.py
if [ ! -f "$FILTER" ]; then
	echo "ERROR: $FILTER not found" >&2
	exit 1
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

# kept NAME FILE: the rule names left in a SARIF file, sorted, on one line
kept() {
	"$PY" - "$1" <<'EOT'
import json, sys
d = json.load(open(sys.argv[1]))
names = []
for run in d["runs"]:
	ids = {r["id"]: r.get("name", "") for r in run["tool"]["driver"]["rules"]}
	for r in run["results"]:
		names.append("%s:%s" % (ids.get(r["ruleId"], "?"), r.get("level", "")))
print(" ".join(sorted(names)))
EOT
}

"$PY" - "$BUILD/in.sarif" <<'EOT'
import json, sys
rules = [("FF1", "buffer/strcpy"), ("FF2", "buffer/strecpy"), ("FF3", "buffer/getwd"),
	("FF4", "race/access"), ("FF5", "buffer/char"), ("FF6", "buffer/strlen"),
	("FF7", "integer/atoi"), ("FF8", "buffer/getenv"), ("FF9", "format/printf")]
def res(rid, level, rank, text):
	return {"ruleId": rid, "level": level, "rank": rank,
		"message": {"text": dict(rules)[rid] + ":text"},
		"locations": [{"physicalLocation": {"artifactLocation": {"uri": "x.c"},
			"region": {"startLine": 1, "snippet": {"text": text}}}}]}
results = [
	res("FF1", "error", 0.8, "strcpy(a, b);"),
	res("FF2", "error", 0.8, "strecpy(a, a+sizeof a, b);"),
	res("FF3", "warning", 0.6, "getwd(buf, sizeof buf);"),
	res("FF4", "error", 0.8, "t = access[omode&3];"),
	res("FF4", "error", 0.8, "if(access(path, R_OK) == 0)"),
	res("FF5", "note", 0.4, "char buf[64];"),
	res("FF6", "note", 0.2, "n = strlen(s);"),
	res("FF7", "note", 0.4, "v = atoi(s);"),
	res("FF8", "warning", 0.6, "p = getenv(\"X\");"),
	res("FF9", "note", 0.0, "printf(\"%d\", n);"),
	res("FF1", "note", 0.2, "strcpy(a, \"c\");"),
]
json.dump({"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "Flawfinder",
	"rules": [{"id": i, "name": n} for i, n in rules]}}, "results": results}]},
	open(sys.argv[1], "w"))
EOT

if "$PY" "$FILTER" "$BUILD/in.sarif" "$BUILD/out.sarif" > "$BUILD/log" 2>&1; then
	got=$(kept "$BUILD/out.sarif")
	want="buffer/getenv:warning buffer/strcpy:error integer/atoi:note race/access:error"
	if [ "$got" = "$want" ]; then
		pass "a strcpy, a call to access(), an atoi and a getenv are kept; strecpy, getwd, an array named access, a declaration and what is below level 2 are dropped"
	else
		fail "kept: $got (wanted: $want)"
	fi
	if grep -q '4 results kept, 7 dropped' "$BUILD/log" && grep -q "strecpy" "$BUILD/log" && grep -q "below the level" "$BUILD/log"; then
		pass "it says how many it dropped and why"
	else
		fail "its account: $(tr '\n' ';' < "$BUILD/log" | cut -c1-300)"
	fi
else
	fail "the filter failed: $(head -3 "$BUILD/log" | tr '\n' ' ')"
fi

# -n changes nothing
cp "$BUILD/in.sarif" "$BUILD/dry.sarif"
if "$PY" "$FILTER" -n "$BUILD/dry.sarif" > /dev/null 2>&1 && cmp -s "$BUILD/in.sarif" "$BUILD/dry.sarif"; then
	pass "-n writes nothing"
else
	fail "-n changed its file"
fi

# a file that is not SARIF is an error, not an empty result
echo 'not json' > "$BUILD/bad.sarif"
if "$PY" "$FILTER" "$BUILD/bad.sarif" > /dev/null 2>&1; then
	fail "a file that is not JSON was accepted"
else
	pass "a file that is not JSON is refused"
fi

if grep -q 'tools/flawfinder-filter.py flawfinder-results.sarif' "$ROOT/.github/workflows/security.yml"; then
	pass "the security workflow filters the SARIF before it uploads it"
else
	fail "the security workflow does not run the filter on flawfinder-results.sarif"
fi

FF=$(command -v flawfinder 2>/dev/null)
if [ -z "$FF" ]; then
	echo "SKIP: flawfinder itself (not installed)"
else
	mkdir "$BUILD/src"
	cat > "$BUILD/src/t.c" <<'EOT'
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
extern char *strecpy(char*, char*, char*);
extern char *getwd(char*, int);
static int access[] = { 0400, 0200 };
void
f(char *a, char *b, int m)
{
	char buf[64];
	strecpy(buf, buf+sizeof buf, b);
	getwd(buf, sizeof buf);
	m = access[m&1];
	strcpy(a, b);
	m += strlen(b);
}
EOT
	(cd "$BUILD/src" && "$FF" --sarif --minlevel 2 t.c > "$BUILD/real.sarif" 2>/dev/null)
	if "$PY" "$FILTER" "$BUILD/real.sarif" > "$BUILD/log" 2>&1; then
		got=$(kept "$BUILD/real.sarif")
		if [ "$got" = "buffer/strcpy:error" ]; then
			pass "flawfinder's own output for one of each: the strcpy alone is left"
		else
			fail "flawfinder's own output, filtered, has: $got"
		fi
	else
		fail "the filter failed on flawfinder's own output: $(head -3 "$BUILD/log" | tr '\n' ' ')"
	fi
	(cd "$ROOT" && "$FF" --sarif --minlevel 2 libsec/ libmp/ libkeyring/ libinterp/ emu/port/ lib9/ > "$BUILD/tree.sarif" 2>/dev/null)
	if "$PY" "$FILTER" "$BUILD/tree.sarif" > "$BUILD/log" 2>&1; then
		errs=$(kept "$BUILD/tree.sarif" | tr ' ' '\n' | grep -c ':error$')
		if [ "$errs" -eq 0 ]; then
			pass "the tree has no Flawfinder result at level error ($(head -1 "$BUILD/log" | sed 's/flawfinder-filter: //'))"
		else
			fail "the tree has $errs Flawfinder results at level error: $(kept "$BUILD/tree.sarif" | tr ' ' '\n' | grep ':error$' | sort | uniq -c | tr '\n' ' ')"
		fi
	else
		fail "the filter failed on the tree's output"
	fi
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
