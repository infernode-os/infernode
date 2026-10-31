import socket,time,os,sys
tok = open(os.path.expanduser('~/pitools/netcons.token')).read().strip()
def sess(cmds, w=4):
    for attempt in range(6):
        try:
            c = socket.create_connection(('192.168.1.104', 17010), timeout=10); c.settimeout(40)
            g=c.recv(4096); break
        except Exception as e:
            try: c.close()
            except Exception: pass
    else: sys.exit('no console')
    c.sendall((tok+'\n').encode()); time.sleep(1.5)
    out=b''
    for cmd in cmds:
        c.sendall((cmd+'\n').encode()); time.sleep(w)
        c.settimeout(3)
        try:
            while True:
                d=c.recv(65536)
                if not d: break
                out+=d
        except Exception: pass
    c.close(); return out.decode(errors='replace')
if __name__ == '__main__':
    print(sess(sys.argv[1:]))
