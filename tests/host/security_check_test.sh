#!/bin/bash
# Regression tests for the in-Inferno security-check script.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[[ -x "$EMU" ]] || { echo "SKIP: emu not found at $EMU"; exit 77; }

FIX="$ROOT/tmp/security-check-fixture"
rm -rf "$FIX"
mkdir -p "$FIX/env" "$FIX/lib/ndb" "$FIX/lib/keyring" "$FIX/mnt/audit"
printf '1\n' > "$FIX/env/cnsamode"
printf 'keyring\n' > "$FIX/env/serve_llm_auth"
printf '/lib/keyring/serve-llm\n' > "$FIX/env/serve_llm_key"
printf '32\n' > "$FIX/env/serve_llm_auth_limit"
printf '8\n' > "$FIX/env/serve_llm_auth_rate"
printf '30000\n' > "$FIX/env/serve_llm_auth_timeout"
printf 'mode=remote\nauth=keyring\nkeyfile=/lib/keyring/serve-llm\n' > "$FIX/lib/ndb/llm"
printf 'test-public-key-placeholder\n' > "$FIX/lib/keyring/serve-llm"
touch "$FIX/mnt/audit/ctl"

run_check() {
    local profile="${1:-server}"
    timeout 20 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
        "sh /lib/sh/security-check $profile /tmp/security-check-fixture" \
        </dev/null 2>&1 || true
}

out="$(run_check)"
grep -q 'security-check result=PASS' <<<"$out" || {
    echo "FAIL: safe fixture was not accepted"
    echo "$out"
    rm -rf "$FIX"
    exit 1
}

printf 'mode=remote\nauth=none\n' > "$FIX/lib/ndb/llm"
out="$(run_check)"
grep -q 'FAIL LLM-AUTH remote mount permits anonymous authentication' <<<"$out" || {
    echo "FAIL: anonymous remote mount was not rejected"
    echo "$out"
    rm -rf "$FIX"
    exit 1
}
grep -q 'security-check result=FAIL' <<<"$out" || {
    echo "FAIL: unsafe fixture did not produce failing summary"
    echo "$out"
    rm -rf "$FIX"
    exit 1
}

# A headless export must never select the anonymous listener branch.
printf 'mode=local\n' > "$FIX/lib/ndb/llm"
printf 'anon\n' > "$FIX/env/serve_llm_auth"
out="$(run_check)"
grep -q 'FAIL EXPORT-AUTH LLM export authentication is not keyring' <<<"$out" || {
    echo "FAIL: anonymous LLM export was not rejected"
    echo "$out"
    rm -rf "$FIX"
    exit 1
}

printf 'keyring\n' > "$FIX/env/serve_llm_auth"
printf '0\n' > "$FIX/env/serve_llm_auth_rate"
out="$(run_check)"
grep -q 'FAIL EXPORT-AUTH-RATE pre-auth rate does not match production policy' <<<"$out" || {
    echo "FAIL: unsafe pre-auth rate was not rejected"
    echo "$out"
    rm -rf "$FIX"
    exit 1
}

# An agent namespace must not expose host command authority.
rm -f "$FIX/env/SERVE_LLM_AUTH" "$FIX/env/serve_llm_auth"
touch "$FIX/cmd"
out="$(run_check agent)"
grep -q 'FAIL AGENT-AUTHORITY /cmd is visible' <<<"$out" || {
    echo "FAIL: agent-visible /cmd was not rejected"
    echo "$out"
    rm -rf "$FIX"
    exit 1
}

rm -rf "$FIX"
echo 'PASS: security-check accepts safe configuration and rejects anonymous mounts, exports, and agent host authority'
