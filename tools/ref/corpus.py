#!/usr/bin/env python3
"""corpus.py - Charon on real sites that need no network: pinned, local.

    tools/ref/corpus.py fetch DIR
    tools/ref/corpus.py ref DIR             (Chromium: the references)
    tools/ref/corpus.py run DIR OUT         (Charon: OUT/scores.txt, pictures)
    tools/ref/corpus.py gate OUT [--update]

The sites are tools/ref/corpus/sources: documentation and project sites
published as files (Python's docs, Rust's book and standard library,
ECMA-262, Bootstrap's site), each fetched by a hash (an archive's
SHA-256, a git commit) into DIR.  No site is reached once they are
fetched, so nothing can refuse the run or change under it: each is
served from this machine, at a root of its own, on the loopback.

The pages are tools/ref/corpus/pages, each rendered at SIZES.  `ref`
renders them in headless Chromium (tools/ref/shot.js: scripts off, its
fonts Charon's, tools/ref/fonts.conf) and keeps only what the score
uses, the picture averaged over 8px cells, as a small PNG in
tools/ref/baseline/corpus/: CI then needs no Chromium, and the reference
does not move with Chromium's releases.  Run it again only when the
sources or pages change.

`run` renders them in Charon (tools/charon-shot.sh) and scores each: the
share of cells whose colour differs from the reference's by more than
24 in a channel, compare.py's "layout" (it forgives glyph rasterisation,
not boxes in the wrong place, missing backgrounds, or text that wraps
differently).  0 is the same.  OUT gets scores.txt, a line per page and
size, and index.html with Charon's picture beside the reference's cells.

`gate` holds the scores to tools/ref/baseline/corpus-scores.txt: a page
whose score grows by more than SLACK fails; what improves is reported,
and --update moves the baseline to the run, in the commit that earns it.
"""
import argparse, hashlib, html, os, shutil, subprocess, sys, tarfile, threading, functools
import http.server, socketserver
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
HERE = os.path.join(ROOT, 'tools', 'ref')
SOURCES = os.path.join(HERE, 'corpus', 'sources')
PAGES = os.path.join(HERE, 'corpus', 'pages')
REFDIR = os.path.join(HERE, 'baseline', 'corpus')
BASELINE = os.path.join(HERE, 'baseline', 'corpus-scores.txt')
SIZES = [('laptop', 1280, 800), ('phone', 390, 844)]
CELL = 8
THRESH = 24	# a cell differs when a channel's mean differs by more than this (compare.py's)
SLACK = 0.01	# how much a page's score may grow before the gate fails


def readlines(path):
    for line in open(path):
        line = line.split('#')[0].strip()
        if line:
            yield line.split()


def sources():
    out = []
    for f in readlines(SOURCES):
        name, kind, url, pin = f[:4]
        opts = dict(o.split('=', 1) for o in f[4:])
        out.append((name, kind, url, pin, opts))
    return out


def pages():
    return [(f[0], f[1]) for f in readlines(PAGES)]


def slug(site, path, size):
    return '%s/%s.%s' % (site, path.replace('/', '_'), size)


# ---- fetch ----

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def fetcharchive(d, name, url, pin, opts):
    site = os.path.join(d, name)
    stamp = os.path.join(site, '.pin')
    if os.path.exists(stamp) and open(stamp).read() == pin:
        return
    algo, want = pin.split(':', 1)
    if algo != 'sha256':
        sys.exit('corpus: %s: only sha256 pins' % name)
    dl = os.path.join(d, '.dl', name + '.archive')
    os.makedirs(os.path.dirname(dl), exist_ok=True)
    if not os.path.exists(dl) or sha256(dl) != want:
        subprocess.run(['curl', '-sSfL', '--max-time', '1800', '-o', dl, url], check=True)
    got = sha256(dl)
    if got != want:
        os.remove(dl)
        sys.exit('corpus: %s: %s has sha256 %s, not the pinned %s' % (name, url, got, want))
    strip = opts.get('strip', '').strip('/')
    only = [p for p in opts.get('only', '').split(',') if p]
    shutil.rmtree(site, ignore_errors=True)
    os.makedirs(site)
    with tarfile.open(dl) as tf:
        keep = []
        for m in tf.getmembers():
            n = m.name
            if strip:
                if n != strip and not n.startswith(strip + '/'):
                    continue
                n = n[len(strip) + 1:]
            if not n:
                continue
            if only and not any(n == p or (p.endswith('/') and n.startswith(p)) or p.startswith(n + '/') for p in only):
                continue
            m.name = n
            keep.append(m)
        # filter='data': no absolute paths, no links out of the site, no devices
        tf.extractall(site, members=keep, filter='data')
    open(stamp, 'w').write(pin)


