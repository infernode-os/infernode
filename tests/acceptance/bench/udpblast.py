# Where do frames vanish? Send N UDP frames in bursts of B (gap G s) and
# compare: sent, chip's rx unicast frames, chip's rx dropped, board ether in.
import socket, time, os, sys, re
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
b = Board('192.168.1.104')
def stats():
    o = b.sh('/tmp/lan78stats.dis', wait=2.5); d = {}
    for l in o.splitlines():
        m = re.match(r'(.+?)\s+(\d+)\s*$', l)
        if m: d[m.group(1).strip()] = int(m.group(2))
    o = b.sh('cat /net/ether0/stats', wait=1.5)
    for l in o.splitlines():
        m = re.match(r'(\w[\w ]*?):\s+(\d+)', l)
        if m: d['ether ' + m.group(1)] = int(m.group(2))
    return d
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
pay = b'\x5a' * 1400
for B, G, N in [(40, 0.02, 3000), (4, 0.002, 3000), (1, 0.0005, 3000), (4, 0.002, 3000), (2, 0.001, 3000), (10, 0.005, 3000), (20, 0.01, 3000)]:
    a = stats(); t0 = time.time(); sent = 0
    while sent < N:
        for i in range(B): u.sendto(pay, ('192.168.1.104', 9)); sent += 1
        t = time.time() + G
        while time.time() < t: pass
    dt = time.time() - t0; time.sleep(1); z = stats()
    print('burst %2d gap %.1f ms: sent %d in %.2fs (%.0f Mbit/s avg)' % (B, G*1000, sent, dt, sent*1442*8/dt/1e6))
    for k in ('rx unicast frames', 'rx dropped frames', 'tx pause frames', 'ether in', 'ether overflows', 'ether soft overflows', 'ether input errs'):
        if k in z: print('    %-22s %+d' % (k, z[k] - a.get(k, 0)))
