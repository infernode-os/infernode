# Bare-metal BCM2837 (Raspberry Pi 3B+) port

Tracked as **INFR-404**. This is InferNode running *native* — as the
firmware on the board, with no host OS underneath — rather than *hosted*,
which is what everything under `emu/` does.

Status: **the Dis VM runs.** A Limbo program, compiled to bytecode and
embedded in the kernel image, is loaded from the in-kernel root
filesystem and executed, and its `sys->print()` reaches the console
through the Sys module, sysfile, chan, devcons and the UART.

Working:

- boot, secondary-core parking, EL2 → EL1, PL011 console
- AArch64 exception vectors, ESR decoding, register dump on fault
- MMU with an identity map, caches on, correct memory attributes
- VideoCore mailbox; framebuffer, verified pixel-exact; GPIO
- ARM generic timer at 100Hz, IRQ delivery, cross-checked against the
  BCM system timer
- `xalloc`, the pool allocator (`malloc`/`free`), Blocks
- the scheduler: process table, context switch, blocking locks
- namespace: channels, path composition, process groups, the root
  device, `kopen`/`kread`/`kwrite`/`kbind`
- a console on `/dev/cons`
- the Dis VM: `libinterp` linked, `disinit`, and Limbo bytecode executing

Known limitation: the VM stalls after its first system call. See
"VM bring-up" below — the cause is partly identified and the
investigation is written down rather than left to be repeated.

Not done: `portclock.c`, `exportfs.c`, `devprog`/`devsrv`/`devenv`,
`os/ip` and any networking, the JIT (excluded deliberately — it needs a
bare-metal W^X allocator), and **any run on real hardware**. Everything
above is QEMU.

Regression-tested by `tests/host/baremetal_test.sh`, which builds the
port, boots it under QEMU, and asserts on the result — including pulling
the framebuffer back out via QMP and checking pixel values. That harness
runs **both** boards: see [os/virt](../virt/README.md), the QEMU `virt`
port that shares this kernel.

## Why `os/` and not `emu/<Platform>`

`emu/port` plus `emu/<Platform>` *is* the host-OS shim — the layer that
maps Inferno's needs onto POSIX (or Win32). A bare-metal port doesn't add
another platform to that layer, it replaces it. The kernel here links
against the shared, host-independent parts of the tree (`libinterp`
including the existing AArch64 JIT in `comp-arm64.c`, `libsec`, `libmath`)
but not against emu's POSIX layer.

This mirrors upstream Inferno, which kept native ports under `os/`
(`os/pc`, `os/bcm`, …) separate from `emu/`. The directory is named for
the SoC rather than the board so that a later BCM2711 (Pi 4) port sits
alongside it, and so CM3+/Zero 2 W — same silicon — can share it.

### `os/arm64`, and what is left here

Everything an AArch64 board shares now lives in `os/arm64`: the boot
stub, exception vectors, trap decoding, `spl`, the device-tree parser,
the portable probes and `kmain` itself. `os/bcm2837` keeps only what is
genuinely this SoC — the memory map, PL011 wiring, VideoCore mailbox,
GPIO, framebuffer, the system timer and the MMU map — plus `board.c`,
the five hooks `../arm64/fns.h` declares.

That split was forced by [os/virt](../virt/README.md) and is the honest
place for the line: with one board, "shared" and "BCM2837" were
indistinguishable, and `main.c` had grown to 1700 lines of mostly
board-independent bring-up checks. A sixth board hook should be read as
an argument for moving code into `os/arm64`, not for widening the
interface.

## Why the Pi 3B+

- InferNode is 64-bit only, which rules out the Pi 1 and Pi Zero
  (BCM2835, 32-bit ARMv6 — no AArch64 mode at all).
- BCM283x has the best bare-metal documentation of any 64-bit-capable Pi:
  a public peripheral datasheet and a large body of reference material.
- Wired Ethernet and a GPIO UART make first bring-up tractable. The
  Zero 2 W is USB-OTG only; the Pi 4 adds xHCI USB3, PCIe and a GENET
  MAC; the Pi 5 puts most I/O behind the RP1 southbridge, which has no
  public register-level documentation.
