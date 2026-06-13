# GoDis differential-test findings

Live worklist of real godis↔Go divergences surfaced by the differential-testing
harness (`tools/godis/difftest`). These are **not** gated in CI (the locked
corpus is); they are the ranked queue for follow-up fix sprints.

Regenerate this picture any time:

```sh
cd tools/godis
go run ./cmd/difftest testdata _corpus      # summary + worklist
```

Current standing: **214 match, 20 skipped, 3 divergences** below.
The `skipped` programs (see `_corpus/skip.txt`) are excluded because `go run` is
not a faithful oracle (Inferno-only `inferno/sys`, nondeterministic
goroutine/select/map order, or behavior Go leaves implementation-defined such as
builtin `println` float formatting and `cap()` growth).

Each finding lists how to reproduce it in isolation:

```sh
go run ./cmd/godis -o /tmp/x.dis <prog.go>
go run <prog.go>                                  # Go reference
../../emu/Linux/o.emu -r../.. -c0 /tmp/x.dis      # godis interpreter
../../emu/Linux/o.emu -r../.. -c1 /tmp/x.dis      # godis JIT
```

---

## ~~1. `strconv.Atoi`/`ParseInt` never report an error~~  ·  FIXED

`Atoi`, `ParseInt`/`ParseUint` (base 10) now emit a decimal syntax-validation
loop (`emitAtoiChecked` in `lower.go`) and return a Go-identical
`strconv.<fn>: parsing "<s>": invalid syntax` errorString on bad input.
`strconv_err.go` and `tier6_8.go` are promoted into the locked corpus.
Overflow (`ErrRange`) is still not detected.

## ~~2. Map delete / repeated insert+lookup faults~~  ·  FIXED

Three distinct compiler bugs, all fixed and locked
(`gen_map_commaok.go`, `seed_fibmemo.go` promoted):

- **`delete` on pointer-valued maps corrupted the heap.** The swap-with-last
  value temp was a raw `AllocWord`; for pointer value types (e.g.
  `map[int]string`) the load emits MOVP, which decrefs the destination's
  previous contents — uninitialized stack garbage. Now type-aware
  (`allocMapKeyTemp`).
- **Two deletes then an insert faulted with `array bounds error`.** delete
  decremented `count` but left the physical arrays longer; the update grow
  path SLICELAs the whole stored array into a `count+1`-sized one. delete
  now shrinks the stored arrays to `[0:count]` views with SLICEA.
- **Package-level var initializers never ran** (see below) — the actual
  cause of the `seed_fibmemo` memoization fault.

### Fixed en route: package-level var initializers never ran

`var memo = map[int]int{}` (and any `var x = <expr>`) silently never
executed: the synthesized SSA `init` function was excluded from compilation
and only user `init#N` funcs were called. Globals therefore held zero — for
a map global, a nil wrapper, hence the faults on first use. main's preamble
now calls each package's synthesized `init` (which runs var initializers and
`init#N` behind `init$guard`); trivial guard-only inits are elided. Calls to
blockless stub-package inits are no-ops, and the linker now *fails loudly*
on any call to an uncompiled function instead of silently emitting a call to
PC 0.

### Fixed en route: multi-word globals overlapped adjacent MP data

`AllocGlobal` gave every global exactly one 8-byte MP word, but interface
globals (`var errNotFound = errors.New(...)`, `var e error`) are 16 bytes
and struct globals are larger still — writing one clobbered whatever the
allocator placed next (string literals, other globals). Latent until the
package-init fix made initializers actually write to globals;
`gen_error_sentinel.go` lost its "not found" line and a neighbouring
program printed garbage. Globals are now sized by type, one MP word per
data word, with struct pointer fields GC-tracked individually.

### Fixed en route: zero-arg `fmt.Println()` corrupted the heap

A variadic call with no operands passes `nil:[]any`; the vararg tracer
returned "untraceable", so interception fell through to a direct call to the
blockless `fmt.Println` stub — which linked to PC 0 and re-entered main,
corrupting the heap (`alloc:D2B`, segfaults at H-offsets, or hangs). This
was the actual cause of old finding #6 (seed_quicksort's tail crash after
correct output) and the fib-loop crash in seed_fibmemo. The tracer now
yields an empty element list for nil vararg slices.

## 3. `defer` in a loop runs once with final values  ·  `diverge`

`_corpus/gen_defer_order.go`

`for i := 1; i <= 3; i++ { defer fmt.Println("deferred", i) }` used to
*fault*: deferred calls to stub fmt functions emitted a direct call to PC 0.
Deferred `fmt.Print(ln)` is now inlined like the non-deferred form, so the
program completes — but prints `deferred 4` once instead of
`deferred 3/2/1`. This is the known compile-time defer model limitation
(static defer sites expand once at RunDefers; loop-carried argument values
are read after the loop). Fixing it properly is the "runtime defer/recover"
task in the project handoff.

```
gen_defer_order.go   got "body done\ndeferred 4\n"   want "body done\ndeferred 3\ndeferred 2\ndeferred 1\n"
```

Note `_corpus/gen_defer_in_loop.go` and `gen_defer_named_return.go` *do* pass —
the trigger is specifically a deferred call whose arguments are evaluated per
loop iteration.

## 4. Fixed-size multidimensional arrays fault  ·  `c0!=c1`

`_corpus/seed_matrix.go`

A `[3][3]int` matrix multiply faults immediately: `array bounds error` under
`-c0`, `dereference of nil` under `-c1`. Slices of slices (`[][]int`) work
(`testdata`/generated `gen_slice_2d.go` passes), so this is specific to value
arrays-of-arrays.

```
seed_matrix.go   c0 "array bounds error"  c1 "dereference of nil"  want 3 rows of products
```

## 5. `errors.Unwrap(err).Error()` faults  ·  `crash`

`_corpus/gen_error_wrap.go`

`fmt.Errorf("...: %w", base)` formats and `errors.Is` works, but
`errors.Unwrap(wrapped).Error()` faults — the unwrapped error chain isn't
navigable.

```
gen_error_wrap.go   faults after "operation failed: base failure\nis base\n"   want "...\nbase failure\n"
```

## ~~6. Tail crash after correct output~~  ·  FIXED

`seed_quicksort.go`'s tail crash was the zero-arg `fmt.Println()` bug (see
finding #2's "fixed en route" notes). Promoted into the locked corpus along
with `seed_fibmemo.go`.

---

## How findings graduate out of this list

When a fix lands, the program flips to `match`. Lock it in so it can never
regress:

```sh
cd tools/godis
go run ./cmd/difftest -locked _corpus/locked.txt -promote testdata _corpus
```

then delete its entry here.
