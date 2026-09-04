#!/bin/sh
#
# verify-dis-build.sh — build the runtime tree and check nothing is missing.
#
# dis/ is not tracked: it is a build product, like emu/*/o.emu.  A release
# ships it because the CI job that packages the release builds it first.
#
# Untracking removes the drift problem (bytecode can no longer be stale
# relative to its source, because it is always freshly compiled) and
# replaces it with a quieter one: a module dropped from an mkfile's TARG
# simply stops existing, and nothing says so until something fails to load
# at runtime.  That is not hypothetical — 45 modules were in this state and
# only kept working because their bytecode happened to be committed.
#
# So the set of files the build must produce is itself tracked, as
# tools/dis-manifest.txt.  ~960 lines of text instead of ~960 binaries:
# a module appearing or disappearing is a reviewable diff.
#
# Adding a module: build it, then add its path to the manifest in the same
# commit.  Removing one: delete both.  The diff should say what you meant.
#
# A MISSING module fails the check: something the product needs stopped
# being built.  An EXTRA one is only reported.  That asymmetry is
# deliberate -- extras are usually a local scratch build or a step that
# compiles something on the side (release.yml compiles the test-framework
# self-test into dis/lib/), and with bytecode no longer committable, a
# stray file cannot be published by accident the way a stale one could.
#
# Exit codes:
#   0  — the build produced everything the manifest lists
#   1  — modules missing
#   2  — setup error (wrong directory, missing toolchain, build failure)
#
set -e

# comm(1) requires both inputs in the same collation order, and sort(1)
# collates differently by locale -- a manifest generated under en_GB and
# compared under the C locale on a CI runner fails with
# "comm: file 1 is not in sorted order".  Pin both ends to C.
LC_ALL=C
export LC_ALL

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT
cd "$ROOT"

MANIFEST="$ROOT/tools/dis-manifest.txt"

if [ ! -f mkconfig ] || [ ! -f "$MANIFEST" ]; then
	echo "verify-dis-build: run from an InferNode checkout" >&2
	exit 2
fi

if ! command -v mk >/dev/null 2>&1 || ! command -v limbo >/dev/null 2>&1; then
	echo "verify-dis-build: mk and limbo must be on PATH" >&2
	echo "  build them first:  SYSTARG=\$(uname -s) OBJTYPE=<arch> ./makemk.sh" >&2
	echo "  then add:          \$ROOT/\$SYSHOST/\$OBJTYPE/bin" >&2
	exit 2
fi

# Every tree with a DISBIN under dis/, acme/dis/ or xenith/dis/.
# appl/mpeg and appl/veltro are NOT in appl/mkfile's DIRS, so
# `cd appl && mk install` does not reach them.  Listed explicitly rather
# than left to be rediscovered by whoever hits it next.
DIRS="appl appl/mpeg appl/veltro tests"

echo "verify-dis-build: building the runtime tree"
for d in $DIRS; do
	if ! (cd "$d" && mk install) > "$ROOT/.dis-build-$$.log" 2>&1; then
		echo "verify-dis-build: build failed in $d" >&2
		grep -E '\.b:[0-9]+:' "$ROOT/.dis-build-$$.log" | grep -v 'warning:' >&2 || true
		rm -f "$ROOT/.dis-build-$$.log"
		exit 2
	fi
	rm -f "$ROOT/.dis-build-$$.log"
done

# Scope: dis/ (the runtime, which releases ship) and acme/dis/ (acme's own
# command directory).  xenith/dis/ is built by appl/xenith/xenith/bin but was
# never tracked and is not staged into releases, so it is not the manifest's
# business -- including it would only add two dozen permanent "extra" lines.
built="$ROOT/.dis-built-$$.txt"
want="$ROOT/.dis-want-$$.txt"
find dis acme/dis -name '*.dis' -type f 2>/dev/null | sed 's|^\./||' | sort > "$built"
# Sort the manifest here too rather than trusting its committed order: a line
# added in the wrong place should be a harmless diff, not a CI failure.
sort "$MANIFEST" > "$want"

missing=$(comm -23 "$want" "$built")
extra=$(comm -13 "$want" "$built")
rm -f "$built" "$want"

rc=0
if [ -n "$missing" ]; then
	echo "" >&2
	echo "the build did not produce these, but the manifest lists them:" >&2
	echo "$missing" | sed 's/^/    /' >&2
	echo "" >&2
	echo "  A module is usually missing because it is not in its mkfile TARG." >&2
	echo "  If it was removed on purpose, drop its line from" >&2
	echo "  tools/dis-manifest.txt in the same commit." >&2
	rc=1
fi
if [ -n "$extra" ]; then
	echo "note: built but not listed in tools/dis-manifest.txt:"
	echo "$extra" | sed 's/^/    /'
	echo "  If these are meant to ship, add them to the manifest."
fi
[ "$rc" = 0 ] || exit "$rc"

echo "OK: the build produced all $(wc -l < "$MANIFEST" | tr -d ' ') modules the manifest lists"
