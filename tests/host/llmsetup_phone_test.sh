#!/bin/sh
#
# Lucifer's first-run LLM setup on a phone (tests/llmsetup/wizard.sh):
# booted as iOS and Android boot it (lib/lucifer/boot-mobile.sh), the
# wizard offers Remote API, Local model and Remote 9P, not the Claude
# and Codex CLIs -- a phone has no host to run their gateways (iOS can
# run none), so choosing one only ever ended at "can't reach it" -- and
# Remote 9P's answer says that is how a phone uses a computer's CLI
# login.  Booted as a desktop (boot.sh), all five are offered and the
# answer says nothing of phones.  Needs the SDL emulator
# (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/lucibridge.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi
# the wizard shows only with no LLM configured
if [ -s "$ROOT/lib/ndb/llm" ]; then
	echo "SKIP: lib/ndb/llm configures an LLM, so there is no setup wizard"
	exit 77
fi

T=tmp/llmsetup_phone_test.$$
trap 'rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }

boot() {	# boot script, its directory
	mkdir -p "$ROOT/$T/$2"
	SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g720x1560 -r"$ROOT" \
		/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/$1 --no-logon & sleep 45; bind -c /$T/$2 /tmp; run /tests/llmsetup/wizard.sh" \
		</dev/null >"$ROOT/$T/$2/log" 2>&1 || true
	grep -q '^R done' "$ROOT/$T/$2/log" || { fail "$2: the driver did not finish"; grep -v '^fs:' "$ROOT/$T/$2/log" | tail -10; }
}
opts() { sed -n 's/.*options=\(.*\) text=.*/\1/p' "$ROOT/$T/$1/dialogue" 2>/dev/null; }

boot boot-mobile.sh phone
boot boot.sh desktop

o=$(opts phone)
[ "$o" = "Remote API,Local model,Remote 9P" ] && pass "on a phone: $o" || fail "on a phone the wizard offers '$o'"
grep -q 'Claude or Codex CLI from this phone' "$ROOT/$T/phone/answer" 2>/dev/null &&
	pass "on a phone Remote 9P says how to use a computer's CLI login" ||
	fail "on a phone Remote 9P's answer: $(cat "$ROOT/$T/phone/answer" 2>/dev/null)"
o=$(opts desktop)
[ "$o" = "Remote API,Local model,Claude CLI,Codex CLI,Remote 9P" ] && pass "on a desktop: $o" ||
	fail "on a desktop the wizard offers '$o'"
grep -q 'this phone' "$ROOT/$T/desktop/answer" 2>/dev/null &&
	fail "on a desktop Remote 9P's answer speaks of a phone" ||
	pass "on a desktop Remote 9P says nothing of phones"

[ $failed -eq 0 ] || exit 1
echo ALL PASS
