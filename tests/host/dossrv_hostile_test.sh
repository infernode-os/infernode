#!/bin/sh
# dossrv against cards that are not what a FAT is (host-side)
#
# A card is its maker's: its boot sector, its FAT and its directory
# entries say what they like, and dossrv is what reads the card a
# machine is handed. Each of these ended the server (a divide by zero,
# an index past a sector, its own panic) or left it reading for ever,
# and with it every file system it was serving and whatever it had not
# yet written:
#
#   - a boot sector with a sector size of 0 or 4096, or no sectors to a
#     cluster: now "unknown format";
#   - a volume said to be larger than its FAT maps, and a file whose
#     first cluster lies past the FAT: removed without the FAT being
#     indexed past its end;
#   - a file whose first cluster is 1 (the sector before the data: the
#     FAT or the root, read as the file's contents and written as
#     them), past the volume's last, or large enough to wrap: a file of
#     no clusters;
#   - a read at an offset past 2^31, which was a negative index into a
#     sector: the end of the file;
#   - a directory whose chain of clusters comes round to itself, all of
#     its entries deleted: listed, and not for ever.
#
# Then a card that is a FAT is still read. Exit 77 = emu or python3
# missing.

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 77
fi
for d in dossrv rm ls read cat; do
    if [ ! -f "$ROOT/dis/$d.dis" ]; then
        echo "SKIP: $ROOT/dis/$d.dis not built"
        exit 77
    fi
done

echo "=== dossrv hostile card test ==="

DIR="$ROOT/tmp/dossrv_hostile.$$"
GDIR="/tmp/dossrv_hostile.$$"
mkdir -p "$DIR"
OUT="$DIR/out"
trap 'rm -rf "$DIR"' EXIT

python3 - "$DIR" <<'PYEOF'
import struct, sys, os

SEC = 512
PSECS = 8192
RESV = 32
NFAT = 2
CONTENT = b"fat32 works in the hosted emu\n"

def image(sectsize=SEC, spc=1, fatsz=64, entries=(), fatset=(), rootfill=None, extra=()):
    part = bytearray(PSECS * SEC)
    bs = bytearray(SEC)
    bs[0:3] = b"\xEB\x58\x90"
    bs[3:11] = b"INFRNODE"
    struct.pack_into("<H", bs, 11, sectsize)
    bs[13] = spc
    struct.pack_into("<H", bs, 14, RESV)
    bs[16] = NFAT
    bs[21] = 0xF8
    struct.pack_into("<H", bs, 24, 32)
    struct.pack_into("<H", bs, 26, 64)
    struct.pack_into("<I", bs, 32, PSECS)
    struct.pack_into("<I", bs, 36, fatsz)
    struct.pack_into("<I", bs, 44, 2)
    struct.pack_into("<H", bs, 48, 1)
    struct.pack_into("<H", bs, 50, 6)
    bs[64] = 0x80
    bs[66] = 0x29
    bs[71:82] = b"INFR32     "
    bs[82:90] = b"FAT32   "
    bs[510] = 0x55; bs[511] = 0xAA
    part[0:SEC] = bs

    fat = bytearray(fatsz * SEC)
    def setfat(n, v):
        if 4*n + 4 <= len(fat):
            struct.pack_into("<I", fat, 4*n, v)
    setfat(0, 0x0FFFFFF8)
    setfat(1, 0x0FFFFFFF)
    setfat(2, 0x0FFFFFFF)
    setfat(3, 0x0FFFFFFF)
    for n, v in fatset:
        setfat(n, v)
    for i in range(NFAT):
        off = (RESV + i*fatsz) * SEC
        part[off:off+len(fat)] = fat

    data = (RESV + NFAT*fatsz) * SEC
    def dirent(name, clus, size, attr=0x20):
        d = bytearray(32)
        d[0:11] = name
        d[11] = attr
        struct.pack_into("<H", d, 20, (clus >> 16) & 0xFFFF)
        struct.pack_into("<H", d, 26, clus & 0xFFFF)
        struct.pack_into("<I", d, 28, size)
        return d
    o = data
    if rootfill is not None:
        part[o:o+SEC] = rootfill
    else:
        part[o:o+32] = dirent(b"HELLO32 TXT", 3, len(CONTENT))
        o += 32
        for name, clus, size, attr in entries:
            part[o:o+32] = dirent(name, clus, size, attr)
            o += 32
    part[data + SEC : data + SEC + len(CONTENT)] = CONTENT
    for clus, b in extra:
        off = data + (clus-2)*SEC
        part[off:off+len(b)] = b
    return part, dirent

