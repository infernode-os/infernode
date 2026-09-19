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
def snap():
    o = b.sh('cat /net/ether0/stats', 'cat /net/tcp/stats', 'cat /net/ipifc/stats', wait=1.5)
    d = {}
    for l in o.splitlines():
        m = re.match(r'\s*([A-Za-z][A-Za-z0-9 _-]*?)\s*[:=]?\s+(\d+)\s*$', l)
        if m: d[m.group(1).strip()] = int(m.group(2))
    return d
sink = held("load std; listen -A 'tcp!*!8700' {cat > /dev/null}"); time.sleep(2)
a = snap()
MB = 16; data = b'\xa5' * (1024*1024)
s = socket.create_connection(('192.168.1.104', 8700), timeout=10); t0 = time.time()
for i in range(MB): s.sendall(data)
s.shutdown(socket.SHUT_WR)
try: s.settimeout(60); s.recv(1)
except Exception: pass
print('inbound %d MB in %.2fs = %.1f Mbit/s' % (MB, time.time()-t0, MB*8/(time.time()-t0)))
z = snap()
for k in sorted(z):
    if z[k] != a.get(k, 0): print('  %-22s %+d' % (k, z[k] - a.get(k, 0)))
s.close(); sink.close()
