//! `vdet` — host-side video **detector**, prototype of the `/mnt/vision` stage.
//!
//! Decodes a source with the `vdec` library and emits one **detection record per
//! frame** to stdout, as greppable text:
//!
//! ```text
//! frame 0 pts=0ms bright 0.62 40 12 80 64
//! frame 1 pts=100ms none
//! ```
//!
//! The detector here is a deliberately simple, model-free luma-blob pass (bounding
//! box of pixels brighter than a threshold) — enough to prove the
//! frame → detections-as-text → 9P pipeline end to end. A real YOLO/ONNX backend
//! swaps in behind [`detect`] without changing the record format or the
//! downstream `vision9p`/`msg9p` plumbing. See `docs/ML-VISION-9P.md`.

use std::env;
use std::io::{self, Write};
use std::process::exit;

use vdec::{Decoder, Frame};

struct Det {
    class: &'static str,
    conf: f32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
}

/// Model-free placeholder detector: the bounding box of all luma pixels above
/// `thresh`, with "confidence" = fill density of that box. Returns `None` when
/// nothing is bright enough. Swap this for a YOLO/ONNX forward pass; the caller
/// and the wire format do not change.
fn detect(f: &Frame, thresh: u8) -> Option<Det> {
    let (w, h) = (f.width as usize, f.height as usize);
    if w == 0 || h == 0 || f.data.len() < w * h {
        return None;
    }
    let y = &f.data[0..w * h];

    let (mut minx, mut miny, mut maxx, mut maxy) = (w, h, 0usize, 0usize);
    let mut count = 0usize;
    for row in 0..h {
        let base = row * w;
        for col in 0..w {
            if y[base + col] > thresh {
                if col < minx { minx = col }
                if col > maxx { maxx = col }
                if row < miny { miny = row }
                if row > maxy { maxy = row }
                count += 1;
            }
        }
    }
    if count == 0 {
        return None;
    }
    let bw = maxx - minx + 1;
    let bh = maxy - miny + 1;
    let conf = count as f32 / (bw * bh).max(1) as f32;
    Some(Det {
        class: "bright",
        conf,
        x: minx as u32,
        y: miny as u32,
        w: bw as u32,
        h: bh as u32,
    })
}

fn main() {
    let mut args = env::args().skip(1);
    let mut src: Option<String> = None;
    let mut thresh: u8 = 200;
    let mut limit: Option<u64> = None;

    while let Some(a) = args.next() {
        match a.as_str() {
            "--thresh" => {
                thresh = args
                    .next()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or_else(|| die("--thresh needs 0..255"))
            }
            "--limit" => {
                limit = Some(
                    args.next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or_else(|| die("--limit needs a number")),
                )
            }
            "--quiet" | "-q" => { /* accepted for symmetry with vdec */ }
            "-h" | "--help" => usage(),
            other => {
                if other.starts_with('-') {
                    die(&format!("unknown flag {other}"));
                }
                if src.is_some() {
                    die("only one source allowed");
                }
                src = Some(other.to_string());
            }
        }
    }
    let src = src.unwrap_or_else(|| usage());

    let mut dec = Decoder::open(&src).unwrap_or_else(|e| {
        eprintln!("vdet: open {src}: {e}");
        exit(1);
    });

    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut n: u64 = 0;

    let r = dec.for_each_frame(|f: Frame| {
        if let Some(l) = limit {
            if n >= l {
                return false;
            }
        }
        let line = match detect(&f, thresh) {
            Some(d) => format!(
                "frame {n} pts={}ms {} {:.2} {} {} {} {}\n",
                f.pts_ms, d.class, d.conf, d.x, d.y, d.w, d.h
            ),
            None => format!("frame {n} pts={}ms none\n", f.pts_ms),
        };
        // Flush per record so a downstream 9P reader sees detections live.
        if out.write_all(line.as_bytes()).is_err() || out.flush().is_err() {
            return false;
        }
        n += 1;
        true
    });

    if let Err(e) = r {
        eprintln!("vdet: decode error: {e}");
        exit(1);
    }
}

fn usage() -> ! {
    eprintln!("usage: vdet <source> [--thresh 0..255] [--limit N]");
    eprintln!();
    eprintln!("Decode a file or rtsp:// source and emit one detection record per");
    eprintln!("frame to stdout (prototype /mnt/vision detector).");
    exit(2);
}

fn die(msg: &str) -> ! {
    eprintln!("vdet: {msg}");
    exit(2);
}
