#!/bin/sh
# dossrv long-name slot validation test (host-side, #673)
#
# FAT keeps a long name as slots N..1 in front of its 8.3 entry: slot N
# is marked 0x40, and every slot carries the checksum of the 8.3 name.
# dossrv used to take every long-name slot it passed, in any order and
# with any checksum, and prepend it to the name so far. The bench card
# showed what that does: a create that failed after putlongname() left
# orphan slots behind, the next file's name read as the orphans glued
# onto its own ("NotoSansCJKNotoSansCJK..."), and the file could only be
# reached by its 8.3 alias.
#
# A planted image puts four kinds of entry in the root, and each must
# read back right through all three readers -- readdir (ls), searchdir
# (cat by name) and rawstat (ls -l by name):
#
#   1. a good long name                    -> the long name
#   2. an orphan set, then a good set      -> the good set's name alone
#   3. a set whose checksum is not its     -> the 8.3 name
#      entry's
#   4. a set out of sequence (2, then 3)   -> the 8.3 name
#
# And a long name dossrv writes itself must still read back, so the
# checksum it writes and the one it now checks agree.
#
# Exit 77 = emu or python3 missing.

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 77
fi
for d in dossrv cat ls; do
    if [ ! -f "$ROOT/dis/$d.dis" ]; then
        echo "SKIP: $ROOT/dis/$d.dis not built"
        exit 77
    fi
done

echo "=== dossrv long-name slot test ==="

mkdir -p "$ROOT/tmp" 2>/dev/null || true
IMG="$ROOT/tmp/dossrv_lfn_test.img"
GIMG="/tmp/dossrv_lfn_test.img"
SCRIPT="$ROOT/tmp/dossrv_lfn_testscript.sh"
MNT="$ROOT/tmp/dossrv_lfn_mnt"
GMNT="/tmp/dossrv_lfn_mnt"
mkdir -p "$MNT"
OUT=$(mktemp /tmp/dossrv_lfn_test_out.XXXXXX)
trap 'rm -f "$IMG" "$SCRIPT" "$OUT"; rmdir "$MNT" 2>/dev/null' EXIT

# The same bare 64 MB FAT32 layout as dossrv_badent_test.sh.
python3 - "$IMG" <<'PYEOF'
import struct, sys

SEC, PSECS, SPC, RESV, NFAT, FATSZ = 512, 131072, 1, 32, 2, 1024
part = bytearray(PSECS * SEC)

bs = bytearray(SEC)
bs[0:3] = b"\xEB\x58\x90"
bs[3:11] = b"INFRNODE"
struct.pack_into("<H", bs, 11, SEC)
bs[13] = SPC
struct.pack_into("<H", bs, 14, RESV)
bs[16] = NFAT
bs[21] = 0xF8
struct.pack_into("<H", bs, 24, 32)
struct.pack_into("<H", bs, 26, 64)
struct.pack_into("<I", bs, 32, PSECS)
struct.pack_into("<I", bs, 36, FATSZ)
struct.pack_into("<I", bs, 44, 2)
struct.pack_into("<H", bs, 48, 1)
struct.pack_into("<H", bs, 50, 6)
bs[64] = 0x80
bs[66] = 0x29
struct.pack_into("<I", bs, 67, 0x32323232)
bs[71:82] = b"INFR32     "
bs[82:90] = b"FAT32   "
bs[510] = 0x55; bs[511] = 0xAA
part[0:SEC] = bs

files = [
    # (8.3 name, long-name slot sets in disk order, content)
    (b"GOODNA~1TXT", ["good"], b"one\n"),
    (b"NOTOSA~1OTF", ["orphan", "good"], b"two\n"),
    (b"BADSUM~1TXT", ["badsum"], b"three\n"),
    (b"BADSEQ~1TXT", ["badseq"], b"four\n"),
]
longnames = {
    b"GOODNA~1TXT": "GoodName.txt",
    b"NOTOSA~1OTF": "NotoSansCJK-Regular.otf",
    b"BADSUM~1TXT": "WrongOwner.txt",
    b"BADSEQ~1TXT": "OutOfSequence-Name.txt",
}

def sfnsum(n):
    s = 0
    for c in n:
        s = (((s & 1) << 7) | ((s & 0xFE) >> 1)) + c
        s &= 0xFF
    return s

def slots(name, csum):
    chars = [ord(c) for c in name]
    n = (len(chars) + 12) // 13
    if len(chars) % 13:
        chars += [0]
    chars += [0xFFFF] * (n * 13 - len(chars))
    out = []
    for i in range(n, 0, -1):
        s = bytearray(32)
        s[0] = i | (0x40 if i == n else 0)
        s[11] = 0x0F
        s[13] = csum
        seg = chars[(i - 1) * 13 : i * 13]
        for k, off in enumerate([1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]):
            struct.pack_into("<H", s, off, seg[k])
        out.append(bytes(s))
    return out

