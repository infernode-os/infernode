#!/bin/sh
# dossrv "badent" alias test (host-side)
#
# dossrv names a directory entry it cannot present -- an empty name, a
# slash, a control character -- badent-<location>, and rm on that alias
# zaps the entry alone, deliberately leaving its clusters for an offline
# fsck (a damaged entry's start-cluster word is not to be trusted).
# rremove used to decide "damaged" by prefix-matching the name it HANDS
# OUT, so a healthy file that happened to be called badent-1 -- a legal
# 8.3 name -- was removed by the same path and its clusters were lost.
#
# Two things are asserted on the FAT32 image the guest writes, the way
# fsck would, from the host:
#
#   1. A healthy file named badent-1, created and removed through
#      dossrv, leaves NO allocated cluster unreachable from the root.
#      (The old dossrv leaves exactly one.)
#   2. A genuinely damaged entry -- a name with a control character in
#      it, planted in the image -- is still removed by its alias, with
#      its cluster deliberately left: the fix must not have made the
#      damage path go through the ordinary remove.
#
# The same fixture runs under QEMU in baremetal_test.sh, which no CI
# workflow runs; this is the hosted copy so the fix cannot regress
# silently. Exit 77 = emu or python3 missing.

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU"
    exit 77
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 77
fi
for d in dossrv rm ls; do
    if [ ! -f "$ROOT/dis/$d.dis" ]; then
        echo "SKIP: $ROOT/dis/$d.dis not built"
        exit 77
    fi
done

echo "=== dossrv badent alias test ==="

# The image lives under $ROOT/tmp so the guest sees it as /tmp/...
mkdir -p "$ROOT/tmp" 2>/dev/null || true
IMG="$ROOT/tmp/dossrv_badent_test.img"
GIMG="/tmp/dossrv_badent_test.img"
SCRIPT="$ROOT/tmp/dossrv_badent_testscript.sh"
# mount(2) will not create its target, and a checkout has no /n/dos.
MNT="$ROOT/tmp/dossrv_badent_mnt"
GMNT="/tmp/dossrv_badent_mnt"
mkdir -p "$MNT"
OUT=$(mktemp /tmp/dossrv_badent_test_out.XXXXXX)
trap 'rm -f "$IMG" "$SCRIPT" "$OUT"; rmdir "$MNT" 2>/dev/null' EXIT

#
# A 64MB FAT32 partition, the layout baremetal_test.sh puts behind an
# MBR for the Pi's boot partition -- but bare, with no partition table:
# under bare metal osinit hands dossrv the partition RANGE, and the MBR
# scan in dosfs() only knows types 01, 04 and 06, so a whole-disk image
# with a type-0C partition is "unknown format" to a hosted dossrv -f.
# Cluster 2 is the root, cluster 3 holds a plain file, cluster 4 belongs
# to the damaged entry -- name "BAD\x01ENT TXT", which dossrv must alias
# because the kernel refuses names with control characters at dirread.
#
python3 - "$IMG" <<'PYEOF'
import struct, sys

SEC   = 512
PSTART = 0               # hidden sectors: none, the image IS the partition
PSECS  = 131072
SPC    = 1
RESV   = 32
NFAT   = 2
FATSZ  = 1024

part = bytearray(PSECS * SEC)

bs = bytearray(SEC)
bs[0:3]   = b"\xEB\x58\x90"
bs[3:11]  = b"INFRNODE"
struct.pack_into("<H", bs, 11, SEC)
bs[13] = SPC
struct.pack_into("<H", bs, 14, RESV)
bs[16] = NFAT
struct.pack_into("<H", bs, 17, 0)      # root entries: zero, FAT32
struct.pack_into("<H", bs, 19, 0)
bs[21] = 0xF8
struct.pack_into("<H", bs, 22, 0)      # 16-bit sectors/FAT: zero, see 36
struct.pack_into("<H", bs, 24, 32)
struct.pack_into("<H", bs, 26, 64)
struct.pack_into("<I", bs, 28, PSTART)
struct.pack_into("<I", bs, 32, PSECS)
struct.pack_into("<I", bs, 36, FATSZ)
struct.pack_into("<H", bs, 40, 0)
struct.pack_into("<H", bs, 42, 0)
struct.pack_into("<I", bs, 44, 2)      # root's first cluster
struct.pack_into("<H", bs, 48, 1)
struct.pack_into("<H", bs, 50, 6)
bs[64] = 0x80
bs[66] = 0x29
struct.pack_into("<I", bs, 67, 0x32323232)
bs[71:82] = b"INFR32     "
bs[82:90] = b"FAT32   "
bs[510] = 0x55; bs[511] = 0xAA
part[0:SEC] = bs

CONTENT = b"fat32 works in the hosted emu\n"
DAMAGED = b"this entry's name is damaged\n"

fat = bytearray(FATSZ * SEC)
struct.pack_into("<I", fat, 0, 0x0FFFFFF8)
struct.pack_into("<I", fat, 4, 0x0FFFFFFF)
struct.pack_into("<I", fat, 8, 0x0FFFFFFF)   # root, one cluster
struct.pack_into("<I", fat, 12, 0x0FFFFFFF)  # HELLO32.TXT
struct.pack_into("<I", fat, 16, 0x0FFFFFFF)  # the damaged entry's cluster
for i in range(NFAT):
    off = (RESV + i*FATSZ) * SEC
    part[off:off+len(fat)] = fat

data = (RESV + NFAT*FATSZ) * SEC

def dirent(name, clus, size):
    d = bytearray(32)
    d[0:11] = name
    d[11] = 0x20
    struct.pack_into("<H", d, 20, clus >> 16)
    struct.pack_into("<H", d, 26, clus & 0xFFFF)
    struct.pack_into("<I", d, 28, size)
    return d

