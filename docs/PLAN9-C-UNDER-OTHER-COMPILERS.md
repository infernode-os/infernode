# Plan 9 C under compilers that are not Plan 9's

InferNode's C is Plan 9 C: the dialect, the idioms, `waserror`/`nexterror`,
`up` and `m`, `setlabel`/`gotolabel`, the kernel's scheduler shape. Its
compilers are not Plan 9's. The hosted emulator is built with whatever the
host has -- gcc on Linux, Apple clang on macOS, MSVC on Windows -- as
Inferno has been since Vita Nuova's 4th edition; the bare-metal kernel is
built with clang (`--target=aarch64-elf`). Charles Forsyth's `7c`/`7a`/`7l`
(Plan 9 for AArch64, mid-2010s, in the 9front tree) is the one compiler
the dialect was written for on this architecture, and this tree does not
use it.

That is a pragmatic choice, not an endorsement of any toolchain, and it is
allowed to stand. What is not allowed is to forget its cost: Plan 9 C
makes guarantees the dialect silently depends on, and every other compiler
is free to break them while producing correct C. Each time one breaks, the
symptom points somewhere else entirely. This document records every such
break found so far, precisely enough that the next one is recognised on
sight -- and the invariants that must hold under any compiler, with the
detectors that enforce them.

The rule this document exists to teach: **when a fault has no explanation
in the source, read the compiler's output for the site.** `clang -S` with
the harness's flags, or `llvm-objdump -d` on the built kernel, and look at
the instructions between the two events that "cannot" be separated.

## 1. `m` is copied, and the copy goes stale across a migration (#622)

**The guarantee Plan 9 C gives.** `m` (the per-core `Mach*`) lives in a
register the compiler never copies and never caches: every use is a fresh
read of the register at that instruction. `up` is `m->proc`.

**What clang does.** `-ffixed-x28` keeps `m` in x28, but the compiler
copies it into a scratch register before dereferencing:

```
    mov  x8, x28
    ldr  x8, [x8, #16]        ; up = m->proc
```

1,171 such pairs in the September 2026 kernel. The trap path deliberately
never restores x28 from a saved frame (`vectors.S`; the same law
`setlabel`/`gotolabel` follow in `arch.S`), so x28 is always the current
core's. **x8 is not.** A process interrupted between the two instructions,
preempted, and resumed on another core reads the *old* core's `Mach`
through x8, and `up` evaluates to whatever process that core is running
now.

