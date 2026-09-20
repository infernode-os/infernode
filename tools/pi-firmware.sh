#!/bin/sh
#
# pi-firmware.sh — put the CYW43455 WiFi firmware on a Raspberry Pi 3B+ card.
#
# The bare-metal port's ether4330 driver uploads the radio's firmware
# from the card at boot: it asks for /n/dos/firmware/brcmfmac43455-sdio.bin
# (the dongle image), .txt (the board's NVRAM) and .clm_blob (the
# regulatory table).  Those files are Cypress's and are licensed for
# binary redistribution with Cypress parts only, so they are never
# committed to this tree and never appear in a release; they live on the
# card, and this tool is how they get there.
#
# Everything it fetches is pinned: the manifest names one commit of
# RPi-Distro/firmware-nonfree, one revision URL per file, and one SHA256
# per file (docs/DESIGN-PRINCIPLES.md, "The host boundary").  A file is
# installed only after its hash matched, and the copy on the card is
# hashed again after the write, because a FAT card is the one place a
# silently truncated file would go unnoticed until the kernel reports
# "firmware load failed".
#
# Usage:
#     tools/pi-firmware.sh [--from DIR] [--manifest FILE] CARDROOT
#     tools/pi-firmware.sh --verify [--manifest FILE] CARDROOT
#     tools/pi-firmware.sh --print [--manifest FILE]
#
#     CARDROOT   the mounted card's root (e.g. /Volumes/INFERNODE); the
#                files land in CARDROOT/firmware/ under the names the
#                driver looks for.
#     --from DIR take the three files from DIR (by their upstream
#                basenames) instead of downloading; for tests and for
#                cards prepared without a network.
#     --verify   hash the files already in CARDROOT/firmware against the
#                manifest; fetch nothing, write nothing.
#     --print    show what the manifest pins and exit.
#
# Needs only sh, curl (unless --from) and shasum or sha256sum.  Runs as
# whoever mounted the card; it never asks for sudo, and if the card is
# not writable by that user it says so and stops.
#
# Exit status: 0 done; 1 a hash did not match (nothing was installed);
# 2 usage or setup problem (no curl, unreadable manifest, download
# failure, unwritable destination).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/tools/pi-firmware-manifest.txt"
FROM=
MODE=install
DEST=

usage() {
	sed -n '/^# Usage:/,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d' >&2
	exit 2
}

die() {
	echo "pi-firmware: $*" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case $1 in
	--from)
		[ $# -ge 2 ] || usage
		FROM=$2; shift 2 ;;
	--manifest)
		[ $# -ge 2 ] || usage
		MANIFEST=$2; shift 2 ;;
	--verify)
		MODE=verify; shift ;;
	--print)
		MODE=print; shift ;;
	-h|--help)
		usage ;;
	-*)
		echo "pi-firmware: unknown option $1" >&2
		usage ;;
	*)
		[ -z "$DEST" ] || usage
		DEST=$1; shift ;;
	esac
done

[ "$MODE" = print ] || [ -n "$DEST" ] || usage
[ -r "$MANIFEST" ] || die "cannot read manifest $MANIFEST"

# shasum is what macOS ships; sha256sum is what coreutils ships.  The
# output of both is "<hex>  <name>", so one field split serves.
if command -v sha256sum >/dev/null 2>&1; then
	sha256of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
	sha256of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
	die "neither sha256sum nor shasum is on PATH; nothing can be verified"
fi

sizeof() {
	wc -c < "$1" | tr -d ' '
}

# The manifest is 'key value' text, one record per line, no quoting:
#     commit <sha1>
#     file <install-name> <sha256> <size> <licence> <url>
# Everything else is a comment.  The commit line is not just
# documentation: every file URL must contain it, so a manifest edited
# to point one file at a different revision fails here rather than
# installing a mismatched set.
COMMIT=$(sed -n 's/^commit  *\([^ ]*\).*$/\1/p' "$MANIFEST" | head -1)
[ -n "$COMMIT" ] || die "manifest $MANIFEST names no commit"
case $COMMIT in
*[!0-9a-f]*) die "manifest commit is not a hex SHA: $COMMIT" ;;
esac

FILES=$(grep '^file ' "$MANIFEST" || true)
[ -n "$FILES" ] || die "manifest $MANIFEST lists no files"

# Each record is validated before anything is fetched: five fields, a
# 64-hex SHA256, a decimal size, and an https URL that names the pinned
# commit.
echo "$FILES" | while read -r _ name sha size licence url; do
	if [ -z "$name" ] || [ -z "$sha" ] || [ -z "$size" ] || [ -z "$licence" ] || [ -z "$url" ]; then
		echo "pi-firmware: malformed file line in $MANIFEST: $name $sha $size $licence $url" >&2
		exit 2
	fi
	case $sha in
	????????????????????????????????????????????????????????????????) ;;
	*) echo "pi-firmware: $name: SHA256 in manifest is not 64 characters" >&2; exit 2 ;;
	esac
	case $sha in
	*[!0-9a-f]*) echo "pi-firmware: $name: SHA256 in manifest is not hex" >&2; exit 2 ;;
	esac
	case $size in
	''|*[!0-9]*) echo "pi-firmware: $name: size in manifest is not a number" >&2; exit 2 ;;
	esac
	case $url in
	*"$COMMIT"*) ;;
	*) echo "pi-firmware: $name: URL does not name the pinned commit $COMMIT" >&2; exit 2 ;;
	esac
	case $url in
	https://*) ;;
	*) echo "pi-firmware: $name: URL is not https: $url" >&2; exit 2 ;;
	esac
