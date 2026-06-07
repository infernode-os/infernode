# H.264-over-9P video bridge

Status: **phase 1 landed** — host-side decode core (`tools/vdec`) builds and is
validated byte-identical to ffmpeg. Phases 2–6 are designed and ticketed below.

Jira epic: **INFR-263**. This document is the design of record; the per-phase
tickets (INFR-264…271) point back here.

## 1. Why this exists

InferNode needs real-world video feeds (drone / camera / TAK video walls). Those
are H.264/HEVC/AV1. The MPEG-1 spike (`docs/MULTIPLEXED-VIDEO-SPIKE.md`) proved
the *render* half of the problem by porting Inferno 2e's **pure-Limbo MPEG-1
decoder that runs inside the Dis VM** and blitting `YCbCr` frames through a
masked pane. That approach does not extend to modern codecs:

- A pure-Limbo H.264/HEVC decoder in the Dis VM is not viable at usable frame
  rates.
- The VM cannot reach hardware decoders (NVDEC on the Jetson, VideoToolbox on
  macOS), which is exactly where this workload must run.

So this bridge **inverts** the MPEG-1 architecture: decode **outside** the VM on
the host, and deliver finished frames into InferNode over **9P**. This is the
explicit next step the spike itself called for ("still want host-side decode … an
external service feeding raw/JPEG frames over 9P … everything downstream of a
frame is done").

| | MPEG-1 (spike, done) | H.264 bridge (this doc) |
|---|---|---|
| Decode location | in-VM, pure Limbo | **out-of-VM, host process** |
| Hardware accel | n/a | NVDEC / VideoToolbox / sw |
| Frame format | planar `YCbCr` | identical planar I420 |
| Render | `remap24.b` + `vidplay.b` | **reuse unchanged** |

## 2. Architecture

```
                 host process (Rust)                    InferNode (emu)
  ┌─────────────────────────────────────┐        ┌───────────────────────────┐
  file/RTSP ─▶ │ vdec core: libavcodec ─▶ I420 frames │ ──9P──▶ │ /mnt/video/<id>/{ctl,fmt,frame,status}      │
               │ (sw now; NVDEC/VT later)             │        │   │                                       │
               └─────────────────────────────────────┘        │   ▼ read frame → YCbCr ADT                │
                                                               │   remap24 → masked-pane writepixels/draw  │
                                                               └───────────────────────────┘
```

The **frame format and the decode core are invariant** across every phase. The
only thing that changes over time is *who emits the 9P bytes* (§5).

### 2.1 The decode core (`tools/vdec`) — INFR-264 ✅

A protocol-agnostic Rust crate. It knows nothing about 9P, Styx, or the
emulator — it turns an input into a sequence of frames:

```rust
let mut dec = Decoder::open("clip.mp4")?;
dec.for_each_frame(|frame| {           // frame.{width,height,pts_ms,data}
    // frame.data is tightly-packed I420 (stride padding removed)
    true                                // return false to stop early
})?;
```

This is the **durable artifact**. Keeping it 9P-agnostic is what lets the 9P
front swap (Limbo shim → Rust-native → kernel builtin) without ever touching the
decoder. The `vdec` CLI drives it headless for validation (`--y4m`, `--limit`).

### 2.2 Frame format: I420

Tightly-packed planar YUV 4:2:0: `Y` (w·h bytes), then `Cb`, then `Cr` (each
(w/2)·(h/2) bytes), libavcodec row-stride padding stripped. Chosen because it
maps **1:1 onto the `YCbCr` ADT** (`appl/mpeg/mpegio.m:84`) that `remap24.b`
already consumes — so the render path needs no new code.

Hardware decoders that emit other layouts (VideoToolbox → NV12) convert to I420
in the core *before the wire*, so the format is platform-independent (INFR-265).

### 2.3 The 9P interface (per stream) — designed, INFR-266

```
/mnt/video/<id>/ctl      # write: "open <path>", "play", "seek <ms>", "stop"
/mnt/video/<id>/fmt      # read:  "<w> <h> i420 <fps>"
/mnt/video/<id>/frame    # read:  blocking; one frame per read:
                       #        header {magic,w,h,fmt,pts,len} + I420 bytes
/mnt/video/<id>/status   # read:  state / pts / eof
```

Mirrors the InferNode `ctl`+data idiom (`appl/cmd/llmsrv.b`,
`appl/veltro/tools9p.b`). Multiplex = one stream dir (and one player) per feed.

### 2.4 Render path — reused, INFR-268

Unchanged from the MPEG-1 spike: read `frame` → wrap bytes as `Mpegio->YCbCr` →
`remap->remap(...)` → masked-pane `win.image.draw(dst, frame, matte, p)`
(`appl/mpeg/vidplay.b:77`). One player instance per feed.

## 3. Build & test on macOS (phase 1)

```sh
brew install ffmpeg@6
export PKG_CONFIG_PATH="$(brew --prefix ffmpeg@6)/lib/pkgconfig"
cd tools/vdec
cargo build --release
./test-vdec.sh                 # PASS = vdec I420 byte-identical to ffmpeg
./target/release/vdec clip.mp4 --y4m out.y4m && ffplay out.y4m
```

`ffmpeg@6` (not default `ffmpeg`, which is 7.x) because the crate is pinned to
the 6.1 series — see INFR-270. Validated in CI/dev containers on Ubuntu FFmpeg
6.1; the Dis bytecode / render side is platform-independent.

## 4. Security

Threat model priority is adversarial input and protocol/emulator compromise
(see `AGENTS.md`). Relevant here:

- **Untrusted bitstreams.** H.264 decoders are a classic memory-corruption
  surface. Decode runs in a **separate host process** (not in-VM, not in a future
  kernel until hardened), so a decoder crash/exploit is contained to that process
  and does not touch the VM. Run it under OS sandboxing where available.
- **Mount auth.** Dev uses loopback `mount -A` (anon). Any non-loopback listener
  MUST use keyring auth (`mount -k <keyfile>`), consistent with serve-llm
  (INFR-16) and the `lib/sh` profiles. The shipped/headless posture keeps auth
  on — never expose `/mnt/video` anonymously off-box.
- **Not ring-fenced.** This is a general capability and ships normally; it is not
  part of `tests/agent-harness/`.

## 5. The 9P boundary decision (recorded)

"External 9P service" has two internals, differing on how thin the in-VM surface
is and what survives a Rust-kernel rewrite:

- **Phase 2a — thin Limbo styxserver shim (INFR-266).** Reuse InferNode's proven
  `styxservers.m` machinery; the Rust core just emits frames over a pipe. Fast,
  low-risk — but adds a Limbo server to the VM surface, and that 9P layer is
  **rewritten, not lifted**, when the kernel goes Rust.
- **Phase 2b — Rust-native 9P server (INFR-267).** The Rust service presents
  `/mnt/video` directly; in-VM is only `mount` + the render loop (the thinnest VM
  surface). This is the kernel-aligned endpoint; the Limbo shim is deleted.

**Decision:** do 2a first as a *deliberately disposable* shim to land a visible
slice, then migrate to 2b. The decode core does not change across the migration —
that is the entire point of keeping it protocol-agnostic. This was a conscious
trade (de-risk now vs. thin-surface now), not an accident.

## 6. Future: fold into the kernel (INFR-269)

When the kernel is rewritten in Rust (`infernode-os/infernode-rust`), the `vdec`
core can be lifted **in-process as a builtin**, so frames skip the IPC copy.

Grounded on what is readable today — the **C builtin-module ABI**: how
`Crypt`/`Keyring`/`Math` register in `libinterp` (builtin tables, type
descriptors, GC interop). A Rust-kernel builtin needs the equivalent
registration + a memory-ownership story for frame buffers crossing the
Rust↔runtime boundary.

> **TBD — pending `infernode-rust` access.** That repo is out of this session's
> scope and not publicly fetchable, so its actual module/FFI ABI is unknown.
> This section must be completed against the real ABI before INFR-269 starts;
> until then the C ABI is the reference model only.

## 7. Future: Jetson NVDEC hardware port (INFR-265)

The Jetson (Orin) decodes H.264/HEVC on NVDEC via libavcodec's `cuvid`/`nvdec`
hwaccel. Same `Decoder` API; the work is: select the CUDA hwdevice, keep frames
on the GPU as long as possible, and convert NV12→I420 (ideally on-GPU) before the
wire. macOS exercises the *same hwaccel seam* via VideoToolbox, so a green macOS
hwaccel run gives high confidence the Jetson port is a backend swap, not a
redesign. (A future per-window GPU-surface path in the emu display would remove
the CPU framebuffer bottleneck for HD walls — separate project, noted in the
spike's limitations.)

## 8. Phase map

| Phase | Ticket | State |
|------|--------|-------|
| 1 — decode core + headless macOS validation | INFR-264 | ✅ done |
| 2 — hwaccel (VideoToolbox / NVDEC) | INFR-265 | to do |
| 3a — Limbo `vid9p` styxserver shim | INFR-266 | to do |
| 3b — render `/mnt/video` via mpeg path | INFR-268 | to do |
| 4 — Rust-native 9P server | INFR-267 | to do |
| 5 — kernel fold-in (ABI TBD) | INFR-269 | blocked |
| 6 — live RTSP ingest | INFR-271 | to do |
| chore — FFmpeg 7 / version-flexible pin | INFR-270 | to do |
