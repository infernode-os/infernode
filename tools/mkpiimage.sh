#!/bin/sh
#
# mkpiimage.sh -- the card image a Raspberry Pi owner flashes: the
# firmware, config.txt, the kernel and the whole userspace on one FAT32
# partition, laid out as docs/BAREMETAL.md, section 4, describes a card.
#
# Usage:
#     tools/mkpiimage.sh [--size MB] [--firmware DIR] [--manifest FILE] BOARD KERNEL OUT.img
#
#     BOARD      rpi3bplus (the kernel is bcm2837-kernel.img) or
#                rpi4b (bcm2711-kernel.img). One board per image: the
#                kernels differ, and so do the firmware and config.txt.
#     KERNEL     the kernel, as tests/host/baremetal_test.sh leaves it in
#                BAREMETAL_BUILD_DIR; it goes on the card as infernode8.img.
#     OUT.img    the image, uncompressed.
#     --size MB  the card's size (default 1024). What the userspace does
#                not use is the machine's writable usr/: the partition is
#                not grown to fill a bigger card.
#     --firmware DIR
#                take the boot firmware from DIR (by its upstream names)
#                instead of downloading it; it is checked against the
#                manifest either way.
#     --manifest FILE
#                the boot firmware's manifest (default
#                tools/pi-bootfw-manifest.txt); for tests.
#
# What goes on the card, and from where:
#   - the boot firmware this board needs, and LICENCE.broadcom, fetched
#     and checked by tools/pi-firmware.sh against the manifest;
#   - os/<soc>/card/: config.txt, tryboot.cmd and (Pi 4) tryboot.txt;
#   - os/bcm/card/README.txt, LICENSE and NOTICE;
#   - the kernel as infernode8.img;
#   - dis/, which must already be built (tools/verify-dis-build.sh);
#   - lib/, fonts/ and icons/: the files git tracks and nothing else, so
#     that a developer's own configuration (lib/ndb/llm, keys) cannot
#     reach an image built from their tree;
#   - an empty usr/.
# No skiplogon, wifi, netconsole or rootpath: a new card starts the
# login screen and offers nothing on the network. Not the radio's
# firmware either: its licence keeps it out of a release
# (tools/pi-firmware-manifest.txt).
#
# Needs sh, git, python3, and curl unless --firmware is given.
#
# Exit status: 0 done; 1 the image could not be made; 2 usage.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIZE=1024
FWFROM=
MANIFEST="$ROOT/tools/pi-bootfw-manifest.txt"

usage() {
	sed -n '/^# Usage:/,/^# What goes on the card/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d' >&2
	exit 2
}

die() {
	echo "mkpiimage: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case $1 in
	--size)
		[ $# -ge 2 ] || usage
		SIZE=$2; shift 2 ;;
	--firmware)
		[ $# -ge 2 ] || usage
		FWFROM=$2; shift 2 ;;
	--manifest)
		[ $# -ge 2 ] || usage
		MANIFEST=$2; shift 2 ;;
	-h|--help)
		usage ;;
	-*)
		echo "mkpiimage: unknown option $1" >&2
		usage ;;
	*)
		break ;;
	esac
done
[ $# -eq 3 ] || usage
BOARD=$1 KERNEL=$2 OUT=$3

case $SIZE in
''|*[!0-9]*) die "--size is not a number of MB: $SIZE" ;;
esac

# What each board's card holds that the other's does not.
case $BOARD in
rpi3bplus)
	SOC=bcm2837
	FIRMWARE="bootcode.bin start.elf fixup.dat"
	CARDFILES="config.txt tryboot.cmd" ;;
rpi4b)
	SOC=bcm2711
	FIRMWARE="start4.elf fixup4.dat bcm2711-rpi-4-b.dtb"
	CARDFILES="config.txt tryboot.txt tryboot.cmd" ;;
*)
	echo "mkpiimage: unknown board $BOARD (rpi3bplus or rpi4b)" >&2
	usage ;;
esac

[ -f "$KERNEL" ] || die "no kernel at $KERNEL"
for f in dis/sh.dis dis/lucifer.dis dis/wm/logon.dis; do
	[ -f "$ROOT/$f" ] || die "$f is not built; build dis/ first (CLAUDE.md, 'Dis Files')"
done
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
	|| die "$ROOT is not a git checkout: only files git tracks go on a card, and there is no telling which those are"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mkpiimage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM

# The firmware, checked against the manifest, into $STAGE/firmware.
# pi-firmware.sh refuses a set in which any file does not match.
if [ -n "$FWFROM" ]; then
	sh "$ROOT/tools/pi-firmware.sh" --manifest "$MANIFEST" --from "$FWFROM" "$STAGE" >"$STAGE/fw.log" 2>&1 \
		|| { cat "$STAGE/fw.log" >&2; die "the boot firmware did not check out"; }
else
	sh "$ROOT/tools/pi-firmware.sh" --manifest "$MANIFEST" "$STAGE" >"$STAGE/fw.log" 2>&1 \
		|| { cat "$STAGE/fw.log" >&2; die "the boot firmware did not check out"; }
fi

# lib/, fonts/ and icons/ as git has them.
mkdir -p "$STAGE/tree"
# (tar, not cp --parents: macOS's cp has no --parents.)
(cd "$ROOT" && git ls-files -z -- lib fonts icons | tar --null -T - -cf -) | tar -xf - -C "$STAGE/tree" \
	|| die "could not copy the tracked lib/, fonts/ and icons/"

set -- "/infernode8.img=$KERNEL" \
	"/README.txt=$ROOT/os/bcm/card/README.txt" \
	"/LICENSE=$ROOT/LICENSE" "/NOTICE=$ROOT/NOTICE" \
	"/LICENCE.broadcom=$STAGE/firmware/LICENCE.broadcom"
for f in $FIRMWARE; do
	set -- "$@" "/$f=$STAGE/firmware/$f"
done
for f in $CARDFILES; do
	[ -f "$ROOT/os/$SOC/card/$f" ] || die "no os/$SOC/card/$f"
	set -- "$@" "/$f=$ROOT/os/$SOC/card/$f"
done
set -- "$@" "/dis=$ROOT/dis" "/lib=$STAGE/tree/lib" "/fonts=$STAGE/tree/fonts" \
	"/icons=$STAGE/tree/icons" "/usr="

python3 "$ROOT/tools/mkcard.py" "$OUT" "$SIZE" "$@" || die "mkcard failed"
echo "mkpiimage: $OUT is a card for the $BOARD ($SOC)"
