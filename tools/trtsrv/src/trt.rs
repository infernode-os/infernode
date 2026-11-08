//! TensorRT through csrc/shim.cpp: the only `unsafe` in trtsrv.
//!
//! An `Engine` is a deserialized engine placed on the GPU or a DLA core; a
//! `Ctx` is an execution context of one session, with its stream and device
//! memory, made once. Every size is checked here before the shim is called,
//! and the shim checks it again.

use std::ffi::{CStr, c_char, c_int, c_void};

#[repr(C)]
struct TrtEngine {
    _p: [u8; 0],
}
#[repr(C)]
struct TrtCtx {
    _p: [u8; 0],
}

unsafe extern "C" {
    fn trt_load(blob: *const c_void, len: usize, dla: c_int, out: *mut *mut TrtEngine, err: *mut c_char, errlen: c_int) -> c_int;
    fn trt_free(e: *mut TrtEngine);
    fn trt_ntensors(e: *mut TrtEngine) -> c_int;
    fn trt_tensor(e: *mut TrtEngine, i: c_int, name: *mut c_char, namelen: c_int, isinput: *mut c_int, esize: *mut c_int, dims: *mut c_int, ndims: *mut c_int) -> c_int;
    fn trt_layers(e: *mut TrtEngine, buf: *mut c_char, buflen: c_int) -> c_int;
    fn trt_ctx(e: *mut TrtEngine, out: *mut *mut TrtCtx, err: *mut c_char, errlen: c_int) -> c_int;
    fn trt_ctxfree(c: *mut TrtCtx);
    fn trt_run(c: *mut TrtCtx, inp: *const c_void, inlen: usize, out: *mut c_void, outlen: usize, err: *mut c_char, errlen: c_int) -> c_int;
}

/// Where an engine runs.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Place {
    Gpu,
    Dla(i32),
}

impl Place {
    pub fn parse(s: &str) -> Option<Place> {
        match s {
            "gpu" => Some(Place::Gpu),
            "dla0" => Some(Place::Dla(0)),
            "dla1" => Some(Place::Dla(1)),
            _ => None,
        }
    }
    pub fn name(&self) -> String {
        match self {
            Place::Gpu => "gpu".into(),
            Place::Dla(n) => format!("dla{n}"),
        }
    }
}

/// One of an engine's tensors.
#[derive(Clone, Debug)]
pub struct Tensor {
    pub name: String,
    pub input: bool,
    pub esize: usize, // 4 float32, 2 float16
    pub dims: Vec<usize>,
}

impl Tensor {
    pub fn bytes(&self) -> usize {
        self.esize * self.dims.iter().product::<usize>()
    }
    /// its element type as ctl says it
    pub fn kind(&self) -> &'static str {
        if self.esize == 2 { "f16" } else { "f32" }
    }
    /// its shape as vision(4) writes it, the batch of one left out
    pub fn shape(&self) -> String {
        let d: &[usize] = if self.dims.len() > 1 && self.dims[0] == 1 { &self.dims[1..] } else { &self.dims };
        d.iter().map(|x| x.to_string()).collect::<Vec<_>>().join("x")
    }
}

pub struct Engine {
    e: *mut TrtEngine,
    pub tensors: Vec<Tensor>,
    pub layers: Vec<String>,
}

// The engine is read only once deserialized; TensorRT allows contexts to be
// made from it, and run, on any thread.
unsafe impl Send for Engine {}
unsafe impl Sync for Engine {}

fn errstr(buf: &[c_char]) -> String {
    // SAFETY: the shim always NUL-terminates what it writes into buf
    unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
}

