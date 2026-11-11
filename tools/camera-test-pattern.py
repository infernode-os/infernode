#!/usr/bin/env python3
#
# camera-test-pattern.py OUT.mp4 -- a five-minute looped test video to point
# a camera at, for soaking camsrv(4) and wm/camera: 1280x720, 30 fps, H.264.
#
# Each segment has an answer known in advance:
#   1-3  black, grey and white steps, slow to 1 Hz: auto-exposure, and the
#        sensor I2C traffic it causes (segment 3 flashes, 20 s at 1 Hz)
#   4    a slow fade: exposure without hunting
#   5-7  neutral grey, colour bars, solid primaries: white balance (the
#        primaries are grey world's worst case)
#   8    a Siemens star and line pairs: focus and resolution
#   9-10 a sweeping bar, a moving block: torn or mixed frames
# A 16-block code, segment in the top 4 bits and frame in the low 12, is set
# in from the bottom and repeated at the top, so a capture can be placed in
# the sequence even when focus breathing crops an edge.
#
# Needs numpy and ffmpeg with libx264. Nothing here ships: it makes a file.
import subprocess,sys,numpy as np
W,H,F=1280,720,30
out=sys.argv[1]
yy,xx=np.mgrid[0:H,0:W]
def solid(v): return np.full((H,W,3),v,'u1')
def bars():
    c=[(235,235,235),(235,235,16),(16,235,235),(16,235,16),(235,16,235),(235,16,16),(16,16,235),(16,16,16)]
    a=np.zeros((H,W,3),'u1')
    for i,v in enumerate(c): a[:,i*W//8:(i+1)*W//8]=v
    return a
def star():
    a=np.full((H,W,3),255,'u1')
    cx,cy=W//3,H//2; r=np.hypot(xx-cx,yy-cy); t=np.arctan2(yy-cy,xx-cx)
    a[(np.sin(72*t)>0)&(r<300)]=0
    # line pairs at 1,2,3,4,6,8 px, on the right
    for i,p in enumerate((1,2,3,4,6,8)):
        y0=70+i*100; a[y0:y0+80,720:1200]=255
        a[y0:y0+80,720:1200][:,((np.arange(480)//p)%2==0)]=0
    return a
STAR=star(); BARS=bars()
def seqs():
    # (segment number, seconds, frame function of frame index)
    t=lambda s:int(s*F)
    y=[]
    def steps(hold,cycles,levels=(0,255)):
        def f(i):
            return solid(levels[(i//t(hold))%len(levels)])
        return t(hold)*len(levels)*cycles,f
    y.append((1,)+steps(5,3))                     # slow black/white
    y.append((2,)+steps(1.5,8,(0,128,255,64)))    # medium, four levels
    y.append((3,)+steps(.5,20))                   # fast: 1 Hz
    n=t(30)
    y.append((4,n,lambda i:solid(int(255*abs(2*i/n-1)))))   # ramp down and up
    y.append((5,t(20),lambda i:solid(128)))       # neutral grey: white balance
    y.append((6,t(20),lambda i:BARS))
    def colour(i): return solid(0)+np.array([(255,0,0),(0,255,0),(0,0,255)][(i//t(5))%3],'u1')
    y.append((7,t(30),colour))                    # saturated: grey world's worst case
    y.append((8,t(45),lambda i:STAR))             # focus
    def bar(i):
        a=solid(32); x=(i*24)%W; a[:,x:x+40]=255; return a      # vertical bar, one sweep in 1.8 s
    y.append((9,t(30),bar))
    def blk(i):
        a=solid(64); x=(i*64)%W; y0=(i*36)%(H-120); a[y0:y0+120,x:x+120]=(255,255,0); return a
    y.append((10,t(30),blk))                      # a fast block
    return y
S=seqs(); total=sum(s[1] for s in S); print("frames",total,"seconds",total/F)
p=subprocess.Popen(["ffmpeg","-y","-loglevel","error","-f","rawvideo","-pix_fmt","rgb24","-s",f"{W}x{H}","-r",str(F),"-i","-",
 "-c:v","libx264","-preset","medium","-crf","18","-pix_fmt","yuv420p","-movflags","+faststart",out],stdin=subprocess.PIPE)
for seg,n,f in S:
    for i in range(n):
        a=f(i).copy()
        code=(seg<<12)|(i&0xfff)
        for y0 in (40, H-64):
            for b in range(16):
                x=80+b*(W-160)//16; a[y0:y0+24,x:x+(W-160)//16-4]=255 if code>>(15-b)&1 else 0
        p.stdin.write(a.tobytes())
p.stdin.close(); p.wait(); print("done",p.returncode)
