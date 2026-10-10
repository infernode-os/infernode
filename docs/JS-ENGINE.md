# A JavaScript engine for InferNode

Status (§13): the parser, the interpreter tier with the built-ins, the
`js` command, the realm sandbox and the DOM binding in Charon are built,
on branch feat/js-engine; Charon runs pages' scripts with `scripts on`.
`/mnt/js`, the origin filter and webfs sessions, lazy compilation and
the compiled tiers are to come.

This is InferNode's script engine, not Charon's. Charon is its first and
largest user. The same engine should serve a `js` command beside `sh`,
scripting inside other applications, and Veltro tools. The design follows
[DESIGN-PRINCIPLES.md](DESIGN-PRINCIPLES.md): the namespace is the
capability, mechanism lives in the engine, and policy is expressed as
files.

The decisions asked for are listed at the end. The first of them, whether
to write the engine or embed one, waits on a measured spike (§9).


## 1. Goals and non-goals

Goals, in order:

1. **Safe with hostile input.** Every web page is untrusted code. A
   page must not be able to reach anything it was not given, and a bug in
   the engine must not become a hole in InferNode.
2. **Fast.** Native code on the platforms that have a Dis JIT (amd64,
   arm64, riscv64) without InferNode maintaining a JavaScript JIT of its
   own.
3. **Conformant.** test262 is the scoreboard, as WPT is for Charon. Live
   sites are the acceptance test.
4. **Decoupled.** The engine knows nothing about HTML. Hosts give it
   objects; the namespace gives it authority.

Non-goals for the first year: WebAssembly, SharedArrayBuffer and Atomics,
and matching V8 on compute benchmarks. The target is "page scripts run
correctly and feel instant", not peak arithmetic throughput.


## 2. What is already in the tree

- **`appl/lib/ecmascript`**, the original Inferno ECMAScript engine: a
  late-1990s, ES3-era design (its own bytecode, boxed values,
  string-keyed property lookup). Charon's binding to it went with the old
  Charon engine; an old `js` command (`appl/cmd/js.b`) and acme's `Jwin`
  still load it. The new engine starts fresh and takes nothing from it.
  The new `js` command replaces the old one, and the library is removed
  once nothing loads it.
- **`nsconstruct`** (`module/nsconstruct.m`,
  [appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md)). Veltro's proven
  sandbox. `restrictdir(target, allowed, writable)` forks the namespace
  and bind-replaces a directory with a view of only the allowed names.
  Combined with `NEWPGRP`, `NEWENV`, `NEWFD` and `NODEVS`, it is the
  mechanism the script sandbox reuses (§6). Veltro's v2 model, which built
  the sandbox with `NEWNS` from scratch, was abandoned for v3's
  fork-and-restrict. The reasons are written up in
  [VELTRO_NAMESPACE_SECURITY.md](VELTRO_NAMESPACE_SECURITY.md) and apply
  here too.
- **`webfs`** (`/mnt/web`). HTTP as files, with clone-based connections.
  Today it is **one session**: one cookie jar for every client, readable
  through `/mnt/web/cookies`. Binding it into a page's namespace as it is
  would hand every page every cookie, HttpOnly ones included. A
  per-origin view is required (§6.2).


## 3. The central decision: write it, or embed it

### Option A: a Limbo engine that compiles JavaScript to Dis

A parser, a bytecode interpreter tier, and a compiler tier that emits Dis
modules, loaded at runtime and made native by the existing Dis JIT.

- **Speed without a JIT of our own.** Compiling to Dis gets machine code
  on three architectures, and JIT improvements benefit Limbo and
  JavaScript alike.
- **Memory safety, with one qualification.** Limbo code cannot corrupt
  emu's memory: bounds, nil and type errors are exceptions. That covers
  the parser, the interpreter tier, the runtime and the built-ins, which is
  most of the engine and most of where engine bugs live.

  The qualification: **the Dis loader does not type-check bytecode.**
  `libinterp/load.c` checks a module's structure (sizes, branch targets,
  heap type ids, and signatures when required) but not that instructions
  respect the pointer maps. A Dis module's safety comes from the compiler
  that produced it. A compiler
  that emits Dis at runtime is therefore trusted code, exactly as a
  browser's JIT is. A bug there that emits a wrong type map or a
  mismatched pointer slot is a memory-safety bug. Mitigations:
  - the compiler emits from a small fixed set of instruction templates,
    not free-form code;
  - a verifier pass type-checks each generated module before `load`
    (pointer slots, frame maps, and that no call goes outside the module's
    import table). This is affordable because the generator, not a human,
    is its only client;
  - the interpreter tier is the reference: compiled and interpreted
    results are differentially fuzzed against each other.

  This is still a much smaller trusted base than a C engine, where
  everything is trusted.
