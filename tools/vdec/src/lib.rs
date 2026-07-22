//! InferNode host-side video **decode core**.
//!
//! Turns a video file/stream into a sequence of tightly-packed planar **I420**
//! (YUV 4:2:0) frames using libavcodec. It is deliberately *protocol-agnostic*:
//! it knows nothing about 9P, Styx, or the emulator. The 9P boundary that
//! presents `/mnt/video` to InferNode is a separate, swappable layer
//! (see `docs/H264-9P-BRIDGE.md`).
//!
//! I420 is the canonical wire format precisely because it maps 1:1 onto the
//! `YCbCr` ADT (`appl/mpeg/mpegio.m`) that the existing MPEG-1 render path
//! (`appl/mpeg/remap24.b`, `vidplay.b`, and the Matrix `video-pane`) already
//! consumes. Everything downstream of a frame is therefore already built.
//!
//! # Inputs
//! Any libavcodec input: a local file, or a **network URL** — `rtsp://`,
//! `rtp://`, `http(s)://`, `udp://` (INFR-271). URLs are opened with an options
//! dictionary so RTSP transport and timeouts are controllable.
//!
//! # Decode backends
//! Software by default. A hardware backend (VideoToolbox on macOS, NVDEC/CUDA on
//! the Jetson, VAAPI/QSV on Linux) can be requested via [`HwAccel`] (INFR-265);
//! if the device or a matching codec hw-config is unavailable the core falls
//! back to software transparently. Hardware frames (NV12, etc.) are transferred
//! to system memory and converted to canonical I420 before the wire, so the
//! frame format stays platform-independent regardless of backend.
//!
//! # Why this crate exists separately
//! This is the durable, kernel-foldable artifact. The decode backend and the
//! frame format stay constant across every phase of the project; only the thing
//! that *fronts* it with 9P changes (Limbo styxserver shim now, Rust-native 9P
//! server when the kernel goes Rust).

use std::path::Path;
use std::ptr;

use ffmpeg_next as ffmpeg;
use ffmpeg::format::{input, input_with_dictionary, Pixel};
use ffmpeg::media::Type;
use ffmpeg::software::scaling::{context::Context as Scaler, flag::Flags};
use ffmpeg::util::frame::video::Video;
use ffmpeg::Dictionary;

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

/// Hardware decode backend selection. `None` is pure software (the default and
/// the only backend validated byte-for-byte against ffmpeg here); the rest name
/// a libavcodec hardware device type. Selection is best-effort: if the device
/// cannot be created, or the codec has no hw-config for it, the core logs and
/// falls back to software.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HwAccel {
    None,
    VideoToolbox,
    Nvdec,
    Cuda,
    Vaapi,
    Qsv,
}

impl HwAccel {
    /// Parse a `--hwaccel` name. `none`/empty -> software.
    pub fn parse(s: &str) -> Option<HwAccel> {
        match s {
            "none" | "" | "software" | "sw" => Some(HwAccel::None),
            "videotoolbox" | "vt" => Some(HwAccel::VideoToolbox),
            "nvdec" => Some(HwAccel::Nvdec),
            "cuda" | "cuvid" => Some(HwAccel::Cuda),
            "vaapi" => Some(HwAccel::Vaapi),
            "qsv" => Some(HwAccel::Qsv),
            _ => None,
        }
    }

    /// The libavutil device-type name, or `None` for software.
    fn device_name(self) -> Option<&'static str> {
        match self {
            HwAccel::None => None,
            HwAccel::VideoToolbox => Some("videotoolbox"),
            HwAccel::Nvdec => Some("nvdec"),
            HwAccel::Cuda => Some("cuda"),
            HwAccel::Vaapi => Some("vaapi"),
            HwAccel::Qsv => Some("qsv"),
        }
    }
}

/// Open-time options. `Default` is software decode with libavcodec's own
/// defaults — i.e. exactly the original behaviour.
#[derive(Clone, Debug)]
pub struct Options {
    pub hwaccel: HwAccel,
    /// RTSP transport: `Some("tcp")` forces TCP (recommended for lossy links),
    /// `Some("udp")` UDP. Ignored for non-RTSP inputs.
    pub rtsp_transport: Option<String>,
    /// I/O read timeout in microseconds for network inputs (libavformat
    /// `timeout`/`stimeout`). `None` leaves the libavformat default.
    pub timeout_us: Option<i64>,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            hwaccel: HwAccel::None,
            rtsp_transport: None,
            timeout_us: None,
        }
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
    /// The stream's average frame rate as a rational, `(0, _)` when the
    /// container doesn't declare one.
    frame_rate: (u32, u32),
    /// The hw pixel format frames arrive in when a hardware backend is active,
    /// or `AV_PIX_FMT_NONE` for software. Used to detect frames that must be
    /// transferred out of device memory before scaling.
    hw_pix_fmt: ffmpeg::ffi::AVPixelFormat,
}

