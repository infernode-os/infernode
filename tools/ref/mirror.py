#!/usr/bin/env python3
"""mirror.py - a caching mirror of live sites, for reference comparisons.

    tools/ref/mirror.py [-p port] [-d cachedir] [--offline]

http://127.0.0.1:PORT/<host>/<path> is https://<host>/<path>, fetched on
the host (through whatever proxy the host uses) the first time and from
the cache after that, so a page and everything it loads stays fixed
while two browsers render it.  Absolute and protocol-relative URLs in
HTML and CSS are rewritten to point back at the mirror, so neither
browser reaches the network itself: Charon fetches from here through
webfs like from any http server.

--offline serves only what is cached.
"""
import argparse, gzip, hashlib, http.server, os, re, socketserver, sys, urllib.request, zlib

UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36'
TEXTY = ('text/html', 'text/css', 'application/xhtml+xml', 'image/svg+xml')


def cachepath(d, url):
    h = hashlib.sha1(url.encode()).hexdigest()
    return os.path.join(d, h[:2], h)


class Mirror(http.server.BaseHTTPRequestHandler):
    cache = None
    offline = False
    port = 0

    def log_message(self, fmt, *a):
        sys.stderr.write('mirror: ' + (fmt % a) + '\n')

    def do_GET(self):
        path = self.path.lstrip('/')
        if '.' not in path.split('/')[0]:
            # a root-relative URL that escaped rewriting: the referring page's host
            ref = self.headers.get('Referer', '')
            m = re.match(r'http://127\.0\.0\.1:\d+/([^/]+)/', ref)
            if m:
                path = m.group(1) + '/' + path
        if '/' not in path:
            path += '/'
        url = 'https://' + path
        status, ctype, body = self.fetch(url)
        if ctype.split(';')[0].strip() in TEXTY:
            body = self.rewrite(body, path.split('/')[0])
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def fetch(self, url):
        cp = cachepath(self.cache, url)
        if os.path.exists(cp):
            with open(cp, 'rb') as f:
                status = int(f.readline())
                ctype = f.readline().decode().strip()
                return status, ctype, f.read()
        if self.offline:
            return 404, 'text/plain', b'not cached\n'
        req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Encoding': 'gzip, deflate'})
        try:
            r = urllib.request.urlopen(req, timeout=30)
            status, ctype, body = r.status, r.headers.get('Content-Type', 'application/octet-stream'), r.read()
            enc = r.headers.get('Content-Encoding', '')
        except urllib.error.HTTPError as e:
            status, ctype, body = e.code, e.headers.get('Content-Type', 'text/plain'), e.read()
            enc = e.headers.get('Content-Encoding', '')
        except Exception as e:
            return 502, 'text/plain', ('mirror: %s\n' % e).encode()
        if enc == 'gzip':
            body = gzip.decompress(body)
        elif enc == 'deflate':
            body = zlib.decompress(body)
        os.makedirs(os.path.dirname(cp), exist_ok=True)
        with open(cp, 'wb') as f:
            f.write(b'%d\n%s\n' % (status, ctype.encode()))
            f.write(body)
        return status, ctype, body

    def rewrite(self, body, host):
        here = 'http://127.0.0.1:%d/' % self.port
        s = body.decode('utf-8', errors='surrogateescape')
        # root-relative references keep their site: /x on host is /host/x here
        s = re.sub(r'((?:href|src|action|poster|data)\s*=\s*["\']?)/(?!/)', lambda m: m.group(1) + '/' + host + '/', s, flags=re.I)
        s = re.sub(r'(url\(\s*["\']?)/(?!/)', lambda m: m.group(1) + '/' + host + '/', s, flags=re.I)
        s = re.sub(r'(srcset\s*=\s*["\'])([^"\']*)', lambda m: m.group(1) + re.sub(r'(^|,\s*)/(?!/)', lambda n: n.group(1) + '/' + host + '/', m.group(2)), s, flags=re.I)
        # not www.w3.org: those are namespace names and DTDs, not fetches
        s = re.sub(r'https?://(?!www\.w3\.org)([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?=[/"\'\s)?#]|$)', lambda m: here + m.group(1), s)
        s = re.sub(r'(["\'(=\s])//([A-Za-z0-9.-]+\.[A-Za-z]{2,})/', lambda m: m.group(1) + here + m.group(2) + '/', s)
        return s.encode('utf-8', errors='surrogateescape')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-p', type=int, default=8780)
    ap.add_argument('-d', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tmp', 'mirror'))
    ap.add_argument('--offline', action='store_true')
    a = ap.parse_args()
    Mirror.cache = os.path.abspath(a.d)
    Mirror.offline = a.offline
    Mirror.port = a.p
    os.makedirs(Mirror.cache, exist_ok=True)
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    srv = socketserver.ThreadingTCPServer(('127.0.0.1', a.p), Mirror)
    srv.daemon_threads = True
    print('mirror on http://127.0.0.1:%d/<host>/<path>, cache %s' % (a.p, Mirror.cache), file=sys.stderr)
    srv.serve_forever()


if __name__ == '__main__':
    main()
