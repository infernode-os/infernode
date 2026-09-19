# Bracket an inbound TCP transfer with the driver's rxstats and report.
import socket, time, os, sys
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
def held(cmd):
    c = socket.create_connection(('192.168.1.104', 17010), timeout=15); c.settimeout(2.0)
    time.sleep(0.5); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.5)
    try: c.recv(4096)
    except socket.timeout: pass
    c.sendall((cmd + '\n').encode()); return c
sink = held("load std; listen -A 'tcp!*!8700' {cat > /dev/null}"); time.sleep(2)
b = Board('192.168.1.104')
def rxstats():
    return b.sh("echo rxstats > /net/ether0/clone", "cat /net/ether0/stats | grep -i 'rx:'", wait=1.0)
b.sh("{echo rxstats >[1=0]} <> /net/ether0/clone", wait=1.0)
MB = int(sys.argv[1]) if len(sys.argv) > 1 else 8
data = b'\xa5' * (1024*1024)
s = socket.create_connection(('192.168.1.104', 8700), timeout=10)
t0 = time.time()
for i in range(MB): s.sendall(data)
s.shutdown(socket.SHUT_WR)
try:
    s.settimeout(30); s.recv(1)
except Exception: pass
dt = time.time() - t0; s.close()
print('inbound %d MB in %.2fs = %.1f Mbit/s' % (MB, dt, MB*8/dt))
print(b.sh("{echo rxstats >[1=0]} <> /net/ether0/clone", wait=1.5).strip()[-400:])
sink.close()
