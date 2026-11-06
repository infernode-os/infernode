#!/usr/bin/env python3
# mkclip.py picture out.y4m n: n frames of a picture as a y4m clip (I420,
# full range), the middle one plain grey, for tests/host/vision_feed_test.sh
import sys
import numpy as np
from PIL import Image
src, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
im = Image.open(src).convert("RGB")
w, h = im.size
w -= w % 2; h -= h % 2
im = im.crop((0, 0, w, h))
ycc = np.asarray(im.convert("YCbCr")).astype(np.float32)
def planes(a):
    y = a[:, :, 0].astype(np.uint8)
    cb = a[:, :, 1].reshape(h//2, 2, w//2, 2).mean((1, 3)).round().astype(np.uint8)
    cr = a[:, :, 2].reshape(h//2, 2, w//2, 2).mean((1, 3)).round().astype(np.uint8)
    return y.tobytes() + cb.tobytes() + cr.tobytes()
dog = planes(ycc)
grey = planes(np.full_like(ycc, 128))
with open(out, "wb") as f:
    f.write(b"YUV4MPEG2 W%d H%d F10:1 Ip A1:1 C420jpeg\n" % (w, h))
    for i in range(n):
        f.write(b"FRAME\n")
        f.write(grey if i == n // 2 else dog)