- `libinterp/comp-arm64.c` already targets AArch64 for the macOS and
  Linux/Jetson hosted builds, so the JIT is reused unchanged.

## Building

Everything needed is already present on a normal macOS dev box — no
`brew install` required. There is deliberately no build script or mkfile
yet: the linker path below is machine-specific, and pinning it into
committed build rules would be wrong until the toolchain choice settles.

```sh
cd os/bcm2837

LLD=~/.rustup/toolchains/stable-aarch64-apple-darwin/lib/rustlib/aarch64-apple-darwin/bin/gcc-ld/ld.lld
OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy
CC="clang --target=aarch64-elf -ffreestanding -nostdlib -mgeneral-regs-only -O2 -Wall -Wextra"

$CC -c l.S -o l.o
$CC -c uart.c -o uart.o
$CC -c main.c -o main.o
"$LLD" -T kernel.ld l.o uart.o main.o -o kernel8.elf
"$OBJCOPY" -O binary kernel8.elf kernel8.img
```

Note for zsh users: `$CC` above is written unquoted on purpose, but zsh
does **not** word-split unquoted parameter expansions the way bash does.
Run these under `sh`/`bash`, or paste the flags inline — otherwise clang
swallows the whole string into `--target=` and fails with "invalid
version in target triple".

Toolchain notes:

- **Compiler**: Apple clang, via `--target=aarch64-elf`. It emits real
  ELF AArch64 objects; no GNU cross-gcc is needed.
- **Linker**: `ld.lld`, taken from the rustup toolchain. Xcode ships no
  `ld.lld`, and Homebrew's `llvm` formula omits it, so on a typical dev
  box the rustup copy is the only ELF-capable linker available.
- **objcopy**: Homebrew `llvm`'s `llvm-objcopy`, to flatten ELF into the
  raw image the Pi boot ROM expects.

## Running under QEMU

QEMU's `raspi3b` machine model is the BCM2837, and is the primary
development target:

```sh
qemu-system-aarch64 -M raspi3b -kernel kernel8.img -display none -serial stdio
```

Expected output:

```
InferNode bare-metal (BCM2837 / Raspberry Pi 3B+)
  exception level: EL2
  mpidr_el1:       0x0000000080000000
  console:         PL011 UART0, polled
boot OK
```

### Debugging

`-s -S` starts a GDB stub on `:1234` with the CPU halted before the first
instruction — the only way to debug early boot, MMU and exception-vector
code, which runs before any console exists.

```sh
qemu-system-aarch64 -M raspi3b -kernel kernel8.img -display none -serial stdio -s -S
```

Then, since macOS ships `lldb` rather than `gdb`:

```sh
lldb kernel8.elf -o 'gdb-remote 1234' -o 'breakpoint set --name kmain' -o continue
```

This gives symbolic breakpoints and backtraces that walk from C back into
the assembly boot stub.

## QEMU vs real hardware

QEMU is the fast loop, but it is not the truth. Known divergences:

- **Entry PC.** QEMU starts the CPU at `0x0` behind a small firmware shim
  that branches to the load address; real hardware enters at the load
  address directly. Boot code must not assume its own entry PC.
- **Caches.** QEMU's TCG does not model split I/D caches. Code that omits
  instruction-cache maintenance after writing instructions
  (`DC CVAU` / `IC IVAU` / `DSB` / `ISB`) runs fine here and fails on
  silicon. This matters specifically for the Dis JIT, which writes code at
  runtime — JIT bring-up must be validated on the board, not just here.
- **Peripherals.** SD/EMMC timing, USB and the VideoCore mailbox
  framebuffer are modelled loosely or not at all.

Real-hardware bring-up needs a USB-serial cable on GPIO 14/15 (there is no
video output until the framebuffer works) and a FAT32 SD card carrying the
Broadcom firmware blobs (`bootcode.bin`, `start.elf`, `fixup.dat`) plus
`kernel8.img` and a `config.txt` setting `arm_64bit=1`.

## Prior art, and where the driver code will actually come from

