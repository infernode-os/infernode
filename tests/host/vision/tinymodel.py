#!/usr/bin/env python3
"""tinymodel.py DIR: a vision(4) model of the test's own, a picture and a clip.

A real detector's weights are megabytes fetched by hash, so the tests
that need one skip where it is not; this is a model small enough to make
on the spot, for tests/host/visionfs_test.sh, which is about the file
server and not about what a network finds.

DIR/model folds its 32x32 input to one cell (space to depth, five
times) and has one convolution over that with weights of zero, so its
one head is its biases whatever it is shown: a box at the
middle of the input as large as the input, objectness 0.9, and of its
two classes the second, at 0.95.  Every picture and every frame has
exactly one detection: class 'traffic light' (a name with a blank in
it), score 0.85 or 0.86, its box the picture.

DIR/p.ppm is a 48x32 picture (P6); DIR/c.y4m a clip of eight 48x32
frames at ten a second.
"""
import hashlib
import os
import struct
import sys

d = sys.argv[1]
m = os.path.join(d, "model")
os.makedirs(m, exist_ok=True)

NCLASS = 2
OC = NCLASS + 5
nw = OC * 3 * 32 * 32
bias = [0.5, 0.5, 0.0, 0.0, 0.9, 0.2, 0.95]
weights = bytes(4 * nw) + struct.pack("<%df" % OC, *bias)
with open(os.path.join(m, "weights"), "wb") as f:
    f.write(weights)
with open(os.path.join(m, "sha256"), "w") as f:
    f.write(hashlib.sha256(weights).hexdigest() + "\n")
with open(os.path.join(m, "info"), "w") as f:
    f.write("kind=detect decode=yolox input=32x32 classes=%d order=rgb fill=114\n" % NCLASS)
with open(os.path.join(m, "classes"), "w") as f:
    f.write("thing\ntraffic light\n")
with open(os.path.join(m, "graph"), "w") as f:
    f.write("vis 1\n")
    f.write("input name=x c=3 h=32 w=32\n")
    for a, b in ("xa", "ab", "bc", "cd", "de"):
        f.write("s2d in=%s out=%s\n" % (a, b))
    f.write("conv in=e out=y ic=3072 oc=%d kh=1 kw=1 stride=1 pad=0 group=1 act=none w=0 b=%d\n" % (OC, nw))
    f.write("output in=y name=head stride=32\n")

w, h = 48, 32
with open(os.path.join(d, "p.ppm"), "wb") as f:
    f.write(b"P6\n%d %d\n255\n" % (w, h) + bytes(range(256)) * (3 * w * h // 256))
with open(os.path.join(d, "c.y4m"), "wb") as f:
    f.write(b"YUV4MPEG2 W%d H%d F10:1 Ip A1:1 C420jpeg\n" % (w, h))
    for i in range(8):
        f.write(b"FRAME\n" + bytes([60 + 20 * i]) * (w * h) + bytes([128]) * (2 * (w // 2) * (h // 2)))
