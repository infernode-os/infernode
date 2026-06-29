#!/bin/sh
#
# refresh.sh — fetch the latest Yubico libfido2 Windows release into
# third-party/libfido2/win-amd64/. Verifies the upstream signature against
# Yubico's release PGP key before overwriting staged binaries.
#
# Usage:  ./third-party/libfido2/refresh.sh [VERSION]
#         (defaults to the version pinned below)
#
set -eu

VERSION="${1:-1.17.0}"
ZIP="libfido2-${VERSION}-win.zip"
BASE="https://developers.yubico.com/libfido2/Releases"

ROOT="$(cd "$(dirname "$0")" && pwd)"
DL="$ROOT/_download"
STAGE="$ROOT/win-amd64"

mkdir -p "$DL"
cd "$DL"

echo "==> downloading $ZIP"
curl -sSLfO "$BASE/$ZIP"
curl -sSLfO "$BASE/$ZIP.sig"

# Signature verification: Yubico signs with their release key
# (https://developers.yubico.com/Software_Projects/Software_Signing.html).
# Skipped silently when gpg is unavailable, but printed loudly so a
# refresh isn't quietly trustless on CI.
if command -v gpg >/dev/null 2>&1; then
    echo "==> verifying signature"
    if ! gpg --verify "$ZIP.sig" "$ZIP" 2>&1 | tee /tmp/libfido2-sigcheck.log; then
        echo "ERROR: signature verification failed"
        echo "       fetch Yubico's release key first:"
        echo "       gpg --keyserver keys.openpgp.org --recv-keys 0xBCA00FD4B2168C0A"
        exit 1
    fi
else
    echo "WARNING: gpg not installed — skipping signature check"
fi

echo "==> extracting Win64/v143/dynamic + headers into $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib"

# Extract just the bits we need: x64 v143 dynamic DLLs + import libs, and
# the full include tree. The ARM/ARM64/Win32/static variants and PDBs stay
# in the source zip (kept in _download/ — gitignored).
unzip -q -o "$ZIP" \
    "libfido2-${VERSION}-win/Win64/Release/v143/dynamic/*.dll" \
    "libfido2-${VERSION}-win/Win64/Release/v143/dynamic/*.lib" \
    "libfido2-${VERSION}-win/include/*"

mv "libfido2-${VERSION}-win/Win64/Release/v143/dynamic/"*.dll "$STAGE/bin/"
mv "libfido2-${VERSION}-win/Win64/Release/v143/dynamic/"*.lib "$STAGE/lib/"
mv "libfido2-${VERSION}-win/include" "$STAGE/include"
rm -rf "libfido2-${VERSION}-win"

# Re-stamp the LICENSE shipped alongside the binaries (Yubico's zip
# doesn't include LICENSE; pull from main branch).
echo "==> updating LICENSE-libfido2"
if command -v curl >/dev/null 2>&1; then
    curl -sSLfo "$STAGE/LICENSE-libfido2" \
        https://raw.githubusercontent.com/Yubico/libfido2/main/LICENSE || \
        echo "WARNING: could not refresh LICENSE-libfido2; keeping previous copy"
fi

echo "==> done. Review the binary churn:"
echo "    git status third-party/libfido2/win-amd64/"
