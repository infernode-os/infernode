//! trtsrv: TensorRT engines on the Jetson's GPU and DLAs as a 9P file tree
//! on standard input and output, for vision(4) (#1086).
//!
//! vision(4) starts it through the host command device and mounts the pipe,
//! so it is never on the network and only vision(4) is exported. Decoding a
//! picture, the letterbox, the detector's own decoding and NMS stay in
//! vision(4), shared with the Pi's engine; here a tensor goes in and tensors
//! come out.
//!
//! ```text
//! ctl        w  load NAME PLACE ENGINE SHA256   (PLACE gpu | dla0 | dla1)
//!               unload NAME
//!            r  a line a model: model NAME place=dla0 type=f16 in=3x416x416
//!               out=85x52x52,85x26x26,85x13x13 sha256=...  (type: f32 or
//!               f16, all of an engine's tensors)
//! clone      r  a new session's number, N; the session lasts while one of
//!               its files is open
//! N/ctl      rw model NAME
//! N/run      rw an inference an open: write the input tensor (of the
//!               model's type, exactly its size), then read its outputs,
//!               the heads in the engine's order
//! N/status   r  state=ready model=NAME place=dla0 runs=N ms_p50= ms_p95=
//! ```
//!
//! A place is chosen before the engine is deserialized, and an engine whose
//! layers did not land where asked is refused: on a DLA, every layer but
//! the reformatting copies at its edges must be the DLA's.

mod sha256;
mod trt;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use styx9p::{Answer, Ctx, File, Filesystem, Qid, Result, Server, Stat, errors, read_at};
use trt::{Engine, Place};

const QROOT: u64 = 0;
const QCTL: u64 = 1;
const QCLONE: u64 = 2;
// a session N's files: N << 8 | kind
const KDIR: u64 = 0;
const KCTL: u64 = 1;
const KRUN: u64 = 2;
const KSTATUS: u64 = 3;
const NMS: usize = 64;

struct Model {
    engine: Arc<Engine>,
    place: Place,
    sha: String,
}

struct Session {
    // the context before the engine it was made from, so it goes first
    ctx: Option<trt::Ctx>,
    model: Option<(String, Arc<Engine>, Place)>,
    opens: usize,
    runs: u64,
    ms: Vec<f64>,
    err: Option<String>,
}

#[derive(Default)]
struct State {
    models: HashMap<String, Model>,
    sessions: HashMap<u64, Arc<Mutex<Session>>>,
    next: u64,
}

#[derive(Default, Clone)]
struct Trt {
    st: Arc<Mutex<State>>,
}

fn qsess(n: u64, kind: u64) -> Qid {
    let p = n << 8 | kind;
    if kind == KDIR { Qid::dir(p) } else { Qid::file(p) }
}

impl Trt {
    fn session(&self, n: u64) -> Option<Arc<Mutex<Session>>> {
        self.st.lock().unwrap().sessions.get(&n).cloned()
    }

    fn ctl(&self, line: &str) -> std::result::Result<(), String> {
        let w: Vec<&str> = line.split_whitespace().collect();
        match w.as_slice() {
            ["load", name, place, path, sha] => {
                let place = Place::parse(place).ok_or_else(|| format!("{place}: not gpu, dla0 or dla1"))?;
                let blob = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
                let got = sha256::hex(&blob);
                if got != *sha {
                    return Err(format!("{name}: engine is not the one recorded"));
                }
                let engine = Engine::load(&blob, place)?;
                if std::env::var_os("TRTSRV_LAYERS").is_some() {
                    for l in &engine.layers {
                        eprintln!("trtsrv: layer {l:?}");
                    }
                }
                placed(&engine, place)?;
                if engine.inputs().count() != 1 {
                    return Err(format!("{name}: one input wanted"));
                }
                if engine.tensors.iter().any(|t| t.esize != engine.tensors[0].esize) {
                    return Err(format!("{name}: its tensors are of more than one type"));
                }
                let m = Model { engine: Arc::new(engine), place, sha: got };
                self.st.lock().unwrap().models.insert(name.to_string(), m);
                Ok(())
            }
            ["unload", name] => match self.st.lock().unwrap().models.remove(*name) {
                Some(_) => Ok(()),
                None => Err(format!("{name}: no such model")),
            },
            _ => Err(format!("bad ctl: {line}")),
        }
    }

