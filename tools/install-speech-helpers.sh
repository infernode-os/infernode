#!/usr/bin/env bash
set -euo pipefail

PREFIX=${INFERNODE_SPEECH_HOME:-"$HOME/.local/share/infernode-speech"}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VENV="$PREFIX/venv"
BIN="$PREFIX/bin"
LIBEXEC="$PREFIX/libexec"
MODELS="$PREFIX/models"
KOKORO_DIR="$MODELS/kokoro"
OPENWAKEWORD_DIR="$MODELS/openwakeword"
WHISPER_MODEL="$MODELS/ggml-base.en.bin"

KOKORO_ONNX_VERSION=${KOKORO_ONNX_VERSION:-0.4.7}
OPENWAKEWORD_VERSION=${OPENWAKEWORD_VERSION:-0.6.0}
KOKORO_MODEL_URL=${KOKORO_MODEL_URL:-https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx}
KOKORO_VOICES_URL=${KOKORO_VOICES_URL:-https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin}
WHISPER_MODEL_URL=${WHISPER_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin}

log() {
  printf '%s\n' "$*"
}

download_once() {
  local url=$1
  local dest=$2

  if [ -s "$dest" ]; then
    log "exists: $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "download: $url"
  curl -L --fail --retry 3 --output "$dest.tmp" "$url"
  mv "$dest.tmp" "$dest"
}

install_whisper_cpp() {
  if ! command -v brew >/dev/null 2>&1; then
    log "skip: Homebrew not found; install whisper-cpp separately if needed"
    return 0
  fi
  if brew list --formula whisper-cpp >/dev/null 2>&1; then
    log "exists: Homebrew whisper-cpp"
    return 0
  fi
  log "install: brew install whisper-cpp"
  brew install whisper-cpp
}

install_python_deps() {
  if [ ! -x "$VENV/bin/python" ]; then
    log "create: $VENV"
    python3 -m venv "$VENV"
  fi
  "$VENV/bin/python" -m pip install --upgrade pip
  "$VENV/bin/python" -m pip install \
    "kokoro-onnx==$KOKORO_ONNX_VERSION" \
    "openwakeword==$OPENWAKEWORD_VERSION" \
    "soundfile>=0.13,<0.14" \
    "sounddevice>=0.5,<0.6" \
    "numpy>=2,<3"
}

download_openwakeword_models() {
  mkdir -p "$OPENWAKEWORD_DIR"
  INFERNODE_OPENWAKEWORD_DIR="$OPENWAKEWORD_DIR" "$VENV/bin/python" <<'PY'
import os
import pathlib
import shutil

target = pathlib.Path(os.environ["INFERNODE_OPENWAKEWORD_DIR"])
target.mkdir(parents=True, exist_ok=True)

try:
    import openwakeword
    import openwakeword.utils

    openwakeword.utils.download_models()
    src = pathlib.Path(openwakeword.__file__).resolve().parent / "resources" / "models"
    copied = []
    for path in src.glob("*jarvis*"):
        if path.is_file():
            out = target / path.name
            shutil.copy2(path, out)
            copied.append(str(out))
    if copied:
        print("copied: " + ", ".join(copied))
    else:
        print("notice: openWakeWord downloaded models, but no jarvis model was found to copy")
except Exception as exc:
    print("notice: openWakeWord model download skipped: %s" % exc)
PY
}

