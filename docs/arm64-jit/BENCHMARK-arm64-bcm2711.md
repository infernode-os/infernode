# ARM64 JIT Benchmark Results — Bare Metal (Raspberry Pi 4B)

## Platform
- **Hardware:** Raspberry Pi 4B rev 1.5 (revision code `c03115`, BCM2711 C0), 4 GB RAM, fan and heatsink, 31C room
- **CPU:** ARM Cortex-A72, 4 cores at 1.8 GHz (`arm_boost=1`; out of order)
- **OS:** InferNode native kernel (`os/bcm2711`), master 19bfc4ac8 + #931 (Wi-Fi; nothing in the Dis VM or the JIT), 1,982,141 bytes; the Dis VM runs in the kernel, no host OS
- **Date:** 2026-10-18

The same two suites and the same protocol as the [Raspberry Pi 3B+](BENCHMARK-arm64-bcm2837.md) (Cortex-A53, 4 cores at 1.4 GHz, in order), so the tables compare directly: the JIT (`libinterp/comp-arm64.c`, `INFERNO_NATIVE`), the interpreter with `echo 0 > /dev/jit` before the module loads, timings from the benchmark's own `sys->millisec()`, three JIT runs and one interpreter run, the board freshly booted and idle at its login screen with gigabit Ethernet and Wi-Fi up.

**The board must be idle.** A first run of these suites, on the same kernel, was made with a soak's four background shell loops still running on the board (they outlived the soak; `~/pitools/soak/soak.py` now stops them) -- a quarter of every core -- and gave 80,019 ms for v1 JIT and a JIT slower than the interpreter on v2. Those numbers say nothing about the JIT; the ones below are from a fresh boot with `/dev/sysstat` showing the cores idle.

---

### Summary

| Suite | Pi 3B+ interp | Pi 3B+ JIT | **Pi 4B interp** | **Pi 4B JIT** | Pi 4B ÷ 3B+ (interp, JIT) | JIT ÷ interp (3B+, 4B) |
|-|-:|-:|-:|-:|-:|-:|
| jitbench v1 | 273,572 | 37,816 | **73,661** | **10,413** | 3.7x, 3.6x | 7.2x, 7.1x |
| jitbench v2 | 17,752 | 2,607 | **5,526** | **989** | 3.2x, 2.6x | 6.8x, 5.6x |

Times in ms, best of three JIT runs; v1 JIT runs 10,440, 10,495, 10,413, v2 JIT runs 993, 1,099, 989.

### jitbench v1 — Per-benchmark

| Benchmark | 3B+ interp | 3B+ JIT | 4B interp | 4B JIT | 4B ÷ 3B+ interp | 4B ÷ 3B+ JIT | 4B JIT speedup |
|-|-:|-:|-:|-:|-:|-:|-:|
| Integer Arithmetic | 6,806 | 827 | 2,171 | 248 | 3.1x | 3.3x | 8.8x |
| Loop with Array Access | 241,981 | 33,564 | 62,895 | 9,022 | 3.8x | 3.7x | 7.0x |
| Function Calls | 288 | 31 | 108 | 9 | 2.7x | 3.4x | 12.0x |
| Fibonacci (recursive) | 8,950 | 1,742 | 3,066 | 672 | 2.9x | 2.6x | 4.6x |
| Sieve of Eratosthenes | 967 | 134 | 247 | 53 | 3.9x | 2.5x | 4.7x |
| Nested Loops | 14,580 | 1,517 | 5,174 | 401 | 2.8x | 3.8x | 12.9x |

### jitbench v2 — Per-item

