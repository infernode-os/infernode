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

- `vm0`, `currun`, `iprogpid`, `upkilled`, `addprog`, `strictlink`,
  `keepbroken`, `heapaudittext`, `renameproguser` — the Dis VM is not
  linked yet;
- `muxclose` — `devmnt.c` is not linked, and there are no mounts;
- `randominit`/`randomread`/`hwrandom*` — no generator, and `genrandom`
  panics rather than making a key that only looks random;
- `reboot`/`halt`/`tryboot` — there is nowhere to return to, so they stop
  the machine;
- `dumpstack`, `labelstack`, `procsave`/`procrestore` — the unwinder and
  FP save;


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

## The clock and preemption

The 8254 tick now drives os/port's scheduler. `linkproc` opens
interrupts and `hzclock` runs from the IRQ0 handler: it counts
`m->ticks`, records the interrupted pc in `up->pc`, runs `checkalarms()`
— which is what expires a `tsleep` — and, when a process at the running
process's priority is ready, calls `sched()`.

The `inpreempt` flag bounds the nesting. `sched()` returns only when the
process is scheduled again, so the flag brackets exactly one preemption;
without it, each tick that arrived while the handler was still unwound
would nest another frame on the same kernel stack until it ran off the
bottom.

`preemptest` proves both halves at once. A hog process never sleeps or
yields; a watcher samples the hog's counter, `tsleep`s for 100 ms (a
timeout, not a wakeup from another process), and requires the counter to
have moved. Without preemption the watcher never runs; without a clock
the sleep never expires.

```
preempt: hog advanced 60294981 in 100ms
preemptest passed
```

The tick drives os/port's own timer queue. `clockinit` measures the TSC
against the 8254's channel 2 one-shot; when a virtual machine does not
emulate that output (9vm does not), it falls back to ten channel 0 ticks,
which are already arriving. `fastticks` is `rdtsc` at the measured rate,
and `os/port/tod.c` derives the nanosecond clock from it.
`os/port/portclock.c`'s `timerintr` walks the Timer queue on each tick
and runs the periodic clock Timer, which is what calls `hzclock` —
preemption and expired sleeps included. `addclock0link` timers work, and
`microdelay` is now a calibrated TSC wait.

The interrupt is still the firing granularity: `timerset` has no one-shot
to program, so a timer due between ticks fires on the next one.

## Queues

`os/port/allocb.c` and `qio.c` are compiled unmodified: the Block
allocator and the Queue layer every stream and device sits on. `qread`
blocks on a Rendez when the queue is empty, `qwrite` blocks when its
limit is reached, and both are woken by the other side.

`qiotest` makes both directions matter: a reader blocks on an empty
queue; a writer `qwrite`s 11 bytes into a queue limited to 8, so the
write itself must block until the reader consumes; a watchdog reports a
lost wakeup instead of hanging the boot.

`fmttest` checks that the formatter honours its sink: `%p` used to
write through the console instead of `snprint`'s buffer, which showed
up as an empty string and a wrong length.

```
qio: read 11 "hello world"
qiotest passed
```

This is also where `up` had to stop being `(m->proc)`: `qread` declares
`int m, n`, and the `waserror()` macro expanded `up` inside that scope,
dereferencing the integer. `up` is now `(*upaddr())`, where `upaddr()`
names `m` only where no local can shadow it — the same trap
`os/arm64/dat.h` documents for x28.

## Channels and devices

`os/port/dev.c`, `chan.c`, `devpipe.c`, `devcons.c`, `pgrp.c` and
`sysfile.c` are compiled unmodified, with a two-entry device table
(`os/amd64/devtab.c`: `#c` and `#|`). `chantest` calls `kpipe`, which
takes the real path — `devno` through the device table, `devattach`, the
pipe's directory walk, `devopen` — then writes on one end and reads the
other through the file-descriptor table. It then opens `#c/sysname`
through `namec` and reads the machine name, and writes to `#c/cons`,
which reaches the UART through devcons's console path.

