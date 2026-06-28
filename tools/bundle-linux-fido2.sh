#!/bin/sh
#
# bundle-linux-fido2.sh — make an emu binary self-contained for FIDO2 (#F /dev/2fa).
#
# Copies libfido2 and its non-baseline shared-library deps (libcbor, libcrypto)
# next to the emu binary and sets rpath $ORIGIN, so the release tarball runs
# YubiKey/FIDO2 2fa without the user having to `apt install libfido2`.
#
# Usage: bundle-linux-fido2.sh <emu-binary> <dest-dir>
#   <emu-binary>  the (staged) o.emu to inspect and rpath
#   <dest-dir>    directory the binary loads libs from (its own dir; rpath $ORIGIN)
#
# What is and isn't bundled:
#   bundled  — libfido2, libcbor, libcrypto (discovered via ldd; versioned
#              sonames preserved so the binary's NEEDED entries still resolve)
#   host     — libudev, libz, libcap, libc, ld-linux: baseline on every Linux
#              desktop/server. libudev in particular must match the host's udev
#              runtime, so bundling a copy would be more fragile than using the
#              host's — exactly the macOS split (bundle fido2/cbor/crypto, leave
#              the OS-integration libs to the platform).
#
# Mirrors the macOS @executable_path bundling in .github/workflows/release.yml,
# including the guard that fails the build if libfido2 was not linked in (the
# HAVE_FIDO2-off regression that would ship 2fa as a dead stub).

set -e

BIN="$1"
DEST="$2"

if [ -z "$BIN" ] || [ -z "$DEST" ]; then
	echo "usage: $0 <emu-binary> <dest-dir>" >&2
	exit 2
fi
if [ ! -f "$BIN" ]; then
	echo "$0: no such binary: $BIN" >&2
	exit 2
fi

# Guard: the binary must actually link libfido2. If it does not, the build was
# done without libfido2-dev (-DHAVE_FIDO2 unset) and 2fa would ship as a stub.
if ! ldd "$BIN" | grep -q 'libfido2'; then
	echo "ERROR: $BIN does not link libfido2 — FIDO2/2fa would ship as a dead stub" >&2
	echo "       install libfido2-dev before building so -DHAVE_FIDO2 is set" >&2
	exit 1
fi

mkdir -p "$DEST"

for pat in libfido2 libcbor libcrypto; do
	# ldd line: "<soname> => <path> (0x...)"; take the resolved path for the
	# soname whose name begins with <pat>.
	lib=$(ldd "$BIN" | awk -v p="$pat" '$1 ~ ("^" p "\\.") {print $3; exit}')
	if [ -z "$lib" ] || [ ! -f "$lib" ]; then
		echo "ERROR: could not resolve $pat from $BIN" >&2
		exit 1
	fi
	cp -L "$lib" "$DEST/$(basename "$lib")"
	echo "bundled $(basename "$lib")"
done

# Loader must find the bundled libs next to the binary at runtime.
#
# DT_RUNPATH (what patchelf sets) is searched only for an object's OWN direct
# NEEDED entries, not transitively. So $ORIGIN on the emu binary finds the
# bundled libfido2 (a direct NEEDED), but libfido2's own deps — the bundled
# libcbor and libcrypto — are found only if libfido2 itself carries $ORIGIN.
# Set it on both.
add_origin_rpath() {
	# $1 = ELF file to give an $ORIGIN runpath (idempotent).
	cur=$(patchelf --print-rpath "$1" 2>/dev/null || true)
	case ":$cur:" in
	*:'$ORIGIN':*) ;;	# already present
	*) patchelf --set-rpath "${cur:+$cur:}\$ORIGIN" "$1" ;;
	esac
}
if command -v patchelf >/dev/null 2>&1; then
	add_origin_rpath "$BIN"
	add_origin_rpath "$DEST/libfido2.so.1"
	echo "rpath($BIN): $(patchelf --print-rpath "$BIN")"
	echo "rpath(libfido2.so.1): $(patchelf --print-rpath "$DEST/libfido2.so.1")"
else
	echo "WARNING: patchelf not found — ensure $BIN and the bundled libfido2 have rpath \$ORIGIN" >&2
fi
