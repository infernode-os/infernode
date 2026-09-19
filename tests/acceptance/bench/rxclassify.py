import socket, time, os, sys, re, subprocess
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
def held(cmd):
    c = socket.create_connection(('192.168.1.104', 17010), timeout=15); c.settimeout(2.0)
    time.sleep(0.5); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.5)
    try: c.recv(4096)
    except socket.timeout: pass
    c.sendall((cmd + '\n').encode()); return c
def nstat():
    o = subprocess.run("nstat -az", shell=True, capture_output=True, text=True).stdout; d = {}
    for l in o.splitlines():
        f = l.split()
        if len(f) >= 2 and f[1].lstrip('-').isdigit(): d[f[0]] = int(f[1])
    return d
b = Board('192.168.1.104')
def bstats():
    o = b.sh('cat /net/tcp/stats', 'cat /net/ipifc/stats', 'cat /net/ether0/stats', wait=1.5); d = {}
    for l in o.splitlines():
        m = re.match(r'\s*([A-Za-z][A-Za-z0-9 _-]*?)\s*[:=]?\s+(\d+)\s*$', l)
        if m: d[m.group(1).strip()] = int(m.group(2))
    return d
sink = held("load std; listen -A 'tcp!*!8700' {cat > /dev/null}"); time.sleep(2)
n0 = nstat(); b0 = bstats()
MB = 16; data = b'\xa5' * (1024*1024)
s = socket.create_connection(('192.168.1.104', 8700), timeout=10); t0 = time.time()
for i in range(MB): s.sendall(data)
s.shutdown(socket.SHUT_WR)
try: s.settimeout(60); s.recv(1)
except Exception: pass
dt = time.time() - t0
n1 = nstat(); b1 = bstats()
print('inbound %d MB in %.2fs = %.1f Mbit/s' % (MB, dt, MB*8/dt))
print('--- sender (Linux) classification')
for k in ['TcpOutSegs','TcpRetransSegs','TcpExtTCPTimeouts','TcpExtTCPFastRetrans','TcpExtTCPSlowStartRetrans','TcpExtTCPLostRetransmit','TcpExtTCPLossProbes','TcpExtTCPLossProbeRecovery','TcpExtTCPSackRecovery','TcpExtTCPRenoRecovery','TcpExtTCPSACKReneging','TcpExtTCPDSACKRecv','TcpExtTCPSpuriousRTOs','TcpExtTCPSackFailures','TcpExtTCPRenoFailures']:
    d = n1.get(k,0) - n0.get(k,0)
    if d: print('  %-28s %+d' % (k, d))
print('--- board')
for k in sorted(b1):
    d = b1[k] - b0.get(k, 0)
    if d and k not in ('in','out'): print('  %-22s %+d' % (k, d))
s.close(); sink.close()
