#!/usr/bin/env python3
"""wptrun.py - run web-platform-tests reftests in Charon.

    tools/ref/wptrun.py [-j N] [-o outdir] [--chromium] wptroot path...

Each path (a directory or file under wptroot) is searched for reftests:
pages with <link rel=match href=...> (or rel=mismatch).  The test and its
reference are both rendered by Charon's engine at 800x600, as WPT does,
and compared pixel for pixel, within the test's <meta name=fuzzy>
allowance.  A test that needs script to reach its final state (class
reftest-wait, or any <script> but testharness) is reported as needs-js:
Charon has none, so those are counted apart.

The pages are served over HTTP from wptroot by a server this script
starts, so absolute paths in tests (/fonts/ahem.css, /css/support/...)
resolve as they do in WPT; Charon fetches through webfs.

--chromium also renders each failing test in headless Chromium, for the
triage page: test as Charon, reference as Charon, test as Chromium.

Results: outdir/results.txt (one "status path" line per test),
outdir/summary.txt (per directory), and outdir/index.html, a page of the
failures side by side.
"""
import argparse, html, os, re, shutil, subprocess, sys, threading, time
import functools, http.server, socketserver
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p9img

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
W, H = 800, 600
WPTROOT = None

LINKRE = re.compile(r'<link\b[^>]*>', re.I)
ATTR = lambda name: re.compile(r'\b' + name + r'\s*=\s*("([^"]*)"|\'([^\']*)\'|([^\s>]+))', re.I)
RELRE, HREFRE, NAMERE, CONTENTRE = ATTR('rel'), ATTR('href'), ATTR('name'), ATTR('content')
METARE = re.compile(r'<meta\b[^>]*>', re.I)
SCRIPTRE = re.compile(r'<script\b([^>]*)>', re.I)


def attr(rx, tag):
    m = rx.search(tag)
    if not m:
        return None
    return next(g for g in m.groups()[1:] if g is not None)


def parse(path):
    """(refs, fuzzy, needsjs): refs is [(kind, absolute path)]."""
    try:
        src = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return [], None, False
    refs = []
    for tag in LINKRE.findall(src):
        rel = (attr(RELRE, tag) or '').lower()
        if rel in ('match', 'mismatch'):
            href = attr(HREFRE, tag)
            if href:
                href = href.split('#')[0]
                if href.startswith('/'):
                    refs.append((rel, os.path.normpath(os.path.join(WPTROOT, href[1:]))))
                else:
                    refs.append((rel, os.path.normpath(os.path.join(os.path.dirname(path), href))))
    fuzzy = None
    for tag in METARE.findall(src):
        if (attr(NAMERE, tag) or '').lower() == 'fuzzy':
            fuzzy = attr(CONTENTRE, tag)
    needsjs = 'reftest-wait' in src
    for a in SCRIPTRE.findall(src):
        if 'testharness' not in a and 'reftest-wait' not in a:
            needsjs = True
    return refs, fuzzy, needsjs


def fuzzyrange(spec):
    """(maxdiff range, totalpixels range) from a fuzzy meta."""
    md, tp = (0, 0), (0, 0)
    if not spec:
        return md, tp
    if ':' in spec.split(';')[0] and '=' not in spec.split(';')[0].split(':')[0]:
        spec = spec.split(':', 1)[1]	# "ref.html:..." applies to that ref; good enough
    parts = [p.strip() for p in spec.split(';') if p.strip()]

    def rng(s):
        s = s.split('=', 1)[-1]
        if '-' in s:
            a, b = s.split('-', 1)
            return int(a or 0), int(b)
        return int(s), int(s)
    for i, p in enumerate(parts):
        if p.startswith('maxDifference') or (i == 0 and '=' not in p):
            md = rng(p)
        elif p.startswith('totalPixels') or (i == 1 and '=' not in p):
            tp = rng(p)
    return md, tp


