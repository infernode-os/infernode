#!/bin/sh
#
# piimage_test.sh -- tools/mkpiimage.sh, the Raspberry Pi card images a
# release ships, read back by a FAT32 reader of this test's own (not
# mkcard's, whose writer it checks):
#
#	each board's card has its own firmware, config.txt and tryboot
#	files and not the other board's, and the files are the tree's;
#	the kernel is on it as infernode8.img, byte for byte;
#	dis/ is the built tree's; lib/, fonts/ and icons/ hold what git
#	tracks and nothing else (an untracked file in lib/ stays off);
#	usr/ is there and empty; no skiplogon, wifi, netconsole or rootpath;
#	firmware/ holds the radio's firmware under the names the driver
#	asks for, and the licence it is distributed under;
#	firmware that does not match its manifest is refused, and no image
#	is left behind;
#	fsck.fat, where there is one, finds nothing wrong.
#
# The firmware is stand-in bytes under manifests made here, and the
# kernel is random bytes: what is tested is the card, not the boot. The
# boot is tests/host/baremetal_test.sh's, and a board's.

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || exit 1

command -v python3 >/dev/null 2>&1 || { echo "piimage_test: SKIP (no python3)"; exit 77; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "piimage_test: SKIP (not a git checkout)"; exit 77; }
[ -f dis/lucifer.dis ] && [ -f dis/wm/logon.dis ] || { echo "piimage_test: SKIP (dis not built)"; exit 77; }

fail=0
pass() { echo "PASS: $1"; }
failed() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/piimage.XXXXXX")
untracked=lib/ndb/piimage-test-untracked
trap 'rm -rf "$tmp"; rm -f "$ROOT/$untracked"' EXIT INT TERM

