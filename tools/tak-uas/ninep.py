#!/usr/bin/env python3
"""Minimal 9P2000 client — walk/read/write/ls against the nerv-gcs surface."""
import socket, struct, sys

Tversion, Rversion = 100, 101
Tattach, Rattach = 104, 105
Twalk, Rwalk = 110, 111
Topen, Ropen = 112, 113
Tread, Rread = 116, 117
Twrite, Rwrite = 118, 119
Tclunk, Rclunk = 120, 121
Rerror = 107
NOFID = 0xffffffff
OREAD, OWRITE = 0, 1

class Client:
    def __init__(self, host, port, msize=8192):
        self.s = socket.create_connection((host, port), timeout=8)
        self.msize = msize
        self.tag = 1
        self.fidn = 1
        self._version()
        self.root = self._alloc()
        self._attach(self.root)

    def _alloc(self):
        f = self.fidn; self.fidn += 1; return f

    def _rpc(self, typ, body):
        tag = self.tag; self.tag = (self.tag + 1) & 0xffff
        msg = struct.pack("<IBH", 7 + len(body), typ, tag) + body
        self.s.sendall(msg)
        hdr = self._recvn(7)
        size, rtyp, rtag = struct.unpack("<IBH", hdr)
        data = self._recvn(size - 7)
        if rtyp == Rerror:
            ln = struct.unpack("<H", data[:2])[0]
            raise RuntimeError("Rerror: " + data[2:2+ln].decode(errors="replace"))
        return rtyp, data

    def _recvn(self, n):
        buf = b""
        while len(buf) < n:
            c = self.s.recv(n - len(buf))
            if not c: raise IOError("short read")
            buf += c
        return buf

    def _s(self, b):  # 9p string
        return struct.pack("<H", len(b)) + b

    def _version(self):
        body = struct.pack("<I", self.msize) + self._s(b"9P2000")
        _, d = self._rpc(Tversion, body)

    def _attach(self, fid):
        body = struct.pack("<II", fid, NOFID) + self._s(b"agent") + self._s(b"")
        self._rpc(Tattach, body)

    def walk(self, path):
        parts = [p for p in path.strip("/").split("/") if p]
        nf = self._alloc()
        body = struct.pack("<IIH", self.root, nf, len(parts))
        for p in parts:
            body += self._s(p.encode())
        rtyp, d = self._rpc(Twalk, body)
        nqid = struct.unpack("<H", d[:2])[0]
        if nqid != len(parts):
            raise RuntimeError(f"walk stopped at {nqid}/{len(parts)} for {path}")
        return nf

    def open(self, fid, mode=OREAD):
        self._rpc(Topen, struct.pack("<IB", fid, mode))

    def read(self, fid, count=8192):
        out = b""; off = 0
        while True:
            rtyp, d = self._rpc(Tread, struct.pack("<IQI", fid, off, count))
            n = struct.unpack("<I", d[:4])[0]
            if n == 0: break
            chunk = d[4:4+n]; out += chunk; off += n
            if n < count: break
        return out

    def write(self, fid, data):
        rtyp, d = self._rpc(Twrite, struct.pack("<IQI", fid, 0, len(data)) + data)
        return struct.unpack("<I", d[:4])[0]

    def clunk(self, fid):
        try: self._rpc(Tclunk, struct.pack("<I", fid))
        except Exception: pass

    def readfile(self, path):
        f = self.walk(path); self.open(f, OREAD)
        try: return self.read(f)
        finally: self.clunk(f)

    def writefile(self, path, data):
        f = self.walk(path); self.open(f, OWRITE)
        try: return self.write(f, data if isinstance(data, bytes) else data.encode())
        finally: self.clunk(f)

    def ls(self, path):
        f = self.walk(path); self.open(f, OREAD)
        try: data = self.read(f)
        finally: self.clunk(f)
        names = []; i = 0
        while i + 2 <= len(data):
            sz = struct.unpack("<H", data[i:i+2])[0]
            stat = data[i+2:i+2+sz]; i += 2 + sz
            # skip size[2 already consumed] type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8]
            p = 2 + 4 + 13 + 4 + 4 + 4 + 8
            nlen = struct.unpack("<H", stat[p:p+2])[0]
            names.append(stat[p+2:p+2+nlen].decode(errors="replace"))
        return names

if __name__ == "__main__":
    host, port = "127.0.0.1", 7777
    c = Client(host, port)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "tree"
    if cmd == "ls":
        print("\n".join(c.ls(sys.argv[2])))
    elif cmd == "cat":
        sys.stdout.buffer.write(c.readfile(sys.argv[2]))
    elif cmd == "echo":
        n = c.writefile(sys.argv[3], sys.argv[2]); print(f"wrote {n} bytes")
    elif cmd == "tree":
        print("/version:", c.readfile("version").decode(errors="replace").strip())
        print("vehicles/:", c.ls("vehicles"))
        for v in c.ls("vehicles"):
            print(f"  {v}/:", c.ls(f"vehicles/{v}"))
            try: print(f"    state:", c.readfile(f"vehicles/{v}/state").decode(errors="replace").strip()[:400])
            except Exception as e: print("    state err:", e)
            try: print(f"    control:", c.readfile(f"vehicles/{v}/control").decode(errors="replace").strip()[:200])
            except Exception as e: print("    control err:", e)
        try: print("ui/:", c.ls("ui"))
        except Exception as e: print("ui err:", e)
        try: print("attention:", c.readfile("attention").decode(errors="replace").strip()[:300])
        except Exception as e: print("attention err:", e)
