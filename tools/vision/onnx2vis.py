#!/usr/bin/env python3
"""
onnx2vis: an ONNX detector to a vision(4) model directory (#1086).

    onnx2vis.py [--classes file] [--decode yolox] [--check] model.onnx outdir

The directory it makes:

    graph     the network, one operation a line, attr=value (see below)
    weights   every weight and bias, float32 little-endian, in graph order
    classes   one class name a line, in index order
    info      kind=detect decode=yolox input=416x416 classes=80 order=bgr fill=114
    sha256    sha256 of weights (vision(4) refuses weights that do not match)

The graph's operations, on tensors of one image, channels then rows then
columns (CHW), float32:

    input name=T c= h= w=
    conv out= in= oc= ic= kh= kw= stride= pad= group= act=none|silu|sigmoid|relu w= b=
    add out= a= b=
    act out= in= act=sigmoid|silu|relu
    maxpool out= in= k= stride= pad=
    up2 out= in=                        nearest, twice the rows and columns
    s2d out= in=                        space to depth: the 2x2 cells (0,0) (1,0)
                                        (0,1) (1,1) as four times the channels
    concat out= in=a,b,...              along channels
    output name= in= stride=            a detection head, stride pixels a cell

w= and b= are offsets in floats into weights; a conv's weights are
oc x ic/group x kh x kw, its bias oc. Everything vision(4) needs to run a
model is here: the converter is the only thing that reads ONNX.

Only what detectors of the YOLOX family use is converted; anything else
is refused, naming the operation.

--check runs the graph with numpy (as vision(4)'s engine will) against
onnxruntime on a random input, and fails if they differ.
"""
import argparse, hashlib, os, sys
import numpy as np
import onnx
from onnx import shape_inference, numpy_helper, helper

COCO = ("person bicycle car motorcycle airplane bus train truck boat traffic_light "
        "fire_hydrant stop_sign parking_meter bench bird cat dog horse sheep cow "
        "elephant bear zebra giraffe backpack umbrella handbag tie suitcase frisbee "
        "skis snowboard sports_ball kite baseball_bat baseball_glove skateboard "
        "surfboard tennis_racket bottle wine_glass cup fork knife spoon bowl banana "
        "apple sandwich orange broccoli carrot hot_dog pizza donut cake chair couch "
        "potted_plant bed dining_table toilet tv laptop mouse remote keyboard "
        "cell_phone microwave oven toaster sink refrigerator book clock vase scissors "
        "teddy_bear hair_drier toothbrush").split()


def die(msg):
    sys.exit("onnx2vis: " + msg)