write_wrappers() {
  mkdir -p "$BIN" "$LIBEXEC"

  cat >"$BIN/kokoro-cli" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PREFIX=${INFERNODE_SPEECH_HOME:-"$HOME/.local/share/infernode-speech"}
exec "$PREFIX/venv/bin/python" "$PREFIX/libexec/kokoro_cli.py" "$@"
SH

  cat >"$LIBEXEC/kokoro_cli.py" <<'PY'
#!/usr/bin/env python3
import argparse
import os
import struct
import sys

import numpy as np

DEFAULT_VOICES = [
    "af_bella", "af_sarah", "am_adam", "am_michael",
    "bf_emma", "bf_isabella", "bm_george", "bm_lewis",
]


def resample(samples, src_rate, dst_rate):
    if src_rate == dst_rate or len(samples) == 0:
        return samples
    duration = len(samples) / float(src_rate)
    out_len = max(1, int(duration * dst_rate))
    x_old = np.linspace(0.0, duration, num=len(samples), endpoint=False)
    x_new = np.linspace(0.0, duration, num=out_len, endpoint=False)
    return np.interp(x_new, x_old, samples).astype(np.float32)


def main():
    parser = argparse.ArgumentParser(description="InferNode Kokoro stdout-PCM wrapper")
    parser.add_argument("--voice", default="af_bella")
    parser.add_argument("--format", choices=["pcm"], default="pcm")
    parser.add_argument("--rate", type=int, default=24000)
    parser.add_argument("--list-voices", action="store_true")
    args = parser.parse_args()

    if args.list_voices:
        print("\n".join(DEFAULT_VOICES))
        return 0

    text = sys.stdin.read().strip()
    if not text:
        return 0

    prefix = os.environ.get(
        "INFERNODE_SPEECH_HOME",
        os.path.expanduser("~/.local/share/infernode-speech"),
    )
    model = os.path.join(prefix, "models", "kokoro", "kokoro-v1.0.onnx")
    voices = os.path.join(prefix, "models", "kokoro", "voices-v1.0.bin")

    from kokoro_onnx import Kokoro

    kokoro = Kokoro(model, voices)
    samples, sample_rate = kokoro.create(text, voice=args.voice, speed=1.0, lang="en-us")
    samples = np.asarray(samples, dtype=np.float32)
    samples = resample(samples, int(sample_rate), args.rate)
    samples = np.clip(samples, -1.0, 1.0)
    pcm = (samples * 32767.0).astype("<i2")
    sys.stdout.buffer.write(pcm.tobytes())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

  cat >"$BIN/whisper-stream-cli" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PREFIX=${INFERNODE_SPEECH_HOME:-"$HOME/.local/share/infernode-speech"}
exec "$PREFIX/libexec/whisper_stream_cli.sh" "$@"
SH

  cat >"$LIBEXEC/whisper_stream_cli.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: whisper-stream-cli [--model PATH] [--rate HZ] [--chans N] [--capture ID] [--length MS] [--stdin]

Wrap whisper.cpp's whisper-stream helper in VAD mode (--step 0): each
utterance is transcribed after you stop speaking and emitted as one record:
  final <text>

VAD mode is what makes a voice turn complete — sliding-window step mode
only ever yields interim hypotheses, which the voice-mode daemon treats
as partials and never injects.

The --stdin mode reads s16le PCM and uses the repo-owned energy-VAD adapter
around whisper-cli. Records include the aggregate token confidence:
  partial confidence=0.8123 <text>
  final confidence=0.9234 <text>
EOF
}

model=""
rate=16000
chans=1
capture=${INFERNODE_SPEECH_CAPTURE:--1}
length=${INFERNODE_SPEECH_WINDOW_MS:-5000}
stdin_mode=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  --model)
    model=${2:-}
    shift 2
    ;;
  --rate)
    rate=${2:-16000}
    shift 2
    ;;
  --chans)
    chans=${2:-1}
    shift 2
    ;;
  --capture)
    capture=${2:--1}
    shift 2
    ;;
  --length)
    length=${2:-5000}
    shift 2
    ;;
  --stdin)
    stdin_mode=1
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "error: unknown argument: $1"
    exit 2
    ;;
  esac
done

if [ -z "$model" ]; then
  model=${INFERNODE_SPEECH_HOME:-"$HOME/.local/share/infernode-speech"}/models/ggml-base.en.bin
fi

