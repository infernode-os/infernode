#!/usr/bin/env python3
"""compare.py - render pages in Chromium and Charon, side by side.

    tools/ref/compare.py [-W width] [-H height] [--full] -o outdir url...
    tools/ref/compare.py --sizes standard [--full] -o outdir url...

For each URL: Chromium's rendering (scripts off, as Charon has none),
Charon's, and a difference image, side by side in outdir/<n>.png, with
scores in outdir/scores.txt and a page of them all in outdir/index.html.

Scores: "exact" is the share of pixels that differ visibly; "layout" is
the share that differ once both images are averaged over 8px cells,
which forgives glyph rasterisation but not boxes in the wrong place,
missing backgrounds, or text that wraps differently.  0 is identical.

--sizes standard renders each URL at every one of the standard sizes
(SIZES: a phone, Lucifer's presentation area, a narrow window, a
laptop, a desktop), into outdir/<size>/, with every score in
outdir/sizes.txt: a layout that breaks at one width shows there.  The
sites checked are tools/ref/sites.txt.

Charon renders through tools/charon-shot.sh, Chromium through
tools/ref/shot.js.  Serve live sites through tools/ref/mirror.py so both
see the same bytes.
"""
import argparse, html, os, subprocess, sys
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

# The widths a layout must hold at: what pages are checked against.
SIZES = [
    ('phone', 390, 844),
    ('lucifer', 560, 700),	# Lucifer's presentation area
    ('narrow', 900, 860),	# a window beside another; many sites' middle layout
    ('laptop', 1280, 800),
    ('desktop', 1440, 900),
]


def chromium(url, out, w, h, full):
    cmd = ['node', os.path.join(ROOT, 'tools/ref/shot.js')] + (['-full'] if full else []) + [url, out, str(w), str(h)]
    subprocess.run(cmd, capture_output=True, timeout=120)


def charon(url, out, w, h, full):
    size = str(w) if full else '%dx%d' % (w, h)
    r = subprocess.run([os.path.join(ROOT, 'tools/charon-shot.sh'), url, out, size],
                       capture_output=True, text=True, timeout=300)
    return r.stderr.strip()


def pad(a, h, w):
    o = np.full((h, w, 3), 255, np.uint8)
    o[:min(h, a.shape[0]), :min(w, a.shape[1])] = a[:h, :w]
    return o


def cells(a, k=8):
    h, w = a.shape[0] // k * k, a.shape[1] // k * k
    return a[:h, :w].reshape(h // k, k, w // k, k, 3).mean(axis=(1, 3))


def score(ref, got):
    h, w = max(ref.shape[0], got.shape[0]), max(ref.shape[1], got.shape[1])
    ref, got = pad(ref, h, w), pad(got, h, w)
    d = np.abs(ref.astype(int) - got.astype(int)).max(axis=2)
    exact = float((d > 16).mean())
    layout = float((np.abs(cells(ref) - cells(got)).max(axis=2) > 24).mean())
    diff = (ref * 0.25 + 191).astype(np.uint8)
    diff[d > 16] = (255, 0, 0)
    return exact, layout, ref, got, diff


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-W', type=int, default=1024)
    ap.add_argument('-H', type=int, default=768)
    ap.add_argument('--full', action='store_true')
    ap.add_argument('--sizes', choices=['standard'])
    ap.add_argument('-o', required=True)
    ap.add_argument('urls', nargs='+')
    a = ap.parse_args()
    if not a.sizes:
        run(a.urls, a.o, a.W, a.H, a.full)
        return
    table = {}
    for name, w, h in SIZES:
        print('== %s %dx%d' % (name, w, h))
        for url, e, l, err in run(a.urls, os.path.join(a.o, name), w, h, a.full):
            table.setdefault(url, {})[name] = l
    with open(os.path.join(a.o, 'sizes.txt'), 'w') as f:
        f.write('# layout difference from Chromium, by width (0 is identical)\n')
        f.write('%-50s' % 'url' + ''.join('%9s' % n for n, _, _ in SIZES) + '\n')
        for url in a.urls:
            f.write('%-50s' % url[-50:] + ''.join('%9s' % ('-' if table.get(url, {}).get(n) is None
                else '%.1f%%' % (100 * table[url][n])) for n, _, _ in SIZES) + '\n')
    print(open(os.path.join(a.o, 'sizes.txt')).read())


def run(urls, out, W, H, full):
    os.makedirs(out, exist_ok=True)
    rows = []
    for i, url in enumerate(urls):
        # a server that is down gives two identical error pages: a perfect score
        try:
            import urllib.request
            urllib.request.urlopen(url, timeout=30).read(1)
        except Exception as e:
            rows.append((url, None, None, 'unreachable: %s' % e))
            print('%-60s unreachable: %s' % (url, e))
            continue
        rp, cp = os.path.join(out, '%d-chromium.png' % i), os.path.join(out, '%d-charon.png' % i)
        for p in (rp, cp):
            if os.path.exists(p):
                os.remove(p)
        chromium(url, rp, W, H, full)
        err = charon(url, cp, W, H, full)
        if not os.path.exists(rp) or not os.path.exists(cp):
            rows.append((url, None, None, 'no image: ' + err))
            print('%-60s no image %s' % (url, err))
            continue
        ref = np.asarray(Image.open(rp).convert('RGB'))
        got = np.asarray(Image.open(cp).convert('RGB'))
        exact, layout, ref, got, diff = score(ref, got)
        h, w = ref.shape[:2]
        side = np.full((h, w * 3 + 20, 3), 128, np.uint8)
        side[:, :w], side[:, w+10:2*w+10], side[:, 2*w+20:] = ref, got, diff
        Image.fromarray(side).save(os.path.join(out, '%d.png' % i))
        rows.append((url, exact, layout, err))
        print('%-60s exact %5.1f%%  layout %5.1f%%' % (url, 100 * exact, 100 * layout))
    with open(os.path.join(out, 'scores.txt'), 'w') as f:
        for url, e, l, err in rows:
            f.write('%s %s %s\n' % (url, 'none' if e is None else '%.4f' % e, 'none' if l is None else '%.4f' % l))
    h = ['<!doctype html><meta charset=utf-8><title>Charon vs Chromium</title>',
         '<style>body{font:13px sans-serif} img{max-width:100%;border:1px solid #888}</style>',
         '<p>Left: Chromium (scripts off). Middle: Charon. Right: differences in red.</p>']
    for i, (url, e, l, err) in enumerate(rows):
        h.append('<h3>%s</h3>' % html.escape(url))
        if e is None:
            h.append('<p>no image: %s</p>' % html.escape(err))
        else:
            h.append('<p>exact %.1f%%, layout %.1f%%</p><img src="%d.png">' % (100 * e, 100 * l, i))
    open(os.path.join(out, 'index.html'), 'w').write('\n'.join(h))
    return rows


if __name__ == '__main__':
    main()
