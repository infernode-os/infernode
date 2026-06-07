# GoDis differential-test findings

Live worklist of real godis↔Go divergences surfaced by the differential-testing
harness (`tools/godis/difftest`). These are **not** gated in CI (the locked
corpus is); they are the ranked queue for follow-up fix sprints.

Regenerate this picture any time:

```sh
cd tools/godis
go run ./cmd/difftest testdata _corpus      # summary + worklist
```

Current status: **211 match, 21 skipped, 5 active divergences** below.
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

## 2. Fixed-size multidimensional arrays fault  ·  `c0!=c1`

`_corpus/seed_matrix.go`

A `[3][3]int` matrix multiply faults immediately: `array bounds error` under
`-c0`, `dereference of nil` under `-c1`. Slices of slices (`[][]int`) work
(`gen_slice_2d.go` passes), so this is specific to value arrays-of-arrays.

```
seed_matrix.go   c0 "array bounds error"  c1 "dereference of nil"  want 3 rows of products
```

## 3. Deep recursion through a global map faults  ·  `crash`

`_corpus/seed_fibmemo.go`

With the global-map-initializer fix, the memoized Fibonacci now runs correctly
through `fib(10)` (it previously faulted immediately). But `fib(30)` — deeper
recursion populating the global `map[int]int` cache — still faults with
`dereference of nil`. Likely map growth/rehash under many inserts, or recursion
depth interacting with the global. Good next target now that the init half works.

```
seed_fibmemo.go   faults after "0 1 1 2 3 5 8 13 21 34 55 "   want that + "\n832040\n"
```

## 4. `errors.Unwrap(err).Error()` faults  ·  `crash`

`_corpus/gen_error_wrap.go`

`fmt.Errorf("...: %w", base)` formats and `errors.Is` works, but
`errors.Unwrap(wrapped).Error()` faults — the unwrapped error chain isn't
navigable (`errors.Unwrap` is currently a stub returning a nil interface).

```
gen_error_wrap.go   faults after "operation failed: base failure\nis base\n"   want "...\nbase failure\n"
```

## 5. `errors.Is` on a global sentinel is nondeterministic  ·  flaky (skipped)

`_corpus/gen_error_sentinel.go` (in `_corpus/skip.txt`, kept as a regression test)

`errors.Is(err, errNotFound)` where `var errNotFound = errors.New(...)` matches
`go run` only intermittently (~7/8 runs). `errors.Is` compares just the first
interface word (the errorString tag) via `IBNEW`; for a global sentinel that
word is not a stable discriminator, so the result varies per run. A correct fix
gives sentinel errors a distinct identity and compares it (and walks the unwrap
chain). Exposed by the global-init fix — previously the sentinel was nil, so the
tag-compare was a deterministic (but wrong-for-the-right-reason) match.

## 6. Tail crash after correct output  ·  `c0!=c1`

`_corpus/seed_quicksort.go`

Prints the fully correct sorted sequence, then faults at function/program exit.
Because the output up to the fault is correct, this is likely a frame-teardown
or final-`fmt.Println()` issue rather than a logic bug. Needs isolation (bisect
the recursive `append(append(less, equal...), greater...)` + `copy` against the
trailing empty `fmt.Println()`).

---

## How findings graduate out of this list

When a fix lands, the program flips to `match`. Lock it in so it can never
regress:

```sh
cd tools/godis
go run ./cmd/difftest -locked _corpus/locked.txt -promote testdata _corpus
```

then delete its entry here.
