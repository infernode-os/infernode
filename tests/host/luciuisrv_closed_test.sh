#!/bin/sh
#
# luciuisrv_closed_test.sh — a closed activity takes no more writes, and
# writing to one does not bring the server down.
#
# Closing an activity frees its arrays (messages, artifacts, resources) and
# marks it hidden.  A task closed while it worked kept writing to it (its
# status, its context, its presentation): the first array to grow from
# empty indexed past its end and crashed luciuisrv, and with it the whole
# UI; and a status write undid the close.  Each kind of write is made to a
# closed activity here; each must be refused, and the server must answer
# after.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/luciuisrv.dis" ] || { echo "SKIP: dis/luciuisrv.dis not built"; exit 77; }

FAILED=0
check() {	# description, a write to activity 1 after it is closed
	out=$(timeout 30 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -c "path=(/dis/veltro /dis/cmd /dis .); luciuisrv; \
		echo 'activity create Main' > /mnt/ui/ctl; echo 'activity create Task' > /mnt/ui/ctl; \
		echo 'role=veltro text=one' > /mnt/ui/activity/1/conversation/ctl; \
		echo 'activity delete 1' > /mnt/ui/ctl; \
		$2; echo STATUS \`{cat /mnt/ui/activity/1/status}; echo ALIVE \`{cat /mnt/ui/activity/0/label}" </dev/null 2>&1 || true)
	if printf '%s\n' "$out" | grep -q Broken; then
		echo "FAIL: $1 (the server crashed)"; FAILED=$((FAILED + 1))
	elif ! printf '%s\n' "$out" | grep -q '^ALIVE Main'; then
		echo "FAIL: $1 (no answer after)"; FAILED=$((FAILED + 1))
	elif ! printf '%s\n' "$out" | grep -q '^STATUS hidden'; then
		echo "FAIL: $1 (the activity was reopened)"; FAILED=$((FAILED + 1))
	else
		echo "PASS: $1"
	fi
}

check "status" "echo working > /mnt/ui/activity/1/status"
check "a message" "echo 'role=veltro text=two' > /mnt/ui/activity/1/conversation/ctl"
check "a resource added" "echo 'resource add path=list label=list type=tool status=idle' > /mnt/ui/activity/1/context/ctl"
check "a resource upserted" "echo 'resource upsert path=/x label=x type=file via=list status=active' > /mnt/ui/activity/1/context/ctl"
check "an artifact created" "echo 'create id=a type=markdown label=A' > /mnt/ui/activity/1/presentation/ctl"
check "urgency" "echo 1 > /mnt/ui/activity/1/urgency"

[ "$FAILED" -eq 0 ] || { echo "luciuisrv_closed_test: $FAILED failed"; exit 1; }
echo "luciuisrv_closed_test: PASS"
