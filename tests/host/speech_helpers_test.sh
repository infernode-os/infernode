#!/usr/bin/env bash
set -euo pipefail

PREFIX=${INFERNODE_SPEECH_HOME:-"$HOME/.local/share/infernode-speech"}
BIN="$PREFIX/bin"
TMPDIR=${TMPDIR:-/tmp}
WORKDIR=$(mktemp -d "$TMPDIR/infernode-speech-helpers.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

if [ ! -d "$PREFIX" ]; then
  echo "SKIP: speech helper install dir not found: $PREFIX"
  exit 0
fi

require_exec() {
  local path=$1
  if [ ! -x "$path" ]; then
    echo "FAIL: missing executable wrapper: $path" >&2
    exit 1
  fi
}

require_exec "$BIN/kokoro-cli"
require_exec "$BIN/whisper-stream-cli"
require_exec "$BIN/openwakeword-cli"

"$BIN/kokoro-cli" --list-voices >/dev/null
printf 'hello\n' | timeout 90 "$BIN/kokoro-cli" --voice af_bella --format pcm --rate 24000 >"$WORKDIR/hello.pcm"
if [ ! -s "$WORKDIR/hello.pcm" ]; then
  echo "FAIL: kokoro-cli produced no PCM" >&2
  exit 1
fi

timeout 10 "$BIN/whisper-stream-cli" --help >/dev/null
timeout 10 "$BIN/openwakeword-cli" --help >/dev/null
timeout 10 "$BIN/whisper-stream-cli" --stdin >"$WORKDIR/whisper-stdin.out"
if ! grep -q '^error: whisper-stream stdin PCM mode is not supported' "$WORKDIR/whisper-stdin.out"; then
  echo "FAIL: whisper-stream-cli --stdin did not report the documented limitation" >&2
  exit 1
fi

if [ "${INFERNODE_SPEECH_MIC_SMOKE:-0}" = "1" ]; then
  # Interactive TCC-approved session: prove the mic-capture helpers start
  # and survive a few seconds without crashing (124 = timeout cut them off,
  # which is the expected way to end a streaming helper).
  micstatus=0
  timeout 5 "$BIN/openwakeword-cli" --word "hey jarvis" --threshold 0.99 >/dev/null || micstatus=$?
  case "$micstatus" in
  0|124) ;;
  *)
    echo "FAIL: openwakeword-cli mic mode exited with $micstatus" >&2
    exit 1
    ;;
  esac
else
  echo "SKIP: microphone-dependent wake/STT starts not run; set INFERNODE_SPEECH_MIC_SMOKE=1 only in an interactive TCC-approved session"
fi

printf '\0%.0s' {1..6400} | timeout 45 "$BIN/openwakeword-cli" --stdin --word "hey lucia" --threshold 0.99 >"$WORKDIR/wake.out" || status=$?
status=${status:-0}
case "$status" in
0|124)
  ;;
*)
  echo "FAIL: openwakeword-cli --stdin exited with $status" >&2
  exit 1
  ;;
esac

echo "PASS: speech helper wrappers smoke-tested without microphone access"