An earlier version of this section said the Pi prior art was
"reference only, not a code source", on the grounds that it carried no
license marker. A line-level provenance study (INFR-404) showed that
reasoning was wrong twice over, and the correction matters because it
changes where the networking work comes from.

**The prior art is overwhelmingly Plan 9.** Diffing
`yshurik/inferno-rpi`'s `os/rpi/*` against Plan 9 4th edition
`sys/src/9/bcm/*` puts 6003 of 8056 lines at a verbatim match — 74.5%
overall, and higher on precisely the pieces worth having:

| file | match vs Plan 9 4e |
|---|---|
| `devusb.c` | 99.8% verbatim |
| `dwcotg.h` | 99.8% verbatim |
| `dma.c` | 98.2% verbatim |
| `usbdwc.c` | 96.9% |
| `emmc.c` | 96.3% |
| `etherusb.c` | 95.7% |

What is genuinely original to that port is the Inferno kernel glue —
`main.c`, `trap.c`, `mmu.c`, `dat.h`, `fns.h` — which is exactly what
`os/arm64` and `os/bcm2837` already implement for AArch64. **The one
part that would need permission is the one part we do not need.**

**So the licensing question is moot, and the source is upstream.** Nokia
transferred Plan 9 copyright to the Plan 9 Foundation in 2021, which
relicensed editions 1–4 under MIT, and this tree's `LICENSE` already
credits the Plan 9 Foundation. Driver code should be taken from Plan 9
4e or 9front and cited as such — not routed through a third-party fork.

Worth stating plainly since it came up: **no license file does not mean
public domain.** Copyright is automatic under Berne, and GitHub's terms
grant other users only the right to fork *on GitHub*, not to vendor
into an MIT release tarball.

**It was also more complete than "a bring-up checklist" implied.** That
port had a working DWC OTG host stack, USB Ethernet, EMMC and devusb —
roughly 2,400 lines of working USB and networking. It lacked WiFi, not
Ethernet.

### What this means for networking here

The 3B+'s wired NIC is a LAN7515 behind USB, so a DWC2 host stack gates
Ethernet *and* WiFi. That is no longer "write a USB stack": it is
porting ~2,400 lines of MIT, same-silicon (BCM2835 and BCM2837 share the
Synopsys DWC OTG core), same-idiom C to 64-bit — and the LP64 decision
recorded elsewhere in this tree means upstream's "ulong holds a pointer"
convention is correct by construction rather than broken.

9front moved USB to userspace (`nusb`), so its kernel has no
`etherusb.c`. For a bare-metal Inferno kernel the cleaner base is Plan 9
4e's **in-kernel** `usbdwc.c` + `devusb.c` + `etherusb.c`, then adding a
`lan78xx` entry to `etherusb.c`'s driver-family table — it already
dispatches cdc/asix/smsc through exactly that mechanism, so the 3B+ NIC
is an addition rather than a rewrite. (A userspace 9P USB service would
arguably suit InferNode's design better, but that is a design decision,
not a port, and it should be made before anything is imported.)

None of this reduces the other hard dependency: **this tree has no
TCP/IP stack at all**, so `os/ip` is required for any networking path.

## Lessons that cost time

Recorded because each one presents as something other than what it is.

**With the MMU off, all memory is Device-nGnRnE.** That forbids unaligned
access outright — and at `-O2` the compiler will merge two adjacent
32-bit stores into one 64-bit store. In the mailbox code that landed at a
4-byte-but-not-8-byte-aligned offset and took an alignment fault.
`SCTLR_EL1.A` does not help; Device-memory alignment faults ignore it.
Bringing the MMU up removes the whole class.

**Framebuffer pixel order names describe byte order, not word layout.**
Tag `0x00048006` documents `0=BGR, 1=RGB`, but order 1 puts red at the
*lowest address*, so a little-endian load reads `0xAABBGGRR` and a
literal `0xFF0000` renders blue. We use order 0.

**The GPU does not snoop the ARM's caches.** The framebuffer must not be
mapped cacheable, or the display shows stale pixels while writes sit in a
dirty cache line. It falls above `ramtop`, which is queried from the
firmware rather than hardcoded because the split is configurable in
`config.txt`.

