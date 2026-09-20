#!/usr/bin/env python3
# 48-hour soak: four stress loops each held on its OWN network-console
# connection (a loop started with & dies when its session closes), /dev/memory
# logged every 5 min, the Ethernet and Bluetooth batteries once a day, loops
# re-opened after a reboot. Log: ~/pitools/soak/soak.log.
import os, sys, time, socket, subprocess, threading
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
D = os.path.expanduser('~/pitools/soak'); A = '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance'
HOST = '192.168.1.104'
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
log = open(os.path.join(D, 'soak.log'), 'a'); lk = threading.Lock()
def say(s):
    with lk: log.write(time.strftime('%Y-%m-%d %H:%M:%S ') + s + '\n'); log.flush()
LOOPS = [
    "load std; while {~ 1 1} {cat /dis/sh.dis > /tmp/soak1; rm /tmp/soak1}",
    "load std; while {~ 1 1} {ls /dis > /dev/null; ls /tmp > /dev/null}",
    "load std; while {~ 1 1} {echo hello > /tmp/soak3; cat /tmp/soak3 > /dev/null; rm /tmp/soak3}",
    "load std; while {~ 1 1} {cat /dev/memory > /dev/null; sleep 1}",
]
def keeper(i, cmd):
    while True:
        try:
            c = socket.create_connection((HOST, 17010), timeout=15); c.settimeout(3.0)
            time.sleep(0.6); c.recv(4096); c.sendall((tok + '\n').encode())
            try: c.recv(4096)          # the shell says nothing after a good token
            except socket.timeout: pass
            c.sendall((cmd + '\n').encode()); say('loop %d up' % i); c.settimeout(60.0)
            # The loop never prints, and a reboot leaves the socket half-open. TCP
            # keepalives find that out (the rebooted board answers the probe with a
            # RST) and cost the board nothing. This used to send a newline a minute:
            # each one is a one-byte segment that the console's queue keeps as a
            # whole Block, 240 an hour over four sessions, and over a day that read
            # as a slow leak in the main pool (it was 0.9 MB after 35 hours).
            c.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 60)
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 15)
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 4)
            while True:
                try:
                    if not c.recv(65536): break
                except socket.timeout:
                    pass
        except Exception as e:
            pass
        say('loop %d down; retrying in 60 s' % i); time.sleep(60)
for i, cmd in enumerate(LOOPS): threading.Thread(target=keeper, args=(i, cmd), daemon=True).start()
# The receive path is where #610's panic lives, and the four loops above never
# touch it. A sink held on its own console, and 64 MB pushed into it every ten
# minutes at whatever the link carries; the rate is logged so a slow-down shows.
# The sink is not held by a keeper: the Ethernet battery begins and ends with
# "kill Listen", which takes this listener with its own and leaves the console
# session that started it alive, so a keeper never notices (that is how 53
# pushes were refused on 2026-09-19 after a battery run at 03:25). The pusher
# arms the sink itself whenever it finds the port closed.
sinkconn = [None]
def armsink():
    try:
        if sinkconn[0] is not None: sinkconn[0].close()
    except Exception: pass
    c = socket.create_connection((HOST, 17010), timeout=15); c.settimeout(3.0)
    time.sleep(0.6); c.recv(4096); c.sendall((tok + '\n').encode())
    try: c.recv(4096)
    except socket.timeout: pass
    c.sendall(b"load std; listen -A 'tcp!*!8702' {cat > /dev/null}\n"); sinkconn[0] = c
    say('sink armed'); time.sleep(3)
try: armsink()
except Exception as e: say('sink not armed: %s' % e)
def inbound():
    data = b'\xa5' * (1024*1024)
    while True:
        time.sleep(600)
        try:
            try: c = socket.create_connection((HOST, 8702), timeout=15)
            except ConnectionRefusedError:
                armsink(); c = socket.create_connection((HOST, 8702), timeout=15)
            t0 = time.time()
            for k in range(64): c.sendall(data)
            c.shutdown(socket.SHUT_WR)
            try: c.settimeout(60); c.recv(1)
            except Exception: pass
            c.close(); say('inbound 64 MB at %.1f Mbit/s' % (64*8/(time.time()-t0)))
        except Exception as e:
            say('inbound failed: %s' % e)
threading.Thread(target=inbound, daemon=True).start()
start = time.time(); lastbat = time.time()   # the Ethernet battery ran just before this start
while time.time() - start < 50*3600:
    try:
        b = Board(HOST)
        m = b.sh('cat /dev/memory', 'ps', wait=2.0)
        main = [l for l in m.splitlines() if l.strip().endswith('main')]
        n = sum(1 for l in m.splitlines() if l.strip().endswith('Sh[$Sys]'))
        say('main ' + (' '.join(main[0].split()[:3]) if main else '?') + ' shells %d' % n)
        if time.time() - lastbat > 24*3600 - 600:
            lastbat = time.time()
            for bat, args in (('ethernet', []), ('bluetooth', ['--bdaddr', 'b8:27:eb:ca:4c:8e'])):
                say('battery %s start' % bat)
                out = os.path.join(D, 'soak-%s-%s.txt' % (bat, time.strftime('%m%d-%H%M')))
                rc = subprocess.call(['python3', '-u', os.path.join(A, bat + '.py'), '--board', HOST] + args, stdout=open(out, 'w'), stderr=subprocess.STDOUT, timeout=1800)
                summ = [l for l in open(out) if l.startswith('Passed')]
                say('battery %s rc=%d %s' % (bat, rc, summ[0].strip() if summ else '?'))
                time.sleep(60)
    except Exception as e:
        say('unreachable: %s' % e)
    time.sleep(300)
say('soak finished')