**How it presented.** The Dis interpreter kproc died by `error()`
underflow -- userspace dead, kernel pinging, no panic -- four times in a
day under Bluetooth load (#622). Instrumented, the error stack of one
`dis` kproc would gain a label pushed by `tsleep`, `rread`, `rwrite`,
`kopen` or `cclose` (functions that balance their labels perfectly) while
another kproc's count came up one short, seconds apart. The caller had
pushed its label through a wrong `up`, onto another process's stack.
INFR-458's "something writes a pointer into `nerrlab`" was the same fault
seen from a different angle. It reproduced in QEMU in minutes under six
shell loops on `/tmp` (`tools/qemu-soak.py`) and was caught in the act on
the board by a check in `waserror()` that the stack it runs on is the
kstack of the Proc it pushes onto:

```
waserror: up is 40:dis but the stack is 37:dis's (sp 0x81d010, cpu3, m->proc 37, pc tsleep+0x1c4)
```

Two reads of `m->proc` in one statement, two answers.

**The fix** (`os/port/proc.c`, `mayrun()`): a process switched out *while
still Running* -- by either preemption path (`preemption()` and
`portclock.c`) or the yield inside a spinning lock -- is marked by
`schedinit` and may be dequeued only by the core it ran on, once. A
process that *blocked* did so through a call, where no scratch copy of
`m` is live, and migrates freely. 11 hours clean on the board under load
that had produced an event every 1-3 hours.

**The invariant, under any compiler:** *a process may change core only at
a call boundary.* Preemption must pin. A compiler that never copies `m`
(Plan 9 C) does not need this; every other one does.

**Wrong theories this cost, recorded so they are not repeated:** two
cores owning one Proc through the run queue (killed by tripwires in
`ready()` and `runproc()` staying silent); the exit path leaving labels
(killed by counters across `progexit`/`delprog`/`cclose` staying
silent); a "`mach` flicker" detector that fired constantly and was the
*same* stale-copy mechanism -- `m->machno` cached in a register across a
migration -- misread as evidence for the first theory.

## 2. A local set after `waserror()` and read in its handler must be `volatile`

`setlabel`/`gotolabel` are setjmp/longjmp; C leaves a non-volatile local
modified between them indeterminate, and clang `-O2` folds the value the
local had at `setlabel` into the handler. `devwalk`, `mntwalk`, `namec`,
`qbwrite`, `etherbind` all had this shape: a leak of four blocks per
failed name lookup on the idle desktop, an unconditional `freeb` of a
Block already on the queue. `returns_twice` on `setlabel` does **not**
fix it -- it addresses register caching across the call, a different
hazard; only `volatile` (or the `volatile struct { ... }` idiom) makes
the handler read memory. Full account in `os/bcm2837/README.md`,
"Lessons that cost time". Plan 9 C does not fold across `setlabel`.

## 3. Adjacent stores are merged at `-O2`

Two adjacent 32-bit stores become one 64-bit store. With the MMU off all
memory is Device-nGnRnE, which forbids unaligned access outright, and the
mailbox code took an alignment fault at a 4-but-not-8-aligned offset.
`SCTLR_EL1.A` does not help. Bringing the MMU up removes the class;
before that, `volatile` per store or explicit byte order. Plan 9 C does
not merge.

## 4. `up` named twice in one statement is two reads

`errlabcheck()` once tested `up->nerrlab` and printed `up->nerrlab`, and
on 2026-09-07 produced `panic: waserror: error stack overflow, nerrlab 3`
-- the value that tripped the test and the value in the message were
different reads. Under Plan 9 C they would have been too; the difference
is that `up` there is a register read and here is a memory chain through
a possibly-stale copy (see 1), which is how the values could differ at
all. Read `up` once into a local when it matters.

## 5. Diagnostics that use return addresses see through inlining and tail calls

`getcallerpc()` is `__builtin_return_address(0)`. A helper that reads it
and is *inlined* reports its caller's caller; one called in *tail
position* runs in its caller's frame, so a check that compares a stack
address against the caller's frame reports every site as a mismatch
(2,245 false reports in one boot, all of them `tsleep`). `poperrchk()` is
`noinline`, and `poperror()` ends with an empty `asm volatile` so it is
never a tail call; both are load-bearing and say so in comments. Plan 9 C
neither inlines across functions nor emits tail calls.

## 6. A sentinel written as a 32-bit constant, compared with a 64-bit value (#635)

Not a compiler difference but a *width* one, and it belongs here because
it wore the same disguise for four days: a symptom in compiled code
with no explanation in the source. Plan 9 C's `ulong` is 32 bits; this
kernel's is 64. `os/port/exception.c` kept

```
#define NOPC	0xffffffff
```

while `load.c` stores "no handler" as `(ulong)-1` and `patchex()`
preserves it. So `handler()`'s `if(newpc != NOPC)` never matched: an
exception block whose clauses did not name the exception and had no
wildcard was taken as a handler at pc `(ulong)-1`, and the Prog was
resumed at `(ulong)m->prog + (ulong)-1` -- **one byte below its module's
compiled code**, written straight into the Prog's saved registers with
`memmove(&p->R, &R, ...)`. That is why seven probes on every path the
interpreter writes a PC stayed silent and only the victim's next quantum
fired ("misaligned PC in compiled module", `R.PC == prog - 1`). Any
Limbo `raise` that crosses a non-matching `exception` block did it:
`osinit`'s `{ bt->init } exception e { "fail:*" => }` when `bt9p` raised
"module not loaded" (a library missing from the card), `sh`'s blocks
around every command, the `kill Wpa` in the Wi-Fi battery.

The emulator's copy of the same file had been fixed in March 2026
(`903d18c70`, "LP64 NOPC mismatch"); the kernel's copy was imported from
the older source in August without it. **Two copies of one file are two
bugs.** Regression test: `tests/exception_test.b`, run by the QEMU
harness inside the kernel's own interpreter and by the emu suite.

The wider lesson for this port: every `0xffffffff`, `0x7fffffff`, `-1`
cast to a fixed width, and every `%lux`/`%ux` format on an `ulong` is
suspect where Plan 9 C meant 32 bits. `grep -n '0xffffffff' os/port
libinterp` is a five-minute audit; it found this one after the fact.

## 7. The anonymous struct member, again, in new code

`struct Ctlr { QLock; Rendez r; ... }` is Plan 9 C for "a Ctlr is a
QLock, among other things": `qlock(&ctlr)` works because the compiler
knows a `Ctlr*` converts to the `QLock*` of its unnamed member. Under
clang the line `QLock;` declares nothing (a warning), the Rendez lands
at offset 0, `qlock(&ctlr)` is an incompatible-pointer call (another
warning) that spins on the Rendez's bytes, and the first open of
`/dev/audio` on the board was a data abort inside `qlock` (2026-09-18,
`os/bcm2837/audiopwm.c`, the first cut). The harness had escalated
both warnings to errors for `os/port` and `os/ip` since the day they
destroyed xalloc's free list (`tests/host/baremetal_test.sh`, the
comment at the os/port loop, "167 call sites") -- but not for the
platform directory, where new drivers are written. It does now.
Rule for new kernel C: **name the member** (`QLock lk;`) and lock
`&x->lk`; the escalation catches the other form at build time.