**QEMU starts the CPU at `0x0`,** behind a firmware shim that branches to
the load address. Real hardware enters directly. Boot code must not
assume its entry PC.

## What has been imported from upstream so far

Upstream Inferno is MIT and its copyright holders — Lucent, Vita Nuova,
the Plan 9 Foundation — are already the ones named in this tree's
`LICENSE`, so the import is clean. Upstream's root `NOTICE` states it
plainly, and there are no GPL/BSD/Apache markers anywhere in `os/` or
`libkern`.

| Path | From | Notes |
|---|---|---|
| `Inferno/arm64/include/u.h` | authored, from `Inferno/arm/include/u.h` | LP64, `<stdarg.h>`, named union members |
| `Inferno/arm64/include/lib9.h` | authored, from the arm original | thin: `u.h` + `kern.h` |
| `include/kern.h` | upstream, verbatim | 601 lines, no host includes, was absent here |
| `os/port/lib.h` | upstream, verbatim | kernel libc declarations |
| `libkern/` | upstream, 58 files | see below |

**`libkern` was far smaller than expected.** 40 of its files already
exist in this tree's `lib9` and diff against upstream at 0–1 lines — the
whole `fmt`, `convM2S`/`convS2M`, `rune` and `utf` layer was already
64-bit clean, and includes only `lib9.h`/`fcall.h` rather than any host
header. So the import is really just the freestanding libc primitives a
kernel must supply itself because there is no host to borrow them from.

Not imported, deliberately:

- `vlrt-*`, `vlop-*`, `div-*` — 64-bit arithmetic emulation for 32-bit
  machines. AArch64 does this in hardware.
- every other architecture's `frexp-`, `getfcr-`, `memmove-`, `nan-`,
  `strchr-` variant.
- `charstod.c`, `pow10.c` — the only files needing hardware FP. The
  kernel is built `-mgeneral-regs-only` so no interrupt path can touch
  FP/SIMD state that is not saved. Upstream's own kernel stubs `_efgfmt`
  to `-1`, so the native kernel never formatted floating point either.
- `strdup.c`, `vsmprint.c`, `smprint.c`, `fcallfmt.c` — these need an
  allocator, which arrives with `os/port/alloc.c` in Layer 1.

Four upstream sources needed edits, all of them C-dialect rather than
64-bit: `atol.c` and `toupper.c` omitted return types (Plan 9 C allows
it, C99 does not), and `kern.h` declared `strtoll` without the `const`
its own definition uses.

## Decision: the Plan 9 C dialect is de-anonymized by hand

`os/port` and `os/ip` are written in Plan 9 C, which uses three
extensions ISO C does not have: anonymous struct members (`Lock;` inside
a struct), passing the *container* where an embedded member is expected
(`qlock(c)` for `qlock(&c->l)`), and omitting parameter names in
definitions. That is roughly 115 declaration sites and 270 call sites
across the two trees, so how it is handled is a real decision rather than
a detail.

The obvious answer — GCC's `-fplan9-extensions`, which implements exactly
this — **does not work here**, and the reason matters:

- `-fplan9-extensions` is a **GCC** flag. Neither Apple clang 17 nor
  Homebrew LLVM clang 21 recognizes it at all.
- Clang's `-fms-extensions` accepts the anonymous members and *appears*
  to accept the container-passing, but only by downgrading it to a
  `-Wincompatible-pointer-types` warning. It never performs the
  conversion. It happens to produce correct code when the anonymous
  member is at offset 0, which is why it looks like it works.
- Tested with the member at offset 16: the call wrote to **offset 0**.
  It clobbered an unrelated field and left the lock untouched, silently.

Silent memory corruption on lock acquisition is the worst possible
failure mode in a kernel, and `-fms-extensions` produces it without so
much as an error. So imported files get explicit member names
(`Lock l;`, `Ref r;`) and explicit call sites (`&c->l`, `&c->r`).

This also matches what InferNode's hosted tree already did —
`emu/port/dat.h` names these members explicitly — which keeps the two
ports diff-able. That is worth a great deal, because 34 of the `os/port`
files have a 64-bit-clean sibling in `emu/port` and are best ported by
diffing against it.