if [ "$stdin_mode" -eq 1 ]; then
  PREFIX=${INFERNODE_SPEECH_HOME:-"$HOME/.local/share/infernode-speech"}
  exec "$PREFIX/venv/bin/python" "$PREFIX/libexec/whisper_stdin_cli.py" \
    --stdin --model "$model" --rate "$rate" --chans "$chans" --length "$length"
fi

find_whisper_stream() {
  if command -v whisper-stream >/dev/null 2>&1; then
    command -v whisper-stream
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    local prefix
    prefix=$(brew --prefix whisper-cpp 2>/dev/null || true)
    if [ -n "$prefix" ] && [ -x "$prefix/bin/whisper-stream" ]; then
      printf '%s\n' "$prefix/bin/whisper-stream"
      return 0
    fi
  fi
  return 1
}

bin=$(find_whisper_stream || true)
if [ -z "$bin" ]; then
  echo "error: whisper-stream binary not found; install Homebrew whisper-cpp"
  exit 0
fi
if [ ! -s "$model" ]; then
  echo "error: whisper model not found: $model"
  exit 0
fi

# VAD mode: whisper-stream waits for end-of-utterance, then prints the
# transcribed segment. Filter its chrome — "### Transcription" separators,
# ANSI escapes, [timestamp] blocks — and emit each utterance as a final.
#
# No stdio filter (tr, sed, grep) may sit in this pipeline: writing to a
# pipe they block-buffer, and transcript lines are tiny, so records would
# sit in the filter's buffer until the helper exits — which it never does.
# \r is stripped per line in bash instead. stderr is not discarded: the
# shim keeps a bounded tail of it, the only diagnostic when whisper dies.
esc=$(printf '\033')
"$bin" --model "$model" --capture "$capture" --step 0 --length "$length" --keep 200 --vad-thold 0.6 |
while IFS= read -r line; do
  line=${line//$'\r'/}
  case "$line" in
  '#'*) continue ;;
  esac
  text=$(printf '%s' "$line" | sed -E "s/${esc}\[[0-9;]*[A-Za-z]//g; s/\[[^]]*\]//g; s/^[[:space:]]+//; s/[[:space:]]+\$//")
  [ -n "$text" ] || continue
  echo "final $text"
done
SH

  cat >"$BIN/openwakeword-cli" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PREFIX=${INFERNODE_SPEECH_HOME:-"$HOME/.local/share/infernode-speech"}
exec "$PREFIX/venv/bin/python" "$PREFIX/libexec/openwakeword_cli.py" "$@"
SH

  cat >"$LIBEXEC/openwakeword_cli.py" <<'PY'
#!/usr/bin/env python3
import argparse
import os
import signal
import sys
import time

import numpy as np


def parse_args():
    parser = argparse.ArgumentParser(description="InferNode openWakeWord wrapper")
    parser.add_argument("--word", default="hey jarvis")
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--stdin", action="store_true", help="read 16 kHz s16le mono PCM from stdin")
    parser.add_argument("--model", default="", help="explicit model file or openWakeWord model name")
    parser.add_argument("--rate", type=int, default=16000)
    return parser.parse_args()


