# JIT Compilation

**Purpose:** What the JIT does, when to enable it, and where to look when something goes wrong.

> Looking for benchmark numbers? See [BENCHMARKS.md](BENCHMARKS.md). Looking for ARM64 implementation details? See [PORTING-ARM64.md](PORTING-ARM64.md) and [docs/arm64-jit/](arm64-jit/). This document is the user-facing summary.

## TL;DR

```sh
emu -c1 -r.        # JIT enabled (recommended for AMD64 and ARM64)
emu -c0 -r.        # interpreter only
emu     -r.        # default depends on the build; treat as interpreter
```

Use `-c1` on Linux/macOS AMD64 and ARM64. Use `-c0` (or no flag) on Windows — there is no Windows JIT yet, the emulator falls back to the interpreter.

## What it does

InferNode's emulator compiles Dis VM bytecode to native machine code at module load time. Two backends ship and are wired up by `Make` based on the host architecture:

| Backend                    | Targets                                       | Source                       |
|----------------------------|-----------------------------------------------|------------------------------|
| `comp-amd64.c`             | x86-64, System V ABI (Linux/macOS) + Windows x64 ABI | `libinterp/comp-amd64.c` |
| `comp-arm64.c`             | ARMv8-A, AAPCS64 ABI (macOS Apple Silicon, Linux on Jetson/Pi) | `libinterp/comp-arm64.c` |

Older 32-bit backends (`comp-386.c`, `comp-arm.c`, `comp-mips.c`, `comp-power.c`, `comp-sparc.c`, etc.) are kept for completeness but the active 64-bit ports are AMD64 and ARM64.

### W^X compliance

The JIT writes machine code into pages it later executes. Each platform handles W^X differently:

- **macOS** — `mmap(MAP_JIT)` plus `pthread_jit_write_protect_np()` to flip the writable/executable bit per thread. Required on Apple Silicon.
- **Linux** — `mmap(MAP_ANON)` with `PROT_READ|PROT_WRITE|PROT_EXEC`.
- **Windows** — `VirtualAlloc(PAGE_READWRITE)` then `VirtualProtect(PAGE_EXECUTE_READ)` once the code is written. (Currently used for the 32-bit `comp-386.c` path; no 64-bit Windows JIT yet.)

## Speedup

Best-of-3 against the interpreter, v1 suite (6 compute benchmarks):

| Platform        | CPU                    | Speedup |
|-----------------|------------------------|---------|
| Linux AMD64     | AMD Ryzen 7 H 255      | **14.2×** |
| Windows AMD64   | AMD Ryzen 7 255        | 13.3× (currently interpreter-only on shipped builds) |
| macOS ARM64     | Apple M4               | **9.6×**  |
| Linux ARM64     | Cortex-A78AE (Jetson)  | **8.3×**  |

v2 (26 benchmarks, broader workload mix) drops to 2.6–5.7× because function-call-heavy workloads can't eliminate frame allocation, module pointer validation, and GC interaction. Branch-heavy code can hit 36×; tight inner loops 14–18×; recursive Fibonacci is closer to 3×.

Full numbers: [BENCHMARKS.md](BENCHMARKS.md).

## The `-c` flag

```
emu -c <level> ...
```

| Level | Behaviour |
|-------|-----------|
| `0`   | Interpreter only. No JIT. |
| `1`   | JIT enabled. **This is what you want.** |
| `2`   | Reserved/internal. |
| `3`   | JIT + cflag-gated logging in the compiler. |
| `4`   | More verbose JIT logging. |
| `5–9` | Progressively more diagnostic output, used while debugging the JIT itself. |

Anything above `1` is for compiler bring-up, not normal use. The accepted range is `0`–`9` (see `emu/port/main.c:136`).

## Forcing JIT vs. interpreter for specific code

Two compile-time hints in Limbo source map to Dis module flags:

- `MUSTCOMPILE` — module insists on JIT; load fails on interpreter-only emulators.
- `DONTCOMPILE` — module is interpreted even when `-c1` is set.

These are set by the Limbo compiler from `pragma`s. Ordinary code does not need them; they exist for modules that depend on a specific code path.