A real `aarch64-elf-gcc` would restore the option, and is worth
revisiting if one is ever installed.

## VM bring-up: the four bugs that were in the way

The Dis VM now loads `/osinit.dis` from the in-kernel root filesystem and
runs it to completion: it prints, reads a file through the namespace,
writes to `/dev/cons`, and does a thousand heap allocations through the
garbage collector. Four separate bugs stood between "first `sys->print`
reaches the console" and that, and each is worth recording because none
of them announced itself where it happened.

**1. `addclock0link` deadlocked against `tod`.** `os/port/tod.c`
initialises itself lazily: the first `ns2fastticks()` calls `todinit()`,
and `todinit()` ends by calling `addclock0link()`. So the first timer
callback registered before `tod` is up re-enters `addclock0link()` while
already holding `timers[0]`, and taslock's spin limit fires with
`ilock: no way out` — which reads as a lock bug and is an
initialisation-order bug. `clockinit()` used to run in a probe, after
`chandevinit()` had already registered a console callback. It now runs
in the boot sequence, before anything can register a timer.

**2. The pool quanta was a 32-bit number.** This was the heap
corruption. `p->quanta` is both the allocation granularity and the
smallest block the allocator can create when it splits, so it has a hard
lower bound: a free block must hold a complete `Bhdr` — including the
five `u.s` tree pointers `pooladd()` writes — plus its `Btail`. That is
32 bytes on ILP32 and 64 under LP64. Upstream's `31` let the splitter
carve out a 32-byte remainder, and `pooladd()` then wrote 24 bytes past
the end of it onto the next block's `magic` and `size`.
`emu/port/alloc.c` already carries this scar and uses `127`. It is now
`63` here, with a compile-time assertion so a future field added to
`Bhdr` breaks the build instead of memory.

**3. FP/SIMD state was not saved across context switches.** `procsave()`
was a no-op, on the reasoning that the kernel is built
`-mgeneral-regs-only`. That is true of the kernel and false of the
system: `libinterp` is deliberately built *with* FP, because Dis has a
floating point type, and `libinterp` is where a Dis process spends its
time. `d8`-`d15` are callee-saved under AAPCS64 and were preserved
neither by the interrupt path (which saves `x0`-`x30` into the `Ureg`)
nor by `setlabel`/`gotolabel` (which save `x19`-`x29`). clang allocates
those registers for ordinary values, so the damage landed on live
pointers, not on Limbo floats: a preempted process resumed, returned
through a corrupted frame, and died somewhere unrelated with `pc = sp-16`
on a stack it did not own.

**4. `getcallerpc` was one frame short.** Not a crash — worse. The
out-of-line version in `arch.S` returned `x30`, a PC *inside* the calling
function rather than that function's return address, so every allocator
and lock diagnostic in the kernel produced a confident, plausible lie.
`probecallerpc()` now checks it.

### What this cost, and the lesson

Bug 2 took by far the longest, and most of that time was not spent on
the allocator. The test harness linked both the real kernel and the
fault-injection kernel to a single `k.elf`, so the ELF left on disk
belonged to whichever built last. Every faulting address resolved
against the wrong binary and landed in a function that had nothing to do
with anything — `cmount`, `cvtup`, `eqchantdqid`. Two of those were
disassembled, found to be preceded by a `nop` rather than a `bl`, and
still not disbelieved, because a symbol name is very convincing.

Each image now gets its own ELF, and `BAREMETAL_BUILD_DIR` keeps the
build directory so a fault can be symbolised at all. **Verify the
toolchain before trusting what it tells you about the bug** — a
diagnostic nobody checks is not neutral, it actively misleads.

## There is a shell

    ; path=(/dis .)
    ; echo hello from bare metal
    hello from bare metal
    ; ls /dis
    /dis/cat.dis
    /dis/echo.dis
    /dis/lib
    /dis/ls.dis
    /dis/pwd.dis
    /dis/sh.dis
    ; pwd
    #/
    ; cat /dev/sysname
    infernode

