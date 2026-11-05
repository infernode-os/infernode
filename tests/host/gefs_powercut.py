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
# random flush.
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
k = rnd.randrange(len(segs))
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
    r = rnd.random()
    if r < 0.3:
        nold += 1
        continue
    new = j[os_[-1]:os_[-1]+Blk] if r < 0.75 else (lambda o: j[o:o+Blk])(rnd.choice(os_))
    if tear and rnd.random() < 0.3:
        b = bytearray(old)
        for s in range(0, Blk, Sec):
            if rnd.random() < 0.5:
                b[s:s+Sec] = new[s:s+Sec]
        new = bytes(b); ntorn += 1
    else:
        nnew += 1
    f.seek(addr); f.write(new)
f.close()
print('cut after flush %d of %d: %d blocks in flight, %d new, %d old, %d torn' % (k, len(segs)-1, len(vers), nnew, nold, ntorn))
