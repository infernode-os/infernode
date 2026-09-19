import socket, time, os, sys, re
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
b = Board('192.168.1.104')
def sh(*a, **k):
    for i in range(5):
        try: return b.sh(*a, **k)
        except Exception as e: time.sleep(2)
    raise
def stats():
    o = sh('/tmp/lan78stats.dis', wait=2.5); d = {}
    for l in o.splitlines():
        m = re.match(r'(.+?)\s+(\d+)\s*$', l)
        if m: d[m.group(1).strip()] = int(m.group(2))
    return d
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); pay = b'\x5a' * 1400
for dly in sys.argv[1:]:
    print('BULK_IN_DLY', dly, '->', sh('/tmp/lan78stats.dis reg 94 ' + dly, wait=2).strip().splitlines()[-1])
    for B, G, N in [(4, 0.002, 3000), (10, 0.005, 3000), (40, 0.02, 3000), (80, 0.04, 3000)]:
        a = stats(); sent = 0
        while sent < N:
            for i in range(B): u.sendto(pay, ('192.168.1.104', 9)); sent += 1
            t = time.time() + G
            while time.time() < t: pass
        time.sleep(1); z = stats()
        print('   burst %2d: dropped %5d  pause %5d' % (B, z['rx dropped frames'] - a['rx dropped frames'], z['tx pause frames'] - a['tx pause frames']), flush=True)