out = sys.argv[1]
def write(name, part):
    open(os.path.join(out, name + ".img"), "wb").write(part)

# boot sectors that are none
write("sect0", image(sectsize=0)[0])
write("sect4096", image(sectsize=4096)[0])
write("clust0", image(spc=0)[0])

# a FAT of one sector (128 entries) for a volume of thousands of clusters
write("smallfat", image(fatsz=1, entries=[(b"FAR     TXT", 5000, 30, 0x20)])[0])

# first clusters that are no cluster
write("starts", image(entries=[
    (b"ONE     TXT", 1, 30, 0x20),
    (b"PAST    TXT", 9000, 30, 0x20),
    (b"WRAP    TXT", 0x7FFFFFF0, 30, 0x20),
])[0])

# the root: one cluster of deleted entries, linked to itself
deleted = bytearray()
_, dirent = image()
for i in range(16):
    d = dirent(b"\xe5ELETED TXT", 0, 0)
    deleted += d
write("rootloop", image(fatset=[(2, 2)], rootfill=bytes(deleted))[0])

# a directory the same
sub = bytearray()
sub += dirent(b".          ", 5, 0, 0x10)
sub += dirent(b"..         ", 0, 0, 0x10)
for i in range(14):
    sub += dirent(b"\xe5ELETED TXT", 0, 0)
write("dirloop", image(entries=[(b"LOOP       ", 5, 0, 0x10)], fatset=[(5, 5)], extra=[(5, bytes(sub))])[0])

# and a card that is one
write("good", image()[0])
PYEOF

for m in sect0 sect4096 clust0 smallfat starts rootloop dirloop good; do
    mkdir -p "$DIR/m_$m"
done

cat > "$DIR/script.sh" <<INFERNO
load std
D=$GDIR
echo '=== sect0'
dossrv -f \$D/sect0.img -m \$D/m_sect0
ls \$D/m_sect0
echo '=== sect4096'
dossrv -f \$D/sect4096.img -m \$D/m_sect4096
ls \$D/m_sect4096
echo '=== clust0'
dossrv -f \$D/clust0.img -m \$D/m_clust0
ls \$D/m_clust0
echo '=== smallfat'
dossrv -f \$D/smallfat.img -m \$D/m_smallfat
ls \$D/m_smallfat
cat \$D/m_smallfat/FAR.TXT > \$D/far.out
rm \$D/m_smallfat/FAR.TXT
ls \$D/m_smallfat > \$D/smallfat.ls
echo '=== starts'
dossrv -f \$D/starts.img -m \$D/m_starts
ls \$D/m_starts
cat \$D/m_starts/ONE.TXT > \$D/one.out
cat \$D/m_starts/PAST.TXT > \$D/past.out
cat \$D/m_starts/WRAP.TXT > \$D/wrap.out
echo over > \$D/m_starts/ONE.TXT
rm \$D/m_starts/PAST.TXT
rm \$D/m_starts/WRAP.TXT
cat \$D/m_starts/HELLO32.TXT > \$D/starts-hello.out
cat \$D/m_starts/ONE.TXT > \$D/one2.out
ls \$D/m_starts > \$D/starts.ls
echo '=== rootloop'
dossrv -f \$D/rootloop.img -m \$D/m_rootloop
ls \$D/m_rootloop > \$D/rootloop.ls
echo rootloop-listed
echo '=== dirloop'
dossrv -f \$D/dirloop.img -m \$D/m_dirloop
ls \$D/m_dirloop/LOOP > \$D/dirloop.ls
echo dirloop-listed
cat \$D/m_dirloop/HELLO32.TXT > \$D/dirloop-hello.out
echo '=== good'
dossrv -f \$D/good.img -m \$D/m_good
read -o 2147483653 10 < \$D/m_good/HELLO32.TXT > \$D/far-read.out
read -o 4294967301 10 < \$D/m_good/HELLO32.TXT > \$D/far-read2.out
cat \$D/m_good/HELLO32.TXT > \$D/good.out
echo more > \$D/m_good/NEW.TXT
cat \$D/m_good/NEW.TXT > \$D/new.out
echo '=== SCRIPT DONE ==='
INFERNO