done || exit 2

if [ "$MODE" = print ]; then
	echo "manifest: $MANIFEST"
	echo "commit:   $COMMIT"
	echo "$FILES" | while read -r _ name sha size licence url; do
		echo "$name"
		echo "    from     $url"
		echo "    sha256   $sha"
		echo "    size     $size"
		echo "    licence  $licence"
	done
	exit 0
fi

FWDIR="$DEST/firmware"

# --verify: the card already has files; say whether they are the pinned
# ones.  Useful before a board test and after a card has been through
# another machine.
if [ "$MODE" = verify ]; then
	[ -d "$FWDIR" ] || die "$FWDIR does not exist"
	bad=0
	echo "$FILES" | {
		while read -r _ name sha size licence url; do
			f="$FWDIR/$name"
			if [ ! -f "$f" ]; then
				echo "MISSING  $f"
				bad=1
				continue
			fi
			got=$(sha256of "$f")
			if [ "$got" = "$sha" ]; then
				echo "ok       $f ($(sizeof "$f") bytes, $licence)"
			else
				echo "MISMATCH $f"
				echo "         expected $sha"
				echo "         got      $got"
				bad=1
			fi
		done
		exit $bad
	}
	exit $?
fi

# Install.  The destination is checked before any network traffic so a
# read-only or absent card fails in a second, not after a download.
[ -d "$DEST" ] || die "$DEST is not a directory (mount the card first)"
mkdir -p "$FWDIR" 2>/dev/null || die "cannot create $FWDIR (is the card mounted read-only, or owned by another user?)"
[ -w "$FWDIR" ] || die "$FWDIR is not writable by $(id -un); this tool does not use sudo"

if [ -n "$FROM" ]; then
	[ -d "$FROM" ] || die "--from $FROM is not a directory"
	SRC=$FROM
else
	command -v curl >/dev/null 2>&1 || die "curl is not on PATH (use --from DIR with files fetched elsewhere)"
	SRC=$(mktemp -d "${TMPDIR:-/tmp}/pi-firmware.XXXXXX") || die "mktemp failed"
	trap 'rm -rf "$SRC"' EXIT INT TERM
fi

echo "pi-firmware: manifest $MANIFEST"
echo "pi-firmware: RPi-Distro/firmware-nonfree at $COMMIT"

# Phase 1: obtain and verify every file.  Nothing is copied to the
# card until all three have matched, so a mismatch leaves the card as
# it was rather than with two new files and one old one.
echo "$FILES" | {
	rc=0
	while read -r _ name sha size licence url; do
		base=${url##*/}
		src="$SRC/$base"
		if [ -n "$FROM" ]; then
			if [ ! -f "$src" ]; then
				echo "pi-firmware: $src not found in --from directory" >&2
				rc=2
				break
			fi
			echo "pi-firmware: $name: from $src"
		else
			echo "pi-firmware: $name: fetching $url"
			# --proto =https refuses a redirect to plain http; the
			# manifest's URLs are https and the file must stay so.
			if ! curl -fsSL --proto '=https' --retry 3 --max-time 900 -o "$src" "$url"; then
				echo "pi-firmware: download failed: $url" >&2
				rc=2
				break
			fi
		fi
		got=$(sha256of "$src")
		if [ "$got" != "$sha" ]; then
			echo "pi-firmware: $name: SHA256 MISMATCH, refusing to install" >&2
			echo "    expected $sha" >&2
			echo "    got      $got" >&2
			echo "    size     $(sizeof "$src") (manifest says $size)" >&2
			rc=1
			break
		fi
		gotsize=$(sizeof "$src")
		if [ "$gotsize" != "$size" ]; then
			# Cannot happen with a matching SHA256; kept because a wrong
			# size line in the manifest should be noticed, not shipped.
			echo "pi-firmware: $name: size $gotsize does not match manifest $size" >&2
			rc=1
			break
		fi
		echo "pi-firmware: $name: sha256 ok ($gotsize bytes, $licence)"
	done
	exit $rc
} || exit $?

# Phase 2: copy to the card, then hash the copy.  cp then re-hash rather
# than trusting cp's status, because the failure this guards against --
# a card that accepted the write and stored something else -- reports
# success to cp.
echo "$FILES" | {
	rc=0
	while read -r _ name sha size licence url; do
		base=${url##*/}
		src="$SRC/$base"
		dst="$FWDIR/$name"
		if ! cp "$src" "$dst"; then
			echo "pi-firmware: copy to $dst failed" >&2
			rc=2
			break
		fi
		got=$(sha256of "$dst")
		if [ "$got" != "$sha" ]; then
			echo "pi-firmware: $dst does not hash correctly after the copy; the card may be faulty" >&2
			rm -f "$dst"
			rc=1
			break
		fi
		echo "pi-firmware: installed $dst"
	done
	exit $rc
} || exit $?

echo "pi-firmware: done; $(echo "$FILES" | wc -l | tr -d ' ') files under $FWDIR"
echo "pi-firmware: these files are Cypress binary-redistribution licensed; they belong on the card, not in the tree"
exit 0
