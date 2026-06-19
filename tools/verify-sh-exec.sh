#!/bin/bash
#
# verify-sh-exec.sh — fail-fast guard against the "non-executable shell
# test" bug class that hid most of the INFR-312 test-suite failures.
#
# What happened: the in-emu test runner (tests/runner.b) runs each shell
# test via sh->system(), which *execs* the path. A script tracked 100644
# therefore fails immediately with
#     sh: /tests/inferno/<name>.sh: file does not exist
# and never runs at all — so a dozen tests/inferno/*.sh were silently
# failing as "file does not exist", masked as "needs a live backend".
#
# This script verifies that every shell test under tests/ is tracked
# executable (git mode 100755). It checks git's recorded mode rather than
# the working-tree bit, because that is what a fresh checkout (and CI)
# actually gets, independent of local umask. Runs in well under a second.
#
# Exit codes:
#   0  — every tests/**/*.sh is tracked executable
#   1  — at least one is non-executable; details printed to stderr
#   2  — usage / setup error
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "verify-sh-exec: not a git work tree ($ROOT)" >&2
	exit 2
fi

fail=0
checked=0

# git ls-files -s prints:  <mode> <object> <stage>\t<path>
# A regular file is 100644 (non-exec) or 100755 (exec). We require 100755
# for every shell test under tests/.
while IFS= read -r line; do
	[ -z "$line" ] && continue
	mode="${line%% *}"
	path="${line#*$'\t'}"
	checked=$((checked + 1))
	if [ "$mode" != "100755" ]; then
		echo "FAIL: $path is tracked $mode — shell tests must be 100755" >&2
		echo "      (the runner execs them via sh->system(); 100644 -> 'file does not exist')" >&2
		echo "      fix: chmod +x '$path' && git update-index --chmod=+x '$path'" >&2
		fail=1
	fi
done < <(git ls-files -s -- 'tests/**/*.sh' 'tests/*.sh')

if [ "$checked" -eq 0 ]; then
	echo "verify-sh-exec: no shell tests found under tests/ — check invocation" >&2
	exit 2
fi

if [ "$fail" -ne 0 ]; then
	echo "verify-sh-exec: one or more shell tests are non-executable (see above)" >&2
	exit 1
fi

echo "OK: $checked shell tests under tests/ are all tracked executable"
exit 0
