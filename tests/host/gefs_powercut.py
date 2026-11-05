#!/usr/bin/env python3
#
# gefs_powercut.py -- the disks a power cut could leave, from gefs's -W
# journal: every block it wrote, in order, and every device flush.
#
#	gefs_powercut.py base.img journal out.img seed [notear]
#
# What was written before a flush is on the medium; of what was written
# after the last flush before the cut, any block may have reached it or
# not, in any of the versions written, and (unless notear) a block may
# be torn into 4 KB sectors of the old and the new, as a drive whose
# atomic write unit is a sector can leave it. The cut is put after a
# flush chosen at random, weighted as said below.
#
import sys, os, random, shutil
Blk = 16384
Sec = 4096
base, jpath, out, seed = sys.argv[1:5]
tear = len(sys.argv) < 6
rnd = random.Random(int(seed))
j = open(jpath, 'rb').read()
segs = [[]]
i = 0
while i < len(j):
    c = j[i:i+1]
    if c == b'W':
        addr = int.from_bytes(j[i+1:i+9], 'big')
        segs[-1].append((addr, i+9))
        i += 9 + Blk
    elif c == b'F':
        segs.append([])
        i += 1
    else:
        sys.exit('powercut: bad journal at %d' % i)
# A block written over one already on disk is what a commit can hang
# on: copy on write puts everything else in fresh blocks. The cut goes
# more often where such rewrites are in flight, and tears them more
# often, with the first sector (where headers are) new more often.
bf = open(base, 'rb')
def basezero(addr):
    bf.seek(addr)
    return bf.read(Blk).count(0) == Blk
# the structures written in place, by their type: log, deadlist, arena
# header, superblock
inplace = (3, 4, 5, 0x6765)
def kind(o):
    return int.from_bytes(j[o:o+2], 'big')
seen = set()
rewrites = []
weights = []
for s in segs:
    rw = set(a for a, o in s if a in seen or not basezero(a))
    rewrites.append(rw)
    weights.append(20 if any(a in rw and kind(o) in inplace for a, o in s) else 1)
    seen.update(a for a, o in s)
k = rnd.choices(range(len(segs)), weights)[0]
shutil.copyfile(base, out)
f = open(out, 'r+b')
for s in segs[:k]:
    for addr, o in s:
        f.seek(addr); f.write(j[o:o+Blk])
vers = {}
for addr, o in segs[k]:
    vers.setdefault(addr, []).append(o)
nnew = nold = ntorn = 0
for addr, os_ in vers.items():
    f.seek(addr); old = f.read(Blk)
    if len(old) < Blk:
        old += bytes(Blk - len(old))
    rw = addr in rewrites[k]
    r = rnd.random()
    if r < (0.15 if rw else 0.3):
        nold += 1
        continue
    new = j[os_[-1]:os_[-1]+Blk] if r < 0.75 else (lambda o: j[o:o+Blk])(rnd.choice(os_))
    if tear and rnd.random() < (0.7 if rw else 0.3):
        b = bytearray(old)
        for s in range(0, Blk, Sec):
            if rnd.random() < (0.75 if rw and s == 0 else 0.5):
                b[s:s+Sec] = new[s:s+Sec]
        new = bytes(b); ntorn += 1
    else:
        nnew += 1
    f.seek(addr); f.write(new)
f.close()
print('cut after flush %d of %d: %d blocks in flight (%d rewrites), %d new, %d old, %d torn' % (k, len(segs)-1, len(vers), len(rewrites[k]), nnew, nold, ntorn))
