#!/usr/bin/env python3
"""
trtonnx: an ONNX detector made ready to build TensorRT engines from (#1086).

    trtonnx.py model.onnx out.onnx

The network vision(4) runs, for trtexec to build engines from (GPU, DLA):

  - cut at its detection heads, the tensors onnx2vis takes as heads (a
    head's Concat of box, objectness and classes, feeding only the
    rearranging tail on the way to the graph's output): the tail is
    vision(4)'s own decoding, done in Limbo, and the DLAs cannot run it;
  - every stride-1 max pool of kernel 9 or 13 (an SPP block) rewritten as
    a chain of 5x5 pools, which is the same function exactly (a max of
    maxes over the same window: 9 = 5 then 5, 13 = 5, 5, 5), since the
    DLAs pool at most 8x8;
  - the space-to-depth front (four strided Slices into a Concat, which
    TensorRT runs on the GPU even in a DLA engine) rewritten as the
    convolution it is: 2x2, stride 2, weights 0 or 1, an output channel
    a cell offset of an input channel; exact, the DLAs run it.

The output's heads are checked against the original's with onnxruntime on a
random input: they must agree exactly, or nothing is written.
"""

import sys

import numpy as np
import onnx
from onnx import helper, numpy_helper, shape_inference


def die(msg):
    sys.stderr.write("trtonnx: %s\n" % msg)
    sys.exit(1)


def heads_of(g):
    users = {}
    for n in g.node:
        for x in n.input:
            users.setdefault(x, []).append(n)
    outputs = {o.name for o in g.output}

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
    for n in g.node:
        if n.op_type == "Concat" and helper.get_attribute_value(n.attribute[0]) == 1 and tailonly(n.output[0]):
            heads.append(n.output[0])
    return heads


def rewrite_pools(g):
    nodes = []
    k5 = 0
    for n in g.node:
        a = {x.name: helper.get_attribute_value(x) for x in n.attribute}
        k = a.get("kernel_shape", [0])
        if (n.op_type == "MaxPool" and len(set(k)) == 1 and k[0] in (9, 13)
                and all(s == 1 for s in a.get("strides", [1]))
                and all(p == k[0] // 2 for p in a.get("pads", [0]))):
            reps = (k[0] - 1) // 4
            src = n.input[0]
            for i in range(reps):
                out = n.output[0] if i == reps - 1 else "%s_k5_%d" % (n.output[0], i)
                nodes.append(helper.make_node("MaxPool", [src], [out], name="%s_k5_%d" % (n.name, i),
                                              kernel_shape=[5, 5], strides=[1, 1], pads=[2, 2, 2, 2]))
                src = out
            k5 += 1
        else:
            nodes.append(n)
    del g.node[:]
    g.node.extend(nodes)
    return k5


def rewrite_s2d(g):
    consts = {t.name: numpy_helper.to_array(t) for t in g.initializer}
    for n in g.node:
        if n.op_type == "Constant":
            consts[n.output[0]] = numpy_helper.to_array(n.attribute[0].t)
    producer = {o: n for n in g.node for o in n.output}
    shapes = {v.name: [d.dim_value for d in v.type.tensor_type.shape.dim]
              for v in list(g.value_info) + list(g.input) + list(g.output)}
    done = 0
    nodes = []
    for n in g.node:
        if n.op_type == "Concat" and len(n.input) == 4 and all(
                x in producer and producer[x].op_type == "Slice" for x in n.input):
            order, src = [], None
            for x in n.input:
                s2 = producer[x]
                s1 = producer.get(s2.input[0])
                if s1 is None or s1.op_type != "Slice":
                    break
                st = (int(consts[s1.input[1]][0]), int(consts[s2.input[1]][0]))
                ax = (int(consts[s1.input[3]][0]), int(consts[s2.input[3]][0]))
                sp = (int(consts[s1.input[4]][0]), int(consts[s2.input[4]][0]))
                if ax != (2, 3) or sp != (2, 2) or (src is not None and s1.input[0] != src):
                    break
                src = s1.input[0]
                order.append(st)
            else:
                c = shapes[src][1]
                w = np.zeros((4 * c, c, 2, 2), dtype=np.float32)
                for j, (r, k) in enumerate(order):
                    for ch in range(c):
                        w[j * c + ch, ch, r, k] = 1.0
                wname = n.output[0] + "_s2d_w"
                g.initializer.append(numpy_helper.from_array(w, wname))
                nodes.append(helper.make_node("Conv", [src, wname], [n.output[0]], name=n.name + "_s2d",
                                              kernel_shape=[2, 2], strides=[2, 2], pads=[0, 0, 0, 0]))
                done += 1
                continue
        nodes.append(n)
    del g.node[:]
    g.node.extend(nodes)
    return done


def main():
    if len(sys.argv) != 3:
        die("usage: trtonnx.py model.onnx out.onnx")
    src, dst = sys.argv[1:]
    m = shape_inference.infer_shapes(onnx.load(src))
    g = m.graph
    heads = heads_of(g)
    if not heads:
        die("no detection heads found")
    vi = {v.name: v for v in list(g.value_info) + list(g.output)}
    for h in heads:
        if h not in vi:
            die("head %s has no shape" % h)
    npool = rewrite_pools(g)
    ns2d = rewrite_s2d(g)
    # the outputs are the heads; what only fed the tail goes
    del g.output[:]
    g.output.extend(vi[h] for h in heads)
    need = set(heads)
    keep = []
    for n in reversed(list(g.node)):
        if any(o in need for o in n.output):
            keep.append(n)
            need.update(n.input)
    keep.reverse()
    del g.node[:]
    g.node.extend(keep)
    live = need
    inits = [t for t in g.initializer if t.name in live]
    del g.initializer[:]
    g.initializer.extend(inits)
    onnx.checker.check_model(m)

    # the same heads, exactly, as the original computes them
    import onnxruntime as ort
    om = onnx.load(src)
    om.graph.output.extend(vi[h] for h in heads)
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    a = ort.InferenceSession(om.SerializeToString(), so, providers=["CPUExecutionProvider"])
    b = ort.InferenceSession(m.SerializeToString(), so, providers=["CPUExecutionProvider"])
    inp = a.get_inputs()[0]
    x = np.random.default_rng(1).random([d if isinstance(d, int) else 1 for d in inp.shape], dtype=np.float32) * 255
    ra = a.run(heads, {inp.name: x})
    rb = b.run(heads, {b.get_inputs()[0].name: x})
    for h, p, q in zip(heads, ra, rb):
        if p.shape != q.shape or not np.array_equal(p, q):
            die("head %s differs: max %g" % (h, float(np.max(np.abs(p - q)))))
    onnx.save(m, dst)
    print("trtonnx: %s: %d heads (%s), %d pools rewritten as 5x5 chains, %d space-to-depth as a convolution, %d nodes; heads exactly as the original's"
          % (dst, len(heads), " ".join("x".join(str(d.dim_value) for d in vi[h].type.tensor_type.shape.dim[1:]) for h in heads),
             npool, ns2d, len(g.node)))


main()
