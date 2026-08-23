# Bare-metal BCM2837 (Raspberry Pi 3B+) port

Tracked as **INFR-404**. This is InferNode running *native* — as the
firmware on the board, with no host OS underneath — rather than *hosted*,
which is what everything under `emu/` does.

Status: **early bring-up.** The kernel boots, parks the secondary cores,
clears `.bss`, and talks to the PL011 console. Nothing else yet: no
exception vectors, no MMU, no timer, no Dis VM.

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

## Next

1. Exception vectors and a fault handler, so crashes report instead of
   silently hanging.
2. Drop from EL2 to EL1 (the firmware enters at EL2 — see the boot output
   above).
3. MMU and page tables; get the caches on.
4. Timer and interrupt controller, then a scheduler.
5. Scope which parts of `emu/port` are genuinely portable versus
   POSIX-bound — this determines how much of the existing tree the native
   kernel can reuse, and is the main open design question.
6. Bring up the Dis VM and `comp-arm64.c` on the board.
