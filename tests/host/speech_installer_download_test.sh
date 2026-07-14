#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/infernode-speech-download.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/bin"
cat >"$WORKDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
  --output)
    out=$2
    shift 2
    ;;
  http://*|https://*)
    url=$1
    shift
    ;;
  *)
    shift
    ;;
  esac
done

printf '%s\n' "$url" >>"$FAKE_CURL_LOG"
case "$url" in
*primary-fails*) exit 22 ;;
*short*) printf 'bad' >"$out" ;;
*) dd if=/dev/zero of="$out" bs=128 count=1 2>/dev/null ;;
esac
SH
chmod +x "$WORKDIR/bin/curl"

export PATH="$WORKDIR/bin:$PATH"
export FAKE_CURL_LOG="$WORKDIR/curl.log"
export INFERNODE_SPEECH_HOME="$WORKDIR/install"
export WHISPER_MODEL_MIN_BYTES=100

# Sourcing exposes the installer helpers without running the installation.
source "$ROOT/tools/install-speech-helpers.sh"

model="$WORKDIR/models/ggml-base.en.bin"
: >"$FAKE_CURL_LOG"
download_model "$model" 100 \
  "https://example.invalid/primary-fails" \
  "https://example.invalid/fallback"
[ "$(wc -c <"$model")" -ge 100 ]
grep -q 'primary-fails' "$FAKE_CURL_LOG"
grep -q '/fallback' "$FAKE_CURL_LOG"

# A complete existing model is retained without touching the network.
before=$(cksum "$model")
: >"$FAKE_CURL_LOG"
download_model "$model" 100 "https://example.invalid/primary-fails"
[ "$before" = "$(cksum "$model")" ]
[ ! -s "$FAKE_CURL_LOG" ]

# A short response is rejected and the next candidate is tried atomically.
rm -f "$model"
: >"$FAKE_CURL_LOG"
download_model "$model" 100 \
  "https://example.invalid/short" \
  "https://example.invalid/fallback"
[ "$(wc -c <"$model")" -ge 100 ]
[ ! -e "$model.tmp" ]

echo "PASS: speech installer retries, validates, and atomically installs models"
