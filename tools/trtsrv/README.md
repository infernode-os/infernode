# trtsrv

TensorRT engines on the Jetson's GPU and two DLAs, served as a 9P file
tree on standard input and output, for vision(4) (#1086). vision(4) runs
it as a host command and mounts the pipe, so it is never on the network:

    mount -A {os trtsrv load m dla0 .../engines/dla0.plan SHA256 >[1=0]} /mnt/trt

(`>[1=0]`: `mount {cmd}` gives the command its channel on standard input,
which Limbo servers read and write; `os` writes the host program's output to
standard output, so it is joined to the channel.)

```
ctl        w  load NAME PLACE ENGINE SHA256   (PLACE gpu | dla0 | dla1)
              unload NAME
           r  model NAME place=dla0 type=f16 in=3x416x416 out=85x52x52,... sha256=...
clone      r  a new session, N; it lasts while one of its files is open
N/ctl      rw model NAME
N/run      rw an inference an open: write the input tensor (in the model's
              type, f32 or f16), then read its outputs, the heads in order
N/status   r  state=ready model=NAME place=dla0 runs=N ms_p50= ms_p95=
```

- Rust, on [styx9p](https://github.com/pdfinn/styx9p). The only C++ is
  `csrc/shim.cpp`, because TensorRT's only native interface is C++; the
  only `unsafe` is `src/trt.rs`, its binding.
- An engine is refused unless its SHA-256 is the one given, and unless its
  layers are where its place says: on a DLA, all but the reformatting
  copies at its edges are the DLA's; on the GPU, none is. Engines must be
  built with `--profilingVerbosity=detailed` so that can be seen.
- Engines take and give FP16 (mkengines.sh): half the bytes over 9P, and
  pixels are exact in it; `$Tensor`'s `tohalf` and `fromhalf` convert in
  Limbo. Copies to and from the device go through pinned buffers.
- Each session has its execution context and CUDA stream, made once. An
  inference runs on its first read, off the connection's task, so one
  session's inference never holds up another's messages.

Engines: `mkengines.sh model.onnx modeldir` makes the network ready for the
DLAs (`tools/vision/trtonnx.py`: cut at its heads, SPP pools as 5x5 chains,
space to depth as a convolution; checked exact), builds FP16 engines for
`gpu`, `dla0` and `dla1`, checks where their layers landed, and writes
`modeldir/engines/sha256`.

Build: `cargo build --release` (TensorRT 10 and CUDA as JetPack installs
them; `CUDA_HOME`, `TRT_INCLUDE`, `TRT_LIB` to say otherwise).
Test: `tests/host/trtsrv_test.sh`.
