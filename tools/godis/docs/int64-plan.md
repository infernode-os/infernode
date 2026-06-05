# Plan: widen Go `int` to 64 bits

## Problem

Go's `int`/`uint` are 64-bit, but GoDis currently operates on them as 32-bit
Dis `WORD`s. The frame *slot* is 8 bytes (`IBY2WD == 8`), but only the low
word is ever written or computed, so any value that needs more than 32 bits is
wrong:

```go
println(1 << 31)        // godis: -2147483648   go: 2147483648
var n int = 3000000000  // truncates / sign-flips
```

(Large *constants* are already materialized correctly from module data — see
`Compiler.AllocIntWord` — but *computed* values still overflow because the
arithmetic is 32-bit.)

## Why this is not a one-line flip

Three properties of the current backend make this a pervasive change rather
than a localized one.

1. **Value moves are not type-discriminated.** Copies between slots (call
   arguments, returns, phi edges, struct fields, assignments) are emitted with
   a duplicated `if isPtr { MOVP } else { MOVW }` idiom at dozens of sites
   (e.g. `lower.go` call marshaling ~5363/5411/5524/5605, struct fields
   ~5613/5615). The `else MOVW` branch moves *every* non-pointer value — int,
   bool, byte, the low word of a float — and only ever copies 32 bits. There
   is no central "move a value of type T" helper to change in one place.
   `IMOVW` appears ~730× in `lower.go` and ~1150× in `lower_stdlib.go`.

2. **High words are never established.** Non-pointer slots are not
   zero/sign-extended (the same gap that motivated `emitZeroStackSlots`).
   32-bit `WORD` ops don't care about the high word, but 64-bit `LONG` ops do.
   So before any `ADDL`/`BLTL` can be used, every int value must have a valid
   high word at its point of creation: constants, conversions, arithmetic
   results, loads from memory, function results, `len`/`cap`, range indices.

3. **Dis boundaries expect `WORD`.** Array indexing (`INDW`/`INDX`), several
   `Sys` calls, and string/byte primitives take 32-bit indices/lengths. Go
   makes all of these `int`, so a 64-bit int must be narrowed (`CVTLW`) back to
   a word at each such boundary.

What *is* already centralized and easy: scalar arithmetic and comparison go
through `arithOp` (4 call sites) and `compBranchOp`, so switching the *operator
selection* to `ADDL`/`SUBL`/`MULL`/`DIVL`/`MODL` and `BEQL`/`BLTL`/… is small.
The hard part is feeding those ops correct 64-bit operands (points 1–2) and
narrowing at boundaries (point 3).

## Phased plan

Each phase keeps the full E2E suite (`go test ./...`, 170 programs on the
emulator) green before moving on.

- **Phase 1 — typed move layer (pure refactor, no behavior change).**
  Introduce `emitValueMove(dst, src dis.Operand, t types.Type)` and route the
  scattered `if isPtr {MOVP} else {MOVW}` sites through it. It still emits the
  current ops, so the suite stays byte-for-byte identical. This creates the
  single seam Phase 3 needs.

- **Phase 2 — 64-bit value discipline for one opt-in type (`int64`/`uint64`).**
  - `arithOp`/`compBranchOp`: emit `*L` ops when the basic kind is
    `Int64`/`Uint64`.
  - Sign-extend on creation: int64 constants via `MOVL`/`CVTWL`; conversions
    via `CVTWL` (int→int64) and `CVTLW` (int64→int); int64 prints via `CVTLC`.
  - `emitValueMove` copies 8 bytes (`MOVL`) for int64.
  - Add `int64`-specific E2E tests (e.g. `1<<40`, large multiply/compare).
  This proves the machinery on a surface the existing tests barely touch, so
  regression risk is low.

- **Phase 3 — make `int`/`uint` 64-bit.** Flip `GoTypeToDis` int kinds to use
  the long path and the Phase-1 move layer. Narrow at Dis boundaries:
  - array/slice indexing → `CVTLW` before `INDW`/`INDX`;
  - `Sys`/host call arguments declared as `WORD`;
  - string/byte builtins (`len`, slicing) that index with words.
  Iterate against the E2E suite; expect the bulk of fallout here.

