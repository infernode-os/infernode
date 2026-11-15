#!/bin/sh
#
# llmctl9p_test.sh — /llm (llmctl9p) says what it does.
#
# The crossing to the host's llmctl is switched off, so every verb is
# refused; what is checked is that the refusals are true:
#   - the files belong to the user serving them (they were "inferno"'s
#     whoever that was, and ctl is mode 600: another user could not
#     open their own ctl);
#   - an unknown verb is refused with the list of verbs as it is (it
#     named three of the five) and without the writer's text in it;
#   - a known verb is refused too, saying to use the host's llmctl;
#   - status reads as a line saying the same.
#
set -e

. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/llmctl9p.dis" ] || { echo "SKIP: dis/llmctl9p.dis not built"; exit 77; }

WORK="$(mktemp -d)"
SCRIPT="$ROOT/tests/inferno/.llmctl9p.$$.sh"
SCRATCH="$ROOT/tmp/llmctl9p.$$"
cleanup() {
	rm -f "$SCRIPT"
	rm -rf "$WORK" "$SCRATCH"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$SCRATCH/llm"
M=/tmp/llmctl9p.$$/llm
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
mount {llmctl9p} $M
echo R user \`{cat /dev/user}
echo R ls \`{ls -l $M/ctl}
echo 'set bogus;rm -rf /' > $M/ctl >[2] /tmp/llmctl9p.$$/bad.err
echo R bad \`{cat /tmp/llmctl9p.$$/bad.err}
echo 'set claude' > $M/ctl >[2] /tmp/llmctl9p.$$/good.err
echo R good \`{cat /tmp/llmctl9p.$$/good.err}
echo R status \`{cat $M/status}
echo R done
echo halt > '#c/sysctl'
EOF

LOG="$WORK/log"
cd "$ROOT"
with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis \
	"/tests/inferno/$(basename "$SCRIPT")" </dev/null > "$LOG" 2>&1 || true

failed=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; failed=1; }

grep -q '^R done' "$LOG" && ok "the driver finished" || bad "the driver did not finish"
user=$(sed -n 's/^R user //p' "$LOG")
owner=$(sed -n 's/^R ls //p' "$LOG" | awk '{print $4}')
[ -n "$user" ] && [ "$owner" = "$user" ] && ok "ctl belongs to the user serving it ($user)" \
	|| bad "ctl belongs to '$owner', the server's user is '$user'"
grep -q '^R bad .*set ollama|sglang|claude|codex|none' "$LOG" && ok "an unknown verb is refused with the verbs there are" \
	|| bad "an unknown verb's refusal does not list the verbs"
grep -q '^R bad .*bogus' "$LOG" && bad "the refusal carries the writer's text" \
	|| ok "the refusal does not carry the writer's text"
grep -q '^R good .*llmctl set claude.* on the host' "$LOG" && ok "a known verb is refused, saying to use the host's llmctl" \
	|| bad "a known verb was not refused with what to do"
grep -q '^R status .*llmctl status' "$LOG" && ok "status says the same" || bad "status does not say so"

if [ "$failed" = 0 ]; then echo "ALL PASS"; exit 0; fi
echo "--- log"
cat "$LOG"
exit 1
