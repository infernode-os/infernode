#!/usr/bin/env python3
# fake_remote.py DIR
#
# Builds the repositories tests/host/git_tool_test.sh hands to the agent's
# git tool, with no git on the host (objects are zlib and SHA-1), and then
# serves two remotes for them over git's smart HTTP on 127.0.0.1, writing
# the port to DIR/port once it listens.
#
# DIR/repo: one commit (a.txt, sub/x.txt, sub/y.txt, src/a.txt) on master,
# its files in the work tree, and three branches a hostile remote could
# have left by a fetch, each a child of that commit:
#   evil       its tree has an entry ".." (a tree holding ESCAPED-DOTDOT.txt)
#   evilgit    its tree has an entry ".GIT" (a tree holding config)
#   evilslash  its tree has a file named "../ESCAPED-SLASH.txt"
# DIR/repo3: that commit and its files, and nothing else.
# DIR/repo2: HEAD names a branch with no commit; a branch "other" whose
# commit has a.txt, and another a.txt, not committed, in the work tree.
#
# The remotes (both DIR/repo's):
#   origin  http://user:SEKRET-TOKEN@127.0.0.1:PORT/r.git
#           master as it is, and a branch "feature", one commit ahead
#           (b.txt), whose pack is sent with a line of progress text
#   bad     http://127.0.0.1:PORT/bad.git
#           the same, and a branch named refs/heads/../../../../ESCAPED-REF
import hashlib, os, sys, zlib
from http.server import BaseHTTPRequestHandler, HTTPServer

D = sys.argv[1]
WHO = b'T <t@example.invalid> 1700000000 +0000'
PROGRESS = b'PROGRESS-TEXT-FROM-THE-REMOTE\n'
objs = {}

def obj(kind, body):
    data = kind.encode() + b' ' + str(len(body)).encode() + b'\0' + body
    h = hashlib.sha1(data).hexdigest()
    objs[h] = (kind, body)
    return h

def tree(entries):
    # entries: (mode, name, hash); git orders them by name, a tree's as name + "/"
    key = lambda e: e[1] + (b'/' if e[0] == b'40000' else b'')
    return obj('tree', b''.join(m + b' ' + n + b'\0' + bytes.fromhex(h) for m, n, h in sorted(entries, key=key)))

def commit(t, parent, msg):
    s = b'tree ' + t.encode() + b'\n'
    if parent:
        s += b'parent ' + parent.encode() + b'\n'
    return obj('commit', s + b'author ' + WHO + b'\ncommitter ' + WHO + b'\n\n' + msg + b'\n')

def store(gitdir, hashes):
    for h in hashes:
        kind, body = objs[h]
        d = os.path.join(gitdir, 'objects', h[:2])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, h[2:]), 'wb') as f:
            f.write(zlib.compress(kind.encode() + b' ' + str(len(body)).encode() + b'\0' + body))

def put(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)

def mkgit(gitdir, head, refs, config=b''):
    for d in ('objects/pack', 'refs/heads', 'refs/tags', 'refs/remotes'):
        os.makedirs(os.path.join(gitdir, d), exist_ok=True)
    put(os.path.join(gitdir, 'HEAD'), b'ref: refs/heads/' + head + b'\n')
    put(os.path.join(gitdir, 'config'), b'[core]\n\trepositoryformatversion = 0\n\tbare = false\n' + config)
    for name, h in refs.items():
        put(os.path.join(gitdir, 'refs/heads', name), h.encode() + b'\n')

F644, DIR = b'100644', b'40000'
files = {'a.txt': b'one\n', 'sub/x.txt': b'x\n', 'sub/y.txt': b'y\n', 'src/a.txt': b'a\n'}
ba = obj('blob', files['a.txt'])
sub = tree([(F644, b'x.txt', obj('blob', b'x\n')), (F644, b'y.txt', obj('blob', b'y\n'))])
src = tree([(F644, b'a.txt', obj('blob', b'a\n'))])
base = [(F644, b'a.txt', ba), (DIR, b'sub', sub), (DIR, b'src', src)]
t1 = tree(base)
c1 = commit(t1, None, b'first')
local = set(objs)