## 8. The JIT is a compiler too

`libinterp/comp-arm64.c` emits AArch64 for Dis instructions. Its
preamble saves x19-x22, x29, x30 and uses x0-x5, x20-x22; it does not
touch x28. Any change to its register use must keep that property, and
any C it calls into is subject to everything above -- a Dis `exit` is
`error("")`, a longjmp out of JIT-compiled frames into `vmachine`'s
handler.

## What is kept in the kernel, and why

All of these are cheap and silent on a healthy machine; their job is to
make the *next* instance of this class a named line on the console
instead of a power cycle and a week.

| where | what it checks | what it prints |
|---|---|---|
| `vmachine` (`dis.c`) | error-stack depth after every Prog quantum | the Prog, module, whether it exited, and who pushed each disputed label; repairs the count and re-arms its own label |
| `errlabcheck()` (`proc.c`) | `waserror()` runs on the kstack of the Proc it pushes onto | both Procs, core, `m->proc`, caller |
| `poperror()` / `poperrchk()` | the popped label was pushed from this frame | both sites |
| `ready()` | a proc readied while Running with a core on it | who, from where |
| `runproc()` | a dequeued proc another core still has as `m->proc` | both cores |
| `progexit`/`delprog`/`cclose` | error-stack depth across each teardown step | the step |
| `-DPROCTRACE` (off) | every write to a Proc's `mach`/`state`, recorded | dumped by the above |

`tools/qemu-soak.py` is the reproduction harness for this class.

## Policy

- Build with the host's native compiler for hosted targets (gcc on
  Linux, clang on macOS, MSVC on Windows) and clang for bare metal. This
  is pragmatism about what each platform ships, not a preference.
- Every guarantee the dialect takes from Plan 9 C and the compiler does
  not give is documented **here**, with the symptom it produced, the
  instruction sequence that produced it, and the invariant that replaces
  the guarantee. A fault that turns out to be one of these is a new entry
  or a new paragraph under an old one, before the fix is merged.
- The alternative -- building the kernel with Forsyth's `7c`/`7a`/`7l` --
  is a bounded port (the C is already Plan 9 C; the assembly in `l.S`,
  `arch.S`, `vectors.S` would be rewritten for `7a`; `7l` produces Plan 9
  `a.out`, not ELF, so the boot image path and the harness's symbolisation
  change). It removes the class rather than the instances, and is the
  right answer if this list keeps growing.
