#!/usr/bin/env python3
# Provoke #681: the talarm lock loop. Overlap the START of inbound TCP bursts
# (ether0rx/ether0tx going from idle to flat out, through chanwait -> tsleep at
# splhi) with console sessions that spawn processes (cat, ps) -- the coincidence
# the soak met by accident -- as often as possible, and time how long the board lasts.
#   repro.py <label> <minutes> [push] [stream] [sess] [loops] [storm]
import os, sys, time, socket, threading, re
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
HOST = '192.168.1.104'
label, minutes, what = sys.argv[1], float(sys.argv[2]), set(sys.argv[3:])
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
SER = '/mnt/orin-ssd/pdfinn/infernode-captures/serial/%s.log' % time.strftime('%Y-%m-%d')
LOG = open(os.path.expanduser('~/pitools/repro/repro.log'), 'a')
def say(s):
    l = time.strftime('%Y-%m-%d %H:%M:%S ') + '[%s] ' % label + s
    print(l, flush=True); LOG.write(l + '\n'); LOG.flush()
stop = threading.Event(); counts = {'push': 0, 'pushfail': 0, 'sess': 0, 'sessfail': 0}
def held(cmd):
    c = socket.create_connection((HOST, 17010), timeout=15); c.settimeout(3.0)
    time.sleep(0.6); c.recv(4096); c.sendall((tok + '\n').encode())
    try: c.recv(4096)
    except socket.timeout: pass
    c.sendall((cmd + '\n').encode()); return c
def pusher():
    data = b'\xa5' * (256*1024)
    while not stop.is_set():
        try:
            c = socket.create_connection((HOST, 8702), timeout=8)
            for k in range(16): c.sendall(data)          # 4 MB: the start is what matters
            c.close(); counts['push'] += 1
        except Exception:
            counts['pushfail'] += 1; time.sleep(2)
        if 'stream' not in what: time.sleep(1.0)            # idle again, so the next one is a start; 'stream' keeps the link busy
def sessions():
    b = Board(HOST)
    while not stop.is_set():
        try:
            b.sh('cat /dev/memory > /dev/null; ps > /dev/null; ls /dis > /dev/null', wait=0.5); counts['sess'] += 1
        except Exception:
            counts['sessfail'] += 1; time.sleep(2)
LOOPS = ["load std; while {~ 1 1} {cat /dis/sh.dis > /tmp/soak1; rm /tmp/soak1}",
         "load std; while {~ 1 1} {ls /dis > /dev/null; ls /tmp > /dev/null}",
         "load std; while {~ 1 1} {echo hello > /tmp/soak3; cat /tmp/soak3 > /dev/null; rm /tmp/soak3}",
         "load std; while {~ 1 1} {cat /dev/memory > /dev/null; sleep 1}"]
mark = os.path.getsize(SER)
keep = []
if 'push' in what: keep.append(held("load std; listen -A 'tcp!*!8702' {cat > /dev/null}")); time.sleep(2)
if 'loops' in what: keep += [held(l) for l in LOOPS]
if 'storm' in what:
    # 32 Dis threads each in sys->sleep(1): ~30,000 tsleep()s a second from preemptible procs
    keep.append(held("mkdir /tmp/jet >[2] /dev/null; mount -A tcp!192.168.1.151!6666 /tmp/jet; cp /tmp/jet/dis/stage/tsleepstorm.dis /tmp/tsleepstorm.dis; /tmp/tsleepstorm.dis 32 1 %d" % int(minutes*60+30)))
    time.sleep(6)
threads = []
if 'push' in what: threads.append(threading.Thread(target=pusher, daemon=True))
if 'sess' in what: threads += [threading.Thread(target=sessions, daemon=True) for _ in range(2)]
for t in threads: t.start()
say('start: %s for %g min' % (' '.join(sorted(what)), minutes))
t0 = time.time(); hit = None
while time.time() - t0 < minutes * 60:
    time.sleep(5)
    text = open(SER, 'rb').read()[mark:].decode('latin1')
    m = re.search(r'lock loop[^\n]*|panic: [^\n]*', text)
    if m:
        hit = m.group(0); break
stop.set()
el = time.time() - t0
say('%s after %.0f s: %s; pushes %d (%d failed) sessions %d (%d failed)' % ('PANIC' if hit else 'no panic', el, hit or '-', counts['push'], counts['pushfail'], counts['sess'], counts['sessfail']))
sys.exit(1 if hit else 0)