```
chantest: read 5 "hello"
chantest: sysname "infernode"
console from #c/cons
chantest passed
```

`devcons.c` owns `print`, `panic`, `putstrn`, `debugkey` and `seconds`
now: the formatter is libkern's (`vseprint`), the console is
`serwrite` — the machine hands it the polled UART — and
`os/amd64/print.c` is the seam `dofmt` asks for (the format lock, and the
`%e`/`%f`/`%g` and `%r` verbs this kernel declines).

## The #~ device

`os/9vm/dev9vm.c` (compiled with the board) exposes the rings as
`#~/host` and `#~/ns`: byte streams carrying complete 9P2000 messages.
The device table gains it, and `ringdevtest` runs a whole 9P2000
conversation through it — version, attach, a two-element walk, open,
read, clunk — using the kernel's own `convS2M`/`convM2S`:

```
ringdev: 9P2000 msize 32768
ringdev: read 15 "hello from 9vm
ringdevtest passed
```

`mounttest` takes it the rest of the way: the kernel's root device
(`devroot`, with a generated one-directory image) supplies the namespace
root and its `/n`; `kmount(fd, -1, "/n", MREPL, "")` hands the `#~/host`
stream to `devmnt`, which negotiates 9P, attaches and records the mount;
opening `/n/sub/hello.txt` then walks through the mount into 9vm's
exported tree.

```
mounttest: #~/host mounted on /n
mounttest: read 15 "hello from 9vm
"
mounttest passed
```

The harness generates the root image with `tools/mkrootfs.py`
(`/n=`, `/m=`, and `/dis/vmtest.dis` for the VM test) and runs both
mount tests with `-r "$BUILD/root"`, so the files read are the host's,
not fixtures.

## The Dis VM

`disinit()` hands the machine to the Dis interpreter.  The pieces are
the upstream ones: `libinterp` (heap, collector, loader, opcodes) and
`os/port/dis.c`, `exception.c` and `inferno.c`, compiled against
`runt.h` and `sysmod.h` generated by the Limbo compiler from
`module/runt.m`.  The amd64 code generator is linked too, so a module
can be interpreted or compiled to native code; `cflag` chooses, per
load, and the default is still the interpreter.

Dis has a `REAL` type, so this is the first part of the kernel that
uses SSE.  The kernel core is still built `-mno-sse` — no interrupt
path may touch floating point state that nothing saves — while
libinterp and the two files around it are built with `-msse2`.
`procsave`/`procrestore` FXSAVE64/FXRSTOR64 the 512-byte state at every
context switch (`fp.S` saves through an aligned stack slot, because a
Prog's `Osenv` is a malloc'd block of no particular alignment), and
`dis.c` keeps each Prog's own copy across a quantum.

`vmtest` starts two floating point users: the VM interpreting
`/dis/vmtest.dis`, and `fpwork`, a kernel process summing 1.0 in an XMM
register for a second of ticks.  The invariant is exact — summing 1.0
n times must equal `(double)n` — so a lost register is a wrong answer
rather than a rounding difference.  `fpwork` owns the halt: the Limbo
program prints its verdict and sleeps, and the check that ends the boot
is the one that measured the scheduler.

```
Initial Dis: "/dis/vmtest.dis"
vmtest: the Dis VM is running in the kernel
vmtest: 6*7=42
vmtest: 1.5*2.0=3, 1.5+2.0=3.5
vmtest: string "kernel" array[3]=42
vmtest passed
vmtest: fp worker ok (2179828974 additions across 100 ticks)
```

The program is `os/amd64/vmtest.b`, compiled by the harness and placed
in the root image at `/dis/vmtest.dis`; it writes `halt` to `#c/sysctl`
when it has finished, which is what ends the boot.

## The JIT

