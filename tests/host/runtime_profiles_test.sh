#!/bin/sh
# Materialize the production nsaudit profiles and compare their live /tool,
# namespace manifest, and nsaudit views. No LLM or external service is needed.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

SH=/dis/sh.dis
PASSED=0
FAILED=0
OUTPUT=

pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; echo "$OUTPUT"; FAILED=$((FAILED + 1)); }

[ -x "$EMU" ] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[ -f "$ROOT/dis/veltro/tools9p.dis" ] || { echo "SKIP: tools9p.dis not found"; exit 77; }

for profile in profile-minimal-headless profile-desktop-gui profile-messaging profile-payments; do
	if diff -ru "$ROOT/lib/veltro/profiles/$profile" \
	    "$ROOT/tests/nsaudit-fixtures/$profile" >/dev/null; then
		pass "$profile fixture matches its production declaration"
	else
		OUTPUT="$(diff -ru "$ROOT/lib/veltro/profiles/$profile" \
		    "$ROOT/tests/nsaudit-fixtures/$profile" || true)"
		fail "$profile fixture drifted from production"
	fi
done

run_profiles()
{
	name=$1
	shift
	pargs=
	for profile in "$@"; do
		pargs="$pargs -P $profile"
	done
	log="/tmp/runtime-profiles-$name-$$.log"
	timeout 18 "$EMU" -c0 -r"$ROOT" "$SH" -c \
		"path=(/dis/veltro /dis/cmd /dis .); mkdir -p /mnt/msg /mnt/ui/activity/0/presentation /n/wallet; touch /mnt/msg/status /mnt/msg/draft /n/wallet/accounts; tools9p -v $pargs &sleep 5; echo TOOLS; cat /tool/tools; echo; echo PATHS; cat /tool/paths; echo; echo ROLE; cat /tool/meta/role; echo NODEVS; cat /tool/meta/nodevs; echo XENITH; cat /tool/meta/xenith; echo ACTID; cat /tool/meta/actid; echo; echo WALLETBUDGET; cat /tool/walletbudget; echo; echo MANIFEST; cat /tmp/veltro/.ns/manifest; echo NSAUDIT; nsaudit -m /tool; echo PROFILE_READY" \
		</dev/null >"$log" 2>&1
	rc=$?
	OUTPUT="$(cat "$log")"
	rm -f "$log"
	sleep 1
	emu_timeout_ok "$rc" && printf '%s\n' "$OUTPUT" | grep -q '^PROFILE_READY$'
}

check_common()
{
	name=$1
	if printf '%s\n' "$OUTPUT" | grep -q '^/tmp/veltro/scratch cow$' &&
	   printf '%s\n' "$OUTPUT" | grep -q '^path=/tmp/veltro/scratch label=Activity Scratch perm=cow$' &&
	   ! printf '%s\n' "$OUTPUT" | grep -q '^path=/tmp/veltro label=' &&
	   [ "$(printf '%s\n' "$OUTPUT" | awk '/^ROLE$/{getline; print; exit}')" = toplevel ] &&
	   [ "$(printf '%s\n' "$OUTPUT" | awk '/^NODEVS$/{getline; print; exit}')" = set ] &&
	   [ "$(printf '%s\n' "$OUTPUT" | awk '/^ACTID$/{getline; print; exit}')" = 0 ] &&
	   ! printf '%s\n' "$OUTPUT" | grep -q 'severity=high'; then
		pass "$name has truthful scratch, metadata, manifest, and audit"
	else
		fail "$name runtime views disagree"
	fi
}

if run_profiles minimal profile-minimal-headless; then
	check_common minimal
else
	fail "minimal profile did not materialize before timeout"
fi

