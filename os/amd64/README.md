# os/amd64 — x86-64 native InferNode

The native x86-64 kernel's first stages: a Multiboot kernel that
identity-maps the first GiB with 2 MiB pages, enters long mode,
initializes a 16550 console, prints the Multiboot memory map, and runs
a trap table, the 8254 timer and a preemptive round-robin run queue.

## The entry

A Multiboot loader enters an ELF64 image in 32-bit protected mode with
`eax = 0x2BADB002` and `ebx` pointing at the Multiboot information. The
stub in `boot.S` identity-maps the first GiB, sets PAE and LME, enables
paging, loads the 64-bit GDT, and jumps to the C entry. The ELF class is
64-bit throughout; only the bytes at `_start` are 32-bit machine code.

The stub's page tables, GDT and saved Multiboot pointer live in the
kernel image's own `.bss`, not at fixed low addresses: a Multiboot loader
may put the information block, memory map or command line anywhere below
1 MiB, and fixed scratch pages could destroy them. The image is linked at
1 MiB, so those symbols are physical addresses while paging is off; the
stub zeroes the block first and addresses it through 32-bit immediates.

Immediates are safe but memory operands with a symbol are not: a 64-bit
assembler emits PC-relative references even under `.code32`, and in
32-bit execution those displacements are absolute, so `lgdt symbol`
would load from the wrong address. That one instruction is encoded by
hand.

Besides the first GiB, the stub maps 64 MiB at 0xF8000000 for 9vm's shared
display: the third PDPT entry points at a second page directory, whose
entries 448..479 cover the window.

## The machine layer

`trapinit` builds an IDT for vectors 0..47 and loads it, remaps the 8259s
to 0x20/0x28, and programs the 8254's channel 0 at `HZ` (100) in mode 2.
The timer is the only source the PIC unmasks; interrupts stay off until a
test asks for them.

trap.S gives every vector its own stub, because whether the CPU pushes an
error code is a property of the vector. The stubs push a dummy where it
does not, push the vector, and join a common path that saves the rest of
the frame and calls `trap(frame)`. In 64-bit mode the CPU's frame is five
qwords (`SS`, `RSP`, `RFLAGS`, `CS`, `RIP`) even without a privilege
change, so `Trapframe` carries all five; `trap.c` asserts its size.

Exceptions report the vector, name, error code, RIP, RSP and — for a page
fault — CR2, then panic except for the breakpoint, which returns.

`trap()` returns a frame pointer, and that is the context switch: on every
timer tick the scheduler saves the interrupted frame and returns another
thread's. A thread that has never run only needs a frame built for it —
RIP at its entry, `CS`/`SS` the kernel's selectors, `RFLAGS` with IF, and
`RSP` at the top of its stack — and the same `iretq` path starts it.
`thread.c` keeps four threads and a round-robin cursor.

## The os/port foundation

The next arc is upstream's os/port on top of this machine.  Its headers
are Plan 9's, in Plan 9's include order — every .c includes:

```
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
```

and this stage supplies the amd64 end of that:

- `Inferno/amd64/include/u.h` and `lib9.h` — the LP64 type vocabulary
  (`ulong` is 64 bits, as os/port assumes), the x87 control/status
  constants, `USED`/`SET`, and the compiler's `<stdarg.h>`.
- `mem.h` — `BY2WD` 8, `BY2PG` 4096, the identity `KADDR`/`PADDR`,
  `KSTACK`, and `HZ`.
- `dat.h` — `Label`, `Lock`, the x87 `FPU`, `Conf`, then
  `../port/portdat.h` (so `Proc`, `Chan`, `Rendez`, `QLock` are the
  real ones), then `Mach` and the one-CPU `m`/`up`.
- `fns.h` — the machine functions, as `../arm64/fns.h` orders them.

`arch.S` implements the two primitives everything else rests on:

- `setlabel`/`gotolabel`, the error machinery's and the scheduler's
  setjmp/longjmp. `setlabel` saves `rsp+8`, the stack as it will be
  after its return, because `gotolabel` jumps to the saved pc instead
  of returning through it; it also saves rbx, rbp and r12-r15, which
  the skipped epilogues would have restored.