esc = obj('blob', b'written outside the work tree\n')
cfg = obj('blob', b'[remote "origin"]\n\turl = http://127.0.0.1:1/REPLACED-BY-A-TREE\n')
cevil = commit(tree(base + [(DIR, b'..', tree([(F644, b'ESCAPED-DOTDOT.txt', esc)]))]), c1, b'evil')
cevilgit = commit(tree(base + [(DIR, b'.GIT', tree([(F644, b'config', cfg)]))]), c1, b'evilgit')
cevilslash = commit(tree(base + [(F644, b'../ESCAPED-SLASH.txt', esc)]), c1, b'evilslash')
local = set(objs)

# what only the remote has: "feature", one commit ahead
t2 = tree(base + [(F644, b'b.txt', obj('blob', b'two\n'))])
c2 = commit(t2, c1, b'second')
remote_only = [h for h in objs if h not in local]

def pack(hashes):
    num = {'commit': 1, 'tree': 2, 'blob': 3}
    out = b'PACK' + (2).to_bytes(4, 'big') + len(hashes).to_bytes(4, 'big')
    for h in hashes:
        kind, body = objs[h]
        n = len(body)
        b = (num[kind] << 4) | (n & 15)
        n >>= 4
        hdr = b''
        while n:
            hdr += bytes([b | 0x80])
            b = n & 0x7f
            n >>= 7
        out += hdr + bytes([b]) + zlib.compress(body)
    return out + hashlib.sha1(out).digest()

def pkt(b):
    return ('%04x' % (len(b) + 4)).encode() + b

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def answer(self, ctype, body):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if 'info/refs' not in self.path:
            self.send_error(404)
            return
        refs = [(c1, b'HEAD'), (c2, b'refs/heads/feature'), (c1, b'refs/heads/master')]
        if self.path.startswith('/bad.git/'):
            refs.append((c2, b'refs/heads/../../../../ESCAPED-REF'))
        body = pkt(b'# service=git-upload-pack\n') + b'0000'
        first = True
        for h, name in refs:
            line = h.encode() + b' ' + name
            if first:
                line += b'\0side-band-64k ofs-delta'
                first = False
            body += pkt(line + b'\n')
        self.answer('application/x-git-upload-pack-advertisement', body + b'0000')
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        body = pkt(b'NAK\n') + pkt(b'\x02' + PROGRESS) + pkt(b'\x01' + pack(remote_only)) + b'0000'
        self.answer('application/x-git-upload-pack-result', body)

srv = HTTPServer(('127.0.0.1', 0), H)
port = srv.server_address[1]

repo = os.path.join(D, 'repo')
conf = ('[remote "origin"]\n\turl = http://user:SEKRET-TOKEN@127.0.0.1:%d/r.git\n'
        '[remote "bad"]\n\turl = http://127.0.0.1:%d/bad.git\n' % (port, port)).encode()
mkgit(os.path.join(repo, '.git'), b'master',
      {'master': c1, 'evil': cevil, 'evilgit': cevilgit, 'evilslash': cevilslash}, conf)
store(os.path.join(repo, '.git'), local)
for name, data in files.items():
    put(os.path.join(repo, name), data)

# DIR/repo3: the first commit and its files alone
repo3 = os.path.join(D, 'repo3')
mkgit(os.path.join(repo3, '.git'), b'master', {'master': c1})
store(os.path.join(repo3, '.git'), local)
for name, data in files.items():
    put(os.path.join(repo3, name), data)

repo2 = os.path.join(D, 'repo2')
mkgit(os.path.join(repo2, '.git'), b'unborn', {'other': c1})
store(os.path.join(repo2, '.git'), local)
put(os.path.join(repo2, 'a.txt'), b'not committed anywhere\n')

with open(os.path.join(D, 'port'), 'w') as f:
    f.write(str(port))
srv.serve_forever()