- **Cost: compatibility takes years.** test262 has roughly 50,000 tests,
  and the built-in library (RegExp, Intl, Date, typed arrays, Proxy) is
  most of the work. Real sites start working well before conformance is
  complete, as with Charon and WPT.

### Option B: embed QuickJS (MIT) in emu

- **Near-complete modern JavaScript in weeks.**
- **Interpreter only.** That is adequate for DOM glue, but slow for
  framework-heavy pages.
- **Unsafe where it matters most.** It is C inside the single emu
  process, parsing hostile input. One memory bug compromises the whole
  instance, and no namespace contains it. It also puts a large foreign
  runtime in the kernel-equivalent.

### Option B′: QuickJS as an external 9P service

QuickJS runs as a separate host process, confined by the host OS sandbox
(seccomp on Linux, sandbox-exec on macOS), and serves 9P. Emu mounts it.
This keeps emu safe, and it matches the principle that a service in any
language meets the system at a mount point. The cost: every DOM access
becomes a cross-process message, which is far too slow for the hot path
(§4.3). It is viable for a `js` command or a Veltro tool, not for
Charon.

### Recommendation

**A, if the spike (§9) shows the compiled tier is within reach of
QuickJS.** It is the only option that is safe for untrusted input,
fast, and consistent with the system. If the spike fails, B′ for
non-browser use and a hard rethink for Charon. B is not recommended under
any outcome.


## 4. Architecture (Option A)

```
   Charon (DOM, CSSOM, events)   js(1) command   Veltro tool   other app
          │ host objects               │              │              │
          └────────────┬───────────────┴──────────────┴──────────────┘
                       ▼
               Js module  (appl/lib/js, module/js.m)
       parse → bytecode → interpreter ──hot──► Dis codegen → verify → load
               runtime: values, shapes, GC roots, built-ins, job queue
                       │
                       ▼
       the realm's namespace (§6): /mnt/web view, storage, granted devices
```

### 4.1 Realms and processes

A **realm** is one global object, with its built-ins and job queue. Each
realm runs on **one Dis thread** and executes to completion, which is
JavaScript's model, so the engine needs no locks on its object graph.
Workers are separate realms on separate threads, communicating by
channel-carried messages; there is no shared memory.

The process structure is the security boundary (§6): the realm thread,
the host objects it calls, and the state those objects mutate all live in
the restricted process group.

### 4.2 The host interface

The host boundary is a module the host implements:

```
Host: module {
    get:       fn(r: ref Realm, o: ref Obj, key: Key): Val;
    set:       fn(r: ref Realm, o: ref Obj, key: Key, v: Val): int;
    has:       fn(r: ref Realm, o: ref Obj, key: Key): int;
    delete:    fn(r: ref Realm, o: ref Obj, key: Key): int;
    keys:      fn(r: ref Realm, o: ref Obj): array of Key;
    call:      fn(r: ref Realm, f: ref Obj, this: Val, args: array of Val): Val;
    construct: fn(r: ref Realm, f: ref Obj, args: array of Val): Val;
};
```

Most DOM properties are plain data, and the binding should not pay a
dynamic dispatch for each one. The host therefore declares **shaped
classes** (Node, Element, CSSStyleDeclaration): fixed slot layouts and
native accessor functions, registered once. The compiler can then inline
cache them exactly as it caches script objects (§5.2). `Host` is the
fallback for truly dynamic objects (named properties, `document.all`).

### 4.3 Where the file interface goes, and where it does not

Every capability the engine *reaches* is a file: network, storage,
devices (§6). The engine's *control* surface is a file server:

```
/mnt/js/
    clone            read: allocates realm N
    N/ctl            write: kill | limit heap 64m | limit cpu 5s | pause | resume
    N/status         read: running|idle|paused|dead, heap, cpu, job counts
    N/console        read: the realm's console output, one line per call
    N/eval           write source, then read the result (a debugging capability)
    N/ns             read: the realm's namespace, as ns(1) prints it
```

