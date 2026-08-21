# Limbo for Go Programmers

Limbo is InferNode's application language. If you know Go, you
already know most of Limbo's ideas — because Go inherited them.
Limbo (1995) sits in the Newsqueak → Alef → Limbo lineage at Bell
Labs that later produced Go's concurrency model: channels,
lightweight processes, and `select` all appear here first, often
under different names.

This page maps what you know onto what you'll write, then lists
the differences that actually bite. The authoritative reference
is the original paper, in-tree at `doc/limbo/limbo.ms`. The best
way to learn remains reading `appl/cmd/` for small utilities and
`module/sys.m` for the system interface.


## The mapping

| Go | Limbo | Notes |
|---|---|---|
| `go f(x)` | `spawn f(x)` | Preemptively scheduled Dis threads |
| `ch := make(chan int)` | `ch := chan of int` | Unbuffered by default |
| `make(chan int, 8)` | `ch := chan[8] of int` | Buffered |
| `ch <- v` / `v := <-ch` | `ch <-= v` / `v := <-ch` | |
| `select { case ... }` | `alt { v := <-ch => ... }` | `alt` predates `select` |
| package | module: `.m` interface + `.b` implementation | Like a header, but typed and checked |
| `import "x"` | `include "x.m";` then `x = load X X->PATH;` | Loading is explicit and at runtime |
| `struct` | `adt` | Can carry functions (methods) |
| `interface` + type switch | `pick` (tagged union) + `pick` statement | Closed set of variants, not structural |
| `x := 5` | `x := 5` | Same type-inferring declaration |
| `func f() (int, error)` | `f(): (int, string)` | Tuples; error is conventionally a string, `nil` = ok |
| `panic` / `recover` | `raise "fail:..."` / `exception` blocks | Exception strings are matched by pattern |
| slices | `array of byte`, sliced `a[1:5]` | Also `list of T` with `hd`/`tl`/`::` |
| `range` | `for(l := lst; l != nil; l = tl l)` | No range statement |
| garbage collection | garbage collection | Reference counting + cycle collection, deterministic finalization |
| `int64` | `big` | `int` is 32-bit; `byte`, `real` also exist |
| `rune` | `int` | Strings index to code points as `int` |

Modules are the load-bearing difference. A Limbo program is a set
of modules linked *at runtime* with `load`, each declaring a
`PATH` constant naming its compiled `.dis` file:

```limbo
include "sys.m";
    sys: Sys;

init(nil: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    sys->print("hello\n");
}
```

`load` returning `nil` is a real and common failure — check it.
This explicitness is what lets a namespace decide which
implementation of an interface a process gets: loading a module
is a filesystem operation, so *module access is a capability*
like any other file.

Concurrency will feel like home:

```limbo
worker(results: chan of string)
{
    results <-= "done";
}

init(...)
{
    results := chan of string;
    spawn worker(results);
    alt {
    r := <-results =>
        sys->print("%s\n", r);
    <-timeout =>
        sys->print("timed out\n");
    }
}
```


## The gotchas that actually bite

**`>>` is a logical shift.** On Go you sign-extend with
`(x << n) >> n`; in Limbo `>>` does not sign-extend, so that
idiom silently produces the wrong value. Sign-extend explicitly
(`if(x > 128) x -= 256;` for a byte). This has caused real bugs
in this tree.

**No `defer`.** Clean up at exit points, or structure with a
single return path. Exceptions (`{ ... } exception e { ... }`)
exist for the error path.

**`int` is 32 bits.** Use `big` for 64-bit values, and mind the
conversions — they are explicit (`big x`, `int b`).

**Errors are strings by convention.** `nil` means success;
functions that can fail return `(result, string)` or raise
`"fail:reason"`. The runtime prints `%r` for the last system
error: `sys->fprint(sys->fildes(2), "open failed: %r\n");`.

**`spawn` is cheap, not free.** Dis threads cost more to create
than goroutines (channel operations are comparably fast). Spawn
for structure, not per-datum.

**Compile with the right toolchain, to the right target.** Use
the native `limbo` compiler on the host (never the hosted
`dis/limbo.dis`), and never invoke `limbo -o` by hand: the
module's `PATH` constant decides where the runtime loads from,
and a `.dis` compiled to any other path is silently ignored.
`tools/compile-limbo.sh <file.b>` reads the constant and emits to
the right place; `mk install` in the source directory does the
same. When a `.m` interface changes, every `.dis` built against
the old interface is stale and fails at load time with `link
typecheck` errors — rebuild the dependents (the post-merge git
hook does this after pulls).


## The shell

You will also write Inferno `sh`. It is rc-style, not POSIX, and
POSIX habits are the most common review comment we make:

| POSIX habit | Inferno sh |
|---|---|
| `a && b` | `a ; b` (no `&&`, no `\|\|`) |
| `for i in x y; do ...; done` | `for i in x y { ... }` |
| `if [ -d /x ]; then` | `if {ftest -d /x} { ... }` |
| `. script.sh` | `run script.sh` |
| `VAR=v cmd` | `VAR=v; cmd` |
| exit status tests | `raise 'fail:reason'` / `raise 'skip:reason'` |

Scripts begin `#!/dis/sh.dis` and usually `load std`. Quoting is
single-quote based, with `''` to embed a quote. A backgrounded
9P server (`svc &`) keeps the emulator alive until killed —
remember that in test scripts. `doc/sh.ms` is the full paper;
`man/1/sh` the reference.


## Where tests go

Unit tests are Limbo modules in `tests/` using
`module/testing.m` — the API is `t.assert`/`t.asserteq`/
`t.fatal`/`t.skip`, deliberately close to Go's `testing.T`. See
the testing section of [CLAUDE.md](../CLAUDE.md) for the full
template, and `tests/example_test.b` for a copyable starting
point. Namespace-contract tests are written in Inferno sh under
`tests/inferno/`; host-boundary integration tests in POSIX sh
under `tests/host/`.
