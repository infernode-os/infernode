# ML vision inference as composable 9P services

**Status:** design exploration (INFR-277) — not committed work. Cross-refs:
`docs/H264-9P-BRIDGE.md` / INFR-263 (the video bridge), nerva3
`appl/nerva/TAK-VIDEO.md` / INFR-272 (the NERVA closed loop), INFR-278
(namespace convention).

## Premise

Inference is **just another model served as a filesystem** — the same shape as
`llm9p`. Three patterns that already exist in the tree combine directly:

- **models as filesystems** — `/mnt/llm` (your LLM stack)
- **frames as a filesystem** — `/mnt/video` (the decode bridge)
- **structured events as a mailbox** — `msg9p` (`/mnt/msg`)

A vision stage is a service that **reads one namespace and writes another**. That
is the whole Plan 9 thesis; ML doesn't need a special mechanism, it needs to obey
the existing one.

## Namespace convention

Synthetic **service** file servers live under `/mnt` (e.g. `/mnt/llm` — INFR #216,
`/mnt/mcp` — #213). `/n` is reserved for fully-mounted **remote filesystem
trees** (another machine's namespace). So vision uses `/mnt/video` and
`/mnt/vision`. (`/n/{tak,msg,llm}` were the same drift and have since been
migrated to `/mnt` under INFR-254; `/n/mail`, `/n/cal` correctly stay on `/n`
as genuinely remote resources.)

## Two shapes

### Detector (YOLO / TensorRT) — frame → structured data

```
/mnt/vision/<id>/
    ctl          # "src /mnt/video/0", "model yolov8n", "classes person,vehicle", "rate 5"
    detections   # read (blocking): one text record per processed frame
    status
```

It **consumes `/mnt/video/<id>/frame` itself**, so it composes with the decoder
with no glue — exactly how `vidplay` consumes the same frames. Output is
**text records** (Plan 9 style: greppable, `tail -f`-able, pipeable):

```
pts=1623ms  person 0.94 320,180 64,140   vehicle 0.88 500,300 120,90
```

Those records flow straight into `msg9p` as C2 events — vision becomes tactical
events on the same async substrate as TAK chat.

### VLM — "describe / answer about this video"

Extend the `/mnt/llm` session to multimodal (attach a frame, or a *reference* to
`/mnt/video/<id>/frame`), or a thin `/mnt/vlm/<id>/{ctl,ask,reply}` that pulls
frames from `/mnt/video`. The agent never touches pixels or tensors.

## Distributed multi-stage pipelines (the point)

Every stage is a 9P service; you **compose by mounting across boxes over Styx**:

```
 box A (capture/decode)     box B (detect)              box C (track / fuse / VLM)     agent (anywhere)
 vdec, NVDEC                 mounts A:/mnt/video         mounts B:/mnt/vision           mounts C semantics
 /mnt/video/0/frame   ─────▶ /mnt/vision/det/0/detections ─────▶ /mnt/vision/track/0   ─────▶ reasons, no pixels
```

- **Fan-out:** several detectors on one feed (different models/classes).
- **Fan-in:** one tracker/fusion stage over many feeds.
- **Chaining:** detect → re-id → VLM caption → fusion.

Stage placement is a **deployment choice** (an ndb-style config, like `ndb/llm`),
not baked into any component. This is the composable distributed universe made
literal.

## Locality: engineer the cut, don't avoid distributing

Because every edge is a mount, you can put any stage on any box. The only physics
is bandwidth: **frame edges are fat** (~MB per frame), **semantic edges are thin**
(bytes of detections/text). So you *choose which edges cross the network* —
co-locate a fat hop when the pipe is scarce, distribute it when you have the
bandwidth or when the GPU you need is on another box. The architecture makes the
cut a configuration decision, never a constraint. (This corrects an earlier
"keep pixels local" overstatement — locality is a tunable, not a rule.)

## The closed loop (NERVA)

Detection bbox + KLV/MISB camera pose → ground coordinates → **CoT marker back to
TAK** through the `takchat` boundary (same boundary, reverse direction). NERVA
watches a drone feed, recognizes a vehicle, and publishes a marker to the TAK
map. See nerva3 `appl/nerva/TAK-VIDEO.md`.

## Serving lifecycle & resources

A vision serving authority mirrors `llmctl` (load/select/place models). On a
single Orin, **NVDEC + inference + a local LLM contend for the GPU** — real
budgeting, per box. Pre/post-processing (I420→RGB→letterbox→tensor, NMS) is
**confined inside the service**: wire stays I420 in / text out, same
boundary-confinement principle as CoT and pixel formats.

## Where it lives

- **Generic InferNode (public core):** the vision *service* — a sibling of
  `vdec` and `llm9p`. Host inference process (ONNXRuntime/TensorRT), 9P front
  (Limbo shim now → native later → kernel builtin), same migration arc as `vdec`.
- **NERVA policy (`appl/nerva/`):** which feeds to watch, alert thresholds, and
  the detection→CoT-marker routing (boundary work in `takchat`).

## Honest open questions

- **Backpressure / frame-drop policy** across stages under load (a slow detector
  must not stall decode; `pts` lets late stages drop, not block).
- **Time alignment** of detections to frames across hosts — `pts` is the join key.
- **Trust graph:** each inference node is another mount; it needs the same keyring
  auth as other 9P services, and distributed model provenance/signing matters
  (cf. module signing, INFR-13).
- **Model/format coverage:** detector input tensors and 10-bit sources interact
  with the I420 wire decision (cf. INFR-263 codec/10-bit thread).