impl Engine {
    /// The engine in `blob`, deserialized on `place`.
    pub fn load(blob: &[u8], place: Place) -> Result<Engine, String> {
        let dla = match place {
            Place::Gpu => -1,
            Place::Dla(n) => n,
        };
        let mut e: *mut TrtEngine = std::ptr::null_mut();
        let mut err = [0 as c_char; 256];
        // SAFETY: blob is valid for len bytes; err for 256
        let r = unsafe { trt_load(blob.as_ptr() as *const c_void, blob.len(), dla, &mut e, err.as_mut_ptr(), err.len() as c_int) };
        if r != 0 || e.is_null() {
            return Err(errstr(&err));
        }
        let mut eng = Engine { e, tensors: Vec::new(), layers: Vec::new() };
        // SAFETY: e is a live engine from trt_load
        let n = unsafe { trt_ntensors(e) };
        for i in 0..n {
            let mut name = [0 as c_char; 256];
            let mut dims = [0 as c_int; 8];
            let (mut isin, mut es, mut nd) = (0 as c_int, 0 as c_int, 0 as c_int);
            // SAFETY: every buffer is the size passed
            let r = unsafe { trt_tensor(e, i, name.as_mut_ptr(), 256, &mut isin, &mut es, dims.as_mut_ptr(), &mut nd) };
            if r != 0 {
                return Err("cannot read the engine's tensors".into());
            }
            eng.tensors.push(Tensor {
                name: errstr(&name),
                input: isin != 0,
                esize: es as usize,
                dims: dims[..nd as usize].iter().map(|&d| d as usize).collect(),
            });
        }
        let mut buf = vec![0 as c_char; 1 << 20];
        // SAFETY: buf is the size passed
        if unsafe { trt_layers(e, buf.as_mut_ptr(), buf.len() as c_int) } == 0 {
            eng.layers = errstr(&buf).lines().map(String::from).collect();
        }
        Ok(eng)
    }

    pub fn inputs(&self) -> impl Iterator<Item = &Tensor> {
        self.tensors.iter().filter(|t| t.input)
    }
    pub fn outputs(&self) -> impl Iterator<Item = &Tensor> {
        self.tensors.iter().filter(|t| !t.input)
    }
    pub fn inbytes(&self) -> usize {
        self.inputs().map(|t| t.bytes()).sum()
    }
    pub fn outbytes(&self) -> usize {
        self.outputs().map(|t| t.bytes()).sum()
    }

    /// A context of a session's own.
    pub fn ctx(&self) -> Result<Ctx, String> {
        let mut c: *mut TrtCtx = std::ptr::null_mut();
        let mut err = [0 as c_char; 256];
        // SAFETY: self.e is live while self is; err is 256
        let r = unsafe { trt_ctx(self.e, &mut c, err.as_mut_ptr(), err.len() as c_int) };
        if r != 0 || c.is_null() {
            return Err(errstr(&err));
        }
        Ok(Ctx { c, inbytes: self.inbytes(), outbytes: self.outbytes() })
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: e came from trt_load; contexts hold an Arc of the Engine,
        // so none outlives it
        unsafe { trt_free(self.e) }
    }
}

pub struct Ctx {
    c: *mut TrtCtx,
    pub inbytes: usize,
    pub outbytes: usize,
}

// A context is used by one session at a time (behind its Mutex).
unsafe impl Send for Ctx {}

impl Ctx {
    /// One inference: `input` exactly the engine's inputs, the outputs back.
    pub fn run(&mut self, input: &[u8]) -> Result<Vec<u8>, String> {
        if input.len() != self.inbytes {
            return Err(format!("an input is {} bytes, not {}", self.inbytes, input.len()));
        }
        let mut out = vec![0u8; self.outbytes];
        let mut err = [0 as c_char; 256];
        // SAFETY: input and out are the sizes passed, checked above
        let r = unsafe {
            trt_run(self.c, input.as_ptr() as *const c_void, input.len(), out.as_mut_ptr() as *mut c_void, out.len(), err.as_mut_ptr(), err.len() as c_int)
        };
        if r != 0 {
            return Err(errstr(&err));
        }
        Ok(out)
    }
}

impl Drop for Ctx {
    fn drop(&mut self) {
        // SAFETY: c came from trt_ctx
        unsafe { trt_ctxfree(self.c) }
    }
}
