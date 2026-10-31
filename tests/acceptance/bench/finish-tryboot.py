# The candidate is already on the card as tryboot.img; request the candidate
# boot, wait, verify, promote (the tail of ~/pitools/tryboot.py).
import socket, time, os, sys
HOST, CONS = '192.168.1.104', 17010
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
ksz = int(sys.argv[1])
def connect():
    c = socket.create_connection((HOST, CONS), timeout=10); c.settimeout(6.0)
    time.sleep(0.6); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.6)
    try: c.recv(4096)
    except socket.timeout: pass
    return c
def run(c, cmd, w=3.0):
    c.sendall((cmd + '\n').encode()); time.sleep(w); out = b''
    try:
        while True:
            b = c.recv(65536)
            if not b: break
            out += b
    except socket.timeout: pass
    return out.decode(errors='replace')
c = connect()
out = run(c, 'ls -l /n/dos/tryboot.img')
if str(ksz) not in out: sys.exit('tryboot.img on the card is not the candidate: ' + out)
run(c, "bind -a '#c' /dev", 1.0)
try: run(c, 'echo tryboot > /dev/sysctl', 1.0)
except Exception: pass
try: c.close()
except Exception: pass
print('candidate boot requested', flush=True); time.sleep(60)
for i in range(24):
    try: c = connect(); break
    except OSError: time.sleep(5)
else: sys.exit('the candidate did not come up')
out = run(c, 'ls -l /dev/bootimage')
if str(ksz) not in out: sys.exit('running kernel is not the candidate: ' + out)
run(c, 'mv /n/dos/infernode8.img /n/dos/kprev.img', 2.0)
run(c, 'mv /n/dos/tryboot.img /n/dos/infernode8.img', 2.0)
print(run(c, 'ls -l /n/dos/infernode8.img /n/dos/kprev.img /dev/bootimage'))
print('promoted', flush=True)