`libinterp/comp-amd64.c` is linked with `INFERNO_NATIVE`, the switch the
ARM64 and RISC-V ports already carry. Under it the code allocator is
`malloc`, not `mmap`: this kernel maps all of RAM without NX, so
ordinary kernel memory is executable and there is no page protection to
ask for. The hosted allocator's search for a `rel32`-reachable address
is not needed either — kernel text and heap are both inside the
identity-mapped first GiB. `segflush()` (`os/amd64/segflush.c`) is a
serialising `cpuid`; x86's instruction cache is coherent, and no code
is rewritten after it has run. The W^X posture is weaker than a hosted
build's, which keeps generated code off the heap; an executable-only
pool is the improvement to make when there is a page allocator to make
it with.

`cflag` is the switch, read once per module at load. The shell and
network boots set it too, so `sh`, its five libraries, its builtins,
`cat` and `nettest` are all compiled: "jit: Sh compiled, 214400 bytes"
appears before the first prompt, and the harness requires it.  The
vmtest boot stays interpreted, which keeps both paths in the suite.
`interptest` sets `0` and `jittest` sets `1`, both running the same
`/jittest.dis` — a
loop, REALs and their formatting, a string and an array, a case,
recursion, an exception and a spawn with a channel — and the harness
requires the same lines from both. The generator's own line says it
ran, because a compile that fails falls back to the interpreter
silently:

```
jittest: cflag 1 (compiling Dis to amd64)
jit: Jittest compiled, 6288 bytes
jittest: sum=499500
jittest: real=3
jittest: fact=720
jittest: caught fail:deliberate
jittest: spawn=7
jittest passed
```

## Console input and the shell

The console was write-only until this stage.  `os/amd64/consinput.c`
adds the receive side: a kernel process samples the 16550's line-status
register every 10 ms, translates CR to NL, echoes (with a real erase for
backspace, since nothing else does), and hands each byte to `kbdputc`.
Polled on purpose: 9vm emulates the 16550's registers faithfully but does
not raise IRQ4, so an interrupt path would work under QEMU and never
under the loader the harness uses.

`init.b` is the first Limbo program a shell boot runs.  It binds `#c` at
`/dev`, so `/dev/cons` is the file `sh` stats to decide it is on a
terminal, binds `#p` at `/prog`, which is where `sh` opens
`/prog/<pid>/wait` to reap the commands it starts, and hands over to
`/dis/sh.dis` with `-l`.

The root image carries what the shell loads: `Filepat`, `String`,
`Bufio`, `Env` and `Arg`, `load std` for control flow, and `echo`.  The
profile is `os/amd64/profile`, not the bare-metal one -- no secstored,
DNS or desktop to complain about.

```
init: the root image is up
init: starting the shell

; echo hello from the shell
hello from the shell
; echo halt > /dev/sysctl
infernode/amd64: halted
```

The harness boots this under 9vm and QEMU and types at it through a
fifo, one line at a time: the first only after init says the shell is
starting, and `halt` only after the shell has answered.  The 16550's
receive FIFO is sixteen bytes on QEMU, and the shell is not reading when
the loader starts.

## The network and the host namespace

`os/ip` is linked whole (sixteen files) and `#I` joins the device
table, with `ipprotoinit[]` written out in `os/amd64/ipproto.c` because
this port has no `mkdevc` to generate it from a configuration: `ipifc`
first — it owns interfaces — then `icmp`, `icmp6`, `udp` and `tcp`.
Loopback is registered before the device table is reset, so
`bind loopback` finds its medium.

`nettest` proves the stack moves data with no hardware at all:

```
nettest: #I bound at /net
nettest: 127.0.0.1/8 on ipifc 0
nettest: icmp echo reply, 36 bytes
nettest: tcp echo over loopback
nettest: #~/ns mounted at /n/remote
nettest: ns read 14 "hello from ns"
nettest passed
```

ICMP covers `ipoput4`, the route lookup, the loopback medium, `ipiput4`,
the protocol demultiplexer and the checksum — `ptclbsum` is a plain C
implementation (`os/amd64/ipchecksum.c`) because no upstream os/ port
has an x86-64 one. TCP adds the handshake, sequence-number arithmetic
and an ordered stream in both directions; the sequence comparisons are
where LP64 breaks silently, so a wrong answer stalls rather than
corrupts.