Typed over the serial line into a kernel with no operating system
underneath it. `tests/host/baremetal_test.sh` drives that session on
every run, because nothing else in the suite can tell a deaf shell from
a clean boot.

Four things stood between "Dis runs" and that prompt, and each
announced itself only once the previous one was fixed:

1. **`#p`** -- sh's `waitfd()` opens `#p/<pid>/wait` to reap children
   and `panic()`s when it cannot, so the shell loaded, resolved every
   library, and died before its first prompt. `os/port/devprog.c` is
   imported from `emu/port/devprog.c`; see the header there for the
   three differences that mattered.
2. **`kbdq`** -- devcons declares the keyboard queue and every input
   path writes to it, but nothing ever created it. Upstream leaves that
   to a platform keyboard driver and this board has none, so reading
   `/dev/cons` reached `qread()` with a nil Queue.
3. **A receive path** -- the console had been write-only. `uartgetc()`
   plus a kproc feeding `kbdputc()`. Polled, deliberately: the transmit
   path has been polled since the first boot, and an interrupt-driven
   receive would be the first untested interrupt source in the kernel.
4. **Commands** -- the root filesystem carries echo, cat, pwd and ls
   with the libraries they load.

The root filesystem is generated by `tools/mkrootfs.py` from a manifest
in the test harness. It stands in for `os/port/mkroot`: `devroot.c`
indexes `rootdata[]` by qid and reads a directory's children as a
contiguous run, so the table index must equal the qid *and* every
directory's children must be adjacent. Breadth-first assignment
satisfies both.

### The instability: re-entrant preemption (fixed)

The port booted and ran `/osinit.dis` to completion only about half the
time, from the same image under the same QEMU. It now does so on every
boot -- 28/28 on bcm2837, 10/10 on virt.

`hzclock()` calls `sched()` directly from the clock interrupt, and
`sched()` re-enables interrupts when the process is resumed -- while
still inside the interrupt handler, several frames deep. The next tick
could therefore arrive before the first had unwound, call `hzclock`
again, and preempt again. Nothing bounded it, and every nesting kept
its `Ureg` and frames on the *same* kernel stack, so the stack only
grew.

The end of it was the process running off the bottom of its 16K kstack,
down through the heap and into `.bss`, where the frames landed on
`fmtalloc` -- libkern's format-handler table -- and the next `print()`
branched through a handler with a formatted character written into it.
Every symptom traced back to that:

| symptom | what it actually was |
|---|---|
| `pc = 0x35000b1738` | `_flagfmt` with byte 4 replaced by `'5'` |
| `pc = 0xa` | a handler slot overwritten by `'\n'` |
| boot stops mid-word and hangs | `_fmtdispatch` spinning on `p->fmt == nil` |

`up->inpreempt` now brackets one process's preemption. The flag is in
`Proc` and not `Mach` because `sched()` does not return until *that*
process is scheduled again; a Mach-wide flag would stay set while
another process ran and suppress its preemption too.

**What actually found it** was a guard word at the base of every kstack,
which caught the overflow immediately: sp at 0xdf340 against a base of
0xdf1f0, 336 bytes left of 16K. Before that, four separate theories had
been proposed and all four were wrong -- a stale `up` during
scheduling, a corrupted saved label, an `errlab` overflow, and simple
stack depth. Each was killed by an invariant that could be checked
rather than argued about, and the invariants are still in the tree
because they cost nothing and they are what made the difference:

* a kstack guard word, checked at trap entry
* an sp-range check at trap entry -- every stack is below the image or
  at/above `end`, so `[_start, end)` is impossible
* `sched()` must be running on `up`'s stack
* `up->sched.pc` in the text and `up->sched.sp` inside `up->kstack`
  before `gotolabel()`
* `errlabcheck()` -- `waserror()` had **no** bound on `up->nerrlab`, so
  at `NERR` it would write a whole `Label` past the end of `errlab` and
  `nexterror()` would `gotolabel()` through it. `error()` checked the
  wrong bound (`> NERR`, not `>=`) and only there. It has never fired,
  but the hazard was real.

Raising `KSTACK` from 16K to 64K did **not** help -- 5 of 8 boots still
overflowed -- and that is what proved it recursion rather than depth.
`KSTACK` is back at upstream's 16K.

