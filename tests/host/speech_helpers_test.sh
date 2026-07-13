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

# The native Whisper and openWakeWord backends can enumerate Core Audio in a
# different order. Prove the configured Whisper capture id reaches the native
# binary instead of silently falling back to a hard-coded device.
mkdir -p "$WORKDIR/bin"
cat >"$WORKDIR/bin/whisper-stream" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$WHISPER_ARG_LOG"
SH
chmod +x "$WORKDIR/bin/whisper-stream"
printf 'fake model\n' >"$WORKDIR/model.bin"
PATH="$WORKDIR/bin:$PATH" INFERNODE_SPEECH_CAPTURE=2 \
  INFERNODE_SPEECH_WINDOW_MS=5000 \
  WHISPER_ARG_LOG="$WORKDIR/whisper.args" \
  "$BIN/whisper-stream-cli" --model "$WORKDIR/model.bin" >/dev/null
if ! awk 'previous == "--capture" && $0 == "2" { found=1 } { previous=$0 } END { exit !found }' \
  "$WORKDIR/whisper.args"; then
  echo "FAIL: whisper-stream-cli did not forward INFERNODE_SPEECH_CAPTURE" >&2
  exit 1
fi
if ! awk 'previous == "--length" && $0 == "5000" { found=1 } { previous=$0 } END { exit !found }' \
  "$WORKDIR/whisper.args"; then
  echo "FAIL: whisper-stream-cli did not forward INFERNODE_SPEECH_WINDOW_MS" >&2
  exit 1
fi

timeout 10 "$BIN/whisper-stream-cli" --stdin >"$WORKDIR/whisper-stdin.out"
if ! grep -q '^error: whisper-stream stdin PCM mode is not supported' "$WORKDIR/whisper-stdin.out"; then
  echo "FAIL: whisper-stream-cli --stdin did not report the documented limitation" >&2
  exit 1
fi

# The wrapper must relay records in real time. A stdio filter in its pipeline
# (tr, sed, grep) block-buffers when writing to a pipe, so tiny transcript
# lines sit in the filter until the helper exits — which a streaming helper
# never does: wake works, listen never delivers, all logs stay empty. Fake a
# whisper-stream that speaks once (with VAD-mode chrome, a timestamp block,
# and a \r) then stays alive well past the deadline; the final must arrive
# while the producer is still running.
cat >"$WORKDIR/bin/whisper-stream" <<'SH'
#!/bin/sh
printf '### Transcription 0 START\n'
printf '[00:00.000 --> 00:02.000]   hello from fake whisper\r\n'
sleep 15
SH
chmod +x "$WORKDIR/bin/whisper-stream"
: >"$WORKDIR/stream.out"
PATH="$WORKDIR/bin:$PATH" "$BIN/whisper-stream-cli" --model "$WORKDIR/model.bin" >"$WORKDIR/stream.out" &
stream_pid=$!
relayed=0
deadline=$((SECONDS + 6))
while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -q '^final hello from fake whisper$' "$WORKDIR/stream.out"; then
    relayed=1
    break
  fi
  sleep 0.2
done
kill "$stream_pid" 2>/dev/null || true
wait "$stream_pid" 2>/dev/null || true
if [ "$relayed" -ne 1 ]; then
  echo "FAIL: whisper-stream-cli did not relay a record while the helper was still running (stdio buffering in the wrapper pipeline?)" >&2
  cat "$WORKDIR/stream.out" >&2
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
