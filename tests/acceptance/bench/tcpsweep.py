# usage: tcpsweep.py reg=val[,reg=val] ...   one configuration per argument
import socket, time, os, sys, re, subprocess
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
b = Board('192.168.1.104')
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
def sh(*a, **k):
    for i in range(6):
        try: return b.sh(*a, **k)
        except Exception as e: time.sleep(2)
    return ''
def held(cmd):
    c = socket.create_connection(('192.168.1.104', 17010), timeout=15); c.settimeout(2.0)
    time.sleep(0.5); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.5)
    try: c.recv(4096)
    except socket.timeout: pass
    c.sendall((cmd + '\n').encode()); return c
def chip():
    o = sh('/tmp/lan78stats.dis', wait=2.5); d = {}
    for l in o.splitlines():
        m = re.match(r'(.+?)\s+(\d+)\s*$', l)
        if m: d[m.group(1).strip()] = int(m.group(2))
    return d
def nstat():
    o = subprocess.run(['nstat', '-az'], capture_output=True, text=True).stdout; d = {}
    for l in o.splitlines()[1:]:
        f = l.split()
        if len(f) >= 2: d[f[0]] = int(f[1])
    return d
sink = held("load std; listen -A 'tcp!*!8701' {cat > /dev/null}"); time.sleep(2)
MB = 16; data = b'\xa5' * (1024*1024)
for conf in sys.argv[1:]:
    if conf != '-':
        for rv in conf.split(','):
            r, v = rv.split('='); print(conf, '->', sh('/tmp/lan78stats.dis reg %s %s' % (r, v), wait=2).strip().splitlines()[-1])
    a = chip(); na = nstat(); rates = []
    for k in range(3):
        s = socket.create_connection(('192.168.1.104', 8701), timeout=10); t0 = time.time()
        for i in range(MB): s.sendall(data)
        s.shutdown(socket.SHUT_WR)
        try: s.settimeout(60); s.recv(1)
        except Exception: pass
        rates.append(MB*8/(time.time()-t0)); s.close(); time.sleep(1)
    z = chip(); nz = nstat()
    print('  %s Mbit/s; chip dropped %d, pause %d; retrans %d, timeouts %d, sackrecov %d' % (
        ' '.join('%.1f' % r for r in rates), z['rx dropped frames'] - a['rx dropped frames'], z['tx pause frames'] - a['tx pause frames'],
        nz['TcpRetransSegs'] - na['TcpRetransSegs'], nz['TcpExtTCPTimeouts'] - na['TcpExtTCPTimeouts'], nz['TcpExtTCPSackRecovery'] - na['TcpExtTCPSackRecovery']), flush=True)
sink.close()