    fn ctltext(&self) -> String {
        let st = self.st.lock().unwrap();
        let mut names: Vec<&String> = st.models.keys().collect();
        names.sort();
        let mut s = String::new();
        for n in names {
            let m = &st.models[n];
            let ins: Vec<String> = m.engine.inputs().map(|t| t.shape()).collect();
            let outs: Vec<String> = m.engine.outputs().map(|t| t.shape()).collect();
            let kind = m.engine.tensors.first().map(|t| t.kind()).unwrap_or("f32");
            s += &format!("model {n} place={} type={kind} in={} out={} sha256={}\n", m.place.name(), ins.join(","), outs.join(","), m.sha);
        }
        s
    }
}

/// A layer's type, as the engine's inspector gives it ("DLA", "Reformat",
/// a GPU kernel's kind), or None if the engine does not say (one built
/// without --profilingVerbosity=detailed).
fn layertype(l: &str) -> Option<&str> {
    let k = "\"LayerType\": \"";
    let i = l.find(k)? + k.len();
    let j = l[i..].find('"')?;
    Some(&l[i..i + j])
}

/// An engine's layers where its place says. On a DLA, every layer is the
/// DLA's but the reformatting copies at its edges; on the GPU, none is.
/// An engine that does not say where its layers run is refused.
fn placed(e: &Engine, place: Place) -> std::result::Result<(), String> {
    if e.layers.is_empty() {
        return Err("the engine has no layers to look at".into());
    }
    let mut types = Vec::new();
    for l in &e.layers {
        match layertype(l) {
            Some(t) => types.push(t),
            None => return Err("the engine does not say where its layers run: build it with --profilingVerbosity=detailed".into()),
        }
    }
    match place {
        Place::Gpu => {
            if types.contains(&"DLA") {
                return Err("a GPU engine with layers on a DLA".into());
            }
        }
        Place::Dla(_) => {
            if !types.contains(&"DLA") {
                return Err("a DLA engine with no layer on the DLA".into());
            }
            if let Some(t) = types.iter().find(|t| **t != "DLA" && **t != "Reformat") {
                return Err(format!("a DLA engine with a layer on the GPU ({t})"));
            }
        }
    }
    Ok(())
}

enum Kind {
    Text(Mutex<Answer>, Option<(Trt, Option<u64>)>), // ctl: Some((fs, session)); else read only
    Clone(u64, Trt),
    Run(u64, Trt, Mutex<RunState>),
    Hold(u64, Trt),
}

#[derive(Default)]
struct RunState {
    input: Vec<u8>,
    base: Option<u64>,
    answer: Option<Answer>,
}

struct TrtFile {
    kind: Kind,
}

impl Drop for TrtFile {
    fn drop(&mut self) {
        let (n, fs) = match &self.kind {
            Kind::Clone(n, fs) | Kind::Run(n, fs, _) | Kind::Hold(n, fs) => (*n, fs),
            Kind::Text(_, Some((fs, Some(n)))) => (*n, fs),
            _ => return,
        };
        let mut st = fs.st.lock().unwrap();
        let gone = match st.sessions.get(&n) {
            Some(s) => {
                let mut s = s.lock().unwrap();
                s.opens = s.opens.saturating_sub(1);
                s.opens == 0
            }
            None => false,
        };
        if gone {
            st.sessions.remove(&n);
        }
    }
}

impl Filesystem for Trt {
    type File = TrtFile;

    fn attach(&self, _: &Ctx) -> Result<Qid> {
        Ok(Qid::dir(QROOT))
    }

    fn walk1(&self, _: &Ctx, dir: Qid, name: &str) -> Result<Qid> {
        if dir.path == QROOT {
            return match name {
                "ctl" => Ok(Qid::file(QCTL)),
                "clone" => Ok(Qid::file(QCLONE)),
                ".." => Ok(Qid::dir(QROOT)),
                _ => match name.parse::<u64>() {
                    Ok(n) if self.session(n).is_some() => Ok(qsess(n, KDIR)),
                    _ => Err(errors::NOT_FOUND.into()),
                },
            };
        }
        let n = dir.path >> 8;
        match name {
            "ctl" => Ok(qsess(n, KCTL)),
            "run" => Ok(qsess(n, KRUN)),
            "status" => Ok(qsess(n, KSTATUS)),
            ".." => Ok(Qid::dir(QROOT)),
            _ => Err(errors::NOT_FOUND.into()),
        }
    }

    fn stat(&self, _: &Ctx, q: Qid) -> Result<Stat> {
        Ok(match q.path {
            QROOT => Stat::new("/", q, 0o555, 0),
            QCTL => Stat::new("ctl", q, 0o644, 0),
            QCLONE => Stat::new("clone", q, 0o444, 0),
            p => {
                let n = p >> 8;
                match p & 0xff {
                    KDIR => Stat::new(n.to_string(), q, 0o555, 0),
                    KCTL => Stat::new("ctl", q, 0o644, 0),
                    KRUN => Stat::new("run", q, 0o666, 0),
                    _ => Stat::new("status", q, 0o444, 0),
                }
            }
        })
    }

