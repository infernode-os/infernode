//! InferNode host-side video **decode core**.
//!
//! Turns a video file/stream into a sequence of tightly-packed planar **I420**
//! (YUV 4:2:0) frames using libavcodec. It is deliberately *protocol-agnostic*:
//! it knows nothing about 9P, Styx, or the emulator. The 9P boundary that
//! presents `/n/video` to InferNode is a separate, swappable layer
//! (see `docs/H264-9P-BRIDGE.md`).
//!
//! I420 is the canonical wire format precisely because it maps 1:1 onto the
//! `YCbCr` ADT (`appl/mpeg/mpegio.m`) that the existing MPEG-1 render path
//! (`appl/mpeg/remap24.b`, `vidplay.b`) already consumes. Everything downstream
//! of a frame is therefore already built and validated.
//!
//! # Why this crate exists separately
//! This is the durable, kernel-foldable artifact. The decode backend (software
//! now; VideoToolbox/NVDEC hwaccel later) and the frame format stay constant
//! across every phase of the project; only the thing that *fronts* it with 9P
//! changes (Limbo styxserver shim now, Rust-native 9P server when the kernel
//! goes Rust).

use std::path::Path;

use ffmpeg_next as ffmpeg;
use ffmpeg::format::{input, Pixel};
use ffmpeg::media::Type;
use ffmpeg::software::scaling::{context::Context as Scaler, flag::Flags};
use ffmpeg::util::frame::video::Video;

/// One decoded frame, tightly packed as planar I420: `Y` (w·h bytes) followed by
/// `Cb` then `Cr` (each (w/2)·(h/2) bytes), with all libavcodec row padding
/// removed so the buffer can go straight onto the wire / into a `YCbCr` ADT.
pub struct Frame {
    pub width: u32,
    pub height: u32,
    /// Presentation timestamp in milliseconds, or `-1` if the source had none.
    pub pts_ms: i64,
    pub data: Vec<u8>,
}

impl Frame {
    /// The byte length a correct I420 buffer must have for these dimensions.
    pub fn expected_len(&self) -> usize {
        let y = (self.width as usize) * (self.height as usize);
        let c = ((self.width / 2) as usize) * ((self.height / 2) as usize);
        y + 2 * c
    }
}

/// A demuxer + decoder bound to the best video stream of an input.
pub struct Decoder {
    ictx: ffmpeg::format::context::Input,
    decoder: ffmpeg::decoder::Video,
    /// Built lazily from the first decoded frame's pixel format, so we never
    /// depend on `decoder.format()` being known before decoding begins.
    scaler: Option<Scaler>,
    stream_index: usize,
    time_base: f64,
    width: u32,
    height: u32,
}

impl Decoder {
    /// Open `path` and bind to its best video stream.
    pub fn open(path: &str) -> Result<Self, ffmpeg::Error> {
        ffmpeg::init()?;
        let ictx = input(&Path::new(path))?;

        let stream = ictx
            .streams()
            .best(Type::Video)
            .ok_or(ffmpeg::Error::StreamNotFound)?;
        let stream_index = stream.index();
        let tb = stream.time_base();
        let time_base = tb.numerator() as f64 / tb.denominator() as f64;
        let params = stream.parameters();
        drop(stream);

        let ctx = ffmpeg::codec::context::Context::from_parameters(params)?;
        let decoder = ctx.decoder().video()?;
        let (width, height) = (decoder.width(), decoder.height());

        Ok(Self {
            ictx,
            decoder,
            scaler: None,
            stream_index,
            time_base,
            width,
            height,
        })
    }

    /// Coded width as reported by the stream (may be 0 until the first frame for
    /// some containers; the per-frame dimensions in [`Frame`] are authoritative).
    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }

    /// Decode every frame, handing each to `sink`. Return `false` from `sink` to
    /// stop early (e.g. a frame limit). This push API is all the headless
    /// validation and the eventual frame-feeder need; the future 9P server wraps
    /// it in a thread + channel for pull-style backpressure.
    pub fn for_each_frame<F: FnMut(Frame) -> bool>(
        &mut self,
        mut sink: F,
    ) -> Result<(), ffmpeg::Error> {
        let stream_index = self.stream_index;
        let time_base = self.time_base;
        // Split borrows of distinct fields so the packet iterator (which borrows
        // `ictx`) and the decoder/scaler can be used in the same scope.
        let ictx = &mut self.ictx;
        let decoder = &mut self.decoder;
        let scaler = &mut self.scaler;

        for (stream, packet) in ictx.packets() {
            if stream.index() == stream_index {
                decoder.send_packet(&packet)?;
                if !drain(decoder, scaler, time_base, &mut sink)? {
                    return Ok(());
                }
            }
        }
        decoder.send_eof()?;
        drain(decoder, scaler, time_base, &mut sink)?;
        Ok(())
    }
}

/// Pull every frame currently buffered in the decoder, convert to I420, and feed
/// `sink`. Returns `Ok(false)` if `sink` asked to stop.
fn drain<F: FnMut(Frame) -> bool>(
    decoder: &mut ffmpeg::decoder::Video,
    scaler: &mut Option<Scaler>,
    time_base: f64,
    sink: &mut F,
) -> Result<bool, ffmpeg::Error> {
    let mut decoded = Video::empty();
    while decoder.receive_frame(&mut decoded).is_ok() {
        let s = match scaler {
            Some(s) => s,
            None => {
                *scaler = Some(Scaler::get(
                    decoded.format(),
                    decoded.width(),
                    decoded.height(),
                    Pixel::YUV420P,
                    decoded.width(),
                    decoded.height(),
                    Flags::BILINEAR,
                )?);
                scaler.as_mut().unwrap()
            }
        };

        let mut yuv = Video::empty();
        s.run(&decoded, &mut yuv)?;

        let pts_ms = decoded
            .pts()
            .map(|p| (p as f64 * time_base * 1000.0) as i64)
            .unwrap_or(-1);

        if !sink(pack_i420(&yuv, pts_ms)) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Copy a YUV420P `Video` frame into a tightly-packed I420 buffer, stripping the
/// per-row stride padding libavcodec inserts for alignment.
fn pack_i420(f: &Video, pts_ms: i64) -> Frame {
    let width = f.width();
    let height = f.height();
    let mut data =
        Vec::with_capacity(f.width() as usize * f.height() as usize * 3 / 2);

    for plane in 0..3usize {
        let (pw, ph) = if plane == 0 {
            (width as usize, height as usize)
        } else {
            ((width / 2) as usize, (height / 2) as usize)
        };
        let stride = f.stride(plane);
        let buf = f.data(plane);
        for row in 0..ph {
            let start = row * stride;
            data.extend_from_slice(&buf[start..start + pw]);
        }
    }

    Frame {
        width,
        height,
        pts_ms,
        data,
    }
}
