#!/usr/bin/env python3
# live.py clip.y4m: the clip as a live y4m source on standard output, its
# frames over and over at 20 a second for 6 s, for tests/host/vision_feed_test.sh
import sys, time
# a live y4m source: the clip's frames over and over, at 20 a second, for 6 s
data = open(sys.argv[1], "rb").read()
hdr, rest = data.split(b"\n", 1)
frames = rest.split(b"FRAME\n")[1:]
out = sys.stdout.buffer
out.write(hdr.replace(b"F10:1", b"F20:1") + b"\n")
t0 = time.time()
i = 0
while time.time() - t0 < 6:
    out.write(b"FRAME\n" + frames[i % len(frames)])
    out.flush()
    i += 1
    time.sleep(max(0, t0 + i / 20 - time.time()))