There is no hardware entropy source (`rnghw` returns -1), so TCP's
initial sequence number is mixed from `nrand` and the clock, as tcp.c
does on any board without a generator. `os/ip/bootp.c` is not imported:
the `bootp`/`bootpread` hooks are nil, which is what devip tests for.
The router-daemon interface refuses rather than inventing an empty route
table.

The other half of the boot is the host namespace. `init.b` binds `#I`
at `/net` and mounts `#~/ns` at `/n/remote` when the loader offers it —
9vm publishes that channel only when given a server to relay to, so a
loader without one prints one line and carries on. With the stub
serving a file, the shell reads it through the namespace:

```
; cat /n/remote/hello
hello from ns
```

That is the ring transport as a file server, not a network device:
`#~` carries 9P, devmnt mounts it, and the shell does not know or care
that the bytes arrived through shared memory.

## The card: virtio-net over PCI

`os/amd64/virtionet.c` drives the modern (1.0) virtio PCI network
device that both QEMU and 9vm present. It is also the kernel's first
PCI driver, so `os/amd64/pci.c` carries the parts of a bus a driver
needs and no more: the configuration pair at 0xCF8/0xCFC, and
`mmiomap()`, which fills in the boot page table entry covering a BAR and
marks it uncached. The capability list says which BAR holds the common
configuration, the doorbell, the ISR byte and the device's own
configuration, so one driver finds the device under either loader.

Two queues, 64 receive buffers posted and a descriptor per frame. A
modern transport's buffers begin with twelve bytes of virtio_net_hdr
(ten on the legacy one); no offload is negotiated, so it is zeroes out
and ignored in.

Receive is **interrupt-driven**. The device's INTx line (11, as the
PCI configuration says) is unmasked through `intrenable()`, `trap.c`
dispatches it, and the handler reads the ISR byte — which is what
deasserts the line — then wakes the receive process. The work itself
(`allocb`, `etheriqb`) is not something an interrupt may do here. The
process still wakes on a 100 ms timeout as a safety net, so a lost
interrupt delays a frame rather than losing it; the boot prints
`interrupt-driven (irq 11)` the first time one arrives, and the harness
requires that line.

```
ether: virtio-net at pci 3:0.0 common 0xfe000000 notify 0xfe003000 devcfg 0xfe002000
ether: virtio-net 52:54:00:12:34:56 is #l (ether0)
nettest: ether0 up at 10.0.2.15/24 on ipifc 1
nettest: icmp echo reply from 10.0.2.2 (36 bytes)
nettest: tcp echo over ether0
```

The harness gives QEMU `-device virtio-net-pci,netdev=n0,disable-legacy=on`
on a user-network backend, configures 10.0.2.15/24 and pings the slirp
gateway; the frames cross the virtio rings in both directions, and the
reply is an ARP resolution and an ICMP exchange, not a loopback
shortcut.  It then opens a TCP connection to 10.0.2.2:45999 -- the
gateway is also the host's loopback under slirp -- and echoes a string
back from a server the harness starts, so the handshake, the sequence
arithmetic and the byte stream run over virtio. 9vm's card is a TAP device, which needs CAP_NET_ADMIN to
open, so the 9vm network boot runs without one and checks that the
absence is reported and loopback still works.