| Item | 3B+ interp | 3B+ JIT | 4B interp | 4B JIT | 4B ÷ 3B+ JIT | 4B JIT speedup |
|-|-:|-:|-:|-:|-:|-:|
| 1a. ADD/SUB chain | 382 | 43 | 125 | 20 | 2.1x | 6.2x |
| 1b. MUL/DIV/MOD | 45 | 6 | 14 | 3 | 2.0x | 4.7x |
| 1c. Bitwise ops | 448 | 57 | 120 | 27 | 2.1x | 4.4x |
| 1d. Shift ops | 372 | 43 | 96 | 14 | 3.1x | 6.9x |
| 1e. Mixed ALU | 518 | 59 | 135 | 23 | 2.6x | 5.9x |
| 2a. Simple branch | 295 | 31 | 126 | 9 | 3.4x | 14.0x |
| 2b. Compare chain | 388 | 43 | 117 | 14 | 3.1x | 8.4x |
| 2c. Nested branches | 49 | 6 | 15 | 1 | 6.0x | 15.0x |
| 2d. Loop countdown | 170 | 19 | 48 | 5 | 3.8x | 9.6x |
| 3a. Sequential read | 241 | 34 | 63 | 9 | 3.8x | 7.0x |
| 3b. Sequential write | 253 | 33 | 63 | 13 | 2.5x | 4.8x |
| 3c. Stride access | 447 | 63 | 121 | 16 | 3.9x | 7.6x |
| 3d. Small array hot | 416 | 56 | 111 | 16 | 3.5x | 6.9x |
| 4a. Simple call | 232 | 25 | 61 | 7 | 3.6x | 8.7x |
| 4b. Recursive fib | 4,469 | 878 | 1,356 | 366 | 2.4x | 3.7x |
| 4c. Mutual recursion | 273 | 48 | 83 | 17 | 2.8x | 4.9x |
| 4d. Deep call chain | 313 | 55 | 98 | 18 | 3.1x | 5.4x |
| 5a. Big add/sub | 260 | 25 | 72 | 10 | 2.5x | 7.2x |
| 5b. Big bitwise | 404 | 40 | 107 | 18 | 2.2x | 5.9x |
| 5c. Big shifts | 434 | 47 | 122 | 16 | 2.9x | 7.6x |
| 5d. Big comparisons | 465 | 42 | 132 | 12 | 3.5x | 11.0x |
| 6a. Byte arithmetic | 379 | 34 | 95 | 13 | 2.6x | 7.3x |
| 6b. Byte array | 729 | 82 | 193 | 26 | 3.2x | 7.4x |
| 7a. List build | 82 | 53 | 43 | 40 | 1.3x | 1.1x |
| 7b. List traverse | 258 | 46 | 73 | 18 | 2.6x | 4.1x |
| 8a. Sieve | 890 | 119 | 235 | 48 | 2.5x | 4.9x |
| 8b. Matrix multiply | 2,099 | 291 | 771 | 94 | 3.1x | 8.2x |
| 8c. Bubble sort | 1,169 | 170 | 533 | 51 | 3.3x | 10.5x |
| 8d. Binary search | 644 | 92 | 201 | 36 | 2.6x | 5.6x |
| 9a. int<->big | 306 | 31 | 112 | 10 | 3.1x | 11.2x |
| 9b. int<->byte | 316 | 28 | 84 | 9 | 3.1x | 9.3x |

Items under about 30 ms are near the timer's resolution and their ratios are rough.

### Reading it

- **3.6x on v1 and 2.6x on v2 under the JIT, 3.2-3.7x under the interpreter**, for 1.29x the clock: most of the gain is the A72's out-of-order core over the A53's in-order one. On the long-running v1 benchmarks, where the timer's resolution does not matter, the JIT gains most on loops over memory (array loop 3.7x, nested loops 3.8x) and least on recursion (Fibonacci 2.6x) and the sieve (2.5x). In v2 the straight ALU chains gain about 2x and list building almost nothing (1.3x, 7a), but most v2 items run for tens of milliseconds and their ratios are indicative only.
- **The JIT's lead over the interpreter is the same on both boards** (v1 7.1x against 7.2x; v2 5.6x against 6.8x), so the JIT carries over to the A72 without a cliff. v2's smaller lead on the 4B is consistent with the interpreter, whose dispatch loop is branchy, gaining more from out-of-order execution than compiled code does; not measured further.
- **Recursive calls** remain the JIT's weak spot on both (v1 Fibonacci 4.6x over the interpreter, v2 recursive fib), as the 3B+ page says (#689).

### The rest of the board, for the same comparison

| | Pi 3B+ | Pi 4B | |
|-|-:|-:|-|
| TCP into the board (netbench, 3 x 10 s, median) | 251 Mbit/s | 932 Mbit/s | the 3B+'s Ethernet is a USB 2 LAN78xx; the 4B's GENET is on the SoC |
| TCP out of the board | 209 Mbit/s | 890 Mbit/s | |
| Wi-Fi receive | 45 Mbit/s | 47 Mbit/s | the same CYW43455 on the same 25 MHz PIO SDIO bus |
| SD card, a 2 MB file read | ~2 MB/s | 7.8 MB/s (19 MB/s raw) | the 4B's EMMC2 reads many blocks per command; the 3B+'s SDHOST one block per command |
| boot self-test `bench` (2M iterations) | 77 ms | 22 ms | |

Raw output: `~/pitools/soak/bench-pi4-1018.txt` on the bench Jetson (and the discarded loaded run beside it, `bench-pi4-1018-UNDER-SOAK-LOOPS.txt`).
