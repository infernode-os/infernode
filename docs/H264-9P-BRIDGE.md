# H.264-over-9P video bridge

Status: **phases 1–3 landed, validated end to end** — host-side decode core
(`tools/vdec`, byte-identical to ffmpeg, network-URL ingest), the `vid9p` 9P
stream server with server-side transport and a live retention window, and the
Matrix render/control modules composed into player and live-wall
crystallisations. Remaining: real-GPU hwaccel validation, a real `rtsp://`
source, the Rust-native server, the kernel fold-in (see the phase map, §8).

Jira epic: **INFR-263**. This document is the design of record; the per-phase
tickets (INFR-264…271) point back here.

## 1. Why this exists

InferNode needs real-world video feeds (camera, screen-share, media walls). Those
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

### 2.3 The 9P interface (per stream) — built, INFR-266

As implemented in `appl/cmd/vid9p.b` (the design's per-read frame header was
dropped in favour of plain offset-addressed I420 — simpler, and it makes the
frame file random access, which is what buys seek/DVR/multi-viewer sync):

```
/mnt/video/<id>/ctl      # write: "open <file.y4m>" | "play [<cmd> arg...]"
                         #        "play" | "pause" | "stop"
                         #        "seek <ms>|+<ms>|-<ms>" | "live"
/mnt/video/<id>/fmt      # read:  "<w> <h> i420 <fps>"
/mnt/video/<id>/frame    # read:  raw I420; frame N is framesize bytes at
                         #        offset N*framesize (framesize = w*h*3/2).
                         #        Offsets are GLOBAL and monotonic.  On a live
                         #        stream, a read past the newest frame BLOCKS
                         #        until it decodes; a read below the retention
                         #        window errors "frame expired".
/mnt/video/<id>/status   # read:  "<src> w= h= framesize= frames= first= eof=
                         #        state= pos= t= follow="  (one line)
```

Mirrors the InferNode `ctl`+data idiom (`appl/cmd/llmsrv.b`,
`appl/veltro/tools9p.b`). Multiplex = one stream dir (one vid9p mount) per feed.

**Transport is server state.** The playhead (`state=`/`pos=`/`t=`) lives in
vid9p and is paced there at the stream's fps, so every consumer of a stream
renders the same synchronised frame, and anything that can write a file drives
playback identically — a Matrix `video-ctl` Tk button, a `video-pane`'s keys,
an agent, or plain sh:

```
echo pause > /mnt/video/0/ctl
echo 'seek +5000' > /mnt/video/0/ctl
```

On a live feed the playhead follows the newest decoded frame (`follow=1`);
seeking back replays the retained buffer (DVR) and `stop`/`live` snap back to
the edge.  On a canned clip, playback loops and `stop` rewinds paused.

**Retention.** A live feed keeps a sliding window of the last `-w` seconds
(default 60, `0` = unlimited) instead of growing without bound; `first=` in
status is the oldest retained frame and reads below it error.  Static sources
are always fully retained.  Covered by `tests/host/vid9p_transport_test.sh`.

### 2.4 Render path — reused, INFR-268

Unchanged from the MPEG-1 spike: read `frame` → wrap bytes as `Mpegio->YCbCr` →
`remap->remap(...)` → masked-pane `win.image.draw(dst, frame, matte, p)`
(`appl/mpeg/vidplay.b:77`). One player instance per feed.

Three consumers exist, all over the identical `fmt`+`frame`+`status` interface
and none adding pixel code:

- **`appl/mpeg/vidplay9p.b`** — a standalone `wmclient` window (optionally a
  shaped matte), the direct analogue of the MPEG-1 `vidplay`.
- **`appl/matrix/video-pane.b`** — a Matrix `MatrixDisplay` module: a pure
  VIEW of the server playhead (it preads whatever frame `pos=` names), so a
  feed becomes a pane in a composition and every pane on one feed shows the
  same frame. Exports `MatrixTicker` (40 ms) so the runtime drives it at frame
  cadence; transport keys forward down the ctl wire.
- **`appl/matrix/video-ctl.b`** — a Matrix `MatrixTkDisplay` module: real Tk
  transport buttons (play/pause/stop/±5s + position label), each press one ctl
  write. Compose beside a `video-pane` over the same mount.

The player and the feed wall are **crystallisations**, not applications:
`/lib/matrix/compositions/video-player` (pane + ctl over one mount) and
`video-live` (pane + ctl per live feed). See `docs/matrix-architecture.md`.

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
| 2 — hwaccel (VideoToolbox / NVDEC) | INFR-265 | ◑ selection + software fallback landed; GPU path pending on-device |
| 3a — Limbo `vid9p` styxserver shim | INFR-266 | ✅ done (static + live spawn + server-side transport + retention window) |
| 3b — render `/mnt/video` via mpeg path (`vidplay9p` + Matrix `video-pane`/`video-ctl`) | INFR-268 | ✅ done (player + live wall as crystallisations) |
| 4 — Rust-native 9P server | INFR-267 | to do |
| 5 — kernel fold-in (ABI TBD) | INFR-269 | blocked |
| 6 — live RTSP ingest | INFR-271 | ◑ URL/RTSP core + `vid9p -c` live spawn landed; UDP MPEG-TS validated end-to-end (demo-live.sh); a real `rtsp://` source still unexercised |
| chore — FFmpeg 7 / version-flexible pin | INFR-270 | to do |

`◑` = partially landed. INFR-265's hardware decode is structurally complete
(device create → `get_format` → `av_hwframe_transfer_data` → I420) and falls back
to software when no device is present; the GPU decode path itself needs
VideoToolbox/NVDEC hardware to validate. INFR-271's decode core accepts
`rtsp://`/`http://`/`udp://` URLs with transport/timeout options today; the
remaining step is to point `vid9p -c vdec <url> --y4m /fd/1` at a live feed.

Naming: this document and the shipped code use **`/mnt/video/<id>`** for the
mount. Some earlier tickets say `/n/video`; treat them as the same mount —
`/mnt/video` is canonical (it is what `vid9p`, `vidplay9p`, and `video-pane`
actually use).
