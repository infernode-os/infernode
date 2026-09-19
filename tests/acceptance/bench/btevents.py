import socket, time, os, subprocess, collections, threading
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
BD = 'B8:27:EB:CA:4C:8E'
def session(cmd):
    c = socket.create_connection(('192.168.1.104', 17010), timeout=15); c.settimeout(2.0)
    time.sleep(0.5); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.5)
    try: c.recv(4096)
    except socket.timeout: pass
    c.sendall((cmd + '\n').encode()); return c
ev = session('cat /net/bt/event'); events = []
def reader():
    ev.settimeout(1.0)
    while True:
        try: d = ev.recv(65536)
        except socket.timeout: continue
        except OSError: return
        if not d: return
        events.append(d.decode(errors='replace'))
threading.Thread(target=reader, daemon=True).start()
ls = session("load std; listen -A 'bt!*!spp' {cat >> /tmp/rfin}"); time.sleep(3)
r = subprocess.run("timeout 12 rctest -i hci0 -c -P 1 %s" % BD, shell=True, capture_output=True, text=True)
out = r.stdout + r.stderr; lines = out.splitlines()
print('connected', sum(1 for l in lines if 'Connected' in l), '| refused', out.count('refused'), '| reset', out.count('reset by peer'))
time.sleep(3)
text = ''.join(events)
print('--- board events (%d lines), first 90:' % text.count('\n'))
for l in text.splitlines()[:90]: print('   ', l[:120])
ls.close(); ev.close()