fat = bytearray(FATSZ * SEC)
struct.pack_into("<I", fat, 0, 0x0FFFFFF8)
struct.pack_into("<I", fat, 4, 0x0FFFFFFF)
struct.pack_into("<I", fat, 8, 0x0FFFFFFF)      # root
data = (RESV + NFAT * FATSZ) * SEC

ents = []
clus = 3
for short, sets, content in files:
    for kind in sets:
        if kind == "good":
            ents += slots(longnames[short], sfnsum(short))
        elif kind == "orphan":
            # what a failed create leaves: a complete set for a name whose
            # 8.3 entry was never written
            ents += slots("NotoSansCJK", sfnsum(b"NOTOSA~2OTF"))
        elif kind == "badsum":
            ents += slots(longnames[short], sfnsum(b"SOMEON~1TXT"))
        elif kind == "badseq":
            s = slots(longnames[short], sfnsum(short))
            bad = bytearray(s[1]); bad[0] = 3    # slot 1 renumbered 3
            ents += [s[0], bytes(bad)]
    d = bytearray(32)
    d[0:11] = short
    d[11] = 0x20
    struct.pack_into("<H", d, 26, clus)
    struct.pack_into("<I", d, 28, len(content))
    ents.append(bytes(d))
    struct.pack_into("<I", fat, 4 * clus, 0x0FFFFFFF)
    off = data + (clus - 2) * SPC * SEC
    part[off : off + len(content)] = content
    clus += 1

root = b"".join(ents)
assert len(root) <= SPC * SEC, len(root)
part[data : data + len(root)] = root
for i in range(NFAT):
    off = (RESV + i * FATSZ) * SEC
    part[off : off + len(fat)] = fat
open(sys.argv[1], "wb").write(part)
PYEOF

cat > "$SCRIPT" <<INFERNO
load std
dossrv -f $GIMG -m $GMNT
echo '--- ls'
ls $GMNT
echo '--- cat'
cat $GMNT/GoodName.txt
cat $GMNT/NotoSansCJK-Regular.otf
cat $GMNT/BADSUM~1.TXT
cat $GMNT/BADSEQ~1.TXT
echo '--- stat'
ls -l $GMNT/NotoSansCJK-Regular.otf
ls -l $GMNT/BADSUM~1.TXT
echo '--- written'
echo five > '$GMNT/A Long Name Written Here.text'
cat '$GMNT/A Long Name Written Here.text'
ls -l '$GMNT/A Long Name Written Here.text'
echo '=== SCRIPT DONE ==='
INFERNO

"$EMU" -r"$ROOT" -c0 sh /tmp/dossrv_lfn_testscript.sh > "$OUT" 2>&1 &
EMU_PID=$!
# dossrv keeps serving, so emu never self-exits: wait for the marker.
i=0
while [ $i -lt 60 ]; do
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

status=0
fail() {
    echo "FAIL: $1"
    status=1
}

grep -q '=== SCRIPT DONE ===' "$OUT" || fail "guest script did not finish"

LS="$(sed -n '/^--- ls$/,/^--- cat$/p' "$OUT")"
echo "$LS" | grep -q '/GoodName.txt$' || fail "a good long name is not listed"
echo "$LS" | grep -q '/NotoSansCJK-Regular.otf$' || fail "a good set behind orphan slots is not listed by its own name"
echo "$LS" | grep -qi '/badsum~1.txt$' || fail "a set with the wrong checksum is not listed by its 8.3 name"
echo "$LS" | grep -qi '/badseq~1.txt$' || fail "a set out of sequence is not listed by its 8.3 name"
grep -q 'NotoSansCJKNotoSansCJK' "$OUT" && fail "orphan slots were glued onto the next name"
grep -q 'WrongOwner' "$OUT" && fail "a long name whose checksum is another entry's was used"
grep -q 'OutOfSequence' "$OUT" && fail "a long name whose slots are out of sequence was used"

for w in one two three four five; do
    grep -qx "$w" "$OUT" || fail "content '$w' was not read back by name"
done
sed -n '/^--- stat$/,/^--- written$/p' "$OUT" | grep -q ' /tmp/dossrv_lfn_mnt/NotoSansCJK-Regular.otf$' \
    || fail "stat of a good set behind orphans does not name it"
sed -n '/^--- written$/,$p' "$OUT" | grep -q 'A Long Name Written Here.text$' \
    || fail "a long name dossrv wrote itself does not stat back"

if [ $status -ne 0 ]; then
    echo "--- guest output ---"
    cat "$OUT"
    exit 1
fi
echo "PASS: orphan, mis-summed and out-of-sequence long-name slots are not taken as a name"
exit 0