/// True for a URL libavformat should open through a protocol handler
/// (rtsp/rtp/http/https/udp/tcp/...), as opposed to a filesystem path.
fn is_url(src: &str) -> bool {
    match src.find("://") {
        Some(i) => {
            let scheme = &src[..i];
            !scheme.is_empty() && scheme.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'-' || b == b'.')
        }
        None => false,
    }
}

impl Decoder {
    /// Open `path_or_url` with default (software) options.
    pub fn open(path_or_url: &str) -> Result<Self, ffmpeg::Error> {
        Self::open_with(path_or_url, &Options::default())
    }

    /// Open a file path or network URL and bind to its best video stream.
    ///
    /// Network URLs (`rtsp://`, `http://`, …) are opened with an options
    /// dictionary carrying `rtsp_transport`/`timeout` so live ingest is
    /// controllable; local paths ignore those options (INFR-271).
    pub fn open_with(source: &str, opts: &Options) -> Result<Self, ffmpeg::Error> {
        ffmpeg::init()?;

        let ictx = if is_url(source) {
            // Network protocols must be initialised before use.
            ffmpeg::format::network::init();
            let mut dict = Dictionary::new();
            if let Some(t) = &opts.rtsp_transport {
                dict.set("rtsp_transport", t);
            }
            if let Some(us) = opts.timeout_us {
                let v = us.to_string();
                // libavformat's socket read timeout, in microseconds. Both keys
                // are set because the option name differs across protocols
                // (`timeout` for TCP/HTTP, `stimeout` for older RTSP builds).
                dict.set("timeout", &v);
                dict.set("stimeout", &v);
            }
            input_with_dictionary(&Path::new(source), dict)?
        } else {
            input(&Path::new(source))?
        };

        let stream = ictx
            .streams()
            .best(Type::Video)
            .ok_or(ffmpeg::Error::StreamNotFound)?;
        let stream_index = stream.index();
        let tb = stream.time_base();
        let time_base = tb.numerator() as f64 / tb.denominator() as f64;
        let fr = stream.avg_frame_rate();
        let frame_rate = if fr.numerator() > 0 && fr.denominator() > 0 {
            (fr.numerator() as u32, fr.denominator() as u32)
        } else {
            (0, 1)
        };
        let params = stream.parameters();
        drop(stream);

        let mut ctx = ffmpeg::codec::context::Context::from_parameters(params)?;

        // Attach a hardware device if one was requested and is usable; leaves
        // `hw_pix_fmt = AV_PIX_FMT_NONE` (software) on any failure.
        let hw_pix_fmt = setup_hwaccel(&mut ctx, opts.hwaccel);

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
            frame_rate,
            hw_pix_fmt,
        })
    }

    /// The stream's declared average frame rate `(num, den)`, or `(0, 1)`
    /// when the container doesn't say (some raw/live streams).
    pub fn frame_rate(&self) -> (u32, u32) {
        self.frame_rate
    }

    /// Coded width as reported by the stream (may be 0 until the first frame for
    /// some containers; the per-frame dimensions in [`Frame`] are authoritative).
    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }

    /// Whether a hardware decode backend is actually active (a device was
    /// created and the codec has a matching hw-config). False means software.
    pub fn hw_active(&self) -> bool {
        self.hw_pix_fmt != ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_NONE
    }

    /// Decode every frame, handing each to `sink`. Return `false` from `sink` to
    /// stop early (e.g. a frame limit). This push API is all the headless
    /// validation and the frame-feeder need; a future 9P server wraps it in a
    /// thread + channel for pull-style backpressure.
    pub fn for_each_frame<F: FnMut(Frame) -> bool>(
        &mut self,
        mut sink: F,
    ) -> Result<(), ffmpeg::Error> {
        let stream_index = self.stream_index;
        let time_base = self.time_base;
        let hw_pix_fmt = self.hw_pix_fmt;
        // Split borrows of distinct fields so the packet iterator (which borrows
        // `ictx`) and the decoder/scaler can be used in the same scope.
        let ictx = &mut self.ictx;
        let decoder = &mut self.decoder;
        let scaler = &mut self.scaler;

        for (stream, packet) in ictx.packets() {
            if stream.index() == stream_index {
                decoder.send_packet(&packet)?;
                if !drain(decoder, scaler, time_base, hw_pix_fmt, &mut sink)? {
                    return Ok(());
                }
            }
        }
        decoder.send_eof()?;
        drain(decoder, scaler, time_base, hw_pix_fmt, &mut sink)?;
        Ok(())
    }
}