> ⚠️ **Compiler choice matters.** The hosted Limbo (`/dis/limbo.dis` running inside the emulator) sets `MUSTCOMPILE` on the modules it produces. If you compile a `.dis` with the hosted limbo and then load it on an interpreter-only platform, you will get `compiler required` errors. Use the **native** limbo (`MacOSX/arm64/bin/limbo` or `Linux/<arch>/bin/limbo`) to produce portable bytecode. See [CLAUDE.md §JIT Compiler Availability](../CLAUDE.md#jit-compiler-availability).

## Coverage

Not every Dis opcode is JIT-compiled. The compilers fall back to the interpreter for instructions that are rare or whose native sequences would be longer than the interpreter call.

ARM64 (`comp-arm64.c`):

- **155 opcodes (~91 %)** compiled to native ARM64.
- **16 opcodes (~9 %)** punted to the interpreter (complex string ops, some 64-bit float conversions, send/receive, etc.).
- All other opcodes are a compile-time error in the JIT — a deliberate conservative choice that surfaces unhandled instructions immediately.

For the full opcode-by-opcode breakdown, see [arm64-jit/OPCODE-ANALYSIS.md](arm64-jit/OPCODE-ANALYSIS.md) and [arm64-jit/OPCODE-DETAILED-ANALYSIS.md](arm64-jit/OPCODE-DETAILED-ANALYSIS.md).

AMD64 has comparable coverage; see `libinterp/comp-amd64.c`.

## Bounds checking

Array bounds checks are on by default and inserted by the JIT. Two flags toggle this:

```
emu -B ...     # suppress JIT array bounds checks (faster, unsafe)
emu -b ...     # historical — bounds checks; now the default and a no-op
```

Disable bounds checks only for benchmarking. Production builds should leave them on.

## Memory pool option

Pool quanta affect both the interpreter and the JIT:

```
emu -p heap=512m -p main=512m -p image=512m ...
```

These are the values the [Lucia launch scripts](LUCIA.md#launching) use. Lower values are fine for a shell or batch tasks; the GUI wants the larger pool because it allocates `Image`s.

> 🔑 **The 64-bit fix.** Pool quanta must be 127 on 64-bit (not 31 as on 32-bit) — the single change in `emu/port/alloc.c` that made the 64-bit port work. See [LESSONS-LEARNED.md](LESSONS-LEARNED.md) for the story.

## Diagnosing JIT issues

| Symptom                                              | What to try |
|------------------------------------------------------|-------------|
| `compiler required` when loading a `.dis`           | You compiled it with the hosted limbo. Recompile with the native `limbo` from `MacOSX/arm64/bin/` or `Linux/<arch>/bin/`. |
| Crash inside JIT'd code                             | Re-run with `-c0` to confirm the interpreter works. If yes, file a JIT bug with the exact module and inputs. |
| Slow despite `-c1`                                   | Workload may be function-call-heavy (Fibonacci-like) — JIT can only do so much. Profile with the v2 suite breakdown ([BENCHMARKS.md](BENCHMARKS.md)). |
| `mmap(MAP_JIT)` failure on macOS                    | Sandbox / entitlements issue. Confirm the binary is signed and `com.apple.security.cs.allow-jit` is set if shipping notarised. |
| Windows: no speedup from `-c1`                      | Expected — there is no 64-bit Windows JIT yet. Use `-c0` and the interpreter. |
| Bring-up debugging the JIT itself                   | Use `-c3` or `-c4` for compiler logging; see the `cflag > 3` gates in `comp-arm64.c` and `comp-amd64.c`. |

For deep debug stories — what worked, what didn't, every blind alley — the [arm64-jit/](arm64-jit/) directory has 27 session logs.

### Open faults

Known, unreproduced, and not yet ticketed — recorded here so they are
not lost. Anyone who hits one should attach the module and the exact
command line to a ticket and remove the entry.

- **amd64 `-c1`: SEGV in `altrdy()` (`libinterp/alt.c`) on an `alt`
  over two unbuffered channels inside a helper function.** Seen
  2026-09-05 while writing `tests/fdclose_test.b`: the first draft had a
  helper that spawned a reader and a timer, each with its own unbuffered
  `chan of int`, and `alt`ed on both; it faulted in `altrdy` under
  `-c1` in every test case, and passed under `-c0`. The `Testing` module
  was loaded and a `ref T` was live in the caller's frame at the time.
  Five later probes with the same channel shape, and eight runs of a
  bare module with the identical helper and no `Testing`, did not
  reproduce it, so the `alt` alone is not the trigger; something in the
  surrounding frame is, and it has not been isolated. The draft that
  faulted was not kept. The shipped test avoids `alt` entirely
  (one buffered channel; comment in the test explains). Nothing on the
  AArch64 side was affected: `comp-arm64.c`'s `macfrp` fix was proven
  under QEMU by the bare-metal harness, not by this test.

  *Later the same day, reproduced and attributed.* The full hosted
  runner (`emu -c1 /dis/tests/runner.dis`) hits it deterministically:
  all fifteen cases of `tests/asyncio_test.b` die with
  `sys: segmentation violation addr=0xffffffffd8ab86a0` (and nearby),
  PC in `altrdy` at `alt.c:98`, the `c = ac->c` load. The same runner
  against an emulator built from `origin/master` passes `asyncio`. The
  only commit on `feat/baremetal-pi` that touches `comp-amd64.c` or
  `xec.c` is fb64f77 ("dis: a Limbo int is 32 bits on a 64-bit word"),
  and the faulting address is exactly a 32-bit value sign-extended into
  a 64-bit pointer -- so a `w`-typed store the JIT now sign-extends is
  carrying a pointer-sized value somewhere on the `alt` path (the `Alt`
  block's channel slots, or the count/index words next to them). That
  commit's own tests (`intsem_test`, `jit_test`) pass; the runner is
  the only thing that covers it. **This blocks merging the branch to
  `master`**; see os/bcm2837/README.md, tier 2 item 8. Two unrelated
  pre-existing `-c1` failures (`Aes256Sha256`, `cipher_matrix`, SEGV in
  JIT-generated code) also appear with master's own emulator on a Linux
  amd64 host and are not this branch's.

## When to leave JIT off

- **Tiny scripts / shell pipelines.** JIT compilation has a one-time per-module cost; a script that runs for 2 ms gains nothing and pays the compile.
- **Heap-pressure debugging.** The interpreter is the simpler reference path. Comparing `-c0` and `-c1` results is a useful diagnostic.
- **Windows builds.** No JIT exists yet; `-c0` is the truthful default.

For every other workload — anything that runs longer than a few milliseconds — `-c1` is the right answer.

## See also

- [BENCHMARKS.md](BENCHMARKS.md) — full v1/v2 suites, cross-language comparisons.
- [PERFORMANCE-SPECS.md](PERFORMANCE-SPECS.md) — RAM, binary sizes, startup time.
- [PORTING-ARM64.md](PORTING-ARM64.md) — what porting the JIT to ARM64 actually involved.
- [arm64-jit/](arm64-jit/) — opcode coverage, bring-up logs, debug stories.
- [LESSONS-LEARNED.md](LESSONS-LEARNED.md) — pool-quanta fix and other 64-bit gotchas.
- [CLAUDE.md §JIT Compiler Availability](../CLAUDE.md#jit-compiler-availability) — native vs. hosted limbo and why it matters.