def fetchgit(d, name, url, commit, opts):
    site = os.path.join(d, name)
    os.makedirs(site, exist_ok=True)
    git = lambda *a, **k: subprocess.run(['git', '-C', site] + list(a), check=True, **k)
    if not os.path.isdir(os.path.join(site, '.git')):
        git('init', '-q')
    git('config', 'core.sparseCheckout', 'true')
    with open(os.path.join(site, '.git', 'info', 'sparse-checkout'), 'w') as f:
        for p in opts.get('paths', '').split(','):
            if p:
                f.write(p + '\n')
    head = subprocess.run(['git', '-C', site, 'rev-parse', '-q', '--verify', 'HEAD'], capture_output=True, text=True).stdout.strip()
    if head != commit:
        git('fetch', '-q', '--depth', '1', '--filter=blob:none', url, commit)
        git('-c', 'advice.detachedHead=false', 'checkout', '-q', commit)
    else:
        git('read-tree', '-mu', 'HEAD')
    head = subprocess.run(['git', '-C', site, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    if head != commit:
        sys.exit('corpus: %s: checked out %s, not %s' % (name, head, commit))


def fetch(d):
    for name, kind, url, pin, opts in sources():
        if kind == 'archive':
            fetcharchive(d, name, url, pin, opts)
        elif kind == 'git':
            fetchgit(d, name, url, pin, opts)
        else:
            sys.exit('corpus: %s: unknown kind %s' % (name, kind))
        print('corpus: %s %s' % (name, pin))
    for site, path in pages():
        if not os.path.isfile(os.path.join(d, site, path)):
            sys.exit('corpus: %s has no %s' % (site, path))


# ---- serving ----

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


def serve(d):
    """each site at the root of a server of its own; {site: base url}"""
    bases = {}
    for name, *_ in sources():
        h = functools.partial(Quiet, directory=os.path.join(d, name))
        s = socketserver.ThreadingTCPServer(('127.0.0.1', 0), h)
        s.daemon_threads = True
        threading.Thread(target=s.serve_forever, daemon=True).start()
        bases[name] = 'http://127.0.0.1:%d/' % s.server_address[1]
    return bases


# ---- pictures ----

def cells(a):
    h, w = a.shape[0] // CELL * CELL, a.shape[1] // CELL * CELL
    return a[:h, :w].reshape(h // CELL, CELL, w // CELL, CELL, 3).mean(axis=(1, 3))


def load(png, w, h):
    a = np.asarray(Image.open(png).convert('RGB'))
    o = np.full((h, w, 3), 255, np.uint8)
    o[:min(h, a.shape[0]), :min(w, a.shape[1])] = a[:h, :w]
    return o


def ref(d):
    bases = serve(d)
    tmp = os.path.join(ROOT, 'tmp', 'corpus-ref')
    os.makedirs(tmp, exist_ok=True)
    for site, path in pages():
        for size, w, h in SIZES:
            png = os.path.join(tmp, 'shot.png')
            r = subprocess.run(['node', os.path.join(HERE, 'shot.js'), bases[site] + path, png, str(w), str(h)],
                               capture_output=True, text=True, timeout=180)
            if not os.path.exists(png):
                sys.exit('corpus: Chromium made no picture of %s %s: %s' % (site, path, r.stderr))
            c = np.clip(np.rint(cells(load(png, w, h))), 0, 255).astype(np.uint8)
            out = os.path.join(REFDIR, slug(site, path, size) + '.png')
            os.makedirs(os.path.dirname(out), exist_ok=True)
            Image.fromarray(c).save(out, optimize=True)
            os.remove(png)
            print('ref %s %s %s' % (site, path, size))


def run(d, out):
    bases = serve(d)
    os.makedirs(out, exist_ok=True)
    rows, lines = [], []
    for site, path in pages():
        for size, w, h in SIZES:
            s = slug(site, path, size)
            refpng = os.path.join(REFDIR, s + '.png')
            png = os.path.join(out, s + '.png')
            os.makedirs(os.path.dirname(png), exist_ok=True)
            r = subprocess.run([os.path.join(ROOT, 'tools', 'charon-shot.sh'), bases[site] + path, png, '%dx%d' % (w, h)],
                               capture_output=True, text=True, timeout=600)
            if not os.path.exists(png):
                score = 1.0
                note = 'no picture: ' + (r.stderr.strip().splitlines() or ['?'])[-1]
            else:
                want = np.asarray(Image.open(refpng).convert('RGB')).astype(float)
                got = cells(load(png, w, h))
                hh, ww = min(want.shape[0], got.shape[0]), min(want.shape[1], got.shape[1])
                score = float((np.abs(want[:hh, :ww] - got[:hh, :ww]).max(axis=2) > THRESH).mean())
                note = ''
            lines.append('%.4f %s %s %s%s' % (score, site, path, size, ' # ' + note if note else ''))
            rows.append((score, site, path, size, s))
            print(lines[-1], flush=True)
    open(os.path.join(out, 'scores.txt'), 'w').write('\n'.join(lines) + '\n')
    with open(os.path.join(out, 'index.html'), 'w') as f:
        f.write('<!doctype html><meta charset=utf-8><title>corpus</title><style>img{border:1px solid #888;vertical-align:top;image-rendering:pixelated}</style>\n')
        for score, site, path, size, s in sorted(rows, reverse=True):
            refpng = os.path.relpath(os.path.join(REFDIR, s + '.png'), out)
            f.write('<h3>%.3f %s %s %s</h3><img src="%s" width=%d> <img src="%s.png" width=%d>\n'
                    % (score, html.escape(site), html.escape(path), size, html.escape(refpng), 480, html.escape(s), 480))
    print('corpus: mean %.4f over %d' % (sum(r[0] for r in rows) / max(1, len(rows)), len(rows)))


def scores(path):
    out = {}
    for f in readlines(path):
        out[(f[1], f[2], f[3])] = float(f[0])
    return out


def gate(out, update):
    now = scores(os.path.join(out, 'scores.txt'))
    if update:
        shutil.copy(os.path.join(out, 'scores.txt'), BASELINE)
        print('corpus: baseline updated')
        return 0
    base = scores(BASELINE)
    worse, better = [], []
    for k, b in sorted(base.items()):
        n = now.get(k)
        if n is None:
            worse.append((k, b, None))
        elif n > b + SLACK:
            worse.append((k, b, n))
        elif n < b - SLACK:
            better.append((k, b, n))
    for k, b, n in worse:
        print('WORSE %s %s %s: %.4f -> %s' % (k[0], k[1], k[2], b, 'missing' if n is None else '%.4f' % n))
    for k, b, n in better:
        print('BETTER %s %s %s: %.4f -> %.4f' % (k[0], k[1], k[2], b, n))
    mb = sum(base.values()) / max(1, len(base))
    mn = sum(now.values()) / max(1, len(now))
    print('corpus: mean %.4f -> %.4f; %d worse, %d better' % (mb, mn, len(worse), len(better)))
    if worse:
        print('corpus: FAIL: a page is further from Chromium than the baseline (OUT/index.html shows it)')
        return 1
    if better:
        print('corpus: move the baseline with --update in the commit that earns it')
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['fetch', 'ref', 'run', 'gate'])
    ap.add_argument('dir')
    ap.add_argument('out', nargs='?')
    ap.add_argument('--update', action='store_true')
    a = ap.parse_args()
    if a.cmd == 'fetch':
        fetch(a.dir)
    elif a.cmd == 'ref':
        ref(a.dir)
    elif a.cmd == 'run':
        run(a.dir, a.out or os.path.join(ROOT, 'tmp', 'corpus'))
    else:
        return gate(a.dir, a.update)
    return 0


if __name__ == '__main__':
    sys.exit(main())
