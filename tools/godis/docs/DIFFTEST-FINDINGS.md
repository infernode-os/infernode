# GoDis differential-test findings

Live worklist of real godis↔Go divergences surfaced by the differential-testing
harness (`tools/godis/difftest`). These are **not** gated in CI (the locked
corpus is); they are the ranked queue for follow-up fix sprints.

Regenerate this picture any time:

```sh
cd tools/godis
go run ./cmd/difftest testdata _corpus      # summary + worklist
```

Current standing: **211 match, 20 skipped, 6 divergences** below.
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

## 2. Map delete / repeated insert+lookup faults  ·  `c0!=c1` + `crash`

`_corpus/gen_map_commaok.go`, `_corpus/seed_fibmemo.go`

Map *reads* work, but `delete(m, k)` followed by `len(m)` faults, and a
memoization pattern (`memo[n] = v` then `memo[n]`) faults on the first cached
write/read. The fault differs between interpreter (`segmentation violation`) and
JIT (`dereference of nil`), so it also trips the `c0!=c1` invariant.

```
gen_map_commaok.go   c0/c1 fault after "one true\nfalse\n"   want "...\n1\n"
seed_fibmemo.go      faults after "0 1 "                      want full fib sequence
```

A common real-world pattern (caches, counters); high impact.

## 3. `defer` in a loop faults  ·  `c0!=c1` + `crash`

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