part[data:data+32]    = dirent(b"HELLO32 TXT", 3, len(CONTENT))
part[data+32:data+64] = dirent(b"BAD\x01ENT TXT", 4, len(DAMAGED))

part[data + (3-2)*SPC*SEC : data + (3-2)*SPC*SEC + len(CONTENT)] = CONTENT
part[data + (4-2)*SPC*SEC : data + (4-2)*SPC*SEC + len(DAMAGED)] = DAMAGED

open(sys.argv[1], "wb").write(part)
PYEOF

#
# dossrv is CALLED, not spawned: it forks its server and mounts before
# it returns, so the shell that follows sees the mount. The damaged
# entry is removed by whatever alias dossrv chose for it -- the name
# encodes the entry's location and is not worth hard-coding -- so the
# shell globs for it after the healthy badent-1 is already gone.
#
cat > "$SCRIPT" <<INFERNO
load std
dossrv -f $GIMG -m $GMNT
ls $GMNT
cat $GMNT/HELLO32.TXT
echo cluster-owner > $GMNT/badent-1
ls -l $GMNT
rm $GMNT/badent-1
ls $GMNT
rm $GMNT/badent-*
ls $GMNT
echo '=== SCRIPT DONE ==='
INFERNO

"$EMU" -r"$ROOT" -c0 sh /tmp/dossrv_badent_testscript.sh > "$OUT" 2>&1 &
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

if ! grep -q '=== SCRIPT DONE ===' "$OUT"; then
    echo "FAIL: guest script did not finish"
    cat "$OUT"
    exit 1
fi
if ! grep -q 'fat32 works in the hosted emu' "$OUT"; then
    echo "FAIL: dossrv did not mount and read the FAT32 image"
    cat "$OUT"
    exit 1
fi
if ! grep -q 'badent-[0-9a-f]*$' "$OUT"; then
    echo "FAIL: the damaged entry was not presented under a badent- alias"
    cat "$OUT"
    exit 1
fi

#
# The walk: every allocated cluster reachable from the root, except the
# one the damaged entry owned. Both removals must have happened -- an
# E5 entry whose remaining bytes spell ADENT is badent-1, one spelling
# AD\x01ENT is the damaged one -- or a session that never got as far as
# creating the file would pass for free.
#
WALK="$(python3 - "$IMG" <<'PYEOF'
import struct, sys
img = open(sys.argv[1], "rb").read()
SEC = 512
pstart = 0
bs = img[0:SEC]
spc = bs[13]
resv = struct.unpack_from("<H", bs, 14)[0]
nfat = bs[16]
fatsz = struct.unpack_from("<I", bs, 36)[0]
rootclus = struct.unpack_from("<I", bs, 44)[0]
fatoff = (pstart + resv) * SEC
data = (pstart + resv + nfat*fatsz) * SEC
nclus = fatsz * SEC // 4

def fat(n):
    return struct.unpack_from("<I", img, fatoff + 4*n)[0] & 0x0FFFFFFF

def chain(n):
    out = []
    while 2 <= n < 0x0FFFFFF8 and n not in out and len(out) < nclus:
        out.append(n)
        n = fat(n)
    return out

def cluster(n):
    off = data + (n-2)*spc*SEC
    return img[off : off + spc*SEC]

reachable = set()
deleted_healthy = 0
deleted_damaged = 0
live = []
def walk(start, depth):
    global deleted_healthy, deleted_damaged
    for c in chain(start):
        reachable.add(c)
        b = cluster(c)
        for o in range(0, len(b), 32):
            e = b[o:o+32]
            if e[0] == 0:
                return
            if e[0] == 0xE5:
                if e[1:6] == b"ADENT":
                    deleted_healthy += 1
                if e[1:7] == b"AD\x01ENT":
                    deleted_damaged += 1
                continue
            if e[11] & 0x08:
                continue
            if e[0:1] == b".":
                continue
            live.append(bytes(e[0:11]))
            st = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
            if st >= 2:
                if e[11] & 0x10 and depth < 8:
                    walk(st, depth + 1)
                else:
                    reachable.update(chain(st))

walk(rootclus, 0)
allocated = {n for n in range(2, nclus) if fat(n) != 0}
lost = sorted(allocated - reachable)
print("DELETED-HEALTHY" if deleted_healthy else "NO-DELETED-HEALTHY")
print("DELETED-DAMAGED" if deleted_damaged else "NO-DELETED-DAMAGED")
print("LIVE %s" % " ".join(repr(n) for n in live))
print("LOST %d %s" % (len(lost), lost))
PYEOF
)"
echo "$WALK"

status=0
if ! echo "$WALK" | grep -q '^DELETED-HEALTHY$'; then
    echo "FAIL: badent-1 was not created and removed through dossrv"
    status=1
fi
if ! echo "$WALK" | grep -q '^DELETED-DAMAGED$'; then
    echo "FAIL: the damaged entry was not removed through its badent- alias"
    status=1
fi
if echo "$WALK" | grep -q "BADENT"; then
    echo "FAIL: a BADENT entry is still live in the root directory"
    status=1
fi
# Exactly the damaged entry's cluster is left behind, and nothing else:
# LOST 0 would mean the damage path went through the ordinary remove
# and trusted a start cluster it must not; LOST 2 is the old bug.
if ! echo "$WALK" | grep -q '^LOST 1 \[4\]$'; then
    echo "FAIL: expected exactly cluster 4 (the damaged entry's) left allocated, got: $(echo "$WALK" | grep '^LOST')"
    status=1
fi

if [ $status -ne 0 ]; then
    echo "--- guest output ---"
    cat "$OUT"
    exit 1
fi
echo "PASS: a healthy badent-1 frees its clusters; a damaged entry is zapped and its cluster left"
exit 0
