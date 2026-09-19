# Inbound transfer with the sender's own TCP diagnostics sampled mid-flight.
import socket, time, os, sys, subprocess, threading, re
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
def held(cmd):
    c = socket.create_connection(('192.168.1.104', 17010), timeout=15); c.settimeout(2.0)
    time.sleep(0.5); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.5)
    try: c.recv(4096)
    except socket.timeout: pass
    c.sendall((cmd + '\n').encode()); return c
sink = held("load std; listen -A 'tcp!*!8700' {cat > /dev/null}"); time.sleep(2)
MB = 16; data = b'\xa5' * (1024*1024)
s = socket.create_connection(('192.168.1.104', 8700), timeout=10)
samples = []
def sampler():
    for i in range(8):
        time.sleep(0.4)
        o = subprocess.run("ss -tin dst 192.168.1.104:8700", shell=True, capture_output=True, text=True).stdout
        samples.append(o)
threading.Thread(target=sampler, daemon=True).start()
t0 = time.time()
for i in range(MB): s.sendall(data)
s.shutdown(socket.SHUT_WR)
try: s.settimeout(60); s.recv(1)
except Exception: pass
dt = time.time() - t0
print('inbound %d MB in %.2fs = %.1f Mbit/s' % (MB, dt, MB*8/dt))
last = [x for x in samples if 'cwnd' in x][-1] if any('cwnd' in x for x in samples) else ''
for key in ['wscale', 'rto', 'rtt', 'mss', 'cwnd', 'ssthresh', 'snd_wnd', 'rwnd_limited', 'sndbuf_limited', 'busy', 'unacked', 'retrans', 'delivery_rate', 'notsent']:
    m = re.search(r'(%s:\S+)' % key, last)
    if m: print('  ', m.group(1))
s.close(); sink.close()