/// Configure `ctx` for hardware decoding of type `hw`. Returns the hw pixel
/// format frames will arrive in on success, or `AV_PIX_FMT_NONE` (software) if
/// the backend is `None`, the device type is unknown, the codec has no
/// hw-config for it, or device creation fails. Best-effort by design: a missing
/// GPU must degrade to software, never abort.
fn setup_hwaccel(
    ctx: &mut ffmpeg::codec::context::Context,
    hw: HwAccel,
) -> ffmpeg::ffi::AVPixelFormat {
    use ffmpeg::ffi::*;

    let none = AVPixelFormat::AV_PIX_FMT_NONE;
    let name = match hw.device_name() {
        Some(n) => n,
        None => return none,
    };

    unsafe {
        let cname = std::ffi::CString::new(name).unwrap();
        let dev_type = av_hwdevice_find_type_by_name(cname.as_ptr());
        if dev_type == AVHWDeviceType::AV_HWDEVICE_TYPE_NONE {
            eprintln!("vdec: hwaccel '{name}' not supported by this ffmpeg build; using software");
            return none;
        }

        // Find the codec's hw-config whose device type matches, to learn the
        // pixel format decoded frames will carry.
        let cctx = ctx.as_mut_ptr();
        let codec = avcodec_find_decoder((*cctx).codec_id);
        if codec.is_null() {
            return none;
        }
        let mut hw_pix = none;
        let mut i = 0;
        loop {
            let cfg = avcodec_get_hw_config(codec, i);
            if cfg.is_null() {
                break;
            }
            let methods = (*cfg).methods;
            if methods & (AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX as i32) != 0
                && (*cfg).device_type == dev_type
            {
                hw_pix = (*cfg).pix_fmt;
                break;
            }
            i += 1;
        }
        if hw_pix == none {
            eprintln!("vdec: codec has no '{name}' hw-config; using software");
            return none;
        }

        // Create the hardware device and attach it to the decoder context.
        let mut hw_device: *mut AVBufferRef = ptr::null_mut();
        let r = av_hwdevice_ctx_create(
            &mut hw_device,
            dev_type,
            ptr::null(),
            ptr::null_mut(),
            0,
        );
        if r < 0 {
            eprintln!("vdec: cannot create '{name}' device ({r}); using software");
            return none;
        }
        (*cctx).hw_device_ctx = av_buffer_ref(hw_device);
        av_buffer_unref(&mut hw_device);

        // Stash the target hw pixfmt in `opaque` (pointer-as-int; no allocation)
        // for the get_format callback to read, and install the callback so
        // libavcodec actually selects the hardware surface.
        (*cctx).opaque = hw_pix as i32 as isize as *mut std::os::raw::c_void;
        (*cctx).get_format = Some(get_hw_format);

        hw_pix
    }
}

/// libavcodec `get_format` callback: pick the hardware surface format we set up
/// for, else fall back to the first offered (software) format.
unsafe extern "C" fn get_hw_format(
    ctx: *mut ffmpeg::ffi::AVCodecContext,
    mut fmts: *const ffmpeg::ffi::AVPixelFormat,
) -> ffmpeg::ffi::AVPixelFormat {
    use ffmpeg::ffi::*;
    let target = (*ctx).opaque as isize as i32;
    let first = *fmts;
    while *fmts != AVPixelFormat::AV_PIX_FMT_NONE {
        if (*fmts) as i32 == target {
            return *fmts;
        }
        fmts = fmts.add(1);
    }
    // Hardware format not offered (shouldn't happen once set up): let the codec
    // proceed in software rather than failing the stream.
    first
}

/// Pull every frame currently buffered in the decoder, convert to I420, and feed
/// `sink`. Returns `Ok(false)` if `sink` asked to stop.
fn drain<F: FnMut(Frame) -> bool>(
    decoder: &mut ffmpeg::decoder::Video,
    scaler: &mut Option<Scaler>,
    time_base: f64,
    hw_pix_fmt: ffmpeg::ffi::AVPixelFormat,
    sink: &mut F,
) -> Result<bool, ffmpeg::Error> {
    let mut decoded = Video::empty();
    while decoder.receive_frame(&mut decoded).is_ok() {
        // A hardware-decoded frame lives in device memory in `hw_pix_fmt`;
        // transfer it to a system-memory frame (e.g. NV12) before scaling.
        let mut transferred;
        let src: &Video = if hw_pix_fmt != ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_NONE
            && is_hw_frame(&decoded)
        {
            transferred = Video::empty();
            transfer_hw_frame(&decoded, &mut transferred)?;
            &transferred
        } else {
            &decoded
        };

        let s = match scaler {
            Some(s) => s,
            None => {
                *scaler = Some(Scaler::get(
                    src.format(),
                    src.width(),
                    src.height(),
                    Pixel::YUV420P,
                    src.width(),
                    src.height(),
                    Flags::BILINEAR,
                )?);
                scaler.as_mut().unwrap()
            }
        };

        let mut yuv = Video::empty();
        s.run(src, &mut yuv)?;

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

/// True if `f` carries a hardware-surface reference (lives in device memory).
fn is_hw_frame(f: &Video) -> bool {
    unsafe { !(*f.as_ptr()).hw_frames_ctx.is_null() }
}

/// Copy a hardware frame out of device memory into `dst` (system memory),
/// carrying the presentation timestamp across.
fn transfer_hw_frame(src: &Video, dst: &mut Video) -> Result<(), ffmpeg::Error> {
    unsafe {
        let r = ffmpeg::ffi::av_hwframe_transfer_data(dst.as_mut_ptr(), src.as_ptr(), 0);
        if r < 0 {
            return Err(ffmpeg::Error::from(r));
        }
        (*dst.as_mut_ptr()).pts = (*src.as_ptr()).pts;
    }
    Ok(())
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
