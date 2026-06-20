# GoDis differential-test findings

Live worklist of real godis↔Go divergences surfaced by the differential-testing
harness (`tools/godis/difftest`). These are **not** gated in CI (the locked
corpus is); they are the ranked queue for follow-up fix sprints.

Regenerate this picture any time:

```sh
cd tools/godis
go run ./cmd/difftest testdata _corpus      # summary + worklist
```

Current standing: **236 match, 20 skipped, 0 divergences** — the entire
corpus matches `go run` byte-for-byte under both `-c0` and `-c1`. The
worklist below is the historical record of the fix sprints; new findings
go on top.

## Corpus expansion sprint (gencorpus +19 programs)

Five new generator families (`intProgs`, `valueCopyProgs`, `globalProgs`,
`deferRecoverProgs`, `strconvProgs`) targeting integer edge semantics,
by-value copies, package initialization, the runtime defer model, and
strconv error paths. They immediately flushed out and led to fixes for
four compiler bugs:

- **Interface equality compared only the tag word.** `errA != errB` for
  two distinct `errors.New` sentinels evaluated false (same errorString
  tag). Interface `==`/`!=` now compares both words.
- **Unsigned 64-bit `/`, `%`, and `>>` used signed Dis opcodes.**
  `uint64(1<<63) / 2` produced a sign-smeared result. QUO/REM now emit an
  unsigned long-division sequence (halve-divide-correct, with a top-bit
  divisor fast path); SHR emits a logical shift (halve+mask then
  arithmetic shift). Sub-word unsigned types stay on the signed opcodes
  (they are masked non-negative).
- **Struct fields of array type got one frame word** instead of their
  full footprint (`struct{n int; data [4]int}` overlapped neighbours) —
  the struct-field mirror of the earlier `allocArrayElements` bug.
- **Multi-word loads/stores through pointers and array indexing used the
  wrong shape.** Dereference/store of interfaces/structs/arrays now copy
  word-by-word via a shared layout walker (also fixing nested multi-word
  fields, which previously copied only their first word), and `INDX` is
  used for any multi-word array element (`[][2]int` was indexed with an
  8-byte stride).

All 256 programs (236 locked) match after the sprint.
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
Overflow (`ErrRange`) is now detected too: the validator counts
significant digits and lexically compares boundary-length digit strings
against the int64/uint64 bounds, returning Go's clamped value and
`value out of range` message. ParseUint converts via manual accumulation
(CVTCW is signed and saturates at MaxInt64).

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

## ~~3. `defer` in a loop runs once with final values~~  ·  FIXED

`gen_defer_order.go` promoted. The compile-time defer model (static defer
sites inlined once at RunDefers) was replaced with **runtime defer
records**: each executed defer statement pushes a heap record
`{next PTR, site id WORD, captured args…}` onto a per-frame LIFO list, and
RunDefers / the exception handler drain the list with an emitted dispatch
loop. Captured argument values are snapshotted at defer time (raw
stack/interior addresses as plain words, heap pointers reference-counted,
structs and interfaces flattened). This fixes, in one move:

- defer in a loop — one record per iteration, arguments evaluated at
  defer time (`deferred 3/2/1`);
- defer in a conditional — no record pushed means no call run (the old
  model ran every static site unconditionally);
- the exception path — the handler drains only what was actually
  registered before the panic.

The handler epilogue also now writes *typed* zeros to REGRET (H for
pointer results — a raw 0 faulted the caller's frame teardown) and copies
named-result cells to REGRET after the defers run, so
`func f() (msg string)` + `defer func(){ msg = ... }()` + recover returns
the assigned value.

## ~~4. Fixed-size multidimensional arrays fault~~  ·  FIXED

Two bugs (`seed_matrix.go` promoted):

- `allocArrayElements` reserved one 8-byte frame slot per element regardless
  of element size, so a `[3][3]int` got 24 bytes instead of 72 and rows ≥ 1
  landed in (and were clobbered by) neighbouring locals. Aggregate elements
  now allocate their full footprint recursively.
- Chained `IndexAddr` (the inner index of `a[i][j]`) fell into the heap
  Dis-array branch and ran INDW on a raw interior address. Interior-address
  bases (parent IndexAddr/FieldAddr results) now use plain address
  arithmetic (`ptr = base + idx*elemSize`).

## ~~5. `errors.Unwrap(err).Error()` faults~~  ·  FIXED

`gen_error_wrap.go` promoted. `fmt.Errorf` with `%w` now produces a
synthetic `wrappedError` whose interface value is a heap struct
`{msg string; wrapped tag; wrapped value}`:

- `Error()` dispatches on the tag (inline synthetic, like errorString).
- `errors.Unwrap` returns the wrapped (tag, value) pair, nil otherwise.
- `errors.Is` walks the unwrap chain and — fixing a separate latent bug —
  compares **both** interface words instead of only the tag (tag-only made
  any two errorString sentinels compare equal).
- The `%w` Sprintf verb renders both error representations (multi-level
  wrapping works).

Known divergence from Go, accepted: two `errors.New("x")` calls with the
same literal share the deduplicated MP string, so `errors.Is` between them
reports true where Go reports false (distinct allocations).

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