DIVERGENCE FROM UPSTREAM: `os/ip/ethermedium.c` sends the first ARP
request for a new entry at once. It used to refuse anything within a
second of the entry's creation time, and `NOW` is milliseconds since
boot: a machine whose first packet leaves before it is a second old had
that request dropped with nothing to retry it, so the packet sat in the
cache for ever. The kernels upstream runs on take longer to reach their
first packet.

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
-- preempt
preempt: hog advanced 60294981 in 100ms
preemptest passed
-- clock
infernode/amd64: clock: TSC 3597 MHz
clock: slept 101 ms, 9 timer calls
clocktest passed
-- qio
qio: read 11 "hello world"
qiotest passed
-- fmt
fmttest passed
-- chan
chantest: read 5 "hello"
chantest: sysname "infernode"
console from #c/cons
chantest passed
-- ringdev
ringdev: 9P2000 msize 32768
ringdev: read 15 "hello from 9vm
ringdevtest passed
-- mount
mounttest: #~/host mounted on /n
mounttest: read 15 "hello from 9vm
mounttest passed
-- qemu
...
infernode/amd64: kerneltest passed
PASS: x86-64 boot (9vm ns display trap fault port proc preempt clock qio fmt chan ringdev mount qemu)
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
| `ureg.h` | the exception frame as os/port's clock and traps see it |
| `porttest.c` | the os/port foundation's boot test |
| `proctest.c` | two os/port processes, a QLock and Rendezes |
| `preemptest.c` | the tick preempts a hog, and a timed sleep expires |
| `clock.c` | the TSC's rate, `fastticks`, `microdelay` |
| `clocktest.c` | tod, the timer queue and the measured rate |
| `qiotest.c` | Block queues blocking both ways between two processes |
| `fmttest.c` | snprint writes to its buffer, `%p` included |
| `devtab.c` | the kernel's device table, currently one pipe device |
| `chantest.c` | kpipe, devattach, walk, open, write, read |
| `print.c` | the fmt seam: format lock, `%e/%f/%g`, `%r` |
| `ringdevtest.c` | a 9P2000 conversation over `#~/host` |
| `mounttest.c` | mount that connection on /n and read through it |
| `vmtest.c` | hand the machine to the Dis VM and run a Limbo program |
| `shelltest.c` | boot to a shell instead of a test module |
| `init.b` | the kernel's init: bind #c and #p, then run sh |
| `profile` | the shell's /lib/sh/profile for this root image |
| `consinput.c` | the 16550's receive side, polled, echoed |
| `ipproto.c` | ipprotoinit[], commonuser/commonerror, the hooks os/ip needs |
| `ipchecksum.c` | ptclbsum, the ones-complement checksum os/ip is built on |
| `nettest.c` | boot to the network test |
| `nettest.b` | loopback and ether0: ICMP, TCP, and the host namespace |
| `pci.c` | PCI configuration space (0xCF8/0xCFC) and `mmiomap` |
| `virtionet.c` | the modern virtio-net PCI driver, polled |
| `pcitest.c` | what the loader put on the PCI bus |
| `vmtest.b` | that program: integers, REALs, strings and arrays |
| `segflush.c` | the JIT's code-visible barrier (a serialising `cpuid`) |
| `jittest.c` | boot the same module with `cflag` 0 and 1 |
| `jittest.b` | that module: loops, reals, exceptions, spawn |
| `fpwork.c` | a second SSE user, to prove the scheduler saves FP state |
| `libc.c` | strrchr, strstr, strtol/strtoul, abs and abort, which libc would supply |
| `fp.S` | FXSAVE64/FXRSTOR64, and `fpinit`'s reset image |
| `shim.c` | the pieces proc.c reaches for that are not ported yet |
| `mem.c` | memcpy/memmove/memset/memcmp/strlen, for a freestanding kernel |
| `kernel.ld` | links at 1 MiB; `.multiboot` and `.text.boot` first |

## Next

- An executable-only pool for the JIT instead of RWX kernel memory.
- Compile the shell and the network test with `cflag` 1 once the
  generator has been through more of Limbo than one module.
- More of a root image: the rest of the shell's commands and libraries,
  and a writable /tmp that is not in the read-only image.
- A receive path that uses IRQ4 when the loader raises it, with the
  poll as the fallback (QEMU does, 9vm does not).
- A finer timer source (PIT one-shot) if a driver needs sub-tick
  deadlines.
- A framebuffer console over the display slots.
