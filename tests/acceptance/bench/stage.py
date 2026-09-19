# Robust A/B stage: copy a kernel to the card as tryboot.img (one session for
# the copy, a fresh one to verify, a fresh one to request the candidate boot),
# wait for the candidate, verify the running image by size, promote.
#   stage.py /path/kernel.img [extra.dis ...]
import socket, time, os, sys, subprocess, shutil
HOST, CONS, JET = '192.168.1.104', 17010, '192.168.1.151'
STAGE = '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode/dis/stage'
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
kernel = sys.argv[1]; extras = sys.argv[2:]; ksz = os.path.getsize(kernel)
def connect(tries=30):
    for i in range(tries):
        try:
            c = socket.create_connection((HOST, CONS), timeout=10); c.settimeout(6.0)
            time.sleep(0.6); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.6)
            try: c.recv(4096)
            except socket.timeout: pass
            return c
        except OSError as e:
            time.sleep(5)
    sys.exit('board console unreachable')
def run(c, cmd, w=3.0):
    c.sendall((cmd + '\n').encode()); time.sleep(w); out = b''
    try:
        while True:
            b = c.recv(65536)
            if not b: break
            out += b
    except socket.timeout: pass
    except ConnectionResetError: pass
    return out.decode(errors='replace')
def session(cmds):
    c = connect(); outs = [run(c, cmd, w) for cmd, w in cmds]
    try: c.close()
    except Exception: pass
    return outs
shutil.copy(kernel, STAGE + '/tryboot.img')
for e in extras: shutil.copy(e, STAGE + '/' + os.path.basename(e))
print('staging %s (%d bytes)' % (kernel, ksz), flush=True)
for attempt in range(3):
    t0 = time.time()
    try:
        session([('mkdir /tmp/jet', 1), ('mount -A tcp!%s!6666 /tmp/jet' % JET, 4),
                 ('cp /tmp/jet/dis/stage/tryboot.img /n/dos/tryboot.img', 300)] +
                [('cp /tmp/jet/dis/stage/%s /n/dos/dis/%s' % (os.path.basename(e), os.path.basename(e)), 30) for e in extras] +
                [('unmount /tmp/jet', 2)])
    except Exception as ex:
        print('copy session ended early:', ex, flush=True)
    out = session([('ls -l /n/dos/tryboot.img', 3)])[0]
    print('copy attempt %d: %.0fs; card says: %s' % (attempt, time.time() - t0, out.strip()[-60:]), flush=True)
    if str(ksz) in out: break
else: sys.exit('could not stage the kernel on the card')
session([("bind -a '#c' /dev", 1), ('echo tryboot > /dev/sysctl', 1)])
print('candidate boot requested', flush=True); time.sleep(60)
c = connect(40)
out = run(c, 'ls -l /dev/bootimage')
if str(ksz) not in out: sys.exit('the running kernel is not the candidate: ' + out.strip())
run(c, 'mv /n/dos/infernode8.img /n/dos/kprev.img', 2); run(c, 'mv /n/dos/tryboot.img /n/dos/infernode8.img', 2)
print(run(c, 'ls -l /n/dos/infernode8.img /n/dos/kprev.img /dev/bootimage').strip()); print('promoted', flush=True)