- `_tas`, the test-and-set under `Lock`, a full-width `xchg`.

`arch.c` maps Inferno's spl levels onto RFLAGS.IF, returning the flags
so `splx` restores exactly what it found, and `port.c` defines the
globals os/port expects (`conf`, `machs`, `m`, `active`) and fills the
memory ones from the Multiboot map.

The `porttest` command line proves the three contracts: setlabel
returns 0 and a later gotolabel returns 1 in the same frame; `_tas`
takes, refuses and releases a word; and splhi/splx mask and restore
interrupts.

## os/port processes

`proctest` runs upstream's own scheduler on that foundation. The chain
is the native kernel's:

```
xinit     the base allocator over [end, ramtop)
poolinit  malloc's pools on top of xalloc
procinit  the Proc arena out of xalloc
newproc   a Proc and its kernel stack
kproc     a kernel process at p->sched
schedinit the scheduler loop
```

`os/port/proc.c`, `qlock.c`, `taslock.c`, `alloc.c`, `xalloc.c` and
`alarm.c` are compiled unmodified. `kprocchild` builds the initial
Label (pc at the machine's `linkproc`, sp at the top of the kernel
stack); the scheduler's `setlabel`/`gotolabel` then start it, and
`sleep`/`wakeup` move procs between a Rendez and the run queue.

`shim.c` is what is not ported yet, and only that:

- `print`, `snprint`/`vsnprint` — a small formatter for the verbs the
  kernel's own messages use, until libkern's fmt and `printfp.c`;
- `vm0`, `currun`, `iprogpid`, `upkilled`, `addprog/delprog` — the Dis
  VM is not linked yet, so the registry and VM queries have no answer;
- `closefgrp`/`closepgrp`/`closeegrp`/`closesigs` — no namespaces or
  groups exist yet;
- `dumpstack`, `labelstack`, `debugkey`, `ixsummary`,
  `procsave`/`procrestore` — unwinding, FP save and developer hooks;
- `microdelay` — a pause loop until the PIT clock is calibrated.

The test itself is real: two kernel processes, A and B. A takes and
releases a QLock and sleeps on a Rendez; B takes the same QLock, wakes
A and sleeps on a second Rendez; A wakes B, prints the pass line and
halts. A lost wakeup, a broken error stack or a scheduler that resumes
the wrong stack stops the boot.

```
proctest: A up
proctest: A has qlock
proctest: B up
proctest: B has qlock
proctest: A woke
proctest: proctest passed
```

## Machine tests

## Machine tests

Command line `kerneltest` crosses `int $3`, waits 20 timer ticks, then
creates two worker threads and waits 100 ticks: each worker must have run,
roughly equally, or the test fails. `pftest` writes to `0xdead0000`,
outside every mapping, and the page-fault report and panic are the
expected end of that boot. `tests/host/amd64_boot_test.sh` runs both under
9vm and the same `kerneltest` under QEMU.

## Boot loaders

The kernel is generic: it needs a Multiboot 1 loader, not a particular
one. The harness boots it under every loader it finds.

