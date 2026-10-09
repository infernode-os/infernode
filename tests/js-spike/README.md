# The JavaScript-on-Dis spike

docs/JS-ENGINE.md §9: before any engine code, how fast Dis runs
JavaScript, measured against QuickJS 2026-06-04 on the same machines.

| File | What it measures |
|---|---|
| `bench.js` | the benchmarks, as JavaScript, for `qjs bench.js` |
| `spike.b` | the same, hand-compiled into the Limbo a compiler would emit, in three tiers |
| `valrep.b` | what copying a value costs, by how many pointer fields it holds |
| `tiny.b`, `loadtest.b` | loading a freshly generated module (the JIT translates it at load) |
| `gctest.b` | the collector's pauses, and whether it keeps up, with cyclic garbage |

The tiers in `spike.b`:

- **base:** every value is a `Val`, and every operation calls the runtime.
- **inl:** the same, but with each operation's common case tested in line before calling the runtime.
- **opt:** type-specialised locals behind guards, inline caches checked in line, small callees inlined.

Build: `cd tests/js-spike; mk install`. Run: `emu -c1 -r. /dis/tests/js-spike/spike.dis [base|inl|opt]`. `loadtest` wants a directory of 1,000 copies of `tiny.dis` named `t0000.dis` to `t0999.dis`. An emulator whose program breaks does not exit, so wrap runs in `timeout`.

## Results, 2026-10-09

The figures are milliseconds, best of three. The quiet machine is minipc, Linux on amd64. On the Mac (arm64) the runs varied by up to 3× under load, so its figures are indicative only.

### amd64 JIT (minipc)

| Benchmark | QuickJS | Dis base | Dis inl | Dis opt |
|---|---|---|---|---|
| prop | 144 | 5,668 | 1,992 | 689 |
| call | 136 | 3,623 | 1,904 | 84 |
| closure | 84 | 1,012 | — | 432 |
| alloc | 273 | 2,470 | — | 666 |
| poly | 139 | 3,200 | — | 683 |
| string | 28 | 503 | — | 817 |
| float | 82 | 2,398 | 325 | 26 |

### arm64 JIT (Mac, indicative)

| Benchmark | QuickJS | Dis base | Dis inl | Dis opt |
|---|---|---|---|---|
| prop | 130 | 1,673 | 502 | 96 |
| call | 110 | 958 | 504 | 60 |
| closure | 58 | 316 | — | 145 |
| alloc | 108 | 329 | — | 190 |
| poly | 77 | 712 | — | 194 |
| string | 22 | 164 | — | 187 |
| float | 75 | 467 | 103 | 42 |

### Copying a value (`valrep`: 5M copies)

| Value | amd64 JIT | amd64 interpreter | arm64 JIT |
|---|---|---|---|
| with pointer fields (one or two) | 455 | 335 | 115 |
| no pointer fields | 56 | 222 | 33 |
| tag and number in separate arrays | 22 | 234 | 15 |

### Other measurements

- **Loading a generated module:** 25 µs (amd64) and 35 µs (arm64) for each of 1,000 distinct copies, including JIT translation and a call.
- **Cyclic garbage:** six rounds of about 60 MB of objects in cycles exhausted a 1 GB heap on both machines ("out of memory: heap"). The collector didn't keep up.

## What they say

1. **The optimised tier is a good target where the JIT is good.**
   - On arm64 it is level with QuickJS or within 2.5× of it, and faster on property access, calls and floating point.
   - On amd64 pure floating point is 3× faster than QuickJS, but anything that copies a value is 2.5–5× slower.
2. **The amd64 JIT punts struct copies that hold pointers.** It calls the interpreter's routine for `IMOVMP` on every copy. So copying a value with any pointer in it is 8× slower than one without, and slower than plain interpretation. Real/int conversions (`ICVTFW`, `ICVTWF`) are punted too. A JavaScript value is copied at every assignment, argument and return, so this one instruction is most of the amd64 gap.
3. **The baseline tier is 9–39× slower than QuickJS on amd64**, and 3–13× on arm64. Testing the common case in line gains 2–3×, but that is still far off. So an engine that only interprets, or only has a generic tier, would be slow. Type-specialised code is needed early, not as the last phase.
4. **Strings in Limbo are slow at this work:** 8–40× slower than QuickJS. The engine needs its own string representation (ropes, byte buffers, a flattening strategy), not Limbo strings used directly.
5. **Generated modules are cheap:** a function per module, translated at load, costs tens of microseconds.
6. **The collector is paced by the scheduler, not by allocation.** It runs when the system is idle, or for one slice every 256 scheduling rounds, so a thread that keeps allocating cyclic garbage outruns it. JavaScript makes cycles all the time.

## What follows

The VM comes first. Each of these changes helps all Limbo code, not only JavaScript:

- **JIT:** compile `IMOVMP` in line, specialised to the type's pointer offsets, on amd64, arm64 and riscv64. Compile `ICVTFW`/`ICVTWF` in line on amd64. Target: `valrep`'s pointer rows near its pointer-free ones.
- **Collector:** pace collection by bytes allocated, so allocation pressure drives it. Target: `gctest` finishes, with bounded pauses.

Then rerun this spike and choose the value representation: values holding pointers, relying on the faster copy, or pointer-free values whose objects live in engine-managed tables. Then the parser.
