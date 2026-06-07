# vdec — InferNode host-side video decode core

`vdec` decodes any libavcodec-supported input (H.264/HEVC/MPEG/…) into
tightly-packed planar **I420** frames. It is the **decode core** for the
multiplexed-video bridge: a protocol-agnostic Rust crate that knows nothing
about 9P. See [`../../docs/H264-9P-BRIDGE.md`](../../docs/H264-9P-BRIDGE.md) for
the full architecture, the deferred 9P-boundary decision, and the kernel /
Jetson roadmap.

This is **phase 1**: prove the decode → I420 pipeline end to end, headless, on
macOS. No emulator, no 9P, no GUI.

## Build

Requires Rust and FFmpeg **6.x** development libraries (the crate is pinned to
the 6.1 series — see `Cargo.toml`).

### macOS

```sh
brew install ffmpeg@6
export PKG_CONFIG_PATH="$(brew --prefix ffmpeg@6)/lib/pkgconfig"
cargo build --release        # from tools/vdec/
```

`ffmpeg@6` is keg-only, hence the `PKG_CONFIG_PATH` so `ffmpeg-sys-next` can find
the libraries. (Plain `brew install ffmpeg` currently installs 7.x, which this
pin does not yet build against — tracked as a follow-up.)

### Linux (Ubuntu/Debian)

```sh
sudo apt-get install -y clang libavcodec-dev libavformat-dev libavutil-dev libswscale-dev ffmpeg
cargo build --release
```

## Use

```sh
# Report per-frame metadata
vdec clip.mp4

# Decode to a watchable YUV4MPEG2 stream
vdec clip.mp4 --y4m out.y4m
ffplay out.y4m               # eyeball the decode

# First 10 frames only
vdec clip.mp4 --limit 10
```

## Test

```sh
./test-vdec.sh
```

Generates an H.264 testsrc clip, decodes it through both `vdec` and `ffmpeg`, and
asserts the raw I420 is byte-identical — i.e. that the stride-stripping and plane
packing are correct. Prints `PASS`/`FAIL`.

## Status / roadmap

- **Now:** software decode (libavcodec). Output I420 maps 1:1 onto the `YCbCr`
  ADT the existing MPEG-1 render path already consumes.
- **Next (ticketed):** VideoToolbox (macOS) + NVDEC (Jetson) hwaccel backends;
  the thin Limbo `vid9p` styxserver that presents `/n/video`; reuse of
  `appl/mpeg` rendering; eventual fold of this crate into the Rust kernel.
