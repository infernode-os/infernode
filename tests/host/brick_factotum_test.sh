#!/bin/sh
#
# brick/factotum credential boundary and pairing transaction regression.
# Runs against regular-file USB config fakes: the test is about the commander
# commit order, persistence, restart, migration and public namespace, not the
# firmware parser (covered in the styxbrick repository).

set -eu

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi

STATE="$ROOT/tmp/brick-ft-test"
FAILURES=0
TESTS=0

cleanup() {
    rm -rf "$STATE"
}
trap cleanup EXIT INT TERM
cleanup
mkdir -p "$STATE"

pass() {
    TESTS=$((TESTS + 1))
    echo "PASS: $1"
}

fail() {
    TESTS=$((TESTS + 1))
    FAILURES=$((FAILURES + 1))
    echo "FAIL: $1"
}

contains() {
    name=$1
    output=$2
    pattern=$3
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$name"
    else
        fail "$name (missing $pattern)"
    fi
}

not_contains() {
    name=$1
    output=$2
    pattern=$3
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        fail "$name (found $pattern)"
    else
        pass "$name"
    fi
}

run_case() {
    script=$1
    set +e
    CASE_OUTPUT=$(with_timeout 60 "$EMU" -c0 -r"$ROOT" /dis/sh.dis "$script" 2>&1)
    rc=$?
    set -e
    if ! emu_timeout_ok "$rc"; then
        printf '%s\n' "$CASE_OUTPUT"
        fail "$script exited $rc"
    fi
}

echo "=== brick factotum integration ==="

run_case /tests/brick/factotum_fail.sh
contains "backend-less pairing is refused" "$CASE_OUTPUT" "PAIR-PERSISTENCE-REFUSED"
contains "TLS peer unchanged on persistence failure" "$CASE_OUTPUT" "PEER PEER-UNCHANGED"
contains "sdg pairing unchanged on persistence failure" "$CASE_OUTPUT" "SDG pub 444444"
contains "D2 key unchanged on persistence failure" "$CASE_OUTPUT" "D2 D2-UNCHANGED"
not_contains "failed pairing never reports success" "$CASE_OUTPUT" "BAD-PAIR-SUCCEEDED"
contains "failed pairing releases the profile lock" "$CASE_OUTPUT" "NO-FAIL-PAIR-LOCK"

run_case /tests/brick/factotum_savefail.sh
contains "keyfile write failure is returned" "$CASE_OUTPUT" "PAIR-SAVE-REFUSED"
contains "TLS peer unchanged on keyfile write failure" "$CASE_OUTPUT" "SAVE-PEER PEER-UNCHANGED"
contains "sdg unchanged on keyfile write failure" "$CASE_OUTPUT" "SAVE-SDG pub 444444"
contains "D2 unchanged on keyfile write failure" "$CASE_OUTPUT" "SAVE-D2 D2-UNCHANGED"
contains "save failure releases the profile lock" "$CASE_OUTPUT" "NO-SAVE-PAIR-LOCK"
not_contains "save failure never reports success" "$CASE_OUTPUT" "BAD-SAVE-PAIR-SUCCEEDED"

# The failed case deliberately used an unlocked factotum but did not create a
# persistent keyfile.  Reset only its public fake state before the durable run.
rm -rf "$STATE/failbrick" "$STATE/failprofile"

run_case /tests/brick/factotum_pair.sh
contains "pair completes with durable backend" "$CASE_OUTPUT" "FACTOTUM-PAIR-DONE"
contains "TLS scalar absent from namespace" "$CASE_OUTPUT" "NO-CLIENT-KEY-FILE"
contains "sdg scalar absent from namespace" "$CASE_OUTPUT" "NO-SDG-KEY-FILE"
contains "sdg PSK absent from namespace" "$CASE_OUTPUT" "NO-SDG-PSK-FILE"
contains "D2 key absent from namespace" "$CASE_OUTPUT" "NO-D2-KEY-FILE"
contains "successful pairing releases the profile lock" "$CASE_OUTPUT" "NO-PAIR-LOCK"
not_contains "factotum ctl elides secret values" "$CASE_OUTPUT" "!password="

FIRST_PIN=$(printf '%s\n' "$CASE_OUTPUT" | awk '/FIRST-PIN/{getline; print; exit}')
RETRY_PIN=$(printf '%s\n' "$CASE_OUTPUT" | awk '/RETRY-PIN/{getline; print; exit}')
if [ -n "$FIRST_PIN" ] && [ "$FIRST_PIN" = "$RETRY_PIN" ]; then
    pass "idempotent retry reuses the persisted candidate"
else
    fail "idempotent retry changed TLS identity"
fi

KEY_ROWS=$(printf '%s\n' "$CASE_OUTPUT" | grep -c 'service=brick' || true)
if [ "$KEY_ROWS" -eq 4 ]; then
    pass "exactly four purpose-scoped credentials stored"
else
    fail "expected four factotum credentials, got $KEY_ROWS"
fi

run_case /tests/brick/factotum_reload.sh
contains "encrypted keyfile reload completes" "$CASE_OUTPUT" "FACTOTUM-RELOAD-DONE"
RELOAD_PIN=$(printf '%s\n' "$CASE_OUTPUT" | awk '/RELOAD-PIN/{getline; print; exit}')
if [ "$RELOAD_PIN" = "$FIRST_PIN" ]; then
    pass "TLS identity survives fresh factotum restart"
else
    fail "TLS identity changed after restart"
fi

run_case /tests/brick/factotum_rotate.sh
contains "explicit rotation completes" "$CASE_OUTPUT" "FACTOTUM-ROTATE-DONE"
OLD_PIN=$(printf '%s\n' "$CASE_OUTPUT" | awk '/OLD-PIN/{getline; print; exit}')
NEW_PIN=$(printf '%s\n' "$CASE_OUTPUT" | awk '/NEW-PIN/{getline; print; exit}')
if [ -n "$OLD_PIN" ] && [ -n "$NEW_PIN" ] && [ "$OLD_PIN" != "$NEW_PIN" ]; then
    pass "-R replaces the commander TLS identity"
else
    fail "-R did not replace the commander TLS identity"
fi
ROTATED_ROWS=$(printf '%s\n' "$CASE_OUTPUT" | grep -c 'service=brick' || true)
if [ "$ROTATED_ROWS" -eq 4 ]; then
    pass "rotation replaces rather than duplicates credentials"
else
    fail "rotation left $ROTATED_ROWS factotum credentials"
fi

run_case /tests/brick/factotum_migrate.sh
contains "legacy TLS scalar removed after durable import" "$CASE_OUTPUT" "MIGRATED-CLIENT"
contains "legacy sdg scalar migrated" "$CASE_OUTPUT" "MIGRATED-SDG"
contains "legacy sdg PSK migrated" "$CASE_OUTPUT" "MIGRATED-PSK"
contains "legacy D2 key migrated" "$CASE_OUTPUT" "MIGRATED-D2"
not_contains "migration leaves no reported cleartext secret" "$CASE_OUTPUT" "BAD-MIGRATE-"

echo "=== $TESTS tests, $FAILURES failures ==="
if [ "$FAILURES" -ne 0 ]; then
    exit 1
fi
echo PASS
