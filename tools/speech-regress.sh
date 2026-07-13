#!/usr/bin/env bash
#
# speech-regress.sh — one-command regression suite for the voice/speech stack.
#
# Builds and runs the targeted Limbo suites for voicemode, speech9p,
# speechshim9p, and the speech tooling inside the emulator, then the
# host-side helper smoke test. This is deliberately NOT ./run-tests.sh:
# it touches only the speech/voice suites, so it is cheap enough to run
# after every change to appl/cmd/voicemode.b, appl/veltro/speech*.b,
# module/speech.m, tools/install-speech-helpers.sh, or the boot wiring.
#
# Pass criteria come from the testing framework's output (a final PASS
# summary and no "--- FAIL:" lines), not only the exit status.
#
# Known pre-existing gotcha: speech_kokoro_test prints PASS but the
# emulator never halts afterwards (C-level audio teardown, not a voice
# regression). It runs under timeout, and exit 124 with a PASS summary
# counts as a pass.
#
# usage: tools/speech-regress.sh [-v]
#   -v   stream each suite's output as it runs (failures always print)

set -u

verbose=0
[ "${1:-}" = "-v" ] && verbose=1

cd "$(dirname "$0")/.." || exit 1
export ROOT=$PWD

case "$(uname -s)" in
Darwin) SYSHOST=MacOSX ;;
Linux)  SYSHOST=Linux ;;
*) echo "speech-regress: unsupported host: $(uname -s)" >&2; exit 1 ;;
esac
objtype=$(uname -m)
case "$objtype" in
arm64|aarch64) objtype=arm64 ;;
x86_64|amd64)  objtype=amd64 ;;
esac
export PATH=$ROOT/$SYSHOST/$objtype/bin:$PATH

EMU=$ROOT/emu/$SYSHOST/o.emu
if [ ! -x "$EMU" ]; then
  echo "speech-regress: emulator not built: $EMU" >&2
  exit 1
fi

# Emu suites, cheapest protocol tests first. speech_kokoro_test goes last:
# it drives real audio output and its emu never halts (see header).
SUITES="
speechshim_test
speech9p_voice_test
speech_wake_test
speech_listen_test
voicemode_test
speechtest_test
voice_scripts_test
speech_kokoro_test
"

# Rebuild only the suites we run. Without the native mk (fresh clone,
# tools not bootstrapped) fall back to whatever bytecode is already there.
if command -v mk >/dev/null 2>&1; then
  echo "== building test bytecode"
  buildlog=$(mktemp -t speech-regress-build)
  for t in $SUITES; do
    if ! (cd tests && mk "$t.dis") >>"$buildlog" 2>&1; then
      echo "speech-regress: build failed for $t:" >&2
      cat "$buildlog" >&2
      rm -f "$buildlog"
      exit 1
    fi
  done
  rm -f "$buildlog"
else
  echo "speech-regress: native mk not on PATH; running existing bytecode" >&2
fi

logdir=$(mktemp -d -t speech-regress)
trap 'rm -rf "$logdir"' EXIT

failed=""
npass=0

run_suite() {
  local name=$1 limit=$2
  local log=$logdir/$name.log status ok=0

  printf '== %s ' "$name"
  if [ "$verbose" = 1 ]; then
    echo
    timeout "$limit" "$EMU" -r. "/tests/$name.dis" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
  else
    timeout "$limit" "$EMU" -r. "/tests/$name.dis" >"$log" 2>&1
    status=$?
  fi

  if grep -q '^PASS$' "$log" && ! grep -q -- '--- FAIL:' "$log"; then
    if [ "$status" -eq 0 ]; then
      ok=1
    elif [ "$status" -eq 124 ] && [ "$name" = speech_kokoro_test ]; then
      ok=1  # known no-halt gotcha: PASS output + timeout kill
    fi
  fi

  if [ "$ok" = 1 ]; then
    echo "PASS"
    npass=$((npass + 1))
  else
    echo "FAIL (exit $status)"
    failed="$failed $name"
    if [ "$verbose" != 1 ]; then
      echo "---- tail of $name output ----"
      tail -30 "$log"
      echo "------------------------------"
    fi
  fi
}

for t in $SUITES; do
  limit=240
  [ "$t" = speech_kokoro_test ] && limit=120
  run_suite "$t" "$limit"
done

# Host-side wrapper smoke test. SKIPs itself when no helper install exists,
# which still counts as a pass here — the emu suites above do not depend on
# a helper install.
printf '== speech_helpers_test.sh '
hostlog=$logdir/host.log
if bash tests/host/speech_helpers_test.sh >"$hostlog" 2>&1; then
  # A first-line SKIP means no helper install at all; a trailing SKIP is
  # only the mic-dependent portion, which needs an interactive TCC session.
  if head -1 "$hostlog" | grep -q '^SKIP'; then
    echo "SKIP ($(head -1 "$hostlog"))"
  else
    echo "PASS"
  fi
  npass=$((npass + 1))
else
  echo "FAIL"
  failed="$failed speech_helpers_test.sh"
  echo "---- tail of host test output ----"
  tail -30 "$hostlog"
  echo "----------------------------------"
fi

echo
if [ -n "$failed" ]; then
  echo "speech-regress: FAIL:$failed"
  exit 1
fi
echo "speech-regress: all $npass suites passed"
