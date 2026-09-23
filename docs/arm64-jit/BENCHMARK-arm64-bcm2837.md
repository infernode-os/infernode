# ARM64 JIT Benchmark Results — Bare Metal (Raspberry Pi 3B+)

## Platform
- **Hardware:** Raspberry Pi 3B+ (BCM2837B0), 1 GB RAM
- **CPU:** ARM Cortex-A53, 4 cores at 1.4 GHz (in-order)
- **OS:** InferNode native kernel (`os/bcm2837`), master + #688 + #691, 1,786,701 bytes; the Dis VM runs in the kernel, no host OS
- **Date:** 2026-09-23

No emulator: the JIT (`libinterp/comp-arm64.c`, `INFERNO_NATIVE`) takes executable memory from the kernel pool and flushes the icache itself. The interpreter is the same kernel with `echo 0 > /dev/jit` before the module loads. Timings are the benchmark's own `sys->millisec()`; the board idle at its login screen, gigabit link up. Three JIT runs (within 0.5%), one interpreter run.

---

### jitbench v1 — Totals

| Run | Interp (ms) | JIT (ms) | Speedup |
|-----|-------------|----------|---------|
| 1 | 273,572 | 38,819 | 7.05x |
| 2 | — | 38,620 | — |
| 3 | — | 38,618 | — |
| **Best** | **273,572** | **38,618** | **7.08x** |

### jitbench v1 — Per-benchmark breakdown (best of 3 JIT, one interpreter run)

| Benchmark | Interp (ms) | JIT (ms) | Speedup |
|-----------|-------------|----------|---------|
| Integer Arithmetic | 6,806 | 827 | 8.23x |
| Loop with Array Access | 241,981 | 33,570 | 7.21x |
| Function Calls | 288 | 31 | 9.29x |
| Fibonacci (recursive) | 8,950 | 2,511 | 3.56x |
| Sieve of Eratosthenes | 967 | 134 | 7.22x |
| Nested Loops | 14,580 | 1,517 | 9.61x |
| **Total** | **273,572** | **38,618** | **7.08x** |

### jitbench v2 — Totals

| Run | Interp (ms) | JIT (ms) | Speedup |
|-----|-------------|----------|---------|
| 1 | 17,752 | 7,367 | 2.41x |
| 2 | — | 7,372 | — |
| 3 | — | 7,354 | — |
| **Best** | **17,752** | **7,354** | **2.41x** |

### jitbench v2 — Per-category and per-item breakdown (best of 3 JIT, one interpreter run)

| Benchmark | Interp (ms) | JIT (ms) | Speedup |
|-----------|-------------|----------|---------|
| **Integer ALU** | **1,765** | **207** | **8.53x** |
| 1a. ADD/SUB chain | 382 | 43 | 8.88x |
| 1b. MUL/DIV/MOD | 45 | 5 | 9.00x |
| 1c. Bitwise ops | 448 | 57 | 7.86x |
| 1d. Shift ops | 372 | 43 | 8.65x |
| 1e. Mixed ALU | 518 | 59 | 8.78x |
| **Branch & Control** | **902** | **99** | **9.11x** |
| 2a. Simple branch | 295 | 31 | 9.52x |
| 2b. Compare chain | 388 | 43 | 9.02x |
| 2c. Nested branches | 49 | 6 | 8.17x |
| 2d. Loop countdown | 170 | 19 | 8.95x |
| **Memory Access** | **1,357** | **185** | **7.34x** |
| 3a. Sequential read | 241 | 33 | 7.30x |
| 3b. Sequential write | 253 | 33 | 7.67x |
| 3c. Stride access | 447 | 63 | 7.10x |
| 3d. Small array hot | 416 | 56 | 7.43x |
| **Function Calls** | **5,287** | **5,689** | **0.93x** |
| 4a. Simple call | 232 | 25 | 9.28x |
| 4b. Recursive fib | 4,469 | 5,162 | 0.87x |
| 4c. Mutual recursion | 273 | 238 | 1.15x |
| 4d. Deep call chain | 313 | 264 | 1.19x |
| **Big (64-bit)** | **1,563** | **154** | **10.15x** |
| 5a. Big add/sub | 260 | 25 | 10.40x |
| 5b. Big bitwise | 404 | 40 | 10.10x |
| 5c. Big shifts | 434 | 47 | 9.23x |
| 5d. Big comparisons | 465 | 42 | 11.07x |
| **Byte Ops** | **1,108** | **117** | **9.47x** |
| 6a. Byte arithmetic | 379 | 35 | 10.83x |
| 6b. Byte array | 729 | 82 | 8.89x |
| **List Ops** | **340** | **124** | **2.74x** |
| 7a. List build | 82 | 75 | 1.09x |
| 7b. List traverse | 258 | 49 | 5.27x |
| **Mixed Workloads** | **4,802** | **672** | **7.15x** |
| 8a. Sieve | 890 | 119 | 7.48x |
| 8b. Matrix multiply | 2,099 | 291 | 7.21x |
| 8c. Bubble sort | 1,169 | 170 | 6.88x |
| 8d. Binary search | 644 | 92 | 7.00x |
| **Type Conversions** | **622** | **59** | **10.54x** |
| 9a. int<->big | 306 | 31 | 9.87x |
| 9b. int<->byte | 316 | 28 | 11.29x |