### Smaller things still open

`sprint()` in `devcons.c` assumes every caller's buffer is `PRINTSIZE`,
and `os/port/dev.c:105` hands it a `smalloc(4+strlen(spec)+1)`. It fits
today and will not survive the first caller that formats something
longer.

## Next

Done: exception vectors, EL2→EL1, MMU, timer and IRQ, the `os/port`
import and 64-bit port, the Dis VM, and an interactive shell. What
follows is ordered by dependency, with the reasoning kept where a later
reader needs it.

**1. The JIT (`libinterp/comp-arm64.c`).**
Dis is interpreted today: `xec`'s inner loop costs two indirect calls
per bytecode instruction. Measured against the same code generator in
the hosted emulator, compiled Dis runs an **80M-iteration arithmetic
loop in 0.10s against the interpreter's 1.10s — about 10×**. On a
1.4GHz in-order Cortex-A53, which cannot hide those indirect calls the
way an out-of-order core does, the gap should be wider still.

It is close: the file compiles against these headers with exactly one
blocker, `<sys/mman.h>`. Its only host dependencies are `mmap(PROT_EXEC)`
at three sites and an instruction-cache flush, and both already have
bare-metal equivalents — this kernel maps all RAM without PXN/UXN, so
plain `malloc()` returns executable memory, and `cacheiflush()` in
`os/arm64/arch.S` is CTR_EL0-driven.

**Acceptance is working, stress-tested AND benchmarked** — not merely
"it links". Two reasons it is worth doing before the driver work: the
performance is wanted, and a JIT exercises the port in ways the
interpreter never does. It writes instructions into memory and jumps to
them, so it leans on the MMU attributes, on cache maintenance, and on
the FP/SIMD context switch. Bugs found there are bugs in the port.

**A trap specific to this one:** QEMU's TCG does not model split I/D
caches, so a JIT that omits its icache maintenance works perfectly in
emulation and crashes on real silicon. JIT-generated code must be
validated **on the board**, not only under QEMU.

**2. Hardware bring-up.** Needs a 3.3V USB-serial adapter on GPIO
14/15 and a FAT32 card with the Broadcom blobs plus `config.txt`
carrying `arm_64bit=1`, `enable_uart=1`, and — critically —
`dtoverlay=disable-bt`, because on a Pi 3 the PL011 is wired to
Bluetooth by default and the console comes out of the mini-UART instead.

**3. USB, and a design decision first.** The 3B+'s LAN7515 sits behind
USB, so a DWC2 host stack gates wired Ethernet *and* WiFi. Decide
in-kernel (Plan 9 4e `usbdwc.c` + `devusb.c` + `etherusb.c`) versus a
userspace 9P USB service **before importing anything** — the latter
suits this system's design better but is a design project, not a port.
Import order once decided: `usbdwc.c` + `devusb.c`, then `etherusb.c`
plus a `lan78xx` entry in its driver-family table.

**4. `os/ip`.** No TCP/IP stack exists in this tree at all, so it is a
hard dependency under every networking path. Write the route-table test
*before* touching `iproute.c`: it is the one file with a silent
wrong-answer failure mode, and `tcp.c`'s sequence comparisons survive
LP64 by accident through `(int)` truncation — which is worse than
breaking, because it passes a smoke test and stalls under real traffic.

**5. FT5406 touch**, via mailbox tag `0x0004000F` — the firmware polls
the controller into a buffer, so no I2C driver is needed. Note QEMU
declares that tag but never handles it, so this is hardware-only.

**6. WiFi** (CYW43455 over SDIO), which needs everything above plus an
SDIO/EMMC driver and a firmware blob upload.

Smaller, and worth doing whenever they block something: `devtab` holds
only root, cons and prog, so there are no pipelines (`#|`), no `/env`
(`#e`) and no `/fd` (`#d`). `sprint()` in `devcons.c` still assumes
every caller's buffer is `PRINTSIZE` while `os/port/dev.c:105` hands it
a `smalloc(4+strlen(spec)+1)` — it fits today and will not survive the
first longer format.
