# ARM64 JIT Benchmark Results — Bare Metal (Raspberry Pi 3B+)

## Platform
- **Hardware:** Raspberry Pi 3B+ (BCM2837B0), 1 GB RAM
- **CPU:** ARM Cortex-A53, 4 cores at 1.4 GHz (in-order)
- **OS:** InferNode native kernel (`os/bcm2837`), master 93815740d + #688, 1,786,413 bytes; the Dis VM runs in the kernel, no host OS
- **Date:** 2026-09-23

No emulator: the JIT (`libinterp/comp-arm64.c`, `INFERNO_NATIVE`) takes executable memory from the kernel pool and flushes the icache itself. The interpreter is the same kernel with `echo 0 > /dev/jit` before the module loads (#687 fixed that switch). Timings are the benchmark's own `sys->millisec()`; the board was otherwise idle (the login screen, nobody logged in), gigabit link up, nothing else running. Three JIT runs, one interpreter run (the interpreter takes eight minutes for v1).

---

### jitbench v1 — Totals

| Run | Interp (ms) | JIT (ms) | Speedup |
|-----|-------------|----------|---------|
| 1 | 480,186 | 78,070 | 6.15x |
| 2 | — | 77,229 | — |
| 3 | — | 77,344 | — |
| **Best** | **480,186** | **77,229** | **6.22x** |

### jitbench v1 — Per-benchmark breakdown (best of 3 JIT, one interpreter run)

| Benchmark | Interp (ms) | JIT (ms) | Speedup |
|-----------|-------------|----------|---------|
| Integer Arithmetic | 11,401 | 1,656 | 6.88x |
| Loop with Array Access | 426,691 | 67,196 | 6.35x |
| Function Calls | 495 | 62 | 7.98x |
| Fibonacci (recursive) | 15,475 | 5,021 | 3.08x |
| Sieve of Eratosthenes | 1,587 | 257 | 6.18x |
| Nested Loops | 24,536 | 3,036 | 8.08x |

### jitbench v2 — Totals

| Run | Interp (ms) | JIT (ms) | Speedup |
|-----|-------------|----------|---------|
| 1 | 30,969 | 14,758 | 2.10x |
| 2 | — | 14,799 | — |
| 3 | — | 14,572 | — |
| **Best** | **30,969** | **14,572** | **2.13x** |

### jitbench v2 — Per-category and per-item breakdown (best of 3 JIT, one interpreter run)

| Benchmark | Interp (ms) | JIT (ms) | Speedup |
|-----------|-------------|----------|---------|
| **Integer ALU** | **3,162** | **419** | **7.55x** |
| 1a. ADD/SUB chain | 689 | 87 | 7.92x |
| 1b. MUL/DIV/MOD | 83 | 12 | 6.92x |
| 1c. Bitwise ops | 826 | 115 | 7.18x |
| 1d. Shift ops | 600 | 86 | 6.98x |
| 1e. Mixed ALU | 964 | 119 | 8.10x |
| **Branch & Control** | **1,576** | **201** | **7.84x** |
| 2a. Simple branch | 502 | 62 | 8.10x |
| 2b. Compare chain | 675 | 87 | 7.76x |
| 2c. Nested branches | 83 | 13 | 6.38x |
| 2d. Loop countdown | 316 | 39 | 8.10x |
| **Memory Access** | **2,400** | **373** | **6.43x** |
| 3a. Sequential read | 435 | 67 | 6.49x |
| 3b. Sequential write | 419 | 67 | 6.25x |
| 3c. Stride access | 811 | 126 | 6.44x |
| 3d. Small array hot | 735 | 113 | 6.50x |
| **Function Calls** | **9,182** | **11,344** | **0.81x** |
| 4a. Simple call | 388 | 50 | 7.76x |
| 4b. Recursive fib | 7,737 | 10,292 | 0.75x |
| 4c. Mutual recursion | 506 | 477 | 1.06x |
| 4d. Deep call chain | 551 | 525 | 1.05x |
| **Big (64-bit)** | **2,756** | **309** | **8.92x** |
| 5a. Big add/sub | 469 | 50 | 9.38x |
| 5b. Big bitwise | 669 | 80 | 8.36x |
| 5c. Big shifts | 813 | 94 | 8.65x |
| 5d. Big comparisons | 805 | 85 | 9.47x |
| **Byte Ops** | **1,912** | **233** | **8.21x** |
| 6a. Byte arithmetic | 633 | 69 | 9.17x |
| 6b. Byte array | 1,279 | 164 | 7.80x |
| **List Ops** | **667** | **222** | **3.00x** |
| 7a. List build | 223 | 126 | 1.77x |
| 7b. List traverse | 444 | 96 | 4.62x |
| **Mixed Workloads** | **8,280** | **1,346** | **6.15x** |
| 8a. Sieve | 1,504 | 238 | 6.32x |
| 8b. Matrix multiply | 3,549 | 583 | 6.09x |
| 8c. Bubble sort | 2,095 | 340 | 6.16x |
| 8d. Binary search | 1,132 | 185 | 6.12x |
| **Type Conversions** | **1,031** | **119** | **8.66x** |
| 9a. int<->big | 508 | 62 | 8.19x |
| 9b. int<->byte | 523 | 57 | 9.18x |

### Reading

Every category but two speeds up 6–9x under the JIT, the same shape as the hosted ARM64 results one step down in absolute speed for a 1.4 GHz in-order core. The two exceptions are the ones where the JIT still does the interpreter's work per operation: list building (allocation) and function calls. Deep recursion gains nothing from compilation here — mutual recursion and the deep call chain run at the interpreter's speed, and `4b. Recursive fib` runs *slower* compiled (0.75x); the Jetson shows the same shape at 1.3x. That is filed as #689 with what to measure.

A first pass at what the numbers say about the hardware, not the JIT: the JIT totals are 17x (v1) and 15x (v2) the Jetson AGX Orin's, against a clock ratio of 1.6x, so the in-order A53 costs roughly 10x per cycle on this code compared with the out-of-order A78AE. The interpreter is 12.5x (v1) and 11x (v2) the Jetson's. A comparison of the bare-metal JIT against the hosted emulator on the *same* board (Raspberry Pi OS on a second card) has not been made; until it is, none of these numbers say anything about what running without a host OS is worth.

### Provenance

Raw output, three JIT runs and one interpreter run of each suite, is kept with the bench evidence (`infernode-bench/benchmarks/2026-09-23-fix687-*.txt` on the bench store). The kernel is the 0.5.0 release kernel with the #688 fix; its 48-hour soak began the same evening, after the batteries and a ten-minute storm passed on it.