### Interpreter vs JIT vs Emu, same Raspberry Pi 3B+

**Emu** is the hosted InferNode emulator (`emu/Linux/o.emu`, a headless Linux arm64 build of the same master commit) running under Raspberry Pi OS Lite (Trixie, 2026-09-15, 64-bit, kernel 6.18) on the same board from a second SD card, the same afternoon, its cpufreq governor at 1400 MHz throughout (sampled). Same two suites, same protocol: best of 3 JIT, one interpreter run, ms. "Bare" is the native kernel: no host OS, the Dis VM in the kernel.

| | bare interp | bare JIT | speedup | emu interp | emu JIT | speedup | bare ÷ emu (JIT) |
|---|---|---|---|---|---|---|---|
| Integer Arithmetic | 6,806 | 827 | 8.2x | 5,401 | 715 | 7.6x | 1.16 |
| Loop with Array Access | 241,981 | 33,570 | 7.2x | 192,467 | 29,043 | 6.6x | 1.16 |
| Function Calls | 288 | 31 | 9.3x | 240 | 27 | 8.9x | 1.15 |
| Fibonacci (recursive) | 8,950 | 2,511 | 3.6x | 12,021 | 6,056 | 2.0x | 0.41 |
| Sieve of Eratosthenes | 967 | 134 | 7.2x | 797 | 124 | 6.4x | 1.08 |
| Nested Loops | 14,580 | 1,517 | 9.6x | 11,953 | 1,312 | 9.1x | 1.16 |
| **v1 total** | **273,572** | **38,618** | **7.1x** | **222,879** | **37,283** | **6.0x** | **1.04** |
| v2 Integer ALU | 1,765 | 207 | 8.5x | 1,543 | 181 | 8.5x | 1.14 |
| v2 Branch & Control | 902 | 99 | 9.1x | 717 | 87 | 8.2x | 1.14 |
| v2 Memory Access | 1,357 | 185 | 7.3x | 1,167 | 161 | 7.2x | 1.15 |
| v2 Function Calls | 5,287 | 5,689 | 0.9x | 6,926 | 9,503 | 0.7x | 0.60 |
| v2 Big (64-bit) | 1,563 | 154 | 10.1x | 1,347 | 132 | 10.2x | 1.17 |
| v2 Byte Ops | 1,108 | 117 | 9.5x | 899 | 100 | 9.0x | 1.17 |
| v2 List Ops | 340 | 124 | 2.7x | 333 | 102 | 3.3x | 1.22 |
| v2 Mixed Workloads | 4,802 | 672 | 7.1x | 4,039 | 582 | 6.9x | 1.15 |
| v2 Type Conversions | 622 | 59 | 10.5x | 498 | 50 | 10.0x | 1.18 |
| **v2 total** | **17,752** | **7,354** | **2.4x** | **17,475** | **10,929** | **1.6x** | **0.67** |

### Reading

The same JIT emitting the same instructions on the same chip at the same clock: on straight-line code bare metal costs a consistent 14–17% more than the hosted emulator (#695: the environment the code runs in -- the 1000 Hz tick on four cores, the hub-port polling, page attributes -- not the code; unexplained as of this writing), and on anything that allocates frames it is far cheaper (v1 Fibonacci 0.41x, v2 function calls 0.60x of the hosted time: the kernel's pool against the host's malloc). Net: v1 within 4% of hosted, v2 33% faster. Deep recursion remains the JIT's weak spot on both -- v2's recursive fib is slower compiled than interpreted hosted (0.7x) and barely faster bare (1.1x at 1400 MHz) -- see #689.

Against the Jetson AGX Orin's hosted JIT the totals are 8.4x (v1) and 7.8x (v2) slower for a 1.6x clock ratio: an in-order Cortex-A53 against an out-of-order A78AE, as expected.

### Provenance

Raw output for every run named here -- three JIT and one interpreter run of each suite, bare and emu -- is kept with the bench evidence (`infernode-bench/benchmarks/2026-09-23-*.txt` on the bench store). The kernel is the one whose 48-hour soak began the same evening, after the batteries and a ten-minute storm passed on it.
