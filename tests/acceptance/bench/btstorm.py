import socket, time, os, subprocess, collections
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
BD = 'B8:27:EB:CA:4C:8E'
c = socket.create_connection(('192.168.1.104', 17010), timeout=15); c.settimeout(2.0)
time.sleep(0.5); c.recv(4096); c.sendall((tok + '\n').encode()); time.sleep(0.5)
try: c.recv(4096)
except socket.timeout: pass
c.sendall(b"load std; listen -A 'bt!*!spp' {cat >> /tmp/rfin}\n"); time.sleep(3)
r = subprocess.run("timeout 10 rctest -i hci0 -c -P 1 %s" % BD, shell=True, capture_output=True, text=True)
out = r.stdout + r.stderr
lines = out.splitlines()
print('connected', sum(1 for l in lines if 'Connected' in l))
cnt = collections.Counter(l.split(']: ',1)[-1] for l in lines if "Can't" in l or 'error' in l.lower())
for k, v in cnt.most_common(8): print('%7d  %s' % (v, k[:100]))
# the sequence around one refusal
for i, l in enumerate(lines):
    if 'refused' in l:
        print('context:', [x.split(']: ',1)[-1][:40] for x in lines[max(0,i-3):i+3]]); break
c.close()
