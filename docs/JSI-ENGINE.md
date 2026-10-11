# jsi: a JavaScript interpreter in Limbo

jsi (`appl/lib/jsi`) is a second implementation of `module/js.m`, written
beside the compiling engine of [JS-ENGINE.md](JS-ENGINE.md) (`appl/lib/js`)
so the two can be measured against each other and the better one kept.
It shares that engine's front end (`jslex`, `jsparse`, `jscheck`, the
regular expression compiler `jsre`) and nothing else.  Either engine runs
under the same commands:

	js -I file.js			# jsi; without -I, appl/lib/js
	t262 -r -I dir ...		# test262 under jsi
	js -E /dis/lib/other.dis ...	# any module that implements js.m

Like the interpreter of Charon's first JavaScript engine it walks a tree.
Unlike it, nothing in it is a stopgap: the language is ES2025 and the
proposals the other engine carries (explicit resource management,
iterator helpers, `Promise.try`, `Math.sumPrecise`, import attributes).


## 1. How it runs

**A flat tree.**  The parser's ESTree is compiled once into nodes held in
parallel `int` arrays (`op`, `na` .. `ne`, `npos`), with child lists in
`kids`, constants in `knum`/`kstr` and side records in `infos`.  Every
name is resolved at compile time: an `Nvar` placeholder is rewritten by
`fixup()` into a frame slot (`Nlocal`), an Env slot at a known depth
(`Nenv`), a global lexical slot (`Nglex`), a global property, or a lookup
by name (`Ndyn`) where a `with` or a sloppy direct eval makes that
necessary.  A slot whose binding has a temporal dead zone is read with a
check only where a read can come before the declaration.

**Registers, not return values.**  `ev(n)` evaluates node `n` and leaves
the result in five globals (`rt`, `ri`, `rn`, `rs`, `ro`), the fields of
a value.  `ev` declares no pointer locals: Dis initialises and frees
every pointer slot of a frame on each call, and `ev` is the hottest
function there is.  Leaf operands (locals, constants) are read in line by
the operator's own case.  Statement control flow is two globals, `ctl`
and `ctlid`; a JavaScript exception is the Limbo exception `"JS"` with
the value in `thrown`, and each catch site restores the interpreter's
state.

**Values** are `V { t, i, n, s, o }`: undefined, null, booleans, int32
(the fast path for every arithmetic and comparison operator), doubles,
strings, ropes (append-only piece buffers, flattened when read),
symbols, objects and BigInts (Keyring's `IPint`).

**Objects** are Limbo adts of nine words (128 bytes, one heap block):
a shape, slots, a class, flags, elements and their length, the
function, the closure's Env, and a pick for what a class needs besides.
Shapes carry the prototype and a transition table; a prototype gets a
dictionary shape.  Each property access node has an inline cache (shape,
slot, holder, epoch); prototypes' changes advance an epoch that clears
the caches that went through them.  A function's `prototype` object is
made when first asked for.

**Generators and async functions** run on Dis threads.  `resume` and
`coyield` hand the interpreter's globals across; a promise job runs
from the realm's queue.  An async built-in (`AsyncDisposableStack.prototype.disposeAsync`,
`Array.fromAsync`) is Limbo code run as an async function's coroutine,
so it awaits as a script does.

**Memory** is Dis's: objects are freed by reference counting, cycles by
the collector.  A realm is cyclic from the start (prototypes and their
constructors), so `shutdown` walks it from its roots and clears every
object, and reference counting frees the rest at once.

The other engine (§13 of JS-ENGINE.md) compiles to register bytecode,
keeps its values out of Limbo's heap in arrays of its own, collects them
itself, and compiles hot functions to Dis modules the JIT compiles.


## 2. Speed

`tests/js-spike/bench.js`, the spike's seven patterns, on amd64 (this
build's container, the JIT on, `emu -c1`), the median of three runs, in
ms:

