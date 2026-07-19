#!/bin/sh
# tests/host/llmctl_test.sh — llmctl backend-switcher host tests.
#
# Exercises llmctl's argument validation, ndb read/write helpers, and
# the dispatch logic with mocked systemctl + curl. The destructive
# `set ollama` / `set sglang` paths run against fakes; no real backend
# is started during the test.

set -eu

ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

LLMCTL="$ROOT/llmctl"

if [ ! -x "$LLMCTL" ]; then
    echo "FAIL: llmctl not found or not executable at $LLMCTL" >&2
    exit 1
fi

echo "=== llmctl host tests ==="

# Fixture: temp HOME with a private ndb dir + PATH-based fakes for
# systemctl and curl. Each test invocation pulls them from these
# locations rather than touching the real host.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/home/.infernode/lib/ndb" "$WORK/bin"

# Seed a minimal ndb file matching the on-disk shape.
cat > "$WORK/home/.infernode/lib/ndb/llm" <<EOF
mode=local
backend=openai
url=http://127.0.0.1:11434/v1
model=dummy:latest
dial=
EOF

# Fake systemctl. Reads/writes WORK/state/{ollama,sglang,claude} files as
# the live unit state. State word matches `systemctl is-active` output.
mkdir -p "$WORK/state"
echo active   > "$WORK/state/ollama"
echo inactive > "$WORK/state/sglang"
echo inactive > "$WORK/state/claude"

cat > "$WORK/bin/systemctl" <<EOF
#!/bin/sh
# Args: --user <verb> [--quiet] <unit>
# Strip --user
shift
verb="\$1"; shift
quiet=0
[ "\$1" = "--quiet" ] && { quiet=1; shift; }
unit="\$1"
key=
case "\$unit" in
    ollama.service)         key=ollama ;;
    serving-sglang.service) key=sglang ;;
    claude-gate.service)    key=claude ;;
    *) echo "fake-systemctl: unknown unit \$unit" >&2; exit 1 ;;
esac
state_file="$WORK/state/\$key"
case "\$verb" in
    is-active)
        st="\$(cat "\$state_file" 2>/dev/null || echo unknown)"
        if [ "\$quiet" -eq 1 ]; then
            [ "\$st" = "active" ]
        else
            echo "\$st"
        fi
        ;;
    start) echo active   > "\$state_file" ;;
    stop)  echo inactive > "\$state_file" ;;
    *) echo "fake-systemctl: unknown verb \$verb" >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/systemctl"

# Fake curl. Probes succeed for whichever backend has state=active.
# Scan all args POSIX-ly for the URL pattern (dash has no \${@: -1}).
cat > "$WORK/bin/curl" <<EOF
#!/bin/sh
for arg in "\$@"; do
    case "\$arg" in
        *11434/api/tags)
            [ "\$(cat "$WORK/state/ollama")" = "active" ] && exit 0 || exit 22 ;;
        *30000/v1/models)
            [ "\$(cat "$WORK/state/sglang")" = "active" ] && exit 0 || exit 22 ;;
        *11435/v1/models)
            [ "\$(cat "$WORK/state/claude")" = "active" ] && exit 0 || exit 22 ;;
    esac
done
exit 22
EOF
chmod +x "$WORK/bin/curl"

ORIG_HOME="$HOME"
ORIG_PATH="$PATH"
HOME="$WORK/home"
PATH="$WORK/bin:$PATH"
export HOME PATH

# ── tests ─────────────────────────────────────────────────────

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# 1. --help works and contains the usage line
out="$("$LLMCTL" --help)"
echo "$out" | grep -q "Usage:" || fail "--help missing 'Usage:'"
echo "$out" | grep -q "status" || fail "--help missing 'status' subcommand"
pass "--help renders"

# 2. No-arg dispatches to help (exit 0)
"$LLMCTL" >/dev/null || fail "no-arg invocation should exit 0 (help)"
pass "no-arg → help"

# 3. Unknown command errors with a clear message
if out="$("$LLMCTL" wat 2>&1)"; then
    fail "unknown command should exit non-zero"
fi
echo "$out" | grep -q "unknown command" || fail "unknown-command error message missing"
pass "unknown command rejected"

# 4. `set` with no target errors
if out="$("$LLMCTL" set 2>&1)"; then
    fail "set with no target should fail"
fi
echo "$out" | grep -q "missing argument" || fail "set-no-arg error message missing"
pass "set: missing arg rejected"

# 5. `set wat` errors
if out="$("$LLMCTL" set wat 2>&1)"; then
    fail "set wat should fail"
fi
echo "$out" | grep -q "unknown target" || fail "set-bad-target error message missing"
pass "set: bad target rejected"

# 6. Initial status: ollama=active, sglang=inactive (per fake state)
out="$("$LLMCTL" status)"
echo "$out" | grep -q "^backend  ollama" || fail "status: expected backend=ollama"
echo "$out" | grep -q "^healthy  yes"    || fail "status: expected healthy=yes"
echo "$out" | grep -q "^ollama   active" || fail "status: ollama unit not active"
pass "status reads initial state"

# 7. `set sglang` flips state, updates ndb url
"$LLMCTL" set sglang >/dev/null
[ "$(cat "$WORK/state/ollama")" = "inactive" ] || fail "set sglang: ollama should be stopped"
[ "$(cat "$WORK/state/sglang")" = "active" ]   || fail "set sglang: sglang should be started"
new_url="$(sed -n 's/^url=//p' "$WORK/home/.infernode/lib/ndb/llm")"
[ "$new_url" = "http://127.0.0.1:30000/v1" ] || fail "set sglang: ndb url not updated (got '$new_url')"
ls "$WORK/home/.infernode/lib/ndb/llm.bak."* >/dev/null 2>&1 \
    || fail "set sglang: no backup file created"