def compare(a, b, fuzzy):
    """(ok, maxdiff, npixels)."""
    if a.shape != b.shape:
        return False, 255, -1
    d = np.abs(a.astype(np.int16) - b.astype(np.int16)).max(axis=2)
    n = int((d > 0).sum())
    mx = int(d.max())
    (mdlo, mdhi), (tplo, tphi) = fuzzyrange(fuzzy)
    if n == 0:
        return True, 0, 0
    return mdlo <= mx <= mdhi and tplo <= n <= tphi, mx, n


def findtests(root, paths):
    tests = []
    for p in paths:
        p = os.path.join(root, p)
        files = [p] if os.path.isfile(p) else [
            os.path.join(d, f) for d, _, fs in os.walk(p) for f in fs]
        for f in sorted(files):
            if not re.search(r'\.(html?|xht|xhtml)$', f):
                continue
            if '/support/' in f or '/reference/' in f or re.search(r'-(ref|notref)\.\w+$', f):
                continue
            refs, fuzzy, js = parse(f)
            if refs:
                tests.append((f, refs, fuzzy, js))
    return tests


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def guess_type(self, path):
        if path.endswith(('.xht', '.xhtml')):
            return 'application/xhtml+xml'
        return super().guess_type(path)

    def do_GET(self):
        # wptserve's ?pipe=status(N): the file, with that status; and
        # its FILE.headers sidecars: the file, with those headers
        m = re.search(r'[?&]pipe=status\((\d+)\)', self.path)
        path = self.translate_path(self.path.split('?')[0])
        hdrs = []
        if os.path.isfile(path + '.headers'):
            with open(path + '.headers') as f:
                hdrs = [l.split(':', 1) for l in f.read().splitlines() if ':' in l]
        if not m and not hdrs:
            return super().do_GET()
        try:
            body = open(path, 'rb').read()
        except OSError:
            return self.send_error(404)
        self.send_response(int(m.group(1)) if m else 200)
        ctype = self.guess_type(path)
        for k, v in hdrs:
            if k.strip().lower() == 'content-type':
                ctype = v.strip()
            else:
                self.send_header(k.strip(), v.strip())
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(root):
    handler = functools.partial(Quiet, directory=root)
    srv = socketserver.ThreadingTCPServer(('127.0.0.1', 0), handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]


def emu():
    for p in ('emu/Linux/o.emu', 'emu/MacOSX/o.emu'):
        if os.path.exists(os.path.join(ROOT, p)):
            return os.path.join(ROOT, p)
    sys.exit('build the emulator first')


def renderbatch(jobs, workdir, shard):
    """Render [(url, imgpath-in-emu)] in one emu; returns {img: error or None}.
    A crash or a page that hangs ends the emu: the rest go to a new one."""
    results = {}
    retried = set()
    todo = list(jobs)
    while todo:
        lst = os.path.join(workdir, 'list.%d' % shard)
        with open(lst, 'w') as f:
            for u, o in todo:
                f.write('%s %s\n' % (u, o))
        log = os.path.join(workdir, 'log.%d' % shard)
        cmd = ['setsid', '-w', emu(), '-c1', '-pheap=512m', '-pmain=512m', '-pimage=512m',
               '-r' + ROOT, '/dis/tests/charonbatch.dis', str(W), str(H), '/' + os.path.relpath(lst, ROOT)]
        with open(log, 'w') as lf:
            p = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        done, last, seen = 0, time.time(), 0
        while p.poll() is None:
            time.sleep(0.2)
            lines = open(log, errors='replace').read().splitlines()
            got = [l for l in lines if l.startswith(('ok ', 'fail '))]
            if len(got) != seen:
                seen, last = len(got), time.time()
            elif time.time() - last > 30:
                p.kill()
                subprocess.run(['pkill', '-9', '-g', str(p.pid)], capture_output=True)
                break
        lines = open(log, errors='replace').read().splitlines()
        got = [l for l in lines if l.startswith(('ok ', 'fail '))]
        for l in got:
            st, out, *rest = l.split(' ', 2)
            results[out] = None if st == 'ok' else (rest[0] if rest else 'fail')
        n = len(got)
        if n < len(todo):	# the next one crashed or hung
            u, o = todo[n]
            tail = '\n'.join(l for l in lines[-15:] if 'fsqid' not in l)
            if (u, o) in retried:
                results[o] = 'crash or hang'
                with open(os.path.join(workdir, 'crashes.txt'), 'a') as cf:
                    cf.write('== %s\n%s\n' % (u, tail))
                todo = todo[n+1:]
            else:
                # once more, alone in a fresh emu: a loaded machine can
                # make a page miss its time
                retried.add((u, o))
                todo = [todo[n]] + todo[n+1:]
        else:
            todo = []
    return results


