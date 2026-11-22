#!/usr/bin/env python3
# A scripted TLS 1.2 server for tests/host/x509_chain_test.sh: it sends
# ServerHello, a Certificate message holding the DER files given, what
# the mode says, and ServerHelloDone, and then says what the client did.
#
#	fake_tls12.py port mode key.pem cert.der ...
#
# mode	ecdsa	ECDHE: a ServerKeyExchange signed with key.pem (ECDSA P-256)
#	pss1	ECDHE: a ServerKeyExchange with a one-byte RSA-PSS signature
#	rsakex	RSA key exchange: no ServerKeyExchange
#
# Everything here reaches the client before anything has said who the
# server is.  The last line printed is CLIENT-CONTINUED (it took the
# certificate and sent its key exchange) or CLIENT-STOPPED.
import socket, struct, sys, os
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes, serialization

port, mode, keyfile = int(sys.argv[1]), sys.argv[2], sys.argv[3]
certs = [open(f, 'rb').read() for f in sys.argv[4:]]

def recvall(c, n):
    out = b''
    while len(out) < n:
        ch = c.recv(n - len(out))
        if not ch:
            break
        out += ch
    return out
def hs(t, body): return bytes([t]) + len(body).to_bytes(3, 'big') + body
def rec(b): return b'\x16\x03\x03' + struct.pack('>H', len(b)) + b

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', port))
srv.listen(1)
print('listening', flush=True)
srv.settimeout(60)
conn, _ = srv.accept()
conn.settimeout(20)
hdr = recvall(conn, 5)
body = recvall(conn, struct.unpack('>H', hdr[3:5])[0])
client_random = body[6:38]
sid = body[39:39 + body[38]]
server_random = os.urandom(24) + b'scripted'
suite = {'ecdsa': b'\xc0\x2b', 'pss1': b'\xc0\x2f', 'rsakex': b'\x00\x9c'}[mode]
msgs = hs(2, b'\x03\x03' + server_random + bytes([len(sid)]) + sid + suite + b'\x00')
cl = b''.join(len(c).to_bytes(3, 'big') + c for c in certs)
msgs += hs(11, len(cl).to_bytes(3, 'big') + cl)
if mode != 'rsakex':
    eph = ec.generate_private_key(ec.SECP256R1())
    pt = eph.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    params = b'\x03\x00\x17' + bytes([len(pt)]) + pt
    if mode == 'ecdsa':
        key = serialization.load_pem_private_key(open(keyfile, 'rb').read(), None)
        scheme, sig = b'\x04\x03', key.sign(client_random + server_random + params, ec.ECDSA(hashes.SHA256()))
    else:
        scheme, sig = b'\x08\x04', b'\x01'
    msgs += hs(12, params + scheme + struct.pack('>H', len(sig)) + sig)
msgs += hs(14, b'')
conn.sendall(rec(msgs))
try:
    d = conn.recv(5)
except Exception as e:
    d = b''
if len(d) == 5 and d[0] == 0x16:
    print('CLIENT-CONTINUED', flush=True)
else:
    print('CLIENT-STOPPED', d.hex(), flush=True)
conn.close()
