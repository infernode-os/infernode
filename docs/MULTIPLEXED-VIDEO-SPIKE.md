# Multiplexed video on InferNode — feasibility spike

Status: **proven viable (headless, Linux/amd64).** Decode path validated end to
end; GUI masked-pane player compiles against the current API and is ready to run
on a GUI emu (macOS).

## What this is

A working port of Inferno Second Edition's pure-Limbo **MPEG-1 video decoder**
(`inferno-2e/appl/mpeg`, MIT) to the current InferNode tree, plus a windowed
player that blits decoded frames into a WM window **through a matte image** — so
a feed can appear inside an arbitrary cutout (oval, rounded, bezel). Multiplex =
one player instance per feed.

This grounds the larger question (camera feeds, media video walls): Inferno
was designed for set-top video, and the decode→`writepixels`→masked-`draw`
pipeline is real, not theoretical.

## Files (`appl/mpeg/`)

- `mpegio.m` / `mpegio.b` — MPEG-1 system/elementary bitstream parser; emits
  planar `YCbCr`. VLC Huffman tables are compile-time `include "*.tab"`.
- `decode.b` — I/P/B picture decode with motion compensation (loads an IDCT).
- `scidct.b` — scaled-integer IDCT (the default `IDCT->PATH`).
- `remap24.b` — YCbCr→packed RGB24 for truecolor displays (no dithering).
- `vidplay.b` — GUI player: `wmclient` window + matte compositing.
- `mpegtest.b` — headless: decode N frames, dump PPMs (decode validation).
- `mpegperf.b` — headless: timed decode+remap throughput.

## Modernization (1999 → 2026)

The **entire** language drift was reserved-word collisions:
- `raise` became a keyword → renamed the error helper to `mperror`, and the
  `sys->raise(x)` throw sites became the keyword statement `raise x;`.
- `fixed` became a keyword → only appeared in the `vlc` table *generator*
  (not needed at runtime; the generated `.tab` files are checked in).

Plus the modern image API: `newimage` takes a `Chans` descriptor (`RGB24`,
`GREY8`) instead of a raw `ldepth`, and the fully-opaque matte is
`display.opaque` (was `display.ones`). No algorithmic changes.

## Measured (Linux/amd64, 2.1 GHz Xeon, 1 core, JIT `-c1`, headless)

- Single MPEG-1 SIF (352×240) stream: **~65 fps decode + YCbCr→RGB24 remap**
  (99 frames in 1521 ms). Interpreter (`-c0`) is many× slower — use the JIT.
- Implication: ~2 SIF feeds/core at 30 fps, ~4 at 15 fps. Apple-silicon cores
  run ~2–3× faster single-thread.

Decode correctness confirmed by eye: ffmpeg `testsrc` color bars + circle +
gradient decode recognizably, with working P-frame motion (frames evolve, no
drift). Dis bytecode is portable, so the same `.dis` runs on macOS arm64.

## Masked-pane compositing (the "video through a cutout" idiom)

The hinge is `Image.draw(dst, r, src, matte, p)`: the 4th arg is a per-pixel
matte. `vidplay.b` builds a `GREY8` matte once (0 = hidden, 255 = visible),
e.g. an ellipse via `matte.fillellipse(...)`, then each frame:

    frame.writepixels(vr, remap->remap(ycbcr));   # decoded RGB24 -> staging
    win.image.draw(dst, frame, matte, vr.min);     # composite THROUGH matte

Pass `display.opaque` as the matte for a plain full-frame blit (`-shape rect`).

## Running on macOS (GUI)

    export ROOT=$PWD; export PATH=$PWD/MacOSX/arm64/bin:$PATH
    cd appl/mpeg && mk install            # builds .dis into /dis/mpeg
    # then from a lucifer/wm shell inside emu:
    #   mpeg/vidplay -shape oval /path/to/clip.m1v
    # multiplex: launch several, one per feed.

Make a test clip:  `ffmpeg -f lavfi -i testsrc=size=352x240:rate=25:duration=4 \
  -c:v mpeg1video -pix_fmt yuv420p -bf 0 -f mpeg1video clip.m1v`

## Limitations / next steps

- **MPEG-1 only.** Real-world feeds are H.264/HEVC/AV1 → still want
  host-side decode (an external service feeding raw/JPEG frames over 9P,
  mirroring the connector pattern). Everything downstream of a frame is done.
  **→ Now under way: see [H264-9P-BRIDGE.md](H264-9P-BRIDGE.md) (Jira epic
  INFR-263). Phase 1 — the `tools/vdec` host decode core — is landed and
  validated; it emits the same I420 this render path consumes.**
- **GOP/B-frame edge:** the spike clips use a single GOP, no B-frames. The
  B-frame display-reorder + multi-GOP path needs a once-over before arbitrary
  streams (the upstream player handles it; port not yet exercised here).
- **Single software framebuffer:** all panes composite on CPU into one screen
  texture (see `emu/port/draw-sdl3.c`); fine for a handful of SIF feeds, not a
  wall of HD30. Per-window GPU surfaces would be a separate emu-display project.

## Provenance

Decoder ported from `github.com/inferno-os/inferno-2e` `appl/mpeg` (Inferno
Second Edition, 1999; redistributed by Vita Nuova under MIT).

## Update (2026-06-07): chroma/color decode fixed

Initial macOS testing showed heavy horizontal color streaking. Root-caused by
comparing our decoded planes against ffmpeg (ground truth) and bisecting:
luma + chroma were exact in flat regions, but every block with detail rang.
The cause was the **escape-coded DCT level sign-extension** in `mpegio.b`:

    l = (l << 24) >> 24;   # does NOT sign-extend correctly in Limbo

MPEG-1 escape levels are 8-bit signed (129..255 mean -127..-1). The shift idiom
left them positive, so escape coefficients became huge spurious AC values
(clamped), producing ringing in both luma and chroma. Luma garbage hid in busy
content; chroma garbage showed as streaks over smooth areas. Fixed with an
explicit:

    if (l > 127) l -= 256;

Verified against ffmpeg on a SIF testsrc clip: max per-pixel error dropped from
255 to 21 (the remaining ~15 mean is chroma-upsampling/range rounding vs
ffmpeg, not corruption). Latent in Inferno 2e because escape codes are rare on
low-detail content and dithered 8-bit displays masked them; testsrc's sharp
edges trigger escapes constantly and exposed it.