def chromium(url, png):
    subprocess.run(['node', os.path.join(ROOT, 'tools/ref/shot.js'), url, png, str(W), str(H)],
                   capture_output=True, timeout=60)


def png(a, path):
    from PIL import Image
    Image.fromarray(a).save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-j', type=int, default=4)
    ap.add_argument('-o', default=os.path.join(ROOT, 'tmp/wpt'))
    ap.add_argument('--chromium', action='store_true')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--keep', type=int, default=1500, help='failures to keep pictures of')
    ap.add_argument('root')
    ap.add_argument('paths', nargs='+')
    a = ap.parse_args()
    global WPTROOT
    root = WPTROOT = os.path.abspath(a.root)
    out = os.path.abspath(a.o)
    if not out.startswith(ROOT + '/'):
        sys.exit('outdir must be inside %s (emu writes there)' % ROOT)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(os.path.join(out, 'img'))
    tests = findtests(root, a.paths)
    if a.limit:
        tests = tests[:a.limit]
    port = serve(root)
    url = lambda f: 'http://127.0.0.1:%d/%s' % (port, os.path.relpath(f, root))
    os.makedirs(os.path.join(out, 'png'), exist_ok=True)
    rows, fails = [], []
    t0 = time.time()
    # In chunks: render, judge, keep pictures of the failures, delete the
    # raw images (800x600x4 bytes each) before the next chunk.
    CHUNK = 200
    for c0 in range(0, len(tests), CHUNK):
        chunk = tests[c0:c0+CHUNK]
        pages = {}
        for t, refs, _, _ in chunk:
            for f in [t] + [r for _, r in refs]:
                if f not in pages and os.path.exists(f):
                    pages[f] = '/' + os.path.relpath(os.path.join(out, 'img', '%05d.img' % len(pages)), ROOT)
        jobs = [(url(f), o) for f, o in pages.items()]
        results = {}
        threads = []
        for i in range(a.j):
            th = threading.Thread(target=lambda i=i: results.update(renderbatch(jobs[i::a.j], out, i)))
            th.start()
            threads.append(th)
        for th in threads:
            th.join()
        img = {}

        def load(f):
            o = pages.get(f)
            if o is None:
                return None
            if f not in img:
                img[f] = None
                if results.get(o) is None and os.path.exists(ROOT + o):
                    try:
                        img[f] = p9img.load(ROOT + o)
                    except Exception:
                        pass
            return img[f]
        for t, refs, fuzzy, js in chunk:
            status, detail = 'PASS', ''
            ti = load(t)
            if ti is None:
                status, detail = 'ERROR', results.get(pages.get(t)) or 'no image'
            for kind, r in refs:
                if status != 'PASS':
                    break
                if not os.path.exists(r):
                    status, detail = 'ERROR', 'missing reference ' + os.path.relpath(r, root)
                    break
                ri = load(r)
                if ri is None:
                    status, detail = 'ERROR', 'ref: ' + (results.get(pages.get(r)) or 'no image')
                    break
                ok, mx, n = compare(ti, ri, fuzzy)
                if kind == 'mismatch':
                    ok = n != 0
                if not ok:
                    status, detail = 'FAIL', '%s maxdiff=%d pixels=%d' % (kind, mx, n)
            if status == 'PASS' and ti is not None and (ti == ti[0, 0]).all():
                detail = 'blank'	# a pass that shows nothing proves little
            if js:
                status = 'NEEDSJS'	# a pass without the script would be luck'
            rel = os.path.relpath(t, root)
            rows.append((status, rel, detail))
            if status in ('FAIL', 'ERROR') and len(fails) < a.keep:
                k = len(fails)
                names = []
                for j, f in enumerate([t, refs[0][1]]):
                    im = load(f)
                    if im is None:
                        names.append(None)
                        continue
                    pn = 'png/%d-%d.png' % (k, j)
                    from PIL import Image
                    Image.fromarray(im).resize((400, 300)).save(os.path.join(out, pn), optimize=True)
                    names.append(pn)
                fails.append((t, refs, rel, detail, names))
        shutil.rmtree(os.path.join(out, 'img'), ignore_errors=True)
        os.makedirs(os.path.join(out, 'img'))
        done = len(rows)
        npass = sum(1 for r in rows if r[0] == 'PASS')
        print('%5d/%d tests, %d pass, %.0fs' % (done, len(tests), npass, time.time() - t0), file=sys.stderr)

    with open(os.path.join(out, 'results.txt'), 'w') as f:
        for s, r, d in rows:
            f.write('%s %s %s\n' % (s, r, d))
    bydir = {}
    for s, r, d in rows:
        k = '/'.join(r.split('/')[:2])
        bydir.setdefault(k, {}).setdefault(s, 0)
        bydir[k][s] += 1
    lines = []
    tot = {}
    for k in sorted(bydir):
        c = bydir[k]
        for s, n in c.items():
            tot[s] = tot.get(s, 0) + n
        judged = c.get('PASS', 0) + c.get('FAIL', 0) + c.get('ERROR', 0)
        lines.append('%-28s pass %4d / %4d (%5.1f%%)  needs-js %4d  error %3d' % (
            k, c.get('PASS', 0), judged, 100.0 * c.get('PASS', 0) / max(judged, 1),
            c.get('NEEDSJS', 0), c.get('ERROR', 0)))
    judged = tot.get('PASS', 0) + tot.get('FAIL', 0) + tot.get('ERROR', 0)
    lines.append('%-28s pass %4d / %4d (%5.1f%%)  needs-js %4d  error %3d' % (
        'TOTAL', tot.get('PASS', 0), judged, 100.0 * tot.get('PASS', 0) / max(judged, 1),
        tot.get('NEEDSJS', 0), tot.get('ERROR', 0)))
    open(os.path.join(out, 'summary.txt'), 'w').write('\n'.join(lines) + '\n')
    print('\n'.join(lines))

    # the triage page: test (Charon) | reference (Charon) [| test (Chromium)]
    h = ['<!doctype html><meta charset=utf-8><title>WPT failures</title>',
         '<style>body{font:13px sans-serif} img{width:400px;border:1px solid #888} td{vertical-align:top}</style>',
         '<table><tr><th>test<th>Charon<th>reference (Charon)' + ('<th>Chromium' if a.chromium else '')]
    for i, (t, refs, rel, detail, names) in enumerate(fails):
        cells = ['<img src="%s">' % n if n else '(none)' for n in names]
        if a.chromium:
            pn = 'png/%d-c.png' % i
            chromium(url(t), os.path.join(out, pn))
            cells.append('<img src="%s">' % pn)
        h.append('<tr><td>%s<br>%s<td>%s' % (html.escape(rel), html.escape(detail), '<td>'.join(cells)))
    h.append('</table>')
    open(os.path.join(out, 'index.html'), 'w').write('\n'.join(h))


if __name__ == '__main__':
    main()