def model_for(word, explicit):
    if explicit:
        return explicit
    prefix = os.environ.get(
        "INFERNODE_SPEECH_HOME",
        os.path.expanduser("~/.local/share/infernode-speech"),
    )
    candidates = [
        os.path.join(prefix, "models", "openwakeword", "hey_jarvis_v0.1.onnx"),
        os.path.join(prefix, "models", "openwakeword", "hey_jarvis_v0.1.tflite"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    normalized = word.lower().replace("_", " ").strip()
    if normalized in ("hey lucia", "lucia"):
        return "hey jarvis"
    return normalized or "hey jarvis"


def load_model(selected):
    from openwakeword.model import Model

    framework = "onnx" if selected.endswith(".onnx") else "tflite"
    return Model(wakeword_models=[selected], inference_framework=framework)


def handle_frame(model, frame, threshold):
    scores = model.predict(frame)
    best_name = ""
    best_score = 0.0
    for name, score in scores.items():
        value = float(score)
        if value > best_score:
            best_name = name
            best_score = value
    if best_score >= threshold:
        print("wake %s %.4f" % (best_name or "wake", best_score), flush=True)


def run_stdin(args, model):
    chunk_bytes = 1280 * 2
    while True:
        data = sys.stdin.buffer.read(chunk_bytes)
        if not data:
            # stdin EOF: the capture pump closed our stdin (device gone,
            # config change). Exit so the shim's restart logic owns recovery.
            return 0
        usable = len(data) - (len(data) % 2)
        if usable <= 0:
            continue
        frame = np.frombuffer(data[:usable], dtype=np.int16)
        handle_frame(model, frame, args.threshold)


def run_microphone(args, model):
    try:
        import sounddevice as sd
    except Exception:
        print("error: microphone capture requires sounddevice; use micmode device with --stdin", flush=True)
        return 0

    with sd.RawInputStream(samplerate=args.rate, channels=1, dtype="int16", blocksize=1280) as stream:
        while True:
            data, _overflowed = stream.read(1280)
            frame = np.frombuffer(data, dtype=np.int16)
            handle_frame(model, frame, args.threshold)


def main():
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(0))
    args = parse_args()
    selected = model_for(args.word, args.model)
    model = load_model(selected)
    if args.stdin:
        return run_stdin(args, model)
    return run_microphone(args, model)


if __name__ == "__main__":
    raise SystemExit(main())
PY

  install -m 755 "$SCRIPT_DIR/whisper_stdin_cli.py" "$LIBEXEC/whisper_stdin_cli.py"

  chmod +x "$BIN/kokoro-cli" "$BIN/whisper-stream-cli" "$BIN/openwakeword-cli"
  chmod +x "$LIBEXEC/kokoro_cli.py" "$LIBEXEC/whisper_stream_cli.sh" "$LIBEXEC/openwakeword_cli.py"
}

print_ctl_block() {
  cat <<EOF

InferNode speech helper setup complete.

Paste this block into an Inferno shell after /n/speech is mounted:

echo 'kokorobin $BIN/kokoro-cli' > /n/speech/ctl
echo 'whisperstreambin $BIN/whisper-stream-cli' > /n/speech/ctl
echo 'wakebin $BIN/openwakeword-cli' > /n/speech/ctl
echo 'whispermodel $WHISPER_MODEL' > /n/speech/ctl
echo 'voice af_bella' > /n/speech/ctl
echo 'wakeword hey jarvis' > /n/speech/ctl
echo 'wakethreshold 0.5' > /n/speech/ctl
echo 'duplex half' > /n/speech/ctl

NOTE: the spoken wake phrase is "hey jarvis" — the only pretrained
openWakeWord model shipped today. Saying "hey lucia" will NOT trigger wake
until a custom hey-lucia model is trained and dropped into
$OPENWAKEWORD_DIR (the wrapper picks up an explicit --model path).

For micmode device / stdin-PCM routing, the shim adds the stdin and format
arguments to the configured helpers:

echo 'micmode device' > /n/speech/ctl
EOF
}

main() {
  if [ "$(uname -s)" != "Darwin" ]; then
    log "notice: this installer is macOS-first; continuing with portable Python setup"
  fi
  mkdir -p "$BIN" "$LIBEXEC" "$MODELS" "$KOKORO_DIR" "$OPENWAKEWORD_DIR"
  install_whisper_cpp
  install_python_deps
  download_once "$KOKORO_MODEL_URL" "$KOKORO_DIR/kokoro-v1.0.onnx"
  download_once "$KOKORO_VOICES_URL" "$KOKORO_DIR/voices-v1.0.bin"
  download_once "$WHISPER_MODEL_URL" "$WHISPER_MODEL"
  download_openwakeword_models
  write_wrappers
  print_ctl_block
}

main "$@"