- **Phase 4 — cleanup.** Audit remaining direct `IADDW`/`IMOVW` that handle int
  *values* (vs. addresses/offsets, which stay 32-bit), update the README
  limitations, and add overflow/bit-width tests.

## Risks

- Silent high-word garbage produces wrong results or GC faults that are hard to
  attribute; Phase 1's seam plus per-phase E2E runs are the main mitigation.
- Distinguishing "int value" `IMOVW` from "address/offset" `IMOVW` at the ~1880
  sites is the labor-intensive, error-prone part; the typed move layer confines
  it to one function.
- Performance: 64-bit ops and extra narrowing add instructions; acceptable for
  correctness, measurable via `testdata/bench`.

## Status

- **Phase 1 — done.** `emitValueMove`/`emitArgCopy` are the typed-move seam;
  call/spawn argument marshaling, returns, and phi moves route through it.
  Pure refactor, suite stayed green.
- **Phase 2 — done.** `int64`/`uint64` are now real 64-bit Dis LONGs:
  - moves via `MOVL`; constants via a new `DEFL` module item
    (`Compiler.AllocLong`);
  - arithmetic/comparison via the LONG opcode variants (`arithOp`/
    `compBranchOp` remaps, `wordOpToLong`/`wordBranchToLong`);
  - printing via the `%bd` verb (8-byte vararg) and `CVTLC` for string
    building;
  - conversions int↔int64, int64↔float in `lowerConvert`.
  Covered by `testdata/int64.go`.

  Two bugs were found and fixed along the way:
  - **emu `load.c` DEFL**: `(LONG)(ulong)lo` did not mask the low word on
    LP64 (ulong is 64-bit), so longs with bit 31 set in the low word were
    sign-corrupted. Fixed with `(u32int)lo`.
  - **`fitMid`**: the Dis middle operand (`ushort reg`) is 16 bits, so a
    wider immediate placed there was truncated — a pre-existing bug affecting
    plain `int` too. Over-wide middle immediates are now materialized to a
    slot first.

- **Phase 3 — done.** `int`/`uint`/`uintptr` are 64-bit. This turned out to be
  small once phases 1–2 existed: a Dis WORD is machine-word width (`intptr`,
  64-bit on amd64/arm64), so the WORD arithmetic/compare opcodes already compute
  at 64 bits — what was truncating plain int was the *storage* (32-bit `DEFW`
  constants and word moves leaving stale high bits), not the arithmetic. So
  `isWide64Int` includes int/uint/uintptr and the value path (MOVL moves, DEFL
  constants, `%bd`/`%bud`, conversions) widens; the arithmetic stays on the
  WORD opcodes. Covered by `testdata/int_wide.go`.

  **JIT note.** Integer arithmetic deliberately uses the WORD opcodes, not the
  LONG ones. This is the correct mapping on a 64-bit-WORD host (a Dis WORD is
  machine-word width, so WORD ops already compute at 64 bits) and the LONG ops
  are redundant. It also keeps the JIT happy: when godis emitted the LONG
  arithmetic/compare opcodes, quicksort hung under `-c1` while the `-c0`
  interpreter was fine. Every testdata program now produces identical output
  under `-c0` and `-c1`.

  Follow-up investigation showed this is **not** a general amd64-JIT LONG-op
  bug: Limbo `big` exercises the same LONG opcodes and is correct under `-c1` —
  `jittest` passes 181/181 (big add/sub/mul/div/mod, bitwise, shifts,
  comparisons), and hand-written `big` programs (a quicksort and a
  1M-iteration accumulate-and-compare loop) produce identical output under both
  modes. The hang was specific to the instruction pattern godis emitted around
  the LONG ops (operand modes / temp layout), not the JIT's LONG codegen in
  general. Since the WORD-op path is both correct and simpler, the
  godis-specific trigger was not pursued further — no code path emits it now.
  (An earlier commit message overstated this as a Limbo `big` JIT bug; it is
  not one.)
  `uint64` is handled: ordered compares use the existing sign-bit-flip in
  `lowerComparison`, and `println` uses the `%bud` verb so values above the
  int64 range print unsigned. Remaining int64 gaps are minor: unsigned 64-bit
  *string* formatting (`CVTLC` is signed) and `uint64` division/modulo
  (`DIVL`/`MODL` are signed) for operands above the int64 range.