def convert(path):
    m = shape_inference.infer_shapes(onnx.load(path))
    g = m.graph
    shapes = {v.name: [d.dim_value for d in v.type.tensor_type.shape.dim]
              for v in list(g.value_info) + list(g.input) + list(g.output)}
    inits = {i.name: numpy_helper.to_array(i) for i in g.initializer}
    consts = {}
    for n in g.node:
        if n.op_type == "Constant":
            consts[n.output[0]] = numpy_helper.to_array(n.attribute[0].t)
    val = lambda x: inits[x] if x in inits else consts.get(x)
    nodes = [n for n in g.node if n.op_type != "Constant"]
    producer = {o: n for n in nodes for o in n.output}
    users = {}
    for n in nodes:
        for x in n.input:
            users.setdefault(x, []).append(n)
    outputs = {o.name for o in g.output}

    names = {}
    def name(x):
        if x not in names:
            names[x] = "t%d" % len(names)
        return names[x]

    ops, weights = [], []
    woff = [0]
    def addw(a):
        a = np.ascontiguousarray(a, dtype=np.float32).ravel()
        off = woff[0]
        weights.append(a)
        woff[0] += a.size
        return off

    real_inputs = [i for i in g.input if i.name not in inits]
    if len(real_inputs) != 1:
        die("one input wanted, have %d" % len(real_inputs))
    inp = real_inputs[0].name
    _, c, h, w = shapes[inp]
    ops.append("input name=%s c=%d h=%d w=%d" % (name(inp), c, h, w))

    done = set()
    # which tensors feed only the rearranging tail (Reshape, Concat on
    # rows, Transpose) on the way to the graph's output: those are heads
    def tailonly(x):
        for u in users.get(x, []):
            if u.op_type not in ("Reshape", "Transpose", "Concat"):
                return False
            if u.op_type == "Concat" and helper.get_attribute_value(u.attribute[0]) == 1:
                return False
            for o in u.output:
                if o not in outputs and not tailonly(o):
                    return False
        return True

    heads = []
    for n in nodes:
        if id(n) in done:
            continue
        op = n.op_type
        a = {x.name: helper.get_attribute_value(x) for x in n.attribute}
        if op == "Slice":
            # the space-to-depth front: four strided slices into one Concat
            continue
        if op == "Concat" and all(x in producer and producer[x].op_type == "Slice" for x in n.input):
            src = producer[producer[n.input[0]].input[0]].input[0]
            order = []
            for x in n.input:
                s2 = producer[x]
                s1 = producer[s2.input[0]]
                starts = (int(val(s1.input[1])[0]), int(val(s2.input[1])[0]))
                axes = (int(val(s1.input[3])[0]), int(val(s2.input[3])[0]))
                steps = (int(val(s1.input[4])[0]), int(val(s2.input[4])[0]))
                if axes != (2, 3) or steps != (2, 2) or s1.input[0] != src:
                    die("a Slice that is not space to depth")
                order.append(starts)
            if order != [(0, 0), (1, 0), (0, 1), (1, 1)]:
                die("space to depth in another order: %s" % order)
            ops.append("s2d out=%s in=%s" % (name(n.output[0]), name(src)))
            continue
        if op == "Conv":
            wt = val(n.input[1])
            b = val(n.input[2]) if len(n.input) > 2 else np.zeros(wt.shape[0], np.float32)
            group = a.get("group", 1)
            kh, kw = wt.shape[2], wt.shape[3]
            st = a.get("strides", [1, 1])
            pads = a.get("pads", [0, 0, 0, 0])
            dil = a.get("dilations", [1, 1])
            if st[0] != st[1] or len(set(pads)) != 1 or dil != [1, 1]:
                die("conv %s: unequal strides, pads or dilation" % n.name)
            out = n.output[0]
            act = "none"
            us = users.get(out, [])
            # Sigmoid then Mul(x, sigmoid(x)): SiLU, folded in
            if len(us) == 2 and {u.op_type for u in us} == {"Sigmoid", "Mul"}:
                sg = [u for u in us if u.op_type == "Sigmoid"][0]
                mu = [u for u in us if u.op_type == "Mul"][0]
                if set(mu.input) == {out, sg.output[0]} and users.get(sg.output[0]) == [mu]:
                    act = "silu"
                    done.add(id(sg)); done.add(id(mu))
                    out = mu.output[0]
            elif len(us) == 1 and us[0].op_type in ("Sigmoid", "Relu"):
                act = us[0].op_type.lower()
                done.add(id(us[0]))
                out = us[0].output[0]
            ic = wt.shape[1] * group
            ops.append("conv out=%s in=%s oc=%d ic=%d kh=%d kw=%d stride=%d pad=%d group=%d act=%s w=%d b=%d" % (
                name(out), name(n.input[0]), wt.shape[0], ic, kh, kw, st[0], pads[0], group, act,
                addw(wt), addw(b)))
            continue
        if op in ("Sigmoid", "Relu"):
            ops.append("act out=%s in=%s act=%s" % (name(n.output[0]), name(n.input[0]), op.lower()))
            continue
        if op == "Mul":
            die("a Mul that is not SiLU after a conv (%s)" % n.name)
        if op == "Add":
            ops.append("add out=%s a=%s b=%s" % (name(n.output[0]), name(n.input[0]), name(n.input[1])))
            continue
        if op == "MaxPool":
            k = a["kernel_shape"]; s = a.get("strides", [1, 1]); p = a.get("pads", [0, 0, 0, 0])
            if k[0] != k[1] or s[0] != s[1] or len(set(p)) != 1 or a.get("ceil_mode", 0):
                die("maxpool %s: not square" % n.name)
            ops.append("maxpool out=%s in=%s k=%d stride=%d pad=%d" % (name(n.output[0]), name(n.input[0]), k[0], s[0], p[0]))
            continue
        if op == "Resize":
            scales = val(n.input[2]) if len(n.input) > 2 else None
            if a.get("mode") != b"nearest" or scales is None or list(scales) != [1.0, 1.0, 2.0, 2.0]:
                die("resize %s: only nearest, twice" % n.name)
            ops.append("up2 out=%s in=%s" % (name(n.output[0]), name(n.input[0])))
            continue
        if op == "Concat":
            if a["axis"] == 1:
                ops.append("concat out=%s in=%s" % (name(n.output[0]), ",".join(name(x) for x in n.input)))
                # a head's own concat of box, objectness and classes is the head
                if tailonly(n.output[0]):
                    heads.append(n.output[0])
            continue
        if op in ("Reshape", "Transpose"):
            continue
        die("operation %s (%s) is not converted" % (op, n.name))

    for hd in heads:
        _, hc, hh, hw = shapes[hd]
        ops.append("output name=s%d in=%s stride=%d" % (h // hh, name(hd), h // hh))
    allw = np.concatenate(weights).astype("<f4") if weights else np.zeros(0, "<f4")
    return ops, allw, (c, h, w), heads, shapes


# ---- the numpy reference: what vision(4)'s engine must compute ----

def parse(line):
    f = line.split()
    return f[0], dict(x.split("=", 1) for x in f[1:])


def actf(x, a):
    if a == "silu":
        return x / (1.0 + np.exp(-x))
    if a == "sigmoid":
        return 1.0 / (1.0 + np.exp(-x))
    if a == "relu":
        return np.maximum(x, 0)
    return x


def conv2d(x, w, b, stride, pad, group):
    c, h, wd = x.shape
    oc, icg, kh, kw = w.shape
    xp = np.pad(x, ((0, 0), (pad, pad), (pad, pad)))
    oh = (h + 2 * pad - kh) // stride + 1
    ow = (wd + 2 * pad - kw) // stride + 1
    out = np.empty((oc, oh, ow), np.float32)
    ocg = oc // group
    for gi in range(group):
        xs = xp[gi * icg:(gi + 1) * icg]
        cols = np.empty((icg, kh, kw, oh, ow), np.float32)
        for i in range(kh):
            for j in range(kw):
                cols[:, i, j] = xs[:, i:i + stride * oh:stride, j:j + stride * ow:stride]
        cols = cols.reshape(icg * kh * kw, oh * ow)
        wg = w[gi * ocg:(gi + 1) * ocg].reshape(ocg, -1)
        out[gi * ocg:(gi + 1) * ocg] = (wg @ cols).reshape(ocg, oh, ow)
    return out + b[:, None, None]


def run(ops, weights, x):
    t = {}
    outs = {}
    for line in ops:
        op, a = parse(line)
        if op == "input":
            t[a["name"]] = x
        elif op == "conv":
            oc, ic, kh, kw, g = (int(a[k]) for k in ("oc", "ic", "kh", "kw", "group"))
            wo, bo = int(a["w"]), int(a["b"])
            w = weights[wo:wo + oc * (ic // g) * kh * kw].reshape(oc, ic // g, kh, kw)
            b = weights[bo:bo + oc]
            t[a["out"]] = actf(conv2d(t[a["in"]], w, b, int(a["stride"]), int(a["pad"]), g), a["act"])
        elif op == "add":
            t[a["out"]] = t[a["a"]] + t[a["b"]]
        elif op == "act":
            t[a["out"]] = actf(t[a["in"]], a["act"])
        elif op == "maxpool":
            k, s, p = int(a["k"]), int(a["stride"]), int(a["pad"])
            xi = np.pad(t[a["in"]], ((0, 0), (p, p), (p, p)), constant_values=-np.inf)
            c, h, w = t[a["in"]].shape
            oh, ow = (h + 2 * p - k) // s + 1, (w + 2 * p - k) // s + 1
            o = np.full((c, oh, ow), -np.inf, np.float32)
            for i in range(k):
                for j in range(k):
                    o = np.maximum(o, xi[:, i:i + s * oh:s, j:j + s * ow:s])
            t[a["out"]] = o
        elif op == "up2":
            t[a["out"]] = t[a["in"]].repeat(2, axis=1).repeat(2, axis=2)
        elif op == "s2d":
            x0 = t[a["in"]]
            t[a["out"]] = np.concatenate([x0[:, 0::2, 0::2], x0[:, 1::2, 0::2], x0[:, 0::2, 1::2], x0[:, 1::2, 1::2]])
        elif op == "concat":
            t[a["out"]] = np.concatenate([t[n] for n in a["in"].split(",")])
        elif op == "output":
            outs[a["name"]] = (t[a["in"]], int(a["stride"]))
    return outs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("onnx")
    ap.add_argument("outdir")
    ap.add_argument("--classes")
    ap.add_argument("--decode", default="yolox")
    ap.add_argument("--order", default="bgr", help="channel order the model was trained on")
    ap.add_argument("--fill", type=int, default=114, help="letterbox fill")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    ops, weights, (c, h, w), heads, shapes = convert(args.onnx)
    nclass = shapes[heads[0]][1] - 5 if heads else 0
    classes = open(args.classes).read().split() if args.classes else COCO
    if len(classes) != nclass:
        die("%d classes named, the model has %d" % (len(classes), nclass))
    os.makedirs(args.outdir, exist_ok=True)
    wb = weights.astype("<f4").tobytes()
    open(os.path.join(args.outdir, "graph"), "w").write("vis 1\n" + "\n".join(ops) + "\n")
    open(os.path.join(args.outdir, "weights"), "wb").write(wb)
    open(os.path.join(args.outdir, "classes"), "w").write("\n".join(classes) + "\n")
    open(os.path.join(args.outdir, "sha256"), "w").write(hashlib.sha256(wb).hexdigest() + "\n")
    open(os.path.join(args.outdir, "info"), "w").write(
        "kind=detect decode=%s input=%dx%d classes=%d order=%s fill=%d\n" % (
            args.decode, w, h, nclass, args.order, args.fill))
    print("onnx2vis: %d operations, %d weights, %d heads -> %s" % (len(ops), weights.size, len(heads), args.outdir))

    if args.check:
        import onnxruntime as ort
        rng = np.random.default_rng(1)
        x = rng.uniform(0, 255, (1, c, h, w)).astype(np.float32)
        # the heads, from onnxruntime, by asking for them as outputs
        m = onnx.load(args.onnx)
        for hd in heads:
            m.graph.output.append(helper.make_tensor_value_info(hd, onnx.TensorProto.FLOAT, None))
        sess = ort.InferenceSession(m.SerializeToString(), providers=["CPUExecutionProvider"])
        want = sess.run(heads, {sess.get_inputs()[0].name: x})
        got = run(ops, weights, x[0])
        worst = 0.0
        for (k, (gv, s)), wv in zip(got.items(), want):
            d = np.abs(gv - wv[0]).max()
            scale = np.abs(wv).max()
            worst = max(worst, d / scale)
            print("onnx2vis: head %s stride %d %s: max |diff| %.3g of %.3g" % (k, s, gv.shape, d, scale))
        if worst > 1e-4:
            die("the graph does not compute what the ONNX does (worst %.3g)" % worst)
        print("onnx2vis: check ok")


if __name__ == "__main__":
    main()