`N/eval` is authority: it runs code inside the realm. It is mode 600,
and Charon's server does not export it outside the user's own
namespace.

**The DOM is not served as files.** A page script makes millions of
property accesses; a 9P round-trip for each would be ruinous. The DOM
binding is a direct module interface within one process group. This is
mechanism under a file-shaped policy, not an exception to the principle:
the authority boundary is still the namespace.


## 5. Execution and performance

### 5.1 Values

Dis has no untyped machine word, so NaN-boxing is out. Values are a
`ref` pick ADT (number, string, object, symbol, bigint) with shared
singletons for undefined, null, true and false. Small integers and common
reals are cached to cut allocation. In compiled code, a function whose
locals are type-stable (observed by the interpreter tier) is specialised:
locals become Dis `int` and `real` registers, guarded on entry and at each
call that could change them. A failed guard deoptimises to the
interpreter at that bytecode offset; the interpreter frame is
reconstructed from a side table, the same deoptimisation design V8 and
JSC use.

### 5.2 Property access

Objects carry a **shape** (hidden class): an immutable map from key to
slot, shared by every object built the same way. Each property-access
site has an inline cache. Dis cannot patch code, and does not need to:
the cache is an entry in the compiled module's data (shape, slot),
checked with one pointer compare and refilled on a miss.
Polymorphic sites keep up to four entries, then go megamorphic to a
global lookup cache.

### 5.3 Tiering

1. **Interpreter**: register bytecode, written in Limbo, JIT-compiled
   once with the rest of the engine. It collects type and shape feedback.
2. **Baseline Dis**: per function, after N calls or loop iterations.
   Generic values with inline caches; removes dispatch overhead.
3. **Optimised Dis**: type-specialised (§5.1), with inlining of small
   callees, for the hottest functions.

The compiler emits one Dis module per compilation unit into a
per-realm in-memory file tree and `load`s it. **Spike questions:**
the cost of `load` plus JIT translation per module; whether batching
several functions per module is needed; and how much memory the JIT's
code allocation uses with thousands of small modules.

### 5.4 Memory

Dis frees by reference counting, with a mark-and-sweep pass for cyclic
structures. JavaScript object graphs are pervasively cyclic: every
function's prototype points back to it, and closures capture their
creators. Two consequences, both for the spike to measure:

- Most JavaScript garbage will be collected by the cycle pass, not the
  reference count, so its pause behaviour sets the page's jank.
- Reference-count traffic on every store is a cost V8 does not pay.

If either is bad, the fallback is an engine-managed heap (objects in
arrays, indices not pointers) for JavaScript objects. That is faster for
GC but gives up some of Dis's safety for free; decide only on numbers.

### 5.5 Preemption

The Dis scheduler reschedules at backward branches in both the
interpreter and the JIT (`schedcheck` in `comp-arm64.c`). A tight
JavaScript loop therefore cannot starve emu. Killing a runaway realm is
`kill` on its process group.


## 6. Security: the namespace is the sandbox

### 6.1 The realm's namespace

The host (Charon, the `js` command) builds the realm's process from its
own namespace, Veltro-style: `NEWPGRP`, `FORKNS`, `restrictdir` for each
granted tree, `NEWENV`, `NEWFD` keeping nothing but the host channel,
then `NODEVS`. What a web page's realm sees:

```
/dis/lib/js/...         the engine and built-ins, read-only
/mnt/web/               an origin-scoped web view (§6.2), not the real webfs
/mnt/store/             this origin's storage: cookies, localStorage, IndexedDB
/mnt/perm/              only what the user granted this origin: clipboard,
                        geolocation, camera, notifications. Absent by default.
/tmp/                   a private, empty, size-capped tree
```

That is all. There is no `/n/local`, `/mnt/llm`, `/mnt/wallet`, `/prog`,
`/net` or other origins' storage, and `NODEVS` stops `#U`, `#p` and `#c`
from being attached to get them back. Charon's own chrome (the URL bar,
other tabs, saved passwords, history) lives in a different process group,
and the page cannot name any of it.

### 6.2 Same-origin as a file server

`/mnt/web` in a realm is an **origin filter** in front of webfs, started
per page with the page's origin as its argument:

- requests are tagged with the page's origin;
- cookies come from and go to that origin's jar in `/mnt/store`, with
  SameSite applied;
- CORS is evaluated in the filter. A cross-origin response a script may
  not read comes back opaque, its body file empty;
- there is no `cookies` file; HttpOnly cookies are never visible to the
  realm;
- Content-Security-Policy `connect-src` becomes the filter's allowlist.

A forgotten check in the engine cannot leak another origin's data,
because that data is not in the realm's namespace. This requires a
change to webfs itself: **per-attach sessions** (an attach name selects
a jar), so that the filter is thin and webfs keeps one implementation.

### 6.3 Threats and the mechanism that answers each

| Threat | Mechanism | Strength |
|---|---|---|
| Script reads another site's data | origin filter; per-origin `/mnt/store` | structural: not in the namespace |
| Script reads local files or secrets | fork + restrict + `NODEVS` | structural |
| Script uses a device it wasn't granted | `/mnt/perm` holds only grants; revoking means unmounting | structural |
| Engine bug (parser, runtime, built-ins) | Limbo memory safety: a bug is an exception that kills the realm | structural |
| Engine bug in the Dis code generator | template codegen, verifier before `load`, differential fuzzing | engineered: this is the trusted base |
| Bug in a host object (Charon's DOM binding) | it runs inside the realm's restricted process group, so it holds only the realm's authority | contained |
| Runaway CPU | preemption (§5.5); `/mnt/js/N/ctl limit cpu`; kill the group | structural |
| Runaway memory | per-realm heap accounting in the engine. **emu has none per process today;** `-pheap` is global | needs work (§10) |
| Cross-origin frames | each frame is its own realm, process group and namespace; `postMessage` is a channel the host mediates | structural |
| Timing side channels (Spectre-class) | coarsened `performance.now()`; no SharedArrayBuffer; one origin per process group | mitigated, never solved |
| Bugs in emu's C code | outside this design; small and stable compared with a JS engine | unchanged |

### 6.4 What a browser cannot easily offer

- **The policy is legible.** `cat /mnt/js/N/ns` shows exactly what a
  page can do. It does not have to be inferred from engine internals.
- **Audit and provenance are free.** The realm's network and storage
  operations are file operations, so they go through the existing audit
  machinery like any other.
- **One sandbox for every untrusted script.** A downloaded script, a
  Veltro tool or a userscript gets the same construction with a different
  grant list.

### 6.5 What the namespace does not cover

Within one realm, what script may do to the DOM is language-level policy:
the host binding enforces it, not the namespace. Same-origin frames share
a realm, as browsers require. The namespace guarantees the blast radius of
a mistake, not the absence of mistakes.


## 7. Event loop

The realm thread's loop is an `alt` over its sources:

```
alt {
    t := <-timers   => run(t.callback)
    r := <-fetches  => resolve(r.promise, r.response)
    e := <-events   => dispatch(e)        # input, from the host
    m := <-messages => deliver(m)         # postMessage, workers
    c := <-control  => obey(c)            # /mnt/js/N/ctl
}
```

After each task the realm drains its microtask queue (promise jobs), then
yields to the host for rendering. A fetch is a thread in the realm's
group that reads the filtered `/mnt/web` and sends its result on
`fetches`; nothing blocks the realm thread.


## 8. Language level, the measured subset, and conformance

### 8.1 What live sites use (measured 2026-10-09)

Thirty sites were loaded in Chromium on minipc with JavaScript on, every
built-in and Web API wrapped in a counting Proxy before any page script
ran, and every script the page ran (inline ones included) saved and
parsed. Bot walls and challenges were excluded (NYT, Stack Overflow,
npm, Reddit, CNN, IMDb), as was one site that never finished loading.
That left 20 sites with scripts, plus two (LWN, Debian) that run none.
The sites were GitHub (home and a repository), BBC News, the Guardian,
English and Thai Wikipedia, Google, YouTube, Amazon, MDN, mozilla.org,
NASA, Python docs, Pantip, Apple, Microsoft, Hacker News, Lazada,
Medium and Booking.

**Syntax.** It cannot be subset: one construct the parser does not know
and that whole script runs nothing. Every site with scripts uses ES2015
syntax (arrows, `let`/`const`, classes, templates, destructuring,
spread). Most use 2017 to 2020: `async`/`await` on 18 of 23,
optional chaining on 17, object spread on 15, `??` on 13. Ten need
ES2022, with class fields and private names on nine. The less common
constructs still appear: generators on 9, direct `eval` on 13, modules
and `import()` on 5, `with` on one. The parser has to accept current
ECMAScript from the first day.

**Built-ins.** 273 distinct built-in methods were called anywhere; 100
of them by half the sites or more. The core is the expected one:
String, Array, Object, RegExp, JSON, Math, Map/Set, WeakMap, Promise,
Date and Symbol, with `Proxy` on 10 of 20 and `Reflect.construct` on
11. Used by two sites or fewer: WeakRef, FinalizationRegistry, and
most of Intl.

**Web APIs.** 1,308 distinct APIs were called anywhere, 163 of them by
half the sites. The head is DOM querying and mutation, events,
attributes and classList, inline style, timers, localStorage and
sessionStorage, cookies, URL and URLSearchParams, fetch and
XMLHttpRequest, history, matchMedia, getComputedStyle,
getBoundingClientRect, requestAnimationFrame and requestIdleCallback,
IntersectionObserver, the Performance timing APIs, and `crypto`. Used
by two sites or fewer: IndexedDB, Web Workers, WebRTC, speech,
notifications, the file system APIs, OffscreenCanvas, Web Animations,
and canvas 2D.

**Coverage.** Each site calls a long tail of its own, so "every API a
site calls" is a poor target: implementing APIs in order of how many
sites use them, the median site has 60% of what it calls after 250 APIs,
83% after 500 and 97% after 1,000. Much of the tail is analytics and
feature detection that fails harmlessly. The measure that matters is
whether the page works, which is the live-site acceptance below.

### 8.2 A minimum viable engine

From the measurements:

- the full current syntax;
- the core built-ins above, plus Proxy and Reflect;
- the head of the Web API list: about 250 DOM, event, storage, network,
  timer and observer APIs;
- the interpreter tier only.

Most page script runs once, at load. The compiled tiers (§5.3) wait
until profiles of real pages show where time goes.

### 8.3 Conformance

Scoreboard: test262 pass count, kept per directory as WPT is for
Charon, run on minipc, with no regressions accepted silently. test262's
feature flags let unimplemented features (Intl, WeakRef, Atomics) be
skipped explicitly rather than counted as failures. Acceptance: the
live-site set Charon already measures, plus pages whose layout depends
on script (GitHub menus, BBC).


## 9. The spike: does Dis go fast enough?

Done on 2026-10-09; the method and every figure are in
[tests/js-spike/README.md](../tests/js-spike/README.md). The decision is
Dis, for the safety reasons above, and the spike says what the VM and
the engine need for it to be fast:

- **Where the JIT is good, the optimised tier is a good target.** On
  arm64 it is level with QuickJS or within 2.5× of it, and faster on
  property access, calls and floating point. On amd64 pure arithmetic
  is 3× faster than QuickJS.
- **The amd64 JIT punts struct copies that hold pointers** (`IMOVMP`),
  calling the interpreter's routine for each one, so a value with any
  pointer in it costs 8× a value without, slower even than
  interpretation. JavaScript copies values at every assignment,
  argument and return.
- **A generic (baseline) tier is 9–39× slower than QuickJS on amd64**,
  3–13× on arm64. Type-specialised code is needed early, not as the
  last phase (§5.3, §11).
- **Strings need the engine's own representation**; Limbo strings used
  directly are 8–40× slower at this work.
- **Generated modules are cheap:** 25–35 µs to load and translate one.
- **The collector is paced by the scheduler, not by allocation:** a
  thread making cyclic garbage outruns it and exhausts the heap.

Those findings come from values that hold Limbo pointers, with
JavaScript's objects left to Dis's collector.  Dis is built that way
for Limbo programs: reference counting so a file or window goes the
moment nothing refers to it, an idle-time collector for the rare cycle
(Limbo makes a cyclic type say so), and a small JIT that punts the
rarer instructions.  JavaScript's heap is nothing like that, which is
why V8 and QuickJS manage their own.

**So the engine has its own heap, and Dis is not changed** (spike2,
2026-10-10):

- **Values** are a tag, a handle and a number, with no pointers, so a
  copy is a plain move.
- **Objects** are rows of the engine's own arrays.
- **Locals** live on the engine's value stack.
- **Collection** is the engine's own mark-and-sweep.

On amd64 the optimised tier is then:

- 1.7–3.2× faster than QuickJS on calls, allocation and floating point;
- level with it on closures;
- 1.7–2.5× off it on polymorphic calls and property access;
- 10× off it on strings, which need their own representation.

Six rounds of half a million cyclic objects take about 165 ms, with
pauses of 5–6 ms.

The baseline tier is 3–11× off, so it emits each operation's common
case in line, and specialised code comes early.  §5.1 and §5.4 are
superseded by this.  One amd64 JIT gap shows: real-to-integer
conversions are punted where arm64 compiles them in line, which is a
small separate fix should profiles of Limbo programs justify it.


## 10. Work this needs elsewhere in the system

- **webfs: per-attach sessions** (one jar per attach name), and the
  origin filter (§6.2).
- **Per-realm memory accounting.** Either the engine counts its own
  allocations against a budget (simple, leaky for host objects), or emu
  accounts heap by process group (exact, a C change). Start with the
  former.
- **A Dis bytecode verifier** for generated modules: a small Limbo pass
  over the instruction stream and type maps. It is useful beyond
  JavaScript, for any other runtime code generator.
- **An in-memory file tree for generated modules** that only the realm
  can see, so `load` has something to read.


## 11. Phases

1. Spike (§9). Decide A versus B′.
2. Parser to an AST for current ECMAScript; the test262 parse tests pass.
3. Interpreter tier and the measured core built-ins (§8.2); the `js`
   command; `/mnt/js`.
4. The realm sandbox: namespace construction, the origin filter, webfs
   sessions. **Charon runs scripts in a realm only from here on, never
   unsandboxed.**
5. The DOM binding in Charon via shaped host classes, for the head of
   the measured Web API list (§8.1); the event loop; retire
   `appl/lib/ecmascript`. This is the minimum viable engine.
6. Baseline Dis tier, verifier, differential fuzzing, when profiles of
   real pages call for them.
7. Optimised tier, guided by the same profiles.


## 12. Decisions needed

1. **A or B′**, pending the spike. B (QuickJS inside emu) is not offered.
2. **Language target**: the current specification for syntax from day
   one; built-ins in test262 order.
3. **Location**: `appl/lib/js`, `module/js.m`, `appl/cmd/js.b`, the
   control server at `/mnt/js`. The namespace sketch (§4.3, §6.1) goes to
   a Jira issue for review, per the project rule.
4. **webfs sessions**: change webfs (preferred), or run one webfs per
   origin.


## 13. Status

### What is built

| File | What it is |
|---|---|
| `appl/lib/js/jslex.b`, `jsparse.b` | Tokens and the grammar, to an ESTree-shaped tree (`module/jsparse.m`), scripts and modules |
| `appl/lib/js/jscheck.b` | The early errors that need the whole tree |
| `appl/lib/js/jsre.b`, `jsrx.b` | Regular expressions: patterns parsed in all three modes, compiled to a backtracking machine |
| `lib/js/unicode` | Unicode 17 property and case data, read when first needed |
| `appl/lib/js/js.b` | The engine: one module made of included fragments; each loaded instance is a realm |
| `jsval.b` | Values (tag, int, real: no Limbo pointers), strings, property keys, shapes, the collector |
| `jsobj.b` | The object internal methods, conversions, comparisons |
| `jsops.b`, `jscomp.b` | Register bytecode and the compiler that makes it |
| `jsvm.b` | The interpreter |
| `jsrt.b` | Generators, async functions, promises and jobs, iteration, eval |
| `jsbuiltin.b` and the rest | The built-ins: Object to Date, typed arrays, Proxy, BigInt, iterator helpers, modules, explicit resource management |
| `tests/js/t262.b` | test262, for parsing or (`-r`) running, each test in a fresh realm |
| `tests/js/jsrun.b` | Run scripts in a realm; `$262.disasm(f)` shows a function's bytecode |
| `appl/cmd/js.b` | js(1): files, `-e`, modules, a read-eval-print loop; `-t` timings, `-g n` collection stress |
| `appl/lib/js/jsdom.b` | A web page's realm (`Js->page`): confinement, the DOM's natives over Charon's `Dom->Doc`, the event loop, fetching through webfs |
| `lib/js/dom.js` | The DOM and the window in JavaScript over those natives: nodes, elements and the HTML element classes, events, selectors, forms, style and style sheets, URL, fetch and XMLHttpRequest, timers, storage, observers, custom elements, import maps |
| `appl/lib/web/browser.b` | Charon's side: a realm per page with scripts, the host functions (layout, selectors, parsing), clicks and form input through the realm, a watchdog |
| `tests/js/jspage.b`, `tests/js/pages/` | A page loaded headlessly with scripts on; `dom.html` checks 163 behaviours, `confine.html` the namespace |
| `tests/js_engine_test.b` | The host interface: values, errors, control flow, jobs, host functions, realms apart |

`appl/lib/ecmascript`, the old interpreter, is retired: Jwin (Acme's and
Xenith's scripted window) uses `Js->deffn` and `Js->callfn`.

The design is §9's: the engine's own heap, Dis and its JIT unchanged.
The interpreter runs script-to-script calls in one loop without Limbo
recursion; a thrown value is a Limbo exception unwound through each
code's handler table; generators and async functions suspend by saving
their registers; the collector runs only at the interpreter's safe
points.

### Conformance (test262, 2026-10-10)

- Parsing (`test/language`, `test/annexB/language`): all tests pass.
- Running `test/language`: 98.3% (18638 of 18968; the early-error tests
  are counted by the parser's run).
- Running `test/built-ins`: 99.0% (17605 of 17791).
- `t262 -g 16` runs them with a collection every sixteen allocations,
  which is how the collector's missing roots were found.

Skipped: proposals no browser ships (decorators, import defer and source
phase imports, Temporal, ShadowRealm, the iterator proposals in
progress, await dictionaries, the error stack accessor, immutable array
buffers), Atomics and SharedArrayBuffer, cross-realm tests.

### Web pages

A page's realm is a process that confines itself before running
anything: a new process group, a namespace of only its grants (webfs,
`/lib/js`, a `file:` page's own directory), no descriptors but standard
error, no devices.  `tests/js/pages/confine.html` checks that it can
read nothing else.  The document is Charon's own `Dom->Doc`, shared;
each task holds the session's lock, and the page is laid out again
before the lock is let go.  A script that runs 30 seconds is stopped.

Gaps, in order: storage and cookies last as long as the page (no
`/mnt/store` yet); the realm sees the whole of webfs, cookie jar
included (no origin filter yet, §6.2: scripts cannot name files, so this
matters only for an engine bug); POST forms from script; shadow DOM is
not shown; no canvas, media or workers.

Measured on twenty large sites: Wikipedia, Google, Mozilla and Hacker
News run their scripts cleanly; the largest bundles (YouTube's 10.9 MB)
need lazy compilation, as V8 does it: parsing alone holds about 90 bytes
of tree per character of source.

### Speed

The interpreter is 10-50x slower than QuickJS on the spike's benchmarks
(calls are the worst).  That is what §9 predicted for an interpreter;
the baseline tier is the answer, guided by profiles of real pages.

Compiling a 430 KB bundle takes 100 ms; parsing it 200 ms.

### Toolchain bugs found on the way (reported, not fixed here)

- `libmath/dtoa.c` (every Limbo string-to-real conversion) does not
  return, or returns a wrong value, for some subnormal inputs
  (`2.5e-310`, `4.94e-324`, `1e-320`), outside the emulator too.
- The Limbo compiler folds `x != x` to 0, and branches on the inverse of
  an ordered real comparison: both are wrong when a value is NaN.  The
  engine tests for NaN with `math->isnan` before ordered comparisons.
- The Limbo compiler's inliner writes a small function's result into
  the destination while building it, so `v = f(v)` can read a field it
  has already written.  Such functions in the engine have a local, which
  stops inlining.
- A module implementing two interfaces (`implement A, B`) breaks its
  function references (`invalid mframe`), so the page interface is part
  of `Js`.
- Dis strings hold 16-bit characters (`Rune` is `ushort`, whatever
  `Runemax` says), so a character past the BMP assigned into one is
  cut to 16 bits; the engine keeps UTF-16 as it is.
- emu faults in `poolfree` after an allocation the arena refuses (seen
  once, under collection stress).

