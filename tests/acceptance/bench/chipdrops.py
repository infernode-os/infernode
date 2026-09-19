import socket, time, os, sys, re
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
def held(cmd):
    c = socket.create_connection(('192.168.1.104', 17010), timeout=15); c.settimeout(2.0)
    time.sleep(0.5); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.5)
    try: c.recv(4096)
    except socket.timeout: pass
    c.sendall((cmd + '\n').encode()); return c
b = Board('192.168.1.104')
print(b.sh('mkdir -p /tmp/jet; mount -A tcp!192.168.1.151!6666 /tmp/jet', 'cp /tmp/jet/dis/stage/lan78stats.dis /n/dos/dis/lan78stats.dis; cp /tmp/jet/dis/stage/lan78stats.dis /tmp/lan78stats.dis', 'unmount /tmp/jet', 'ls -l /tmp/lan78stats.dis', wait=3.0).strip()[-90:])
def stats():
    o = b.sh('/tmp/lan78stats.dis', wait=2.5); d = {}
    for l in o.splitlines():
        m = re.match(r'(.+?)\s+(\d+)\s*$', l)
        if m: d[m.group(1).strip()] = int(m.group(2))
    if not d: print('raw:', o[:200])
    return d
sink = held("load std; listen -A 'tcp!*!8700' {cat > /dev/null}"); time.sleep(2)
a = stats()
MB = 16; data = b'\xa5' * (1024*1024)
s = socket.create_connection(('192.168.1.104', 8700), timeout=10); t0 = time.time()
for i in range(MB): s.sendall(data)
s.shutdown(socket.SHUT_WR)
try: s.settimeout(60); s.recv(1)
except Exception: pass
print('inbound %d MB in %.2fs = %.1f Mbit/s' % (MB, time.time()-t0, MB*8/(time.time()-t0)))
z = stats()
for k in z:
    d = z[k] - a.get(k, 0)
    if d or k in ('rx dropped frames', 'rx pause frames', 'tx pause frames'): print('  %-24s %+d' % (k, d))
s.close(); sink.close()
