// Compiles the TensorRT shim (csrc/shim.cpp) and links it with TensorRT and
// the CUDA runtime as JetPack installs them. Only the shim is C++.

use std::{env, path::PathBuf, process::Command};

fn main() {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let cuda = env::var("CUDA_HOME").unwrap_or_else(|_| "/usr/local/cuda".into());
    let trtinc = env::var("TRT_INCLUDE").unwrap_or_else(|_| "/usr/include/aarch64-linux-gnu".into());
    let trtlib = env::var("TRT_LIB").unwrap_or_else(|_| "/usr/lib/aarch64-linux-gnu".into());
    let obj = out.join("shim.o");
    let st = Command::new(env::var("CXX").unwrap_or_else(|_| "g++".into()))
        .args(["-std=c++17", "-O2", "-fPIC", "-Wall", "-c", "csrc/shim.cpp", "-o"])
        .arg(&obj)
        .arg(format!("-I{trtinc}"))
        .arg(format!("-I{cuda}/include"))
        .status()
        .expect("run the C++ compiler");
    assert!(st.success(), "csrc/shim.cpp did not compile");
    let lib = out.join("libtrtshim.a");
    let st = Command::new("ar").arg("crs").arg(&lib).arg(&obj).status().expect("run ar");
    assert!(st.success(), "ar failed");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=trtshim");
    println!("cargo:rustc-link-search=native={trtlib}");
    println!("cargo:rustc-link-search=native={cuda}/lib64");
    println!("cargo:rustc-link-lib=dylib=nvinfer");
    println!("cargo:rustc-link-lib=dylib=cudart");
    println!("cargo:rustc-link-lib=dylib=stdc++");
    println!("cargo:rerun-if-changed=csrc/shim.cpp");
    println!("cargo:rerun-if-env-changed=CUDA_HOME");
}
