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

Regression-tested by `tests/host/baremetal_pi_test.sh` (44 checks), which
builds the port, boots it under QEMU, and asserts on the result —
including pulling the framebuffer back out via QMP and checking pixel
values.

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

## Prior art

LynxLine Labs' "Porting Inferno OS to Raspberry Pi"
([yshurik/inferno-rpi](https://github.com/yshurik/inferno-rpi), with a
fork at [tmendoza/inferno-rpi](https://github.com/tmendoza/inferno-rpi))
reached a working native Inferno on the Pi around 2015–16, crediting
Charles Forsyth and Richard Miller.

It is **reference only, not a code source.** It targets the BCM2835 in
32-bit ARMv6 — a different instruction set and a different MMU and
exception model from this AArch64 target — and carries no license marker,
whereas InferNode is MIT. It is useful as a bring-up checklist (boot →
MMU → UART → mailbox → SD → framebuffer → USB-net); the code here is
written from the Broadcom peripheral documentation and the ARM
architecture reference manual.

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

### Still open

`/dev/sysname` reads back empty, and the kernel's `print` does not
implement `%q` — it emits the verb literally. Neither is load-bearing
yet; both are visible in the `osinit` output.

## Next

1. Timer and interrupt controller, then a scheduler.
2. Import upstream Inferno's `os/port` (native kernel core) and `os/ip`
   (TCP/IP stack) and port them to 64-bit. Upstream is MIT and its
   copyright holders are already credited in this tree's `LICENSE`, so
   the import is clean — but **no upstream `os/` port has ever been
   64-bit**; every one of them (`os/pc`, `os/sa1110`, `os/pxa`,
   `os/omap`) is 32-bit. That port is this project's main contribution.
   It also matters because InferNode today has *no* TCP/IP stack at all:
   `emu/port/ipif-posix.c` delegates to host sockets, which a bare-metal
   kernel cannot do.
3. Bring up the Dis VM and `comp-arm64.c` on the board.
4. FT5406 touch, via mailbox tag `0x0004000F` — the firmware polls the
   controller into a buffer, so no I2C driver is needed.
5. Networking. Wired Ethernet first: the 3B+'s LAN7515 sits behind USB,
   so a DWC2 host controller stack is the gating item. WiFi (CYW43455
   over SDIO) comes after, and shares the `os/ip` work.
