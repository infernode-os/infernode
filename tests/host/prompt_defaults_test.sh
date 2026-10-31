#!/bin/sh
#
# prompt_defaults_test.sh — the agent prompts in ~/.infernode follow the
# shipped defaults until the user edits them.
#
# lib/sh/profile copies lib/veltro/meta.txt and lib/veltro/agents/task.txt
# into ~/.infernode once, and binds the copies over the shipped files.  A
# copy whose hash is in lib/veltro/prompt-defaults was never edited, and is
# brought up to the current default at each boot; an edited one is left.
#
# Checks: the current prompts' hashes are listed (a change to a prompt must
# add its hash, or every install that has the new one would freeze on it);
# a boot brings an unedited old copy up to date; it leaves an edited copy.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

LIST="$ROOT/lib/veltro/prompt-defaults"
FAILED=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

for f in meta.txt agents/task.txt; do
	h=$(sha1sum < "$ROOT/lib/veltro/$f" | cut -d' ' -f1)
	if grep -q "^$h $(basename $f)\$" "$LIST"; then
		ok "the current $f is listed"
	else
		bad "the current $f is listed (add: $h $(basename $f))"
	fi
done

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU (boot checks)"; [ "$FAILED" -eq 0 ] && exit 0 || exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
IH="$WORK/.infernode"
mkdir -p "$IH/lib/veltro" "$IH/lib/veltro-agents" "$IH/lib/ndb"
echo 'mode=local' > "$IH/lib/ndb/llm"	# not a first run: nothing is seeded

# An unedited old meta.txt (the first one ever shipped) and an edited task.txt.
OLDMETA=$(cd "$ROOT" && git log --format=%H -- lib/veltro/meta.txt 2>/dev/null | tail -1)
if [ -z "$OLDMETA" ]; then
	echo "SKIP: no git history for lib/veltro/meta.txt (boot checks)"
	[ "$FAILED" -eq 0 ] && exit 0 || exit 1
fi
(cd "$ROOT" && git show "$OLDMETA:lib/veltro/meta.txt") > "$IH/lib/veltro/meta.txt"
{ cat "$ROOT/lib/veltro/agents/task.txt"; echo "Always answer in French."; } > "$IH/lib/veltro-agents/task.txt"
cp "$IH/lib/veltro-agents/task.txt" "$WORK/edited-task.txt"

HOME="$WORK" "$EMU" -c0 -r"$ROOT" /dis/sh.dis -l -c 'echo BOOTED' </dev/null > "$WORK/emu.log" 2>&1 &
pid=$!
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do
	grep -q '^BOOTED' "$WORK/emu.log" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
kill -9 "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
grep -q '^BOOTED' "$WORK/emu.log" || { bad "the profile ran"; tail -20 "$WORK/emu.log"; exit 1; }

cmp -s "$IH/lib/veltro/meta.txt" "$ROOT/lib/veltro/meta.txt" &&
	ok "an unedited old meta.txt becomes the current default" ||
	bad "an unedited old meta.txt becomes the current default"
cmp -s "$IH/lib/veltro-agents/task.txt" "$WORK/edited-task.txt" &&
	ok "an edited task.txt is left as the user made it" ||
	bad "an edited task.txt is left as the user made it"

[ "$FAILED" -eq 0 ] || { echo "prompt_defaults_test: $FAILED failed"; exit 1; }
echo "prompt_defaults_test: PASS"
