# GoDis differential-test findings

Live worklist of real godis↔Go divergences surfaced by the differential-testing
harness (`tools/godis/difftest`). These are **not** gated in CI (the locked
corpus is); they are the ranked queue for follow-up fix sprints.

Regenerate this picture any time:

```sh
cd tools/godis
go run ./cmd/difftest testdata _corpus      # summary + worklist
```

Current status: **216 match, 21 skipped, 2 active divergences** below.
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

## 2. `errors.Unwrap(err).Error()` faults  ·  `crash`

`_corpus/gen_error_wrap.go`

`fmt.Errorf("...: %w", base)` formats and `errors.Is` works, but
`errors.Unwrap(wrapped).Error()` faults — the unwrapped error chain isn't
navigable (`errors.Unwrap` is currently a stub returning a nil interface).

```
gen_error_wrap.go   faults after "operation failed: base failure\nis base\n"   want "...\nbase failure\n"
```

## 3. `errors.Is` on a global sentinel is nondeterministic  ·  flaky (skipped)

`_corpus/gen_error_sentinel.go` (in `_corpus/skip.txt`, kept as a regression test)

`errors.Is(err, errNotFound)` where `var errNotFound = errors.New(...)` matches
`go run` only intermittently (~7/8 runs). `errors.Is` compares just the first
interface word (the errorString tag) via `IBNEW`; for a global sentinel that
word is not a stable discriminator, so the result varies per run. A correct fix
gives sentinel errors a distinct identity and compares it (and walks the unwrap
chain). Exposed by the global-init fix — previously the sentinel was nil, so the
tag-compare was a deterministic (but wrong-for-the-right-reason) match.

---

## How findings graduate out of this list

When a fix lands, the program flips to `match`. Lock it in so it can never
regress:

```sh
cd tools/godis
go run ./cmd/difftest -locked _corpus/locked.txt -promote testdata _corpus
```

then delete its entry here.
