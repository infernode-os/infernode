#!/usr/bin/env python3
"""
refdetect: what vision(4) should find in a picture, computed independently
(numpy and onnxruntime), for tests/host/visnet_test.sh.

    refdetect.py [--thresh 0.3] [--iou 0.45] [--ppm out.ppm] model.onnx modeldir picture

Reads the picture (any format Pillow reads), letterboxes it as $Tensor
does (bilinear, half-pixel centres, into the top left, the rest the
model's fill), runs the ONNX with onnxruntime, decodes YOLOX's heads and
keeps the best of each class's overlapping boxes, as appl/lib/visnet.b
does. Prints one record a line, best first:

    class=dog score=0.9123 x0=123.4 y0=... x1=... y1=...

--ppm writes the picture's pixels as a binary PPM, so vision(4) can be
given exactly the pixels this read (JPEG decoders differ by a level or
two).
"""
import argparse, sys
import numpy as np
import onnx
import onnxruntime as ort
from PIL import Image


def info(modeldir):
    kv = dict(f.split("=", 1) for f in open(modeldir + "/info").read().split())
    w, h = (int(x) for x in kv["input"].split("x"))
    classes = open(modeldir + "/classes").read().split()
    return w, h, kv["order"], int(kv["fill"]), classes


def letterbox(rgb, ow, oh, scale, fill, bgr):
    h, w, _ = rgb.shape
    rw, rh = min(int(w * scale), ow), min(int(h * scale), oh)
    rw, rh = max(rw, 1), max(rh, 1)
    out = np.full((3, oh, ow), float(fill), np.float32)
    ys = (np.arange(rh, dtype=np.float32) + 0.5) * h / rh - 0.5
    xs = (np.arange(rw, dtype=np.float32) + 0.5) * w / rw - 0.5
    ys = np.maximum(ys, 0); xs = np.maximum(xs, 0)
    y0 = np.minimum(ys.astype(int), h - 1); x0 = np.minimum(xs.astype(int), w - 1)
    y1 = np.minimum(y0 + 1, h - 1); x1 = np.minimum(x0 + 1, w - 1)
    fy = (ys - y0)[:, None, None]; fx = (xs - x0)[None, :, None]
    p = rgb.astype(np.float32)
    v = (1 - fy) * ((1 - fx) * p[y0][:, x0] + fx * p[y0][:, x1]) + fy * ((1 - fx) * p[y1][:, x0] + fx * p[y1][:, x1])
    if bgr:
        v = v[:, :, ::-1]
    out[:, :rh, :rw] = v.transpose(2, 0, 1)
    return out


def heads(onnxpath):
    # the three heads, as onnx2vis names them: the tensors the head concats make
    m = onnx.load(onnxpath)
    users = {}
    for n in m.graph.node:
        for x in n.input:
            users.setdefault(x, []).append(n)
    hs = []
    for n in m.graph.node:
        if n.op_type == "Concat" and n.attribute[0].i == 1:
            us = users.get(n.output[0], [])
            if us and all(u.op_type == "Reshape" for u in us):
                hs.append(n.output[0])
    for hd in hs:
        m.graph.output.append(onnx.helper.make_tensor_value_info(hd, onnx.TensorProto.FLOAT, None))
    return m, hs


def iou(a, b):
    ix = min(a[2], b[2]) - max(a[0], b[0]); iy = min(a[3], b[3]) - max(a[1], b[1])
    if ix <= 0 or iy <= 0:
        return 0.0
    i = ix * iy
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i
    return i / u if u > 0 else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("onnx"); ap.add_argument("modeldir"); ap.add_argument("picture")
    ap.add_argument("--thresh", type=float, default=0.3)
    ap.add_argument("--iou", type=float, default=0.45)
    ap.add_argument("--ppm")
    a = ap.parse_args()
    iw, ih, order, fill, classes = info(a.modeldir)
    rgb = np.asarray(Image.open(a.picture).convert("RGB"))
    h, w, _ = rgb.shape
    if a.ppm:
        with open(a.ppm, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (w, h))
            f.write(rgb.tobytes())
    scale = min(iw / w, ih / h)
    x = letterbox(rgb, iw, ih, scale, fill, order == "bgr")[None]
    m, hs = heads(a.onnx)
    sess = ort.InferenceSession(m.SerializeToString(), providers=["CPUExecutionProvider"])
    outs = sess.run(hs, {sess.get_inputs()[0].name: x})
    dets = []
    for o in outs:
        t = o[0]
        c, gh, gw = t.shape
        s = ih // gh
        t = t.reshape(c, -1)
        obj = t[4]
        best = t[5:].argmax(0)
        score = obj * t[5:].max(0)
        for i in np.nonzero((obj >= a.thresh) & (score >= a.thresh))[0]:
            gx, gy = i % gw, i // gw
            cx = (t[0, i] + gx) * s; cy = (t[1, i] + gy) * s
            bw = np.exp(t[2, i]) * s; bh = np.exp(t[3, i]) * s
            box = [np.clip((cx - bw / 2) / scale, 0, w), np.clip((cy - bh / 2) / scale, 0, h),
                   np.clip((cx + bw / 2) / scale, 0, w), np.clip((cy + bh / 2) / scale, 0, h)]
            dets.append((float(score[i]), int(best[i]), box))
    dets.sort(key=lambda d: (-d[0], d[2][1], d[2][0]))
    keep = []
    for d in dets:
        if all(k[1] != d[1] or iou(k[2], d[2]) < a.iou for k in keep):
            keep.append(d)
    for score, cl, b in keep:
        print("class=%s score=%.4f x0=%.1f y0=%.1f x1=%.1f y1=%.1f" % (classes[cl], score, *b))


if __name__ == "__main__":
    main()
