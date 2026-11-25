#!/bin/sh
#
# fetch.sh -- put the pinned seL4 Microkit SDK in $ROOT/tmp/sel4 and print
# its directory.  The tarball is unpacked only after its SHA256 matched
# tools/sel4/manifest.txt; a cached copy is hashed again before use.
#
# Usage: tools/sel4/fetch.sh
# Exit status: 0 the SDK's directory printed; 1 a hash did not match;
# 2 setup problem (no curl, no sha256sum or shasum, download failed).

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/tools/sel4/manifest.txt"
DIR="$ROOT/tmp/sel4"

key() { sed -n "s/^$1 //p" "$MANIFEST"; }
VERSION="$(key version)"; URL="$(key url)"; SHA="$(key sha256)"
TARBALL="$DIR/$(basename "$URL")"
SDK="$DIR/sdk/microkit-sdk-$VERSION"

if command -v sha256sum >/dev/null 2>&1; then hash() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then hash() { shasum -a 256 "$1" | cut -d' ' -f1; }
else echo "fetch.sh: no sha256sum or shasum" >&2; exit 2; fi

mkdir -p "$DIR" || exit 2
if [ ! -f "$TARBALL" ]; then
	command -v curl >/dev/null 2>&1 || { echo "fetch.sh: no curl" >&2; exit 2; }
	curl -sfL -o "$TARBALL.part" "$URL" || { echo "fetch.sh: download failed: $URL" >&2; rm -f "$TARBALL.part"; exit 2; }
	mv "$TARBALL.part" "$TARBALL"
fi
GOT="$(hash "$TARBALL")"
if [ "$GOT" != "$SHA" ]; then
	echo "fetch.sh: $TARBALL: sha256 $GOT, manifest says $SHA" >&2
	exit 1
fi
if [ ! -f "$SDK/VERSION" ]; then
	rm -rf "$DIR/sdk" && mkdir -p "$DIR/sdk" && tar -xzf "$TARBALL" -C "$DIR/sdk" || exit 2
fi
echo "$SDK"