    fn readdir(&self, ctx: &Ctx, dir: Qid) -> Result<Vec<Stat>> {
        if dir.path == QROOT {
            let mut v = vec![self.stat(ctx, Qid::file(QCTL))?, self.stat(ctx, Qid::file(QCLONE))?];
            let mut ns: Vec<u64> = self.st.lock().unwrap().sessions.keys().copied().collect();
            ns.sort();
            for n in ns {
                v.push(self.stat(ctx, qsess(n, KDIR))?);
            }
            return Ok(v);
        }
        let n = dir.path >> 8;
        [KCTL, KRUN, KSTATUS].iter().map(|k| self.stat(ctx, qsess(n, *k))).collect()
    }

    fn open(&self, _: &Ctx, q: Qid, _mode: u8) -> Result<TrtFile> {
        let hold = |n: u64| -> Result<()> {
            let s = self.session(n).ok_or(errors::NOT_FOUND)?;
            s.lock().unwrap().opens += 1;
            Ok(())
        };
        let kind = match q.path {
            QCTL => Kind::Text(Mutex::new(Answer::default()), Some((self.clone(), None))),
            QCLONE => {
                let mut st = self.st.lock().unwrap();
                st.next += 1;
                let n = st.next;
                let s = Session { ctx: None, model: None, opens: 1, runs: 0, ms: Vec::new(), err: None };
                st.sessions.insert(n, Arc::new(Mutex::new(s)));
                Kind::Clone(n, self.clone())
            }
            p => {
                let n = p >> 8;
                hold(n)?;
                match p & 0xff {
                    KCTL => Kind::Text(Mutex::new(Answer::default()), Some((self.clone(), Some(n)))),
                    KRUN => Kind::Run(n, self.clone(), Mutex::new(RunState::default())),
                    _ => Kind::Hold(n, self.clone()),
                }
            }
        };
        Ok(TrtFile { kind })
    }
}

fn pct(ms: &[f64], p: f64) -> f64 {
    if ms.is_empty() {
        return 0.0;
    }
    let mut v = ms.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() - 1) as f64 * p).round() as usize]
}

impl File for TrtFile {
    async fn read(&self, offset: u64, count: u32) -> Result<Vec<u8>> {
        match &self.kind {
            Kind::Clone(n, _) => Ok(read_at(format!("{n}\n").as_bytes(), offset, count)),
            Kind::Text(a, Some((fs, None))) => {
                let mut a = a.lock().unwrap();
                if offset == 0 {
                    a.set(fs.ctltext());
                }
                Ok(a.read(offset, count))
            }
            Kind::Text(a, Some((fs, Some(n)))) => {
                let s = fs.session(*n).ok_or(errors::NOT_FOUND)?;
                let mut a = a.lock().unwrap();
                if offset == 0 {
                    let s = s.lock().unwrap();
                    a.set(match &s.model {
                        Some((name, _, _)) => format!("model {name}\n"),
                        None => String::new(),
                    });
                }
                Ok(a.read(offset, count))
            }
            Kind::Hold(n, fs) => {
                let s = fs.session(*n).ok_or(errors::NOT_FOUND)?;
                let s = s.lock().unwrap();
                let mut t = match &s.model {
                    Some((name, _, place)) => format!("state=ready model={name} place={}", place.name()),
                    None => "state=nomodel".into(),
                };
                t += &format!(" runs={} ms_p50={:.2} ms_p95={:.2}", s.runs, pct(&s.ms, 0.5), pct(&s.ms, 0.95));
                if let Some(e) = &s.err {
                    t += &format!(" reason={e:?}");
                }
                t += "\n";
                Ok(read_at(t.as_bytes(), offset, count))
            }
            Kind::Run(n, fs, rs) => {
                // the answer once there is one; else the inference, once the
                // input is whole
                {
                    let mut r = rs.lock().unwrap();
                    if let Some(a) = r.answer.as_mut() {
                        return Ok(a.read(offset, count));
                    }
                }
                let s = fs.session(*n).ok_or(errors::NOT_FOUND)?;
                let input = {
                    let r = rs.lock().unwrap();
                    let s = s.lock().unwrap();
                    let ctx = s.ctx.as_ref().ok_or("no model: write model NAME to ctl")?;
                    if r.input.len() != ctx.inbytes {
                        return Err(format!("the input is {} bytes; {} written", ctx.inbytes, r.input.len()).into());
                    }
                    r.input.clone()
                };
                let s2 = Arc::clone(&s);
                let res = tokio::task::spawn_blocking(move || {
                    let mut s = s2.lock().unwrap();
                    let t0 = Instant::now();
                    let out = s.ctx.as_mut().unwrap().run(&input);
                    let ms = t0.elapsed().as_secs_f64() * 1000.0;
                    match &out {
                        Ok(_) => {
                            s.runs += 1;
                            if s.ms.len() == NMS {
                                s.ms.remove(0);
                            }
                            s.ms.push(ms);
                            s.err = None;
                        }
                        Err(e) => s.err = Some(e.clone()),
                    }
                    out
                })
                .await
                .map_err(|e| e.to_string())??;
                let mut r = rs.lock().unwrap();
                let mut a = Answer::default();
                a.set(res);
                let b = a.read(offset, count);
                r.answer = Some(a);
                Ok(b)
            }
            Kind::Text(_, None) => Ok(Vec::new()),
        }
    }

