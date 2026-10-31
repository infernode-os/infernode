#!/usr/bin/env python3
"""mkvectors.py - the WebP vectors tests/readwebp_test.b decodes.

    LIBWEBP=~/ref/libwebp-1.4.0/build ENC=~/ref/enc/enc python3 mkvectors.py

Images are made here (seeded, so the same each time), encoded with
libwebp's cwebp and img2webp, and with ENC, a small program on libwebp's
encoder API for what cwebp cannot be asked (token partitions, the alpha
encoding and filter):

    enc in.rgba w h out.webp key=value...    (WebPConfig fields)

The reference for each vector is libwebp's own decoding of it (dwebp,
fancy upsampling, as browsers decode), kept as an RGBA PNG beside it;
an animation's references are its composited frames as libwebp's
animation decoder gives them (through Pillow).  The manifest, vectors,
has a line per vector: name, frames (0 for a still image) and the
largest per-channel difference allowed in colour (alpha must match).
"""
import os, random, subprocess, sys, tempfile
from PIL import Image

LIB = os.path.expanduser(os.environ.get("LIBWEBP", "~/ref/libwebp-1.4.0/build"))
ENC = os.path.expanduser(os.environ.get("ENC", "~/ref/enc/enc"))
HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp()


def photo(w, h, seed, noise=10, alpha=None):
    """Smooth fields, hard-edged shapes and noise: every intra mode and transform gets used."""
    r = random.Random(seed)
    im = Image.new("RGBA", (w, h))
    px = im.load()
    rects = [(r.randrange(w), r.randrange(h), r.randrange(4, max(5, w // 2)), r.randrange(4, max(5, h // 2)),
              (r.randrange(256), r.randrange(256), r.randrange(256))) for _ in range(5)]
    for y in range(h):
        for x in range(w):
            c = [(x * 255 // max(1, w - 1)), (y * 255 // max(1, h - 1)), ((x * y) // 7) & 255]
            for rx, ry, rw, rh, rc in rects:
                if rx <= x < rx + rw and ry <= y < ry + rh:
                    c = list(rc)
            c = [max(0, min(255, v + r.randint(-noise, noise))) for v in c]
            a = 255
            if alpha == "gradient":
                a = x * 255 // max(1, w - 1)
            elif alpha == "shapes":
                a = 0 if (x // 6 + y // 5) % 3 == 0 else (128 if (x + y) % 7 == 0 else 255)
            elif alpha == "soft":
                a = max(0, min(255, 128 + int(100 * ((x - w / 2) / w)) + r.randint(-20, 20)))
            px[x, y] = (c[0], c[1], c[2], a)
    return im


def palette(w, h, n, seed):
    r = random.Random(seed)
    cols = [(r.randrange(256), r.randrange(256), r.randrange(256), 255) for _ in range(n)]
    im = Image.new("RGBA", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            k = ((x // 3) + (y // 2) * 5 + (r.randrange(4) == 0) * r.randrange(n)) % n
            px[x, y] = cols[k]
    return im


def flat(w, h, seed):
    """Mostly one colour: macroblocks with nothing to code are skipped."""
    r = random.Random(seed)
    im = Image.new("RGBA", (w, h), (90, 140, 200, 255))
    px = im.load()
    x0, y0 = r.randrange(w - 4), r.randrange(h - 4)
    for y in range(y0, y0 + 4):
        for x in range(x0, x0 + 4):
            px[x, y] = (250, 30, 30, 255)
    return im


def chunks(path):
    """A WebP file's chunks: [(id, payload)]."""
    d = open(path, "rb").read()
    out, off = [], 12
    while off + 8 <= len(d):
        cid, n = d[off:off + 4], int.from_bytes(d[off + 4:off + 8], "little")
        out.append((cid, d[off + 8:off + 8 + n]))
        off += 8 + n + (n & 1)
    return out


def chunk(cid, payload):
    return cid + len(payload).to_bytes(4, "little") + payload + (b"\0" if len(payload) & 1 else b"")


def riff(body):
    return b"RIFF" + (len(body) + 4).to_bytes(4, "little") + b"WEBP" + body


def vp8x(flags, w, h):
    return chunk(b"VP8X", bytes([flags, 0, 0, 0]) + (w - 1).to_bytes(3, "little") + (h - 1).to_bytes(3, "little"))


def filtered(a, w, h, filt):
    """The deltas libwebp's unfilter (filters.c) turns back into a."""
    d = bytearray(w * h)
    for y in range(h):
        o = y * w
        f = filt if y > 0 else 1
        if f == 1:
            pred = a[o - w] if y > 0 else 0
            for i in range(w):
                d[o + i] = (a[o + i] - pred) & 255
                pred = a[o + i]
        elif f == 2:
            for i in range(w):
                d[o + i] = (a[o + i] - a[o - w + i]) & 255
        else:
            top = left = tl = a[o - w]
            for i in range(w):
                top = a[o - w + i]
                g = max(0, min(255, left + top - tl))
                d[o + i] = (a[o + i] - g) & 255
                tl, left = top, a[o + i]
    return bytes(d)


def handalpha(name, im, method, filt):
    """An ALPH chunk made here, with a filter the encoder might not choose."""
    w, h = im.size
    opaque = im.convert("RGB")
    cwebp(name + "-rgb", opaque, LOSSY, "-q", "70")
    vectors.pop()
    vp8 = [c for c in chunks(os.path.join(HERE, name + "-rgb.webp")) if c[0] == b"VP8 "][0]
    for ext in (".webp", ".png"):
        os.remove(os.path.join(HERE, name + "-rgb" + ext))
    d = filtered(im.getchannel("A").tobytes(), w, h, filt)
    if method == 0:
        alph = bytes([filt << 2]) + d
    else:
        g = Image.merge("RGBA", (Image.new("L", (w, h)), Image.frombytes("L", (w, h), d), Image.new("L", (w, h)), Image.new("L", (w, h), 255)))
        cwebp(name + "-a", g, 0, "-lossless", "-exact")
        vectors.pop()
        vp8l = [c for c in chunks(os.path.join(HERE, name + "-a.webp")) if c[0] == b"VP8L"][0][1]
        for ext in (".webp", ".png"):
            os.remove(os.path.join(HERE, name + "-a" + ext))
        alph = bytes([(filt << 2) | 1]) + vp8l[5:]	# the stream without its header
    open(os.path.join(HERE, name + ".webp"), "wb").write(riff(vp8x(0x10, w, h) + chunk(b"ALPH", alph) + chunk(*vp8)))
    reference(name)
    vectors.append((name, 0, LOSSY))


def handanim(name, *opts):
    """Frames at offsets, blended and not, disposed and not."""
    cw, ch = 40, 30
    plan = [  # image, x, y, dispose, noblend
        (photo(cw, ch, 80), 0, 0, 0, 0),
        (photo(20, 16, 81, alpha="soft"), 6, 4, 1, 0),
        (photo(24, 18, 82, alpha="shapes"), 10, 8, 0, 0),
        (photo(16, 12, 83, alpha="soft"), 2, 2, 0, 1),
        (photo(cw, ch, 84, alpha="soft"), 0, 0, 0, 0),
    ]
    body = vp8x(0x12, cw, ch) + chunk(b"ANIM", bytes([255, 255, 255, 255, 0, 0]))
    for i, (im, x, y, dispose, noblend) in enumerate(plan):
        tmp = "%s-f%d" % (name, i)
        cwebp(tmp, im, 0, *opts)
        vectors.pop()
        fc = b"".join(chunk(c, p) for c, p in chunks(os.path.join(HERE, tmp + ".webp")) if c in (b"ALPH", b"VP8 ", b"VP8L"))
        for ext in (".webp", ".png"):
            os.remove(os.path.join(HERE, tmp + ext))
        hdr = (x // 2).to_bytes(3, "little") + (y // 2).to_bytes(3, "little") + (im.width - 1).to_bytes(3, "little") + \
            (im.height - 1).to_bytes(3, "little") + (80).to_bytes(3, "little") + bytes([(noblend << 1) | dispose])
        body += chunk(b"ANMF", hdr + fc)
    open(os.path.join(HERE, name + ".webp"), "wb").write(riff(body))
    im = Image.open(os.path.join(HERE, name + ".webp"))
    for i in range(im.n_frames):
        im.seek(i)
        im.convert("RGBA").save(os.path.join(HERE, "%s.%d.png" % (name, i)), optimize=True)
    vectors.append((name, im.n_frames, 0))


def src(im, name):
    p = os.path.join(TMP, name + ".png")
    im.save(p)
    return p


def raw(im, name):
    p = os.path.join(TMP, name + ".rgba")
    open(p, "wb").write(im.convert("RGBA").tobytes())
    return p


vectors = []


def reference(name):
    """dwebp's decoding, as an RGBA PNG."""
    pam = os.path.join(TMP, name + ".pam")
    subprocess.run([os.path.join(LIB, "dwebp"), "-quiet", "-pam", os.path.join(HERE, name + ".webp"), "-o", pam], check=True)
    readpam(pam).save(os.path.join(HERE, name + ".png"), optimize=True)


def readpam(path):
    d = open(path, "rb").read()
    end = d.index(b"ENDHDR\n") + 7
    hdr = dict(l.split(None, 1) for l in d[:end].decode().splitlines()[1:-1])
    w, h = int(hdr["WIDTH"]), int(hdr["HEIGHT"])
    assert hdr["DEPTH"].strip() == "4" and hdr["MAXVAL"].strip() == "255"
    return Image.frombytes("RGBA", (w, h), d[end:end + w * h * 4])


def cwebp(name, im, tol, *opts):
    subprocess.run([os.path.join(LIB, "cwebp"), "-quiet"] + list(opts) + [src(im, name), "-o", os.path.join(HERE, name + ".webp")], check=True)
    reference(name)
    vectors.append((name, 0, tol))


def enc(name, im, tol, *opts):
    subprocess.run([ENC, raw(im, name), str(im.width), str(im.height), os.path.join(HERE, name + ".webp")] + list(opts), check=True)
    reference(name)
    vectors.append((name, 0, tol))


def anim(name, frames, tol, *opts):
    args = [os.path.join(LIB, "img2webp")] + list(opts)
    for i, f in enumerate(frames):
        args += ["-d", "80", src(f, "%s-%d" % (name, i))]
    subprocess.run(args + ["-o", os.path.join(HERE, name + ".webp")], check=True, stdout=subprocess.DEVNULL)
    im = Image.open(os.path.join(HERE, name + ".webp"))
    for i in range(im.n_frames):
        im.seek(i)
        im.convert("RGBA").save(os.path.join(HERE, "%s.%d.png" % (name, i)), optimize=True)
    vectors.append((name, im.n_frames, tol))


LOSSY = 0	# lossy colour must match libwebp exactly too

# lossless
cwebp("ll-photo-m6", photo(96, 64, 1, noise=24), 0, "-lossless", "-m", "6", "-q", "100")
cwebp("ll-photo-m0", photo(64, 40, 2), 0, "-lossless", "-m", "0", "-q", "0")
cwebp("ll-photo-z9", photo(64, 40, 3, noise=40), 0, "-z", "9")
cwebp("ll-pal2", palette(61, 37, 2, 5), 0, "-lossless")
cwebp("ll-pal3", palette(61, 37, 3, 6), 0, "-lossless")
cwebp("ll-pal16", palette(50, 40, 16, 7), 0, "-lossless")
cwebp("ll-pal200", palette(50, 40, 200, 8), 0, "-lossless")
cwebp("ll-1x1", photo(1, 1, 9), 0, "-lossless")
cwebp("ll-wide-alpha", photo(300, 5, 10, alpha="gradient"), 0, "-lossless")
cwebp("ll-alpha-exact", photo(40, 30, 11, alpha="shapes"), 0, "-lossless", "-exact")
cwebp("ll-alpha", photo(40, 30, 12, alpha="shapes"), 0, "-lossless")
cwebp("ll-near", photo(64, 40, 13), 0, "-near_lossless", "40")

# lossy
cwebp("ly-q5", photo(64, 48, 20), LOSSY, "-q", "5")
cwebp("ly-q50", photo(64, 48, 21), LOSSY, "-q", "50")
cwebp("ly-q100", photo(48, 32, 22), LOSSY, "-q", "100")
cwebp("ly-1x1", photo(1, 1, 23), LOSSY)
cwebp("ly-3x200", photo(3, 200, 24), LOSSY)
cwebp("ly-99x41", photo(99, 41, 25, noise=2), LOSSY, "-q", "40")
cwebp("ly-nofilter", photo(48, 32, 26), LOSSY, "-f", "0")
cwebp("ly-simple", photo(48, 32, 27), LOSSY, "-nostrong", "-f", "70", "-sharpness", "7")
cwebp("ly-strong", photo(48, 32, 28), LOSSY, "-strong", "-f", "50", "-sharpness", "3")
cwebp("ly-seg1", photo(48, 32, 29), LOSSY, "-segments", "1")
cwebp("ly-sns", photo(64, 48, 30), LOSSY, "-sns", "100", "-segments", "4", "-q", "30")
cwebp("ly-m0", photo(48, 32, 31), LOSSY, "-m", "0")
cwebp("ly-m6", photo(48, 32, 32), LOSSY, "-m", "6", "-pass", "6")
# (libwebp's encoder writes one partition when it buffers tokens: method 3 up)
enc("ly-parts2", photo(32, 128, 33, noise=8), LOSSY, "partitions=1", "method=2", "q=60")
enc("ly-parts8", photo(32, 128, 34, noise=8), LOSSY, "partitions=3", "method=2", "q=60")
cwebp("ly-flat", flat(128, 128, 36), LOSSY, "-q", "50", "-m", "2")	# (the token path, method 3 up, never skips)
enc("ly-simplefilter", photo(48, 48, 35), LOSSY, "ftype=0", "fstrength=60", "fsharp=2")
cwebp("ly-alpha", photo(40, 32, 40, alpha="soft"), LOSSY, "-alpha_q", "100")
cwebp("ly-alpha-q30", photo(40, 32, 41, alpha="soft"), LOSSY, "-alpha_q", "30")

for method in (0, 1):
    for filt in (0, 1, 2, 3):
        handalpha("ly-alpha-hand-m%df%d" % (method, filt), photo(36, 28, 70 + method * 3 + filt, alpha="soft"), method, filt)

# animations
fr = [photo(40, 30, 50 + i, alpha=("shapes" if i % 2 else None)) for i in range(3)]
anim("an-mixed", fr, LOSSY, "-mixed")
handanim("an-hand-lossless", "-lossless")
handanim("an-hand-lossy", "-q", "70")

with open(os.path.join(HERE, "vectors"), "w") as f:
    for name, n, tol in vectors:
        f.write("%s %d %d\n" % (name, n, tol))
print("%d vectors" % len(vectors))
