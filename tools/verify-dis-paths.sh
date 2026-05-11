#!/bin/bash
#
# verify-dis-paths.sh — fail-fast guard against the "wrong .dis target" bug
# that cost us a full session of theme-propagation debugging.
#
# What happened: I was compiling lucifer-side modules with
#     limbo -o dis/cmd/lucictx.dis appl/cmd/lucictx.b
# but lucifer loads them via
#     LuciCtx: module { PATH: con "/dis/lucictx.dis"; ...}
# i.e. /dis/lucictx.dis (without cmd/).  Old stale .dis files at the
# correct path silently kept running while every "rebuilt" file landed
# in a parallel directory emu never read from.
#
# This script verifies that for every Limbo source file in
# appl/cmd/ that contains a `PATH: con "/dis/...` declaration, the
# corresponding compiled .dis exists at that path AND is at least as
# new as the source.  Runs in under a second.  Pre-commit hook
# candidate; also wired into `make` (see mkfile).
#
# Exit codes:
#   0  — all sources have a fresh, correctly-placed .dis
#   1  — at least one mismatch; details printed to stderr
#   2  — usage / setup error
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
checked=0

scan_module_path() {
	# Return the PATH constant of the module that this .b file
	# IMPLEMENTS (top-level `implement Foo;`), not the first PATH it
	# happens to mention.  Files commonly cite the PATHs of modules
	# they LOAD (cowfs, etc.) before declaring their own interface;
	# matching the first PATH alone gives wrong answers.
	#
	# Strategy: find `implement Foo;`, then scan forward for
	# `Foo: module {` ... `PATH: con "/dis/..."` ... `}`.
	awk '
		/^implement[[:space:]]+[A-Za-z][A-Za-z0-9_]*[[:space:]]*;/ {
			match($0, /[A-Za-z][A-Za-z0-9_]*[[:space:]]*;/)
			impl = substr($0, RSTART, RLENGTH)
			sub(/[[:space:]]*;.*$/, "", impl)
		}
		impl != "" && $0 ~ ("^" impl "[[:space:]]*:[[:space:]]*module") {
			in_mod = 1
			next
		}
		in_mod && /PATH[[:space:]]*:[[:space:]]*con[[:space:]]*"\/dis\// {
			match($0, /"\/dis\/[^"]+"/)
			if(RSTART > 0) {
				p = substr($0, RSTART+1, RLENGTH-2)
				print p
				exit
			}
		}
		in_mod && /^[[:space:]]*}/ {
			in_mod = 0
		}
	' "$1"
}

for src in appl/cmd/*.b; do
	disrel=$(scan_module_path "$src" || true)
	[[ -z "$disrel" ]] && continue

	# Strip leading slash and prefix with the source-tree root.
	dispath="${disrel#/}"
	if [[ ! -f "$dispath" ]]; then
		echo "FAIL: $src declares PATH=$disrel but $dispath is missing" >&2
		fail=1
		continue
	fi

	src_t=$(stat -f %m "$src" 2>/dev/null || stat -c %Y "$src")
	dis_t=$(stat -f %m "$dispath" 2>/dev/null || stat -c %Y "$dispath")

	if (( src_t > dis_t )); then
		echo "FAIL: $src is newer than $dispath (recompile needed)" >&2
		fail=1
	fi
	checked=$((checked + 1))
done

if (( fail )); then
	echo "" >&2
	echo "$checked sources checked; FAILURES above." >&2
	echo "Recompile with: limbo -I module -o <PATH-from-source> <source.b>" >&2
	echo "(do NOT default to dis/cmd/X.dis — read the module's PATH constant)" >&2
	exit 1
fi

echo "OK: $checked sources have fresh .dis at their declared PATH"