    async fn write(&self, offset: u64, data: &[u8]) -> Result<u32> {
        match &self.kind {
            Kind::Text(_, Some((fs, None))) => {
                for line in String::from_utf8_lossy(data).lines() {
                    if !line.trim().is_empty() {
                        fs.ctl(line.trim())?;
                    }
                }
                Ok(data.len() as u32)
            }
            Kind::Text(_, Some((fs, Some(n)))) => {
                let text = String::from_utf8_lossy(data);
                let w: Vec<&str> = text.split_whitespace().collect();
                let name = match w.as_slice() {
                    ["model", name] => name.to_string(),
                    _ => return Err(format!("bad ctl: {}", text.trim()).into()),
                };
                let engine = {
                    let st = fs.st.lock().unwrap();
                    let m = st.models.get(&name).ok_or_else(|| format!("{name}: no such model"))?;
                    (Arc::clone(&m.engine), m.place)
                };
                let ctx = engine.0.ctx()?;
                let s = fs.session(*n).ok_or(errors::NOT_FOUND)?;
                let mut s = s.lock().unwrap();
                s.ctx = None;
                s.ctx = Some(ctx);
                s.model = Some((name, engine.0, engine.1));
                Ok(data.len() as u32)
            }
            Kind::Run(n, fs, rs) => {
                let s = fs.session(*n).ok_or(errors::NOT_FOUND)?;
                let want = s.lock().unwrap().ctx.as_ref().map(|c| c.inbytes).ok_or("no model: write model NAME to ctl")?;
                let mut r = rs.lock().unwrap();
                if r.answer.is_some() {
                    return Err("one inference an open: open run again".into());
                }
                let base = *r.base.get_or_insert(offset);
                let at = offset.checked_sub(base).ok_or("a write before the input's start")? as usize;
                if at != r.input.len() {
                    return Err("the input is written in order".into());
                }
                if at + data.len() > want {
                    return Err(format!("the input is {want} bytes").into());
                }
                r.input.extend_from_slice(data);
                Ok(data.len() as u32)
            }
            _ => Err(errors::PERM.into()),
        }
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> std::io::Result<()> {
    let fs = Trt::default();
    let mut args = std::env::args().skip(1);
    // trtsrv [load NAME PLACE ENGINE SHA256]...: models loaded before serving
    while let Some(a) = args.next() {
        if a != "load" {
            eprintln!("usage: trtsrv [load NAME PLACE ENGINE SHA256]...");
            std::process::exit(2);
        }
        let w: Vec<String> = (&mut args).take(4).collect();
        if w.len() != 4 {
            eprintln!("trtsrv: load NAME PLACE ENGINE SHA256");
            std::process::exit(2);
        }
        if let Err(e) = fs.ctl(&format!("load {}", w.join(" "))) {
            eprintln!("trtsrv: {e}");
            std::process::exit(1);
        }
    }
    // 9P on standard input and output, which are the pipe vision(4) mounts.
    // Not tokio's Stdout: it buffers, and styx9p does not flush (a socket
    // needs none), so replies would wait in it.
    use std::os::fd::AsFd;
    use tokio::net::unix::pipe;
    let rd = pipe::Receiver::from_owned_fd(std::io::stdin().as_fd().try_clone_to_owned()?)?;
    let wr = pipe::Sender::from_owned_fd(std::io::stdout().as_fd().try_clone_to_owned()?)?;
    Server::new(fs).serve_conn(tokio::io::join(rd, wr)).await
}
