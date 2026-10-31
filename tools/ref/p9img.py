"""p9img.py - read an Inferno image(6) file into a numpy RGB array.

The decoder is tools/p9img2png.py's; this is the importable form the
reference tools use.
"""
import numpy as np

NMEM = 1024; NMATCH = 3

def decomp_block(data, w, nrows, bpp):
    bpl=w*bpp
    out=bytearray(bpl*nrows)
    mem=bytearray(NMEM); memp=0
    u=0; eu=len(data)
    y=0; linep=0; elinep=bpl
    while True:
        if linep==elinep:
            y+=1
            if y==nrows: break
            linep=y*bpl; elinep=linep+bpl
        if u==eu: break
        c=data[u]; u+=1
        if c>=128:
            cnt=c-128+1
            while cnt:
                v=data[u]; u+=1
                out[linep]=v; linep+=1
                mem[memp]=v; memp=(memp+1)%NMEM
                cnt-=1
        else:
            offs=data[u]+((c&3)<<8)+1; u+=1
            omemp=(memp-offs) % NMEM
            cnt=(c>>2)+NMATCH
            while cnt:
                v=mem[omemp]
                out[linep]=v; linep+=1
                mem[memp]=v; memp=(memp+1)%NMEM; omemp=(omemp+1)%NMEM
                cnt-=1
    return out

def load(path):
    data = open(path, 'rb').read()
    off = 0
    compressed = data[:11] == b'compressed\n'
    if compressed:
        off = 11
    hdr = data[off:off+60]; off += 60
    chan = hdr[0:11].strip().decode()
    minx = int(hdr[12:24]); miny = int(hdr[24:36]); maxx = int(hdr[36:48]); maxy = int(hdr[48:60])
    w = maxx - minx; h = maxy - miny
    bpp = {'x8r8g8b8': 4, 'a8r8g8b8': 4, 'r8g8b8': 3, 'k8': 1}.get(chan)
    if not bpp:
        raise ValueError('unsupported channels %r' % chan)
    if not compressed:
        rows = data[off:off+w*h*bpp]
    else:
        rows = bytearray(); y = miny
        while y < maxy:
            sub = data[off:off+24]; off += 24
            bmaxy = int(sub[0:12]); nb = int(sub[12:24])
            rows += decomp_block(data[off:off+nb], w, bmaxy-y, bpp)
            off += nb
            y = bmaxy
    a = np.frombuffer(bytes(rows), dtype=np.uint8)[:w*h*bpp].reshape(h, w, bpp)
    if bpp == 1:
        return np.repeat(a, 3, axis=2)
    return a[:, :, 2::-1].copy()	# BGR(X) in memory -> RGB
