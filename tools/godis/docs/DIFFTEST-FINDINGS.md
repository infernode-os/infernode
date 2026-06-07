# GoDis differential-test findings

Live worklist of real godis↔Go divergences surfaced by the differential-testing
harness (`tools/godis/difftest`). These are **not** gated in CI (the locked
corpus is); they are the ranked queue for follow-up fix sprints.

Regenerate this picture any time:

```sh
cd tools/godis
go run ./cmd/difftest testdata _corpus      # summary + worklist
```

Current status: **217 match, 21 skipped, 1 active divergence** below (plus one
flaky program, skipped).
The `skipped` programs (see `_corpus/skip.txt`) are excluded because `go run` is
not a faithful oracle (Inferno-only `inferno/sys`, nondeterministic
goroutine/select/map order, or behavior Go leaves implementation-defined such as
builtin `println` float formatting and `cap()` growth).

Each finding lists how to reproduce it in isolation:

```sh
go run ./cmd/godis -o /tmp/x.dis <prog.go>
go run <prog.go>                                  # Go reference
./emu/Linux/o.emu -r. -c0 /tmp/x.dis              # godis interpreter (from repo root)
./emu/Linux/o.emu -r. -c1 /tmp/x.dis              # godis JIT
```

## Fixed so far

- **`strconv.Atoi`/`ParseInt`/`ParseUint` error reporting.** The Dis `CVTCW`
  opcode silently yields 0 for non-numeric input, and the lowerings hardcoded a
  nil error. Now `lower.go` emits a runtime digit-grammar validation
  (`emitIntParseError`) that writes a non-nil `errorString` on bad input.
- **`delete(m, k)` on pointer-valued maps** (e.g. `map[int]string`) faulted: the
  value-swap temp was a word slot, so `emitStoreThrough`'s `MOVP` decremented a
  garbage refcount → nil deref. Now typed via `allocMapKeyTemp` (H-initialized
  pointer slot), mirroring the key temp.
- **Package-level `var` initializers for composite/reference types.** The
  synthesized package `init` (which runs `var m = map[...]{}` → `MakeMap`+store,
  `var s = []T{...}`, etc.) was skipped entirely; only `init#N` user funcs ran.
  Globals needing runtime init were left nil and faulted on first use. `main` now
  calls the real `init` (which chains to `init#N`); calls to the init of
  intercepted/uncompiled packages are skipped at lower time (`lowerCall`).
- **Fixed-size multidimensional value arrays** (`[N][M]T`) faulted with "array
  bounds error". Two bugs: `allocArrayElements` reserved one frame word per
  element regardless of element size (so `[2]int`-sized rows were
  under-allocated), and nested `IndexAddr` treated an interior row pointer as a
  Dis array and used the bounds-checked `INDW`. Now elements are allocated at
  full size (recursing for nested arrays/structs) and interior pointers are
  indexed by pointer arithmetic (`isInteriorPointer` in `lowerArrayIndexAddr`).
- **`fmt.Println()` / `fmt.Print()` with no arguments** segfaulted. go/ssa passes
  a nil `[]any` slice constant for an empty variadic; the vararg tracer couldn't
  walk it and the call fell through to a direct call to the uncompiled
  `fmt.Println`. Now an empty variadic (`fmtVarargsEmpty`) prints a newline
  (`Println`) / nothing (`Print`). This one fix resolved two separate findings —
  `seed_fibmemo` and `seed_quicksort` both crashed only at their trailing
  `fmt.Println()`, not in their actual logic.
- **`errors.Unwrap` / `errors.Is` chains.** `errors.Unwrap` was a stub returning
  nil and `fmt.Errorf("%w", err)` discarded the wrapped error, so `Unwrap` and
  `Is`-through-wrapping were broken. Added a `wrapError` representation: `%w`
  builds a heap struct `{msg, innerTag, innerVal}` (GC-traced via a custom type
  descriptor) tagged `wrapError`; `.Error()` returns its `msg`; `errors.Unwrap`
  yields the inner error; and `errors.Is` now walks the unwrap chain comparing
  the full interface (tag AND value), instead of comparing only the tag. (Holds
  for errors used within their creating function — the same in-frame limitation
  as any heap-backed interface value in godis.)

---

## 1. `defer` in a loop faults  ·  `c0!=c1` + `crash`

`_corpus/gen_defer_order.go`

`for i ... { defer fmt.Println("deferred", i) }` prints the body then faults
instead of running the three deferred calls LIFO. This corroborates the known
limitation of the compile-time defer model (defer in loops/conditionals is
silently wrong); the harness reaches it independently. Fixing it is the
"runtime defer/recover" task in the project handoff.

```
gen_defer_order.go   c0/c1 fault after "body done\n"   want "body done\ndeferred 3\ndeferred 2\ndeferred 1\n"
```

Note `_corpus/gen_defer_in_loop.go` and `gen_defer_named_return.go` *do* pass —
the trigger is specifically a deferred call whose arguments are evaluated per
loop iteration.

## 2. Global / returned error interface has a nondeterministic value  ·  flaky (skipped)

`_corpus/gen_error_sentinel.go` (in `_corpus/skip.txt`, kept as a regression test)

`errors.Is(err, errNotFound)` — where `var errNotFound = errors.New(...)` is a
package global returned from a helper — matches `go run` only intermittently
(~8/10 runs). `errors.Is` now compares the full interface (tag AND value) and
walks the unwrap chain, so the comparison itself is correct; the residual
flakiness is upstream. The materialized global/returned error interface
occasionally presents a garbage word, i.e. one of its two words is read before
being initialized on some runs — a nondeterministic-materialization bug specific
to a package-global error value flowing through a return. Locally-constructed
sentinels (and the whole `gen_error_wrap` chain) are deterministic and pass.
Next step: trace how a global interface value is loaded/returned (`lowerReturn` /
global materialization) and find the uninitialized read.

---

## How findings graduate out of this list

When a fix lands, the program flips to `match`. Lock it in so it can never
regress:

```sh
cd tools/godis
go run ./cmd/difftest -locked _corpus/locked.txt -promote testdata _corpus
```

then delete its entry here.