if run_profiles desktop profile-desktop-gui; then
	check_common desktop
	if printf '%s\n' "$OUTPUT" | grep -q '^present$' &&
	   printf '%s\n' "$OUTPUT" | grep -q '^gap$' &&
	   printf '%s\n' "$OUTPUT" | grep -q '^keyring$' &&
	   [ "$(printf '%s\n' "$OUTPUT" | awk '/^XENITH$/{getline; print; exit}')" = 0 ] &&
	   printf '%s\n' "$OUTPUT" | grep -q '^authority=sends_ui$' &&
	   ! printf '%s\n' "$OUTPUT" | grep -q '^authority=reads_windows$'; then
		pass "desktop fixed-function UI does not claim /chan authority"
	else
		fail "desktop UI authority is not represented truthfully"
	fi
else
	fail "desktop profile did not materialize before timeout"
fi

if run_profiles messaging profile-messaging; then
	check_common messaging
	if printf '%s\n' "$OUTPUT" | grep -q '^/mnt/msg ro$' &&
	   printf '%s\n' "$OUTPUT" | grep -q '^/mnt/msg/draft rw$' &&
	   ! printf '%s\n' "$OUTPUT" | grep -q '/mnt/msg/\(ctl\|approve\|deny\)'; then
		pass "messaging exposes status/proposal paths without trusted controls"
	else
		fail "messaging path attenuation is wrong"
	fi
else
	fail "messaging profile did not materialize before timeout"
fi

if run_profiles payments profile-payments; then
	check_common payments
	if printf '%s\n' "$OUTPUT" | grep -q '^wallet$' &&
	   [ "$(printf '%s\n' "$OUTPUT" | awk '/^WALLETBUDGET$/{getline; print; exit}')" = '1000000 USDC' ] &&
	   printf '%s\n' "$OUTPUT" | grep -q 'walletbudget_status=bounded' &&
	   ! printf '%s\n' "$OUTPUT" | grep -q 'violation=UNBOUNDED_SPEND'; then
		pass "payments exposes an enforced bounded-spend declaration"
	else
		fail "payments budget is missing or audits as unbounded"
	fi
else
	fail "payments profile did not materialize before timeout"
fi

for spec in \
	"desktop-messaging profile-desktop-gui profile-messaging" \
	"messaging-payments profile-messaging profile-payments" \
	"all profile-desktop-gui profile-messaging profile-payments"; do
	set -- $spec
	name=$1
	shift
	if run_profiles "$name" "$@"; then
		check_common "$name composition"
	else
		fail "$name composition did not materialize before timeout"
	fi
done

# A failed backend request is conservatively reserved. The second proposal
# therefore proves the dispatcher enforces the advertised aggregate cap before
# wallet9p can approve or execute anything. The same process also tries the two
# authority paths that would bypass a local cap: payfetch and child delegation.
log="/tmp/runtime-profile-wallet-$$.log"
timeout 18 "$EMU" -c0 -r"$ROOT" "$SH" -c \
	"path=(/dis/veltro /dis/cmd /dis .); mkdir -p /n/wallet; touch /n/wallet/accounts; tools9p -b wallet,payfetch -P profile-payments task &sleep 5; echo add payfetch > /mnt/toolctl/ctl; echo '41 tools=wallet' > /tool/provision; echo pay acct usdc 600000 0x0000000000000000000000000000000000000001 > /tool/wallet/run; cat /tool/wallet/run; echo; echo pay acct usdc 500000 0x0000000000000000000000000000000000000001 > /tool/wallet/run; cat /tool/wallet/run; echo; echo BUDGET_DONE" \
	</dev/null >"$log" 2>&1
rc=$?
OUTPUT="$(cat "$log")"
rm -f "$log"
if emu_timeout_ok "$rc" && printf '%s\n' "$OUTPUT" | grep -q '^BUDGET_DONE$' &&
   printf '%s\n' "$OUTPUT" | grep -q 'payfetch bypasses the enforced wallet budget' &&
   printf '%s\n' "$OUTPUT" | grep -q 'wallet budget is not delegatable' &&
   printf '%s\n' "$OUTPUT" | grep -q 'wallet budget exceeded: cap 1000000 USDC'; then
	pass "wallet profile enforces its cap without activation or delegation bypass"
else
	fail "wallet profile declaration was not enforced"
fi

echo "Total: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