[qemu-system-x86_64](https://www.qemu.org/) loads the flat image
(`kernel.bin`, made with `objcopy -O binary`) through its Multiboot
option ROM. QEMU refuses an ELF64 image ("give a 32bit one") unless the
header carries the a.out kludge addresses, so `boot.S` sets
`MULTIBOOT_HEADER_HAS_ADDR` and gives the load, bss and entry addresses
explicitly. QEMU then copies the flat image to 1 MiB and enters it; the
ELF is for loaders that parse ELF64.

[9vm](https://github.com/kiljoy001/9vm) is a small KVM microVM runner for
native Harvey, Purgatorio/Inferno and GEFS guests. It loads the ELF64
image, enters it in 32-bit protected mode with a Multiboot information
structure, and emulates a 16550 console at 0x3F8. It is one Multiboot
loader, not a dependency of the kernel. It also publishes the `#~`
shared-memory 9P host ring, which `../9vm` drives; a boot under another
loader has no host filesystem.

## Build and boot

```sh
./tests/host/amd64_boot_test.sh
```

Set `NINEVM` (default `$ROOT/../9vm/9vm`) or `QEMU` to override the
loaders; set either to the empty string to skip it. `BAREMETAL_BUILD_DIR`
keeps the object, ELF and flat files. The harness skips with status 77
when `clang` or `ld.lld` is absent, or when neither loader is available.

```
-- 9vm
infernode/amd64: booting (Multiboot)
...
infernode/9vm: #~/0 host: 8 concurrent reads of 32744 bytes, 300000 bytes verified
infernode/9vm: ring test passed
infernode/amd64: halted
-- ns
...
infernode/9vm: #~/1 ns: 8 concurrent reads of 100 bytes, replies out of order
...
-- display
...
infernode/9vm: display 1024x768 XRGB32 at 0x00000000f8000000
infernode/9vm: display input: key 113 0
infernode/9vm: display test passed
vmdisplay: 2 frames verified, input sent
...
-- trap
...
infernode/amd64: trap 3 breakpoint err 0x0 rip 0x100497 rsp 0x1085a0
infernode/amd64: timer advanced 20 ticks
infernode/amd64: threads a 20526128 b 20669239 over 102 ticks
infernode/amd64: kerneltest passed
-- fault
infernode/amd64: pf test: writing 0xdead0000
infernode/amd64: trap 14 page fault err 0x2 rip 0x100643 rsp 0x1085b0 cr2 0xdead0000
infernode/amd64: panic
infernode/amd64: halted
-- port
infernode/amd64: port: 1 cpu, 65280 pages
infernode/amd64: port: labels ok
infernode/amd64: port: tas ok
infernode/amd64: port: spl ok
infernode/amd64: porttest passed
-- proc
proctest: A has qlock
proctest: B has qlock
proctest: A woke
proctest: proctest passed
-- qemu
...
infernode/amd64: kerneltest passed
PASS: x86-64 boot (9vm ns display trap fault port proc qemu)
```

## Layout

| file | |
|-|-|
| `boot.S` | the 32-bit stub: page tables, long mode, GDT, stack |
| `main.c` | console, Multiboot parse, memory map, the `#~` handoff, halt |
| `console.h` | the console interface the board and the machine share |
| `io.h` | port I/O and the 8259/8254 inter-command delay |
| `trap.h` | the interrupt frame, `HZ`, and interrupt masking |
| `trap.S` | one entry stub per vector, and the common return path |
| `trap.c` | the IDT, the 8259s, the 8254, exceptions, EOI |
| `thread.h` | a thread and the run queue |
| `thread.c` | thread creation, round-robin scheduling |
| `ktest.h` | the machine boot tests |
| `ktest.c` | `kerneltest` and `pftest` |
| `dat.h` | os/port's machine types: Label, Lock, FPU, Conf, Mach |
| `fns.h` | the machine functions os/port asks for |
| `mem.h` | word/page sizes, `HZ`, identity `KADDR`/`PADDR` |
| `arch.S` | setlabel/gotolabel and `_tas` |
| `arch.c` | splhi/spllo/splx/islo |
| `port.c` | `conf`, `machs`, `m`, `active`, and `portinit` |
| `port.h` | the above, and `porttest`/`proctest` |
| `porttest.c` | the os/port foundation's boot test |
| `proctest.c` | two os/port processes, a QLock and Rendezes |
| `shim.c` | the pieces proc.c reaches for that are not ported yet |
| `mem.c` | memcpy/memmove/memset/memcmp/strlen, for a freestanding kernel |
| `kernel.ld` | links at 1 MiB; `.multiboot` and `.text.boot` first |

## Next

- The clock and preemption: `portclock.c` on the 8254, `hzclock` calling
  `sched()`, so a CPU-bound process yields and `tsleep` has timeouts.
- The Dis VM (`os/port/dis.c` + libinterp), which retires the `vm0` and
  registry shims, and real `print` from libkern's fmt.
- Channels, devices and `devmnt`, so `../9vm`'s rings become the
  mountable `#~/0`/`#~/1` (`host`/`ns`) instead of a boot test.
- A framebuffer console over the display slots.
- `os/ip`, the Dis VM and the amd64 JIT.