pass "set sglang flips state + updates ndb + backup"

# 8. `set ollama` flips back
"$LLMCTL" set ollama >/dev/null
[ "$(cat "$WORK/state/sglang")" = "inactive" ] || fail "set ollama: sglang should be stopped"
[ "$(cat "$WORK/state/ollama")" = "active" ]   || fail "set ollama: ollama should be started"
new_url="$(sed -n 's/^url=//p' "$WORK/home/.infernode/lib/ndb/llm")"
[ "$new_url" = "http://127.0.0.1:11434/v1" ] || fail "set ollama: ndb url not flipped back (got '$new_url')"
pass "set ollama flips back"

# 9. `set none` stops both, ndb unchanged
url_before_none="$(sed -n 's/^url=//p' "$WORK/home/.infernode/lib/ndb/llm")"
echo active > "$WORK/state/ollama"  # ensure something is up
"$LLMCTL" set none >/dev/null
[ "$(cat "$WORK/state/ollama")" = "inactive" ] || fail "set none: ollama should be stopped"
[ "$(cat "$WORK/state/sglang")" = "inactive" ] || fail "set none: sglang should be stopped"
url_after_none="$(sed -n 's/^url=//p' "$WORK/home/.infernode/lib/ndb/llm")"
[ "$url_before_none" = "$url_after_none" ] || fail "set none: ndb url should be unchanged"
pass "set none stops both, leaves ndb"

# 10. Idempotent set when already there + healthy
echo active > "$WORK/state/ollama"
"$LLMCTL" set ollama >/dev/null
[ "$(cat "$WORK/state/ollama")" = "active" ] || fail "idempotent set: ollama should still be active"
pass "idempotent set ollama"

# 11. health subcommand reports correctly
echo active   > "$WORK/state/ollama"
echo inactive > "$WORK/state/sglang"
out="$("$LLMCTL" health 2>&1 || true)"
echo "$out" | grep -q "^ollama  healthy"   || fail "health: ollama should be healthy"
echo "$out" | grep -q "^sglang  unhealthy" || fail "health: sglang should be unhealthy"
pass "health reports per-backend status"

# 12. health with bad target errors
if out="$("$LLMCTL" health wat 2>&1)"; then
    fail "health wat should fail"
fi
echo "$out" | grep -q "unknown target" || fail "health-bad-target error missing"
pass "health: bad target rejected"

# 13. `set claude` stops GPU stacks, starts claude-gate, writes url + backend=cli
echo active   > "$WORK/state/ollama"
echo inactive > "$WORK/state/sglang"
echo inactive > "$WORK/state/claude"
"$LLMCTL" set claude >/dev/null
[ "$(cat "$WORK/state/ollama")" = "inactive" ] || fail "set claude: ollama should be stopped"
[ "$(cat "$WORK/state/sglang")" = "inactive" ] || fail "set claude: sglang should be stopped"
[ "$(cat "$WORK/state/claude")" = "active" ]   || fail "set claude: claude-gate should be started"
new_url="$(sed -n 's/^url=//p' "$WORK/home/.infernode/lib/ndb/llm")"
[ "$new_url" = "http://127.0.0.1:11435/v1" ] || fail "set claude: ndb url not updated (got '$new_url')"
new_backend="$(sed -n 's/^backend=//p' "$WORK/home/.infernode/lib/ndb/llm")"
[ "$new_backend" = "cli" ] || fail "set claude: ndb backend should be cli (got '$new_backend')"
pass "set claude starts gate + writes url + backend=cli"

# 14. `set ollama` after claude restores backend=openai and stops the gate
"$LLMCTL" set ollama >/dev/null
[ "$(cat "$WORK/state/claude")" = "inactive" ] || fail "set ollama: claude-gate should be stopped"
[ "$(cat "$WORK/state/ollama")" = "active" ]   || fail "set ollama: ollama should be started"
new_backend="$(sed -n 's/^backend=//p' "$WORK/home/.infernode/lib/ndb/llm")"
[ "$new_backend" = "openai" ] || fail "set ollama: ndb backend should be openai (got '$new_backend')"
pass "set ollama after claude restores backend=openai"

# 15. health includes the claude probe
echo active > "$WORK/state/claude"
out="$("$LLMCTL" health 2>&1 || true)"
echo "$out" | grep -q "^claude  healthy" || fail "health: claude should be healthy"
out="$("$LLMCTL" health claude 2>&1)" || fail "health claude should exit 0 when healthy"
echo "$out" | grep -q "^claude  healthy" || fail "health claude: wrong output"
pass "health covers claude"

# 16. status shows the claude unit line and claude as current backend
echo inactive > "$WORK/state/ollama"
echo inactive > "$WORK/state/sglang"
echo active   > "$WORK/state/claude"
out="$("$LLMCTL" status)"
echo "$out" | grep -q "^backend  claude" || fail "status: expected backend=claude"
echo "$out" | grep -q "^claude   active" || fail "status: claude unit line missing"
pass "status reports claude backend"

# Restore HOME / PATH (cleanup trap handles WORK)
HOME="$ORIG_HOME"
PATH="$ORIG_PATH"
export HOME PATH

echo "=== llmctl host tests: all green ==="