"$EMU" -r"$ROOT" -c1 sh "$GDIR/script.sh" > "$OUT" 2>&1 &
EMU_PID=$!
i=0
while [ $i -lt 180 ]; do
    if grep -q '=== SCRIPT DONE ===' "$OUT" 2>/dev/null; then
        break
    fi
    if ! kill -0 $EMU_PID 2>/dev/null; then
        break
    fi
    sleep 1
    i=$((i + 1))
done
kill $EMU_PID 2>/dev/null
wait $EMU_PID 2>/dev/null

rc=0
bad() { echo "FAIL: $1"; rc=1; }
ok() { echo "PASS: $1"; }

if grep -q '=== SCRIPT DONE ===' "$OUT"; then
    ok "the session ran to its end"
else
    bad "the session did not finish (a directory read for ever, or a server gone): last section $(grep '^===' "$OUT" | tail -1)"
fi
if grep -qi 'panic\|Broken\|zero divide\|array bounds\|dereference of nil' "$OUT"; then
    bad "a server ended: $(grep -i 'panic\|Broken\|zero divide\|array bounds\|dereference of nil' "$OUT" | head -3 | tr '\n' ' ')"
else
    ok "no server ended on what a card said"
fi
for m in sect0 sect4096 clust0; do
    if awk "/^=== $m\$/{f=1;next} /^===/{f=0} f" "$OUT" | grep -q 'unknown format'; then
        ok "$m: a boot sector that is none is an unknown format"
    else
        bad "$m: not refused as an unknown format"
    fi
done
size() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo missing; fi; }
for f in far one past wrap; do
    if [ "$(size "$DIR/$f.out")" = 0 ]; then
        ok "$f: a file whose first cluster is none has no contents"
    else
        bad "$f: read $(size "$DIR/$f.out") bytes of a file whose first cluster is no cluster"
    fi
done
if [ -f "$DIR/smallfat.ls" ] && ! grep -qi 'far' "$DIR/smallfat.ls"; then
    ok "a file past the FAT's end is removed"
else
    bad "the file past the FAT's end was not removed"
fi
if [ -f "$DIR/starts.ls" ] && ! grep -qi 'past\|wrap' "$DIR/starts.ls" && grep -qi 'one' "$DIR/starts.ls"; then
    ok "files with first clusters that are none are removed, and one rewritten"
else
    bad "starts: $(cat "$DIR/starts.ls" 2>/dev/null | tr '\n' ' ')"
fi
if [ "$(cat "$DIR/one2.out" 2>/dev/null)" = over ] && grep -q 'fat32 works' "$DIR/starts-hello.out" 2>/dev/null; then
    ok "the rewritten file is what was written, and its neighbour untouched"
else
    bad "after rewriting the file whose first cluster was 1: '$(cat "$DIR/one2.out" 2>/dev/null)', neighbour '$(cat "$DIR/starts-hello.out" 2>/dev/null)'"
fi
if grep -q 'rootloop-listed' "$OUT" && grep -q 'dirloop-listed' "$OUT"; then
    ok "directories whose chains come round are listed, and the listing ends"
else
    bad "a directory whose chain comes round was read for ever"
fi
if [ "$(size "$DIR/far-read.out")" = 0 ] && [ "$(size "$DIR/far-read2.out")" = 0 ]; then
    ok "a read past 2^31, and past 2^32, is the end of the file"
else
    bad "reads far past the end gave $(size "$DIR/far-read.out") and $(size "$DIR/far-read2.out") bytes"
fi
if grep -q 'fat32 works in the hosted emu' "$DIR/good.out" 2>/dev/null && [ "$(cat "$DIR/new.out" 2>/dev/null)" = more ]; then
    ok "a card that is a FAT is read and written"
else
    bad "the good card: '$(cat "$DIR/good.out" 2>/dev/null)' '$(cat "$DIR/new.out" 2>/dev/null)'"
fi
if [ $rc -ne 0 ]; then
    echo "--- session ---"
    tail -40 "$OUT"
fi
exit $rc
