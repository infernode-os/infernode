#!/bin/sh
#
# toolctl_view_test.sh — tools9p's control tree shows the agent's name
# space as it is and says when its lists change (#1020), through
# tests/tools9p/view.sh:
#
#  - /mnt/toolctl has ns, event and view;
#  - view, mounted, is the root a tool call gets: /tool there, no /usr;
#    after 'bindpath /usr/inferno ro' a new mount has /usr/inferno,
#    whose files read as the host's;
#  - a remove refused still clunks its fid at the export, so the fid
#    walked again at once works ("fid in use" before), in 9P spoken to
#    view by tests/view_remove_helper.b;
#  - it is read-only: remove, a write and a create through it are
#    refused, and the host's file is unchanged;
#  - ns (ns(1)'s text of that name space) has /usr/inferno after the
#    grant and not before;
#  - a reader of event gets 'paths' for the bindpath and 'tools' for a
#    tool removed;
#  - a tool call's own /tool has none of the three.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/list.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

T=tmp/toolctl_view_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap 'rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
with_timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis -c "bind -c /$T /tmp; /tests/tools9p/view.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$ROOT/$T/$1" 2>/dev/null || true; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; tail -20 "$LOG"; exit 1; }

if f ls.ctl | grep -q '/ns$' && f ls.ctl | grep -q '/event$' && f ls.ctl | grep -q '/view$'; then
	pass "/mnt/toolctl has ns, event and view"
else
	fail "/mnt/toolctl: $(f ls.ctl | tr '\n' ' ')"
fi

if f root.before | grep -qx '/n/agent/tool' && ! f root.before | grep -qx '/n/agent/usr'; then
	pass "view is the agent's root: /tool there, no /usr before a grant"
else
	fail "root before the grant: $(f root.before | tr '\n' ' ')"
fi

if f usr.after | grep -qx '/n/agent/usr/inferno/README' && cmp -s "$ROOT/$T/readme" "$ROOT/usr/inferno/README"; then
	pass "after bindpath /usr/inferno ro, view has it, its files as the host's"
else
	fail "after the grant: $(f usr.after | tr '\n' ' ')"
fi

ro=1
for e in rm.err write.err create.err; do
	f $e | grep -q 'read-only' || { ro=0; fail "$e: $(f $e)"; }
done
[ -f "$ROOT/usr/inferno/README" ] && [ "$(head -c 1 "$ROOT/usr/inferno/README")" != x ] || { ro=0; fail "the host's README changed"; }
[ $ro = 1 ] && pass "view is read-only: remove, write and create refused, the host's file unchanged"
if f viewremove | grep -q '^remove: error .*read-only' && f viewremove | grep -qx 'walk again: walk 3'; then
	pass "a refused remove releases its fid: walked again at once, it works"
else
	fail "a refused remove releases its fid: $(f viewremove | tr '\n' ' ')"
fi

if ! f ns.before | grep -q '/usr/inferno' && f ns.after | grep -q '/usr/inferno'; then
	pass "ns has the grant after bindpath and not before"
else
	fail "ns: before $(f ns.before | grep -c usr) usr lines, after $(f ns.after | grep -c usr)"
fi

# (a 'paths' when tools9p's first name space is made may come first)
if f events | grep -qx paths && f events | grep -qx tools && ! f events | grep -qvxE 'paths|tools'; then
	pass "event: 'paths' for the bindpath, 'tools' for the tool removed"
else
	fail "events: '$(f events | tr '\n' ' ')'"
fi

if f agenttool | grep -qE '[[:space:]]list$' && ! f agenttool | grep -qE '[[:space:]](ns|event|view)$'; then
	pass "a tool call's /tool has none of them"
else
	fail "/tool in a tool call: $(f agenttool | tr '\n' ' ')"
fi

[ $failed = 0 ] && echo "toolctl_view_test: PASS"
exit $failed