| | appl/lib/js, interpreted (`-J -1`) | appl/lib/js (default: compiled tier) | jsi |
|---|---|---|---|
| prop: one object's property read and written | 3367 | 2896 | **2368** |
| call: a small function called | 3795 | 3453 | **3338** |
| closure: closures made and called | 2782 | 3143 | **2572** |
| alloc: small objects made, linked, walked | 1736 | 1934 | **1659** |
| poly: one call site, three classes | 8957 | 6763 | **2901** |
| string: a string built, then split | 1435 | 1519 | **559** |
| float: floating-point arithmetic | 2076 | **1667** | 1931 |

jsi is ahead on five of the seven and level on calls, and well ahead
where the work is property lookup through prototypes (`poly`, 2.3x) and
strings (2.7x); the compiled tier wins `float`, a loop it turns wholly
into native code.  The runs shared the machine with a test262 run.

These are amd64 numbers.  On amd64 the compiled tier gives little,
because the amd64 JIT punts some of the instructions its code relies on;
JS-ENGINE.md reports it 5 to 12 times faster than its own interpreter on
arm64 loops.  The decision should wait for the same table on an Apple
Silicon machine.


## 3. Conformance

test262 (`t262 -r -I`, the same skip list as the other engine):

| | appl/lib/js (JS-ENGINE.md §13) | jsi |
|---|---|---|
| `test/language` | 98.3% (18652 of 18968) | LANGUAGE |
| `test/built-ins` | 99.1% (17623 of 17791) | BUILTINS |

What jsi fails, by kind:

- **Tail calls** (34 tests): calls in tail position are not reused; deep
  recursion meets the call depth limit.
- **Proxies observed through `with`**: the order of a proxy's traps
  when it is a `with` object, in a few compound cases.
- **`$262.createRealm`** and Atomics: one realm per engine instance, no
  shared memory, as in the other engine (skipped there too).
- **`String.prototype.normalize`** returns its string (both engines).
- **`JSON.parse`'s source text access** (the reviver's third argument).

Bugs found and fixed while bringing jsi up that the other engine shares
are fixed in the shared code: a template's raw text keeps CR as LF after
a backslash (`jslex`), and t262 matches a runtime error's type without
the "uncaught " prefix.


## 4. What is not there

- **Web pages.**  `Js->page`, the DOM binding Charon uses
  (`appl/lib/js/jsdom.b`), says "not supported yet".  It is the largest
  piece of work left before jsi could replace the other engine in
  Charon; the DOM itself is JavaScript (`lib/js/dom.js`) over a small
  set of natives, so most of it would carry over.
- `js -P` (profile), `-g` (collection stress) and `-J` (the compiled
  tier) are accepted and do nothing.  `-L` sets the parser's lazy
  threshold, but jsi parses such a function's body as soon as it
  compiles the code around it, so nothing is saved yet.


## 5. Files

| File | What it is |
|---|---|
| `appl/lib/jsi/jsi.b` | The module: `init`, scripts, modules, host functions, `test262`, `shutdown` |
| `jsival.b` | Values, atoms, shapes, ropes, number and string conversion, hash maps |
| `jsiobj.b` | The object internal methods, conversions, equality; the arguments object |
| `jsicomp.b` | The tree, scopes and bindings, and making the tree from the parser's |
| `jsieval.b` | The evaluator: expressions, statements, calls, classes, destructuring, eval |
| `jsigen.b` | Generators, async functions and generators, promises, jobs |
| `jsibuiltin.b` | The realm; Object, Function, Symbol, errors, globals |
| `jsiarray.b`, `jsistring.b`, `jsicoll.b`, `jsiregexp.b`, `jsidate.b`, `jsibig.b`, `jsityped.b` | Array; String, Number, Math, JSON; Map, Set, weak collections, Promise, Reflect, Proxy, iterator helpers; RegExp; Date; BigInt; ArrayBuffer, typed arrays, DataView |
| `jsimod.b` | Modules: linking, namespaces, top-level await, dynamic import |
| `jsidispose.b` | `using`, `await using`, DisposableStack, AsyncDisposableStack, SuppressedError; async built-ins |
| `tests/jsi-spike/` | The measurements the design was chosen by (object layout and size) |
