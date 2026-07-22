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

## Inputs

A local file **or** a network URL — `rtsp://`, `rtp://`, `http(s)://`, `udp://`
(INFR-271). URLs open through libavformat's protocol layer with an options
dictionary:

```sh
vdec rtsp://cam.local/stream --rtsp-transport tcp --timeout 5 --y4m out.y4m
vdec http://host/clip.mp4 --limit 100
```

`--rtsp-transport tcp|udp` forces the RTSP transport; `--timeout SECONDS` sets a
network I/O read timeout.

## Hardware decode

`--hwaccel none|videotoolbox|nvdec|cuda|vaapi|qsv` selects a libavcodec hardware
backend (INFR-265). Selection is **best-effort**: if the device can't be created
or the codec has no matching hw-config, `vdec` logs and falls back to software.
Hardware frames are transferred to system memory and converted to canonical I420
before the wire, so the output format is identical across backends. `none`
(default) is the only backend validated byte-for-byte against ffmpeg here;
VideoToolbox (macOS) / NVDEC (Jetson) need on-device validation.

## Status / roadmap

- **Now:** software decode (byte-identical to ffmpeg); file and network-URL
  (RTSP/RTP/HTTP/UDP) inputs; `--hwaccel` selection with software fallback.
  Output I420 maps 1:1 onto the `YCbCr` ADT the existing render path consumes.
- **Live in InferNode:** the Limbo `vid9p` styxserver presents `/mnt/video`, and
  both `appl/mpeg/vidplay9p` and the Matrix `video-pane` render it.
- **Next (ticketed):** validate VideoToolbox/NVDEC on real hardware; Rust-native
  9P server; eventual fold of this crate into the Rust kernel.
