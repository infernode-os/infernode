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

# Parakeet realtime STT (preferred over whisper when it can be built).
# PARAKEET_SRC may point at an existing parakeet.cpp checkout; otherwise the
# upstream repo is cloned under the install prefix. The streaming EOU model
# is not yet published as GGUF, so we also probe dev checkouts and accept an
# explicit PARAKEET_EOU_MODEL path (see find_parakeet_eou_model).
PARAKEET_DIR="$MODELS/parakeet"
PARAKEET_SRC=${PARAKEET_SRC:-"$PREFIX/src/parakeet.cpp"}
PARAKEET_REPO_URL=${PARAKEET_REPO_URL:-https://github.com/mudler/parakeet.cpp.git}
PARAKEET_EOU_MODEL=${PARAKEET_EOU_MODEL:-}
PARAKEET_EOU_URL=${PARAKEET_EOU_URL:-https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/parakeet_realtime_eou_120m-v1-q8_0.gguf}

# Set by install_parakeet on success; selects the ctl configuration.
PARAKEET_OK=0
PARAKEET_MODEL_PATH=""

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

# Locate (or fetch) the cache-aware streaming EOU GGUF. Echoes the path on
# stdout, or nothing when unavailable. The model is not yet in the published
# mudler/parakeet-cpp-gguf set, so the download is attempted last and is
# allowed to fail.
find_parakeet_eou_model() {
  if [ -n "$PARAKEET_EOU_MODEL" ] && [ -s "$PARAKEET_EOU_MODEL" ]; then
    echo "$PARAKEET_EOU_MODEL"
    return 0
  fi
  local m
  for m in "$PARAKEET_DIR"/parakeet_realtime_eou_120m*.gguf; do
    [ -s "$m" ] && { echo "$m"; return 0; }
  done
  # Dev convenience: copy a locally converted model out of a checkout.
  for m in "$PARAKEET_SRC"/models/parakeet_realtime_eou_120m*.gguf \
           "$HOME"/Projects/parakeet.cpp/models/parakeet_realtime_eou_120m*.gguf; do
    if [ -s "$m" ]; then
      mkdir -p "$PARAKEET_DIR"
      cp "$m" "$PARAKEET_DIR/"
      echo "$PARAKEET_DIR/$(basename "$m")"
      return 0
    fi
  done
  local dest="$PARAKEET_DIR/$(basename "$PARAKEET_EOU_URL")"
  if download_once "$PARAKEET_EOU_URL" "$dest" 2>/dev/null && [ -s "$dest" ]; then
    echo "$dest"
    return 0
  fi
  rm -f "$dest.tmp"
  return 0
}

# Build parakeet-stream: InferNode's realtime STT adapter (the tracked
# source tools/parakeet_stream.cpp) compiled against an upstream clone of
# parakeet.cpp. Native EOU turn-taking, faster and more accurate than the
# whisper base.en VAD wrapper. Soft-fails at every step — whisper remains
# the fallback stack.
install_parakeet() {
  local jobs=4
  if ! command -v cmake >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    log "skip: parakeet needs cmake + git (whisper stack remains the default)"
    return 0
  fi
  if [ ! -f "$PARAKEET_SRC/CMakeLists.txt" ]; then
    log "clone: $PARAKEET_REPO_URL"
    if ! git clone --depth 1 --recurse-submodules --shallow-submodules \
        "$PARAKEET_REPO_URL" "$PARAKEET_SRC"; then
      log "skip: parakeet clone failed (whisper stack remains the default)"
      return 0
    fi
  fi

  local build="$PARAKEET_SRC/build-infernode"
  local metal_flag=""
  if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
    metal_flag="-DPARAKEET_GGML_METAL=ON"
  fi
  if [ ! -f "$build/CMakeCache.txt" ]; then
    log "cmake: configuring parakeet.cpp"
    if ! cmake -B "$build" -S "$PARAKEET_SRC" -DPARAKEET_SHARED=ON \
        -DPARAKEET_BUILD_CLI=OFF -DGGML_NATIVE=OFF $metal_flag \
        -DCMAKE_BUILD_TYPE=Release >/dev/null; then
      log "skip: parakeet cmake configure failed"
      return 0
    fi
  fi
  log "build: libparakeet (~1 min)"
  if ! cmake --build "$build" -j "$jobs" >/dev/null; then
    log "skip: parakeet build failed"
    return 0
  fi

  local libdir="" f
  for f in "$build"/libparakeet.dylib "$build"/libparakeet.so \
           "$build"/src/libparakeet.dylib "$build"/src/libparakeet.so; do
    [ -e "$f" ] && { libdir=$(dirname "$f"); break; }
  done
  if [ -z "$libdir" ]; then
    log "skip: libparakeet not found under $build"
    return 0
  fi
  local ggmldir="$build/third_party/ggml/src"

  log "compile: parakeet-stream adapter"
  if ! c++ -std=c++17 -O2 "$SCRIPT_DIR/parakeet_stream.cpp" \
      -I"$PARAKEET_SRC/src" -I"$PARAKEET_SRC/include" \
      -I"$PARAKEET_SRC/third_party/ggml/include" \
      -L"$libdir" -L"$ggmldir" -lparakeet -lggml-base \
      -Wl,-rpath,"$libdir" -Wl,-rpath,"$ggmldir" \
      -o "$BIN/parakeet-stream"; then
    log "skip: parakeet-stream compile failed"
    return 0
  fi

  local model
  model=$(find_parakeet_eou_model)
  if [ -z "$model" ]; then
    log "notice: parakeet-stream built, but no streaming EOU model found."
    log "  Convert nvidia/parakeet_realtime_eou_120m-v1 with parakeet.cpp's"
    log "  scripts/convert_parakeet_to_gguf.py into $PARAKEET_DIR/,"
    log "  or set PARAKEET_EOU_MODEL=/path/to/model.gguf and re-run."
    log "  Falling back to the whisper stack until then."
    return 0
  fi

  # Smoke: model must load and the adapter must exit cleanly on EOF.
  log "smoke: parakeet-stream loads $model"
  if ! dd if=/dev/zero bs=32000 count=1 2>/dev/null | \
      "$BIN/parakeet-stream" --stdin --model "$model" --rate 16000 >/dev/null; then
    log "skip: parakeet-stream smoke test failed (whisper stack remains)"
    return 0
  fi

  PARAKEET_OK=1
  PARAKEET_MODEL_PATH="$model"
  log "ok: parakeet realtime STT installed"
}

# The boot-time speech configuration, one Inferno-sh command per line.
# lib/lucifer/boot.sh runs this file verbatim when it exists, making the
# installer the single source of truth for which helper stack is active.
write_speech_ctl() {
  local ctl="$PREFIX/speech.ctl.sh"
  {
    echo "# Written by tools/install-speech-helpers.sh — applied by boot.sh."
    echo "# Regenerate by re-running the installer; hand-edits survive until then."
    echo "echo 'engine kokoro' > /n/speech/ctl"
    echo "echo 'kokorobin $BIN/kokoro-cli' > /n/speech/ctl"
    echo "echo 'wakebin $BIN/openwakeword-cli' > /n/speech/ctl"
    echo "echo 'voice af_bella' > /n/speech/ctl"
    echo "echo 'wakeword hey jarvis' > /n/speech/ctl"
    echo "echo 'wakethreshold 0.5' > /n/speech/ctl"
    echo "echo 'duplex half' > /n/speech/ctl"
    if [ "$PARAKEET_OK" = 1 ]; then
      echo "echo 'whisperstreambin $BIN/parakeet-stream' > /n/speech/ctl"
      echo "echo 'whispermodel $PARAKEET_MODEL_PATH' > /n/speech/ctl"
      echo "echo 'micmode device' > /n/speech/ctl"
      echo "echo 'capturerate 16000' > /n/speech/ctl"
    else
      echo "echo 'whisperstreambin $BIN/whisper-stream-cli' > /n/speech/ctl"
      echo "echo 'whispermodel $WHISPER_MODEL' > /n/speech/ctl"
      echo "echo 'micmode helper' > /n/speech/ctl"
    fi
  } > "$ctl"
  log "wrote: $ctl"
}

print_ctl_block() {
  cat <<EOF

InferNode speech helper setup complete.

Boot configuration written to $PREFIX/speech.ctl.sh —
lib/lucifer/boot.sh applies it automatically on the next start. To apply it
to a running system, paste its contents into an Inferno shell (or run:
  sh /n/local$PREFIX/speech.ctl.sh ).

Active stack:
  TTS   Kokoro (af_bella) via kokoro-onnx
EOF
  if [ "$PARAKEET_OK" = 1 ]; then
    cat <<EOF
  STT   Parakeet realtime EOU ($(basename "$PARAKEET_MODEL_PATH")) — the model
        itself detects end-of-utterance; audio is captured by the speech
        shim and piped to the adapter (micmode device).
  Wake  openWakeWord ("hey jarvis")

If voice mode hears nothing (emu audio capture issue), fall back to the
whisper stack from inside Inferno:

echo 'whisperstreambin $BIN/whisper-stream-cli' > /n/speech/ctl
echo 'whispermodel $WHISPER_MODEL' > /n/speech/ctl
echo 'micmode helper' > /n/speech/ctl
EOF
  else
    cat <<EOF
  STT   whisper.cpp VAD wrapper ($(basename "$WHISPER_MODEL"))
  Wake  openWakeWord ("hey jarvis")

Parakeet realtime STT was not installed (see notices above) — it is faster
and more accurate; re-run this installer once its requirements are met.
EOF
  fi
  cat <<EOF

NOTE: the spoken wake phrase is "hey jarvis" — the only pretrained
openWakeWord model shipped today. Saying "hey lucia" will NOT trigger wake
until a custom hey-lucia model is trained and dropped into
$OPENWAKEWORD_DIR (the wrapper picks up an explicit --model path).
EOF
}

main() {
  if [ "$(uname -s)" != "Darwin" ]; then
    log "notice: this installer is macOS-first; continuing with portable Python setup"
  fi
  mkdir -p "$BIN" "$LIBEXEC" "$MODELS" "$KOKORO_DIR" "$OPENWAKEWORD_DIR" "$PARAKEET_DIR"
  install_whisper_cpp
  install_python_deps
  download_once "$KOKORO_MODEL_URL" "$KOKORO_DIR/kokoro-v1.0.onnx"
  download_once "$KOKORO_VOICES_URL" "$KOKORO_DIR/voices-v1.0.bin"
  # HuggingFace intermittently 403s this URL; whisper is only the STT
  # fallback, so a failed download must not abort the parakeet install.
  if ! download_once "$WHISPER_MODEL_URL" "$WHISPER_MODEL"; then
    rm -f "$WHISPER_MODEL.tmp"
    log "warn: whisper model download failed ($WHISPER_MODEL_URL) — whisper fallback unavailable until it is fetched manually"
  fi
  download_openwakeword_models
  write_wrappers
  install_parakeet
  write_speech_ctl
  print_ctl_block
}

main "$@"