# stand-in firmware and a manifest for it, in tools/pi-firmware.sh's format
commit=0123456789abcdef0123456789abcdef01234567
mkdir -p "$tmp/fw"
{
	echo "commit $commit"
	for f in bootcode.bin start.elf fixup.dat start4.elf fixup4.dat bcm2711-rpi-4-b.dtb LICENCE.broadcom; do
		echo "stand-in $f" > "$tmp/fw/$f"
		sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/fw/$f")
		echo "file $f $sha $(wc -c < "$tmp/fw/$f" | tr -d ' ') test https://example.invalid/$commit/boot/$f"
	done
} > "$tmp/manifest"
# the radio's, in tools/pi-firmware-manifest.txt's shape: upstream names
# that are not the names on the card
{
	echo "commit $commit"
	for f in brcmfmac43455-sdio.bin:cyfmac43455-sdio-standard.bin brcmfmac43455-sdio.clm_blob:cyfmac43455-sdio.clm_blob \
		brcmfmac43455-sdio.txt:brcmfmac43455-sdio.txt; do
		echo "stand-in radio ${f#*:}" > "$tmp/fw/${f#*:}"
		sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/fw/${f#*:}")
		echo "file ${f%%:*} $sha $(wc -c < "$tmp/fw/${f#*:}" | tr -d ' ') test https://example.invalid/$commit/${f#*:}"
	done
} > "$tmp/radiomanifest"
head -c 300000 /dev/urandom > "$tmp/kernel.img"
echo "a developer's own file" > "$ROOT/$untracked"

# The reader: the partition from the MBR, then the BPB, the FAT and the
# directories. Prints one line per file, "path size sha256", and one
# per directory, "path/".
cat > "$tmp/fatls.py" <<'EOF'
import hashlib, struct, sys
img = open(sys.argv[1], "rb").read()
assert img[510:512] == b"\x55\xaa", "no MBR signature"
ptype = img[446 + 4]
assert ptype in (0x0B, 0x0C), "partition 1 is not FAT32 (type %#x)" % ptype
pstart = struct.unpack_from("<I", img, 446 + 8)[0] * 512
bs = img[pstart:pstart + 512]
sec, spc, resv, nfat = struct.unpack_from("<HBHB", bs, 11)
fatsz, rootclus = struct.unpack_from("<I", bs, 36)[0], struct.unpack_from("<I", bs, 44)[0]
fat = img[pstart + resv * sec: pstart + (resv + fatsz) * sec]
data = pstart + (resv + nfat * fatsz) * sec
csize = spc * sec
def chain(c):
    out = []
    while 2 <= c < 0x0FFFFFF8:
        out.append(c)
        c = struct.unpack_from("<I", fat, 4 * c)[0] & 0x0FFFFFFF
    return out
def read(c, size=None):
    b = b"".join(img[data + (x - 2) * csize: data + (x - 1) * csize] for x in chain(c))
    return b if size is None else b[:size]
def walk(c, path):
    d = read(c)
    lfn = {}
    for o in range(0, len(d), 32):
        e = d[o:o + 32]
        if e[0] == 0:
            break
        if e[0] == 0xE5:
            lfn = {}; continue
        if e[11] == 0x0F:
            n = e[1:11] + e[14:26] + e[28:32]
            lfn[e[0] & 0x1F] = n
            continue
        short = e[0:11]
        if short in (b".          ", b"..         "):
            lfn = {}; continue
        if lfn:
            u = b"".join(lfn[k] for k in sorted(lfn)).decode("utf-16-le")
            name = u.split("\x00")[0]
        else:
            b, x = short[:8].decode().rstrip(), short[8:].decode().rstrip()
            name = b + ("." + x if x else "")
        lfn = {}
        clus = struct.unpack_from("<H", e, 20)[0] << 16 | struct.unpack_from("<H", e, 26)[0]
        size = struct.unpack_from("<I", e, 28)[0]
        p = path + name
        if e[11] & 0x10:
            print(p + "/")
            walk(clus, p + "/")
        else:
            print("%s %d %s" % (p, size, hashlib.sha256(read(clus, size) if size else b"").hexdigest()))
walk(rootclus, "/")
EOF

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# has <listing> <path> <host file>: the card has the file, with those bytes
has() {
	want=$(sha "$3")
	if grep -q "^$2 [0-9]* $want\$" "$1"; then return 0; fi
	echo "    $2: $(grep "^$2 " "$1" || echo absent) (want $want)"
	return 1
}

for board in rpi3bplus rpi4b; do
	case $board in
	rpi3bplus) soc=bcm2837; own="bootcode.bin start.elf fixup.dat"; other="start4.elf fixup4.dat bcm2711-rpi-4-b.dtb tryboot.txt" ;;
	rpi4b)     soc=bcm2711; own="start4.elf fixup4.dat bcm2711-rpi-4-b.dtb"; other="bootcode.bin start.elf fixup.dat" ;;
	esac
	img=$tmp/$board.img
	if sh tools/mkpiimage.sh --size 256 --firmware "$tmp/fw" --manifest "$tmp/manifest" \
		--radio-manifest "$tmp/radiomanifest" $board "$tmp/kernel.img" "$img" > "$tmp/$board.log" 2>&1; then
		pass "$board: mkpiimage builds a card"
	else
		failed "$board: mkpiimage failed: $(tail -3 "$tmp/$board.log" | tr '\n' ' ')"
		continue
	fi
	if ! python3 "$tmp/fatls.py" "$img" > "$tmp/$board.ls" 2> "$tmp/$board.err"; then
		failed "$board: the card does not read back: $(tail -1 "$tmp/$board.err")"
		continue
	fi
	L=$tmp/$board.ls

	ok=1
	for f in $own LICENCE.broadcom; do has "$L" "/$f" "$tmp/fw/$f" || ok=0; done
	[ $ok = 1 ] && pass "$board: its firmware and LICENCE.broadcom are on it" || failed "$board: its firmware"
	ok=1
	has "$L" /firmware/brcmfmac43455-sdio.bin "$tmp/fw/cyfmac43455-sdio-standard.bin" || ok=0
	has "$L" /firmware/brcmfmac43455-sdio.clm_blob "$tmp/fw/cyfmac43455-sdio.clm_blob" || ok=0
	has "$L" /firmware/brcmfmac43455-sdio.txt "$tmp/fw/brcmfmac43455-sdio.txt" || ok=0
	has "$L" /firmware/LICENCE.cypress os/bcm/card/LICENCE.cypress || ok=0
	[ "$(grep -c '^/firmware/.' "$L")" = 4 ] || { echo "    firmware/ holds $(grep -c '^/firmware/.' "$L") files, not 4"; ok=0; }
	[ $ok = 1 ] && pass "$board: firmware/ is the radio's firmware, by the driver's names, and LICENCE.cypress" \
		|| failed "$board: the radio's firmware"
	ok=1
	for f in $other skiplogon wifi netconsole rootpath cmdline.txt; do
		grep -q "^/$f\( \|$\)" "$L" && { echo "    /$f is on the card"; ok=0; }
	done
	[ $ok = 1 ] && pass "$board: nothing of the other board's, and no control file" || failed "$board: the card has what it should not"
	ok=1
	for f in os/$soc/card/*; do has "$L" "/$(basename "$f")" "$f" || ok=0; done
	has "$L" /README.txt os/bcm/card/README.txt || ok=0
	has "$L" /LICENSE LICENSE || ok=0
	has "$L" /NOTICE NOTICE || ok=0
	[ $ok = 1 ] && pass "$board: config.txt, the tryboot files, README.txt, LICENSE and NOTICE are the tree's" || failed "$board: the card's own files"
	has "$L" /infernode8.img "$tmp/kernel.img" && pass "$board: the kernel is infernode8.img, byte for byte" || failed "$board: the kernel"

	ok=1
	for f in dis/sh.dis dis/lucifer.dis dis/wm/logon.dis lib/lucifer/boot-baremetal.sh; do has "$L" "/$f" "$f" || ok=0; done
	[ $ok = 1 ] && pass "$board: dis/ and lib/ are the tree's" || failed "$board: dis/ or lib/"
	ndis=$(find dis -type f | wc -l | tr -d ' ')
	ncard=$(grep -c '^/dis/.* [0-9]* ' "$L")
	[ "$ndis" = "$ncard" ] && pass "$board: every file of dis/ ($ndis)" || failed "$board: dis/ has $ndis files and the card $ncard"
	ngit=$(git ls-files -- lib fonts icons | wc -l | tr -d ' ')
	ncard=$(grep -c '^/\(lib\|fonts\|icons\)/.* [0-9]* ' "$L")
	[ "$ngit" = "$ncard" ] && pass "$board: lib/, fonts/ and icons/ are git's $ngit files, no more" \
		|| failed "$board: git tracks $ngit files in lib/ fonts/ icons/ and the card has $ncard"
	grep -q "^/$untracked " "$L" && failed "$board: an untracked file in lib/ is on the card" \
		|| pass "$board: an untracked file in lib/ is not"
	if grep -q '^/usr/$' "$L" && ! grep -q '^/usr/.' "$L"; then
		pass "$board: usr/ is there and empty"
	else
		failed "$board: usr/ is missing or not empty"
	fi

	FSCK=$(command -v fsck.fat 2>/dev/null || ls /usr/sbin/fsck.fat /sbin/fsck.fat 2>/dev/null | head -1)
	if [ -n "$FSCK" ]; then
		dd if="$img" of="$tmp/part" bs=512 skip=2048 2>/dev/null
		if "$FSCK" -n "$tmp/part" > "$tmp/fsck.txt" 2>&1; then
			pass "$board: fsck.fat finds nothing wrong"
		else
			failed "$board: fsck.fat: $(tail -3 "$tmp/fsck.txt" | tr '\n' ' ')"
		fi
		rm -f "$tmp/part"
	else
		echo "SKIP: $board: no fsck.fat"
	fi
	rm -f "$img"
done

# firmware that is not what the manifest says: refused, nothing left
echo "not the firmware" > "$tmp/fw/start4.elf"
if sh tools/mkpiimage.sh --size 256 --firmware "$tmp/fw" --manifest "$tmp/manifest" \
	--radio-manifest "$tmp/radiomanifest" rpi4b "$tmp/kernel.img" "$tmp/bad.img" > "$tmp/bad.log" 2>&1; then
	failed "firmware that does not match its manifest was used"
elif [ -e "$tmp/bad.img" ]; then
	failed "a refused build left an image behind"
elif grep -q 'MISMATCH' "$tmp/bad.log"; then
	pass "firmware that does not match its manifest is refused, and no image is made"
else
	failed "the refusal does not say why: $(tail -2 "$tmp/bad.log" | tr '\n' ' ')"
fi

# docs/BAREMETAL.md shows these files whole, so a reader making a card by
# hand makes this one: the copies must not drift apart
cat > "$tmp/docblock.py" <<'EOF'
import re, sys
body = "\n".join(l for l in open(sys.argv[1]).read().strip().split("\n") if not l.startswith("#")).strip()
doc = open(sys.argv[2]).read()
blocks = ["\n".join(l[4:] for l in b.strip("\n").split("\n")) for b in re.findall(r"\n((?:    \S.*\n|\n)+)", doc)]
sys.exit(0 if any(b.strip() == body for b in blocks) else 1)
EOF
for f in os/bcm2837/card/config.txt os/bcm2711/card/config.txt os/bcm2711/card/tryboot.txt; do
	if python3 "$tmp/docblock.py" "$f" docs/BAREMETAL.md; then
		pass "docs/BAREMETAL.md shows $f as it is"
	else
		failed "docs/BAREMETAL.md has no block that is $f (without its comments)"
	fi
done

[ $fail = 0 ] || exit 1
exit 0
