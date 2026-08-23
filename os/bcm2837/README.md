# Bare-metal BCM2837 (Raspberry Pi 3B+) port

Tracked as **INFR-404**. This is InferNode running *native* — as the
firmware on the board, with no host OS underneath — rather than *hosted*,
which is what everything under `emu/` does.

Status: **early bring-up.** Working so far:

- boots, parks the three secondary cores, clears `.bss`
- drops EL2 → EL1 (the firmware enters at EL2)
- PL011 console
- AArch64 exception vectors, ESR decoding, register dump on fault
- MMU with an identity map, caches on, correct memory attributes
- VideoCore mailbox (property channel)
- framebuffer, verified pixel-exact
- GPIO

Not yet: timer, interrupt controller, scheduler, and the Dis VM itself.

Regression-tested by `tests/host/baremetal_pi_test.sh`, which builds the
port, boots it under QEMU, and asserts on the result — including pulling
the framebuffer back out via QMP and checking pixel values.

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
