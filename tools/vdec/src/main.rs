//! `vdec` — headless driver for the video decode core.
//!
//! Decodes any libavcodec-supported input (H.264/HEVC/MPEG/…) to planar I420 and
//! either reports per-frame metadata or writes a YUV4MPEG2 (`.y4m`) stream you
//! can watch with `ffplay`. This is the macOS-testable artifact of phase 1: it
//! proves the decode → I420 pipeline end to end with no 9P and no emulator.

use std::env;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::process::exit;

use vdec::{Decoder, Frame};

fn main() {
    let mut args = env::args().skip(1);
    let mut path: Option<String> = None;
    let mut limit: Option<usize> = None;
    let mut y4m: Option<String> = None;
    let mut quiet = false;

    while let Some(a) = args.next() {
        match a.as_str() {
            "--limit" => {
                limit = Some(
                    args.next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or_else(|| die("--limit needs a number")),
                )
            }
            "--y4m" => y4m = Some(args.next().unwrap_or_else(|| die("--y4m needs a path"))),
            "--quiet" | "-q" => quiet = true,
            "-h" | "--help" => usage(),
            other => {
                if other.starts_with('-') {
                    die(&format!("unknown flag {other}"));
                }
                if path.is_some() {
                    die("only one input allowed");
                }
                path = Some(other.to_string());
            }
        }
    }
    let path = path.unwrap_or_else(|| usage());

    let mut dec = Decoder::open(&path).unwrap_or_else(|e| {
        eprintln!("vdec: open {path}: {e}");
        exit(1);
    });
    let (w, h) = (dec.width(), dec.height());
    if !quiet {
        eprintln!("vdec: {path}  {w}x{h}  -> I420");
    }

    let mut writer = y4m.as_ref().map(|p| {
        let f = File::create(p).unwrap_or_else(|e| {
            eprintln!("vdec: create {p}: {e}");
            exit(1);
        });
        let mut bw = BufWriter::new(f);
        // Frame rate is cosmetic for validation; 25:1 keeps ffplay happy.
        writeln!(bw, "YUV4MPEG2 W{w} H{h} F25:1 Ip A1:1 C420mpeg2").unwrap();
        bw
    });

    let mut count = 0usize;
    let mut bytes = 0u64;

    let r = dec.for_each_frame(|frame: Frame| {
        if let Some(l) = limit {
            if count >= l {
                return false;
            }
        }
        debug_assert_eq!(
            frame.data.len(),
            frame.expected_len(),
            "I420 buffer is not tightly packed"
        );

        if let Some(bw) = writer.as_mut() {
            let _ = bw.write_all(b"FRAME\n");
            let _ = bw.write_all(&frame.data);
        }
        if !quiet {
            eprintln!(
                "frame {count:5}  {}x{}  pts={}ms  len={}",
                frame.width, frame.height, frame.pts_ms, frame.data.len()
            );
        }
        count += 1;
        bytes += frame.data.len() as u64;
        true
    });

    if let Err(e) = r {
        eprintln!("vdec: decode error: {e}");
        exit(1);
    }
    if let Some(bw) = writer.as_mut() {
        let _ = bw.flush();
    }
    eprintln!("vdec: {count} frames, {bytes} bytes of I420");
}

fn usage() -> ! {
    eprintln!("usage: vdec <input> [--limit N] [--y4m OUT.y4m] [--quiet]");
    eprintln!();
    eprintln!("Host-side video decode core: decodes any libavcodec-supported input");
    eprintln!("(H.264/HEVC/MPEG/...) to tightly-packed planar I420 frames.");
    eprintln!("  --y4m OUT   write decoded frames as YUV4MPEG2 (watch: ffplay OUT)");
    eprintln!("  --limit N   stop after N frames");
    eprintln!("  --quiet     suppress per-frame logging");
    exit(2);
}

fn die(msg: &str) -> ! {
    eprintln!("vdec: {msg}");
    exit(2);
}
