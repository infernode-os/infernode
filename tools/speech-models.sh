#!/bin/sh
#
# speech-models.sh -- fetch whisper.cpp's models for the emulator's own
# speech engine (#W, devspeech) into lib/speech/models, each checked
# against the SHA-256 pinned here; a model that does not match is not
# kept.  The engine names a model from that directory alone (its ctl's
# model m); ggml-base.en.bin is its default.
#
#	tools/speech-models.sh [name ...]	(default: ggml-base.en.bin)
#	tools/speech-models.sh -l		list what can be fetched
#
set -eu
ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
DIR="$ROOT/lib/speech/models"
URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main

# name size sha256 -- what each is: tiny.en is fast and rough (a phone),
# base.en the default
MODELS='
ggml-tiny.en.bin 77704715 921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f
ggml-base.en.bin 147964211 a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
'

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

if [ "${1:-}" = -l ]; then
	echo "$MODELS" | awk 'NF == 3 {printf "%s\t%d MB\n", $1, $2/1048576}'
	exit 0
fi
[ $# -gt 0 ] || set -- ggml-base.en.bin
mkdir -p "$DIR"
for name in "$@"; do
	line=$(echo "$MODELS" | awk -v n="$name" '$1 == n')
	[ -n "$line" ] || { echo "speech-models: no model $name (-l lists them)" >&2; exit 1; }
	want=$(echo "$line" | awk '{print $3}')
	if [ -f "$DIR/$name" ] && [ "$(sha "$DIR/$name")" = "$want" ]; then
		echo "$name: already here"
		continue
	fi
	tmp="$DIR/.$name.part"
	curl -fsSL -o "$tmp" "$URL/$name"
	got=$(sha "$tmp")
	if [ "$got" != "$want" ]; then
		rm -f "$tmp"
		echo "speech-models: $name: SHA-256 $got, not $want; not kept" >&2
		exit 1
	fi
	mv "$tmp" "$DIR/$name"
	echo "$name: fetched and checked"
done
