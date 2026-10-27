#!/usr/bin/env python3
#
# p9img2png.py — decode an Inferno/Plan9 image ([xa]8r8g8b8 or r8g8b8, compressed or not) to PNG.
#
# The Tk offscreen test harness renders a window to an in-memory image and
# dumps it with Display.writeimage(); that produces the "compressed" image
# format (libdraw/writeimage.c, decoded by libmemdraw/cload.c). This is the
# host-side decoder so rendered Tk windows can be eyeballed as PNGs during
# the brutalist restyle / app migration, on a headless machine or in CI.
#
#   usage: p9img2png.py <infile.img> <outfile.png>
#
# Tests import it for the pixels themselves: load(path).px(x, y).
#

import sys, struct, zlib
NMEM=1024; NMATCH=3
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
class Img:
    """An image's pixels: r, its rectangle (minx, miny, maxx, maxy); px(x, y), the
    colour at a point in its coordinates as 'RRGGBB'; rgb, bytes r g b by row."""
    def __init__(self, r, rgb):
        self.r=r; self.w=r[2]-r[0]; self.h=r[3]-r[1]; self.rgb=rgb
    def px(self, x, y):
        p=((y-self.r[1])*self.w+(x-self.r[0]))*3
        return '%02X%02X%02X' % (self.rgb[p], self.rgb[p+1], self.rgb[p+2])

def load(path):
    """Decode an Inferno image file (as scap and writeimage write it)."""
    data=open(path,'rb').read(); off=0
    compressed=data[:11]==b'compressed\n'
    if compressed: off=11
    hdr=data[off:off+60]; off+=60
    chan=hdr[0:11].strip().decode()
    minx=int(hdr[12:24]); miny=int(hdr[24:36]); maxx=int(hdr[36:48]); maxy=int(hdr[48:60])
    w=maxx-minx; h=maxy-miny
    bpp={'x8r8g8b8':4,'a8r8g8b8':4,'r8g8b8':3,'k8':1}.get(chan)
    assert bpp, f'chan={chan!r}'
    rows=bytearray(); y=miny
    if not compressed:	# uncompressed: the pixels follow the header
        rows=bytearray(data[off:off+w*h*bpp]); y=maxy
    while y<maxy:
        sub=data[off:off+24]; off+=24
        bmaxy=int(sub[0:12]); nb=int(sub[12:24])
        block=data[off:off+nb]; off+=nb
        rows+=decomp_block(block, w, bmaxy-y, bpp)
        y=bmaxy
    rgb=bytearray(w*h*3)
    for p in range(w*h):
        if bpp==1:	# k8: grey
            r=g=b=rows[p]
        else:
            b=rows[p*bpp+0]; g=rows[p*bpp+1]; r=rows[p*bpp+2]
        rgb[p*3]=r; rgb[p*3+1]=g; rgb[p*3+2]=b
    return Img((minx, miny, maxx, maxy), rgb)

def main(path,outpng):
    im=load(path); w=im.w; h=im.h; rgb=im.rgb
    def chunk(t,d):
        c=t+d; return struct.pack('>I',len(d))+c+struct.pack('>I',zlib.crc32(c)&0xffffffff)
    raw=bytearray()
    for yy in range(h):
        raw.append(0); raw+=rgb[yy*w*3:(yy+1)*w*3]
    png=(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+
         chunk(b'IDAT',zlib.compress(bytes(raw),9))+chunk(b'IEND',b''))
    open(outpng,'wb').write(png); print(f'wrote {outpng} {w}x{h}')

if __name__ == '__main__':
    main(sys.argv[1],sys.argv[2])
