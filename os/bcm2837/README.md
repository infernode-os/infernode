# Bare-metal BCM2837 (Raspberry Pi 3B+) port

Tracked as **INFR-404**. This is InferNode running *native* — as the
firmware on the board, with no host OS underneath — rather than *hosted*,
which is what everything under `emu/` does.

Status, 2026-09-05: **it is a machine.** A Pi 3B+ boots this kernel from
its SD card to a Tk login screen on HDMI, with a USB keyboard and
mouse, wired Ethernet configured by DHCP, a writable `/usr` on the
card, secstore-backed keys, and the Lucifer desktop — and a shell on
the serial console the whole time. All four cores schedule. The Dis JIT
runs on the A53 at 27× the interpreter with bit-identical results.
Everything below has been exercised on the board, not only in QEMU,
except where a section says otherwise.

Working, in the kernel (`os/arm64/notyet.c` holds the device table):

- boot, EL2 → EL1, MMU with caches on, all four cores up, exception
  vectors with a register dump on fault, the ARM generic timer, device
  interrupts through the VideoCore controller
- `xalloc`, the pool allocator, Blocks; the scheduler with per-process
  preemption guards; the namespace, channels, mounts (`#M`), process
  groups, `#p`, `#|`, `#e`, `#s`
- the Dis VM and the **JIT**; a sign-extension fix that makes a Limbo
  `int` 32 bits on a 64-bit word (both JITs and the interpreter)
- **`os/ip`** (`#I`): the full stack, ARP, ICMP, TCP, UDP, routing
- **USB**: `#u`, the DWC OTG host stack with split transactions,
  single-shot bulk transfers, hot-plug and unplug
- **`#l`**: the Ethernet data path in the kernel (~2.6 MB/s in, ~4 MB/s
  out), bound to endpoints a Limbo driver has set up
- the SD card as a file (`#S`), the running kernel image as a file
  (`#B/bootimage`), microsecond timing (`#b`), GPIO pins as files
  (`#G`), the framebuffer console (`fbcons`), the draw device (`#i`),
  the pointer (`#m`), the keyboard on `/dev/keyboard`, SSL (`#D`), a
  hardware-fed entropy pool, a tick-driven sampling profiler
- **tryboot**: A/B kernels through the firmware's one-shot flag — a
  candidate is installed under its own name, booted once under a boot
  watchdog, and promoted from its own shell (see "Working on the board
  without moving the card"; the firmware handshake itself is still to
  be proved on the board)

Working, in Limbo on top (`os/init/`, plus the card): `osinit` — the USB
bus walk, the hub watcher, the SD mount, the rootpath policy, `/usr`;
`etherusb` (RNDIS for QEMU, LAN78xx with PHY autonegotiation for the
board, DHCP, and the `#l` handoff); `kbdusb`, `mouseusb`; `dossrv` on
FAT32 with the fixes the card demanded; `auth/secstored`; `wm/logon` as
a Tk form; `luciuisrv` and `lucifer`.

Not done, in one line each; the detail and the order are in "Next" at
the end of this file:

- every process is still the host owner. The desktop's namespace no
  longer holds the raw card, the pins or `/dev/sysctl`, but a non-eve
  user for the desktop and agents is not done
- the tryboot firmware handshake and the watchdog countdown are proved
  against QEMU's model only, which has neither; the board has not yet
  run them
- the harness types the boot script's namespace lines into a shell
  and tests dossrv on the host, but does not boot a populated card
  through rootpath, logon and secstore under QEMU, and no CI job runs
  the bare-metal harness at all
- the fixes of 2026-09-05 (below) have run under QEMU only; none has
  been on the board
- WiFi, touch, USB storage, audio; the Pi 4

Regression-tested by `tests/host/baremetal_test.sh`, which builds the
port, boots it under QEMU's `raspi3b`, and asserts on the result —
pulling the framebuffer back through QMP, hot-plugging USB devices,
round-tripping TCP through the emulated network, and comparing the
served kernel image with the file it booted. 194 checks. A second
QEMU machine (`virt`) once shared this kernel and forced the
`os/arm64` split; it is not in the tree today.

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

That split was forced by a second QEMU machine (`virt`) that shared the
kernel for a while, and it is the honest place for the line: with one
board, "shared" and "BCM2837" were indistinguishable, and `main.c` had
grown to 1700 lines of mostly board-independent bring-up checks. The
`virt` port is not in the tree today; the line it drew held. Since then
`os/bcm2837` has also grown the drivers that are this SoC's — `usbdwc`,
`emmc`/`devsd`, `devgpio`, `fbcons`/`screen`, `random`, `serialboot` —
which is the right side of the line for them. A further board hook
should be read as an argument for moving code into `os/arm64`, not for
widening the interface.

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

The kernel is built by `tests/host/baremetal_test.sh`, and that is the
only supported way to build it.

That is deliberate rather than lazy. The build has to compile `os/port`,
`os/ip`, `libinterp`, this board's drivers and a root filesystem, link
them against a machine-specific `ld.lld`, generate `runt.h` and
`sysmod.h` with the Limbo compiler, and compile the Limbo that goes into
the image -- and the harness already does all of it, in the right
order, with the two warnings that catch Plan 9 dialect errors escalated
to errors. A second copy of that in a script would drift from the one
that is actually exercised.

    BAREMETAL_BUILD_DIR=/tmp/bm ./tests/host/baremetal_test.sh

leaves the artefacts in `/tmp/bm`:

    bcm2837-kernel.img     the image -- rename to kernel8.img for a Pi
    bcm2837-kernel.elf     the same thing unflattened, for addr2line
    bcm2837-nojit.img      the same kernel with -DCFLAG=0, for the
                           JIT comparison
    cc.log                 every compiler and linker diagnostic

Building through the test harness also means the image is never written
unless it passed, which matters more when the target is a board than
when it is QEMU: `build_kernel()` deletes the output before it starts,
so a compile error cannot leave the previous kernel sitting there
looking current. That has caught three separate rounds of confident
wrong measurements on this branch.

Toolchain, all present on a normal macOS dev box with no `brew install`:

- **Compiler**: Apple clang via `--target=aarch64-elf`. It emits real
  ELF AArch64 objects; no GNU cross-gcc is needed.
- **Linker**: `ld.lld`. Xcode ships none and Homebrew's `llvm` formula
  omits it, so the rustup toolchain's copy is usually the only
  ELF-capable linker on the machine. The harness finds it.
- **objcopy**: Homebrew `llvm`'s `llvm-objcopy`, to flatten the ELF
  into the raw image the Pi boot ROM expects.

If any of those is missing the harness SKIPS rather than fails, so a
clean run with no output about the kernel means the toolchain was not
found, not that everything passed.

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
- **The watchdog.** QEMU's `hw/misc/bcm2835_powermgt.c` stores
  `PM_WDOG` and never counts it down; a write to `PM_RSTC` with the
  full-reset `WRCFG` resets the machine *immediately*, whatever the
  count. So under QEMU, arming the boot watchdog is the reset — which
  is how the harness proves the arming write reaches the block with
  the right password and bits, and why the countdown, the reload from
  the clock tick and the disarm can only be watched on the board. The
  property mailbox likewise acknowledges every tag, known or not, so
  the firmware's answer to `SET_REBOOT_FLAGS` means nothing here.
  `PM_RSTS` reads its reset value `0x1000` after every QEMU reset; on
  the board it carries the reset cause.

Real-hardware bring-up needs a USB-serial cable on GPIO 14/15 (the
console is mirrored to the display once `fbcons` is up, but that is
some way into boot) and a FAT32 SD card carrying the
Broadcom firmware blobs (`bootcode.bin`, `start.elf`, `fixup.dat`) plus
the kernel and the `config.txt` under "Working on the board without
moving the card" below — the one recipe in this file.

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
is an addition rather than a rewrite. **That last step is no longer the
plan** — see "Decision: device protocols live outside the kernel,
mechanism inside" below. `usbdwc.c` and `devusb.c` were imported;
`etherusb.c` will not be, because it is an in-kernel `Ether` driver and
that layer is now a program.

None of this reduced the other hard dependency at the time: the tree
had no TCP/IP stack at all. `os/ip` has since been imported, ported to
LP64 and is in the build (`#I`); see "The Ethernet data path is in the
kernel" for how it attaches.

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

**A local set after `waserror()` and read in its handler must be
`volatile`.** `setlabel`/`gotolabel` are setjmp/longjmp, and C leaves a
non-volatile local modified between the two indeterminate; clang `-O2`
takes the offer and folds the value the local had at `setlabel` into the
handler. `devwalk` and `mntwalk` set `alloc = 1` after `waserror()` and
closed the cloned Chan `if(alloc)` -- compiled, the handler was `bl free;
b epilogue`, no `cclose`. `namec` initialised its `Elemlist` to nil
before `waserror()` and freed it in the handler: three `free(nil)`.
Four blocks per failed name lookup, and the idle desktop fails three
lookups a second (`lucictx` polls `/tmp/veltro/.ns/manifest` and
`/tool/{paths,tools}`, none of which exist on the board), so the main
pool grew ~1 MB every ten minutes while the login screen, which probes
nothing, stayed flat. `qbwrite` and `etherbind` had the same shape with
worse consequences: an unconditional `freeb` of a Block already on the
queue if the writer was interrupted, and a failed bind that left every
conversation it had opened open, so the retry failed too. Note what does
NOT fix it: `returns_twice` on `setlabel` (it stops register caching
across the call, a different hazard; the fold is on the value and the
output is byte-identical with or without the attribute). Only `volatile`
-- or the `volatile struct { ... }` idiom `kmount` already uses -- makes
the handler read memory. The hosted emu had the walkers right since the
2007 upstream drop and `namec` wrong, and its soaks were flat only
because nothing in them ever missed. Check the compiler's output, not the
source: `clang -S` with the harness flags and read the block after `bl
setlabel; cbz w0`. That compiler-output check is the only verification
the bare-metal walkers have: `tests/host/baremetal_test.sh` does not yet
count pool blocks across failing lookups on the kernel, and that runtime
check is an open gap. `tests/host/walk_leak_test.sh` counts live
main-pool blocks across 1000 failing lookups in the hosted emu, which
shares `namec` with the kernel but not its `devwalk`/`mntwalk` objects.

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

## Decision: device protocols live outside the kernel, mechanism inside

Recorded because the section above deferred it: *"A userspace 9P USB
service would arguably suit InferNode's design better, but that is a
design decision, not a port, and it should be made before anything is
imported."* It is now made.

**The rule.** The kernel provides access to the *bus* — registers, DMA,
interrupts, and raw endpoints. A driver that speaks one device's
*protocol* on top of that lives outside the kernel, as a program.
Concretely: `usbdwc.c` and `devusb.c` (`#u`) are in; the CDC and
LAN78xx Ethernet drivers are not, and neither will USB storage, HID or
audio be.

### The argument that does not work

The obvious case for userspace is fault isolation: a bug in a driver
should not be able to panic the machine or corrupt unrelated memory.
That argument is true, and it is not the reason, because it proves far
too much.

Look at what this kernel already loads:

    &rootdevtab   '/'   the namespace
    &consdevtab   'c'   /dev/cons
    &progdevtab   'p'   #p, processes
    &pipedevtab   '|'   #|, pipes
    &usbdevtab    'u'   #u, raw USB endpoints
    &ipdevtab     'I'   #I, the entire IP stack

`#I` is seventeen files including a full TCP implementation, parsing
hostile input straight off the wire. If "a bug here shouldn't take the
machine down" were the operative principle, `os/ip` would be the *first*
thing evicted and a USB Ethernet driver would be somewhere near the
last. Nobody is proposing to evict it. So fault isolation cannot be what
is actually being applied, and a decision justified by it would be a
decision we do not in fact believe.

Inferno is not a microkernel and this port is not going to make it one.
Saying so plainly is worth more than a rationale that sounds principled
and is not.

### The line that does hold

Two kinds of thing belong in the kernel:

- **Resources that must be shared and arbitrated across every user.**
  The namespace, the process table, pipes, the IP stack. Everything
  multiplexes through these; putting one outside means every user pays
  an extra hop to reach it, and the kernel's own `kdial` would come to
  depend on a process it is supposed to be able to start.
- **Register, DMA and interrupt access**, where there is no lower-level
  mechanism to build on. `usbdwc.c` owns the DWC OTG core's registers
  and its interrupt; nothing underneath it could.

Everything else — one device's protocol, expressed on top of a mechanism
the kernel already exposes — goes outside. `#u` exists *precisely* to
make that possible: it is raw endpoint access, deliberately published as
files so that class drivers need not be kernel code. A CDC or LAN78xx
driver is exactly that shape.

This is "mechanism, not policy" (docs/DESIGN-PRINCIPLES.md) applied to
drivers, and it is a line that can be drawn the same way twice.

### What it commits us to

If the ether driver is a program, so are the rest of the USB class
drivers: storage, HID, audio. They are all the same shape — protocol on
top of `#u`, used by one device — and splitting them by convenience
would leave us with no rule at all. A future in-kernel USB class driver
needs to argue against this section, not around it.

### What it does not commit us to

Not `#I`, not the scheduler, not `usbdwc`. Those are the first category,
and nothing here is an argument for moving them. In particular this is
not a staged plan to arrive at a microkernel by increments.

### Why `usbdwc.c` is twice the length of 9front's, and what not to delete

Counting lines invites the wrong surgery. `usbdwc.c` is 2179 lines against
9front's 1080 for the same controller; of ours, 907 are comment and 1167
are code, and 9front's file is nearly all code. The controller-driver
*code* is about 1.1x the reference. The rest is the explanation, written
next to the thing it explains, of what this driver does that a minimal
one does not. `chanio()` looks like the culprit at 504 lines; it is 206
lines of code and 288 of comment. The diagnostics -- the channel log,
`dump`, `setdebug` -- are 66 lines and four call sites, compiled always
and switched at run time, and they are what the next controller's
bring-up will want; do not put them behind an `#ifdef`, which is how
debugging code decays.

The code that is here and not in the reference, each item a debugging
session on hardware, each with its reasoning in a comment at the point
of use in `chanio()`:

- **PING** for high-speed bulk OUT once the device has said it is not
  ready, instead of resending the data until it is.
- **A NAK wake that leaves the channel live** and picks up what
  completed while it was parked, rather than tearing down and
  re-enabling every time.
- **A bounded wait on channel enable**: a channel that never ran was
  indistinguishable from one that hung.
- **The DMA pointer tripwire**: the address the channel finished with
  must lie inside the buffer it was given, with sixteen bytes of slack
  for the AHB burst real silicon does and QEMU does not. The slack looks
  like a typo. It is not.
- **Persistent per-endpoint bounce buffers**: a NAK-halted IN transfer
  completes late and DMAs into whatever now owns the freed memory. This
  was the one-in-six boot heap corruption.
- **Split transactions** for low-speed devices behind the hub, driven as
  two halves with the hub's acceptance checked between them.

If a tidy-up wants to make this file shorter, the comments can be
condensed once the lessons are elsewhere; the code above cannot go
without bringing back the bug it fixed. The portability boundary is
`#u`, not this file: a Pi 4 or 5 needs an XHCI driver in any design, XHCI
is an open specification rather than licensed IP so that driver should
be smaller and reusable across vendors, and every Limbo class driver
above `#u` rides free either way.

### How it attaches, concretely

The important discovery is that **`os/ip` attaches to a name, not to a
struct.** `os/ip/ip.h` declares

    extern Chan* chandial(char*, char*, char*, Chan**);

and `ethermedium`'s bind goes through it. The medium dials an ether
device by *name* and cannot tell whether what answers is a C driver
compiled into the kernel or a 9P server mounted into the kernel's
namespace. That is what makes this decision cheap rather than a rewrite:
only the USB protocol moves out. ARP, Ethernet framing and demultiplexing
by ether type stay in `os/ip`, where `arp.c` already implements them.

The namespace, then:

    #u/usb/ep3.1/data      bulk in    -+
    #u/usb/ep3.2/data      bulk out   -+--> etherusb (Dis)
                                                |  serves 9P
                                          /net/ether0/
                                              addr        the MAC
                                              clone       open for a connection
                                              N/ctl       "connect 0x800"
                                              N/data      frames of that type
                                                |  chandial("/net/ether0!0x800")
                                          ethermedium.c
                                                |
                                             os/ip

`ethermedium` opens three connections — `0x800` (IPv4), `0x806` (ARP),
`0x86DD` (IPv6) — so the server's only real obligation beyond shuttling
bytes is to demultiplex inbound frames by ether type onto the right
connection. That is the interface `devether` provides in Plan 9, so the
shape is not invented here.

**`pktmedium` is not the attach point,** though it is the medium already
in this tree and was the obvious first guess. Its `pktin` calls
`ipiput4` directly: it hands over IP datagrams, does no Ethernet framing
and no ARP. Binding there would mean reimplementing ARP in Limbo
alongside the copy in `arp.c` — more code, in a second language, for a
problem already solved.

### The cost, stated rather than predicted

With `#I` inside the kernel and the driver outside, every packet crosses
the boundary: two copies and two trips through the Dis VM in each
direction. A microkernel would not pay this, and Inferno's not being one
is exactly where the cost shows up. The Pi 3B+'s NIC is behind USB 2.0
and realistically tops out around 200-300 Mbit, so the extra copies may
well not be the limit — but that is a guess, and guesses about
performance are how this sort of decision goes wrong.

So it gets measured once there is something to measure, on hardware, and
the number goes in this file. If it turns out to matter, moving a
*working* driver into the kernel is a much smaller job than debugging an
in-kernel one from scratch — which is the other half of why this
ordering was chosen.

### What changes about the import plan

- **Not imported:** `etherusb.c`. It is an in-kernel `Ether` driver and
  this decision says that layer is not kernel code.
- **Imported:** `ethermedium.c`, linked from `os/arm64/main.c` beside
  `loopbackmediumlink()`. It needed one supporting function,
  `commonfdtochan()`, which upstream keeps in `os/ip/plan9.c` alongside
  `commonuser` and `commonerror` — both of which were already in
  `os/arm64/notyet.c`, so it joined them there. **`chandial.c` is not
  needed**: `ip.h` declares it, but `ethermedium` reaches its device
  with `kdial()` and `kopen()`, which this tree already has.
- **Already imported and unaffected:** `usbdwc.c`, `devusb.c`.
- **Written:** `os/init/etherusb.b`, speaking RNDIS (QEMU's `usb-net`)
  and LAN78xx (the board), with DHCP.

### Where the line was redrawn, and why it still holds

The data path did not stay in Limbo. Once the whole system worked, the
per-frame cost of crossing the interpreter and a 9P transaction was
measured and was the ceiling (see "Network throughput" and "The
Ethernet data path is in the kernel"), so `os/port/devether.c` (`#l`)
now shuttles frames between USB endpoints and `os/ip` as kernel
processes. What stays outside is everything that is one device's
*protocol*: enumeration, RNDIS negotiation, the LAN78xx register and
PHY bring-up. `etherusb.b` does that and then hands the two open
endpoints to `#l` with one ctl write.

That is the rule above applied, not abandoned: moving bytes between a
bus endpoint and the IP stack is mechanism, shared by every user of the
network; knowing what a LAN7800's registers mean is policy, and it is
still a program. The USB keyboard and mouse drivers are still programs
too. A storage or audio class driver should expect the same shape —
setup in Limbo, and a kernel data path only when a measurement says
so.

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

### Networking works, intermittently (RESOLVED)

*Resolved after this was written: the consumed 64 bytes were a NAK wake
that re-baselined the DMA pointer and abandoned a live channel
(c911449), on top of a late IN completing into freed memory (d7a7e20,
the persistent bounce buffers). The harness has been clean since. The
account is kept because the wrong hypothesis it records is the one the
next person will reach for.*

The whole path works. os/ip resolves an address by ARP, sends an ICMP
echo through an interface bound to a driver that is not in the kernel,
and reads the reply back:

    etherusb: 10.0.2.15/24 configured on ipifc 1
    etherusb: default route via 10.0.2.2
    etherusb: ICMP echo reply from 10.0.2.2 (46 bytes, type 0)

It does so on roughly three runs in five. What remains is a race, in a
working system.

**The symptom, precisely.** A failing run shows the receive process
reading exactly 44 bytes, twice, and never producing a frame:

    RX read 44 (acc 44)
    RX read 44 (acc 44)

44 is the length of an RNDIS header alone. The real message is 108
bytes -- 44 of header and 64 of frame -- delivered as a 64-byte packet
followed by a 44-byte one. So in a failing run the first 64 bytes have
already been consumed and discarded somewhere, and what arrives is the
tail of a message whose head no longer exists. The driver cannot
resynchronise from that, because an RNDIS stream has no framing other
than the lengths in the headers.

**A hypothesis that was tried and is WRONG.** The obvious explanation
is that `chanio` measures how much arrived by watching hcdma advance,
and that this controller does not always write the DMA pointer back --
so a packet that genuinely landed is counted as nothing and dropped.
Taking the length from hctsiz's Xfersize instead, which counts down as
data arrives, made it strictly worse: six runs out of six failed
rather than two out of five. Reverted. Whatever consumes those 64
bytes, it is not that.

Worth stating because it is easy to reach for twice.

**What is NOT in doubt**, having each been verified independently:
the controller, the hub, RNDIS init and the packet filter, both bulk
directions, the file interface, the demultiplex by ether type, and
os/ip's send and receive paths. Three separate bugs were found and
fixed getting here -- a shadowed `mac` that put 00:00:00:00:00:00 on
every frame, a zero-length-packet spin that starved the machine, and a
parked zero-count read that truncated the first frame to arrive.

**On how much this is worth.** RNDIS is what QEMU's usb-net speaks and
the Pi 3B+'s LAN7515 does not, so this particular race is emulator
work that will not carry over to the board. It is worth enough effort
to keep the emulated path usable as a test rig, and not worth more
than that; the LAN78xx family is the one that matters on hardware.

### What changes on real hardware, and what to suspect first

Reviewed before the board arrived, because the answer was not what the
commit messages implied.

**The split-transaction path is NOT the one the board will use.** Five
USB changes on this branch are gated on splits not being in use, and
that was described as leaving hardware behaviour alone. It does not.
The 3B+'s LAN7515 is a HIGH-SPEED hub and the Ethernet function behind
it is high speed too, so `ep->dev->speed` is Highspeed, `chansetup`
falls through to `hcsplt = 0`, and every one of those gates takes the
same branch on the board that it takes under QEMU. Splits will only be
exercised by full- or low-speed devices plugged into the Pi's own
ports.

That is reassuring in one way -- the paths that were debugged here are
the paths that will run, rather than emulator-only detours -- and it
means two of them are genuine behaviour changes against upstream on
real silicon:

- `ctltrans` uses `multitrans` for the data stage of a control IN
  where upstream would program one transfer. Packet at a time. It is
  upstream's own root-port path, so it is proven, just slower.
- `eptrans` uses `multitrans` for bulk OUT likewise. At high speed
  maxpkt is 512, so a 1514-byte frame becomes three channel
  operations instead of one.

**So if networking on the board works but is slow, look there first.**
Neither change is needed on hardware if the controller completes a
multi-packet transfer programmed in one go, which the real one is
documented to do and QEMU's model does not. The other three -- the
zero-length completion test, waking bulk IN on Nak as well as Chhltd,
and the separate read and write locks in Epio -- are supersets of
upstream's behaviour or outright fixes, and should be left alone.

**The JIT's cache maintenance was reviewed and looks correct.**
`cacheiflush` does the architecturally required sequence: `dc cvau`
over the range using CTR_EL0.DminLine, `dsb ish`, `ic ivau` using
IminLine, `dsb ish`, `isb`. It takes a `ulong` length, so unlike
`cachedwbse` -- which had exactly this bug -- the prototype makes the
64-bit `add` safe, and every caller passes a `ulong` that cannot be
negative. Static review is as far as this can be taken: TCG does not
model split I/D caches, so the only real test is the board.

### First hardware bring-up: what emulation could not have told us

The port ran on a real Pi 3B+ for the first time and everything above
the drivers worked on the first attempt: boot, EL2->EL1, MMU, both
timers cross-checked, interrupts, the Dis VM, the JIT, the IP stack,
ICMP and TCP over loopback, and a shell prompt. `midr_el1` reads
0x410fd034 (Cortex-A53 r0p4), board rev a020d3, 948MB. The generic
timer is 19.2MHz here against 62.5MHz under QEMU and the two clocks
still agree, so no frequency had been baked in anywhere.

What follows is the part worth keeping: every bug found on the board
was invisible in emulation, and three of them were mine in ways QEMU
could not have exposed.

**A bus address is not a physical address.** `chanio` programmed
`hc->hcdma = PADDR(a)`. The DWC OTG core is a bus master on the
VideoCore side and sees memory through ITS addresses -- the same
reason `mailbox.c` uses `BUSADDR`, a macro that had been sitting in
io.h with exactly one caller. QEMU does not model the alias, so PADDR
is correct there and only there. **Any DMA on this SoC needs BUSADDR;
if a new driver's transfers silently never happen, look here first.**

**An unbounded wait is a machine-killer, not a driver bug.**
`chanwait()` slept indefinitely for a transfer to complete. Under
emulation transfers always completed, so it never mattered. On the
board it took the whole machine down -- no console output, no response
to input -- which meant there was no shell left to ask what had gone
wrong and no way to reboot but the power switch. Bounding it turned a
dead board into a printed fault, and that printed fault is what found
the bus-address bug one iteration later. **Bound every wait on a
device that can fail to answer.**

**A self-test can be a false alarm with a confident name.** A
start-of-frame probe unmasked SOF and waited 50ms from inside the USB
`init()` -- which runs before the root port has been reset or enabled,
and an unenabled port carries no frames. It reported "controller
interrupt NEVER ARRIVES" on every real boot for a controller behaving
perfectly correctly, and sent me chasing an inherited-FIQ theory that
a register dump then refuted. It has been deleted. **A test that can
report failure for a legitimate condition is worse than no test**, and
this one cost two iterations and a wrong hypothesis committed to the
history.

**Console input had never been exercised.** Output worked from the
first boot, which proves the line, the adapter and the baud in one
direction only. Nothing had ever typed at the board. Under
investigation.

### Working on the board without moving the card

Two ways in, and the card never needs to come out for either.

**Over the wire.** `serialboot` pulls a kernel over the UART: build,
send (about a minute for 618KB at 115200), watch. It lives on the card
as `serialboot.img` for a card with no kernel yet, and every installed
kernel carries the same loader and offers it in a window at the start
of each boot (`recover.c`), so a kernel that boots far enough to print
can always be replaced by one fed from the host. `reboot` on
`/dev/sysctl` resets through the watchdog, since this SoC has no reset
line, so once the console accepts input the loop needs nobody at the
power switch.

**From the card, as A/B.** The kernel `config.txt` names is the
known-good one and nothing overwrites it in place. A new kernel is
installed under a *candidate* name, booted exactly once under a boot
watchdog, and promoted from its own shell:

    cp /dev/bootimage /n/dos/tryboot.img       # the running kernel, or one serialboot fed in
    echo tryboot > /dev/sysctl                 # reset; the next boot is the candidate

The candidate comes up saying so — `boot: command line: tryboot`,
`wdog: armed, 90 s boot budget`, and from osinit `CANDIDATE kernel`
with the two commands below — and releases the watchdog when the shell
is loaded (`wdog: released after N ms`). Then:

    mv /n/dos/tryboot.img /n/dos/infernode8.img   # keep it
    echo reboot > /dev/sysctl                     # or reject it: boots infernode8.img

A candidate that panics resets through `exit()`; one that *hangs* is
reset by the watchdog at the 90-second budget, or within 15 seconds if
it hung with interrupts off. Either way the firmware's tryboot flag was
spent on the way in, and the reset boots `infernode8.img`. The budget
and the reasons for arming only candidate boots are in the comment
above `boardbootwatchdog()` in `board.c`; the words the kernel reads
from the command line are `tryboot` (candidate: arm and announce),
`bootwatchdog` (arm any boot; a hang then loops, which is what an
unattended board wants), `nowatchdog` (never arm — for a kernel being
stepped under a debugger) and `wdogtest` (arm, and ignore the release,
so the reset at the budget can be watched on the board).

The hardware count is 15 seconds at most (20 bits at 65536Hz), so the
90-second budget is kept by reloading it, and the boot path has two
halves to reload it in. After `kmain`'s final `spllo` the clock tick on
core 0 does it every 64 ticks. Before that — the allocators, the
probes, the SMP launch, the card, everything up to `schedinit` —
interrupts are masked and the tick cannot run, and that half is not
short: `probeuartin` waits three seconds on purpose, `launchsmp` up to
five for cores that never answer, `emmcinit` two for a card to power
up plus its command timeouts. So `microdelay()`, which every one of
those waits loops around, and `probeuartin`'s own loop poll the same
reload whenever five seconds have passed since the last one. In code
that is waiting on purpose the count never falls below ten seconds;
it reaches zero only when nothing has polled for fifteen — a hang, or
a spin that does not go through `microdelay` (the mailbox spin is the
one that matters). QEMU cannot show the reload at all, since its model
resets on the arming write; the interval is a board result.

A boot whose command line *cannot be read* — `GET_COMMAND_LINE`
unanswered, or a line longer than the kernel's 1024-byte buffer, which
the protocol answers by copying nothing and reporting the length —
arms. The kernel cannot tell which boot it is, and a boot that reaches
the shell releases the watchdog and has lost nothing but the line
`boot: command line: (UNREAD: the firmware reports N bytes, ...)`
saying why, while a candidate left unarmed because its line was
1100 bytes would have cost the power switch. `nowatchdog` cannot be
honoured on such a boot, because it cannot be seen; the fix is a
shorter `cmdline.txt` or a bigger buffer (`Mboxcmdlinemax` in
`board.h`). A real Pi's line, with the firmware's additions, runs to
a few hundred bytes.

The one `config.txt`, with `init_uart_clock` pinned because uart.c
divides for 115200 assuming 48MHz and the firmware, not the kernel,
decides what that reference is:

    arm_64bit=1
    dtoverlay=disable-bt
    init_uart_clock=48000000
    kernel=infernode8.img
    cmdline=cmdline.txt

    [tryboot]
    kernel=tryboot.img
    cmdline=tryboot.cmd

`tryboot.cmd` holds the single word `tryboot`; `cmdline.txt` may be
empty or absent. The `[tryboot]` section is the firmware's conditional
filter for a boot made with the flag set; on firmware old enough not to
know it, a `tryboot.txt` that is a copy of `config.txt` with the two
`[tryboot]` lines in place of the two above it does the same job, and
that is the file the firmware documentation historically described.
For a card with no kernel yet, `kernel=serialboot.img` in place of the
`kernel=infernode8.img` line, and the first candidate is installed from
a serial-fed kernel exactly as above.

Be clear about what the guard on a candidate rests on: **two** firmware
behaviours, stacked, and neither yet seen on a Pi 3. First, that
`SET_REBOOT_FLAGS` from this kernel makes the next boot take the
`[tryboot]` section at all. Second, that the section's `cmdline=` is
what the firmware then hands `GET_COMMAND_LINE`, so the word reaches
the kernel. The second is the same conditional-filter machinery that
applies the section's `kernel=` — the firmware documentation lists
`cmdline` as an ordinary `config.txt` property and `[tryboot]` as an
ordinary conditional filter, restricting neither to a model — so a
firmware that boots `tryboot.img` from
the section but serves the other file's line would be a firmware bug
rather than a documented gap; but it is untested, and the failure is
quiet. If the first behaviour fails the candidate never boots and the
known-good kernel does, which is safe. If the second fails the
candidate boots *unguarded* and the only tell is its own `wdog: not
armed (not a tryboot candidate)` line on a boot that should have said
`armed`. Watch for that line on the first candidate boot; and if it
appears, `bootwatchdog` in the **known-good** `cmdline.txt` puts the
guard on every boot regardless of which section the firmware applied,
since that file is read whenever the section does not override it.

*Status, 2026-09-05.* Everything on this path that emulation can prove
is in the harness: the command line reaching the kernel and `osinit`
through `#B/bootargs`, the candidate announcement and promotion text,
the arming write reaching the PM block, the `booted` release
handshake, and `echo tryboot > /dev/sysctl` resetting the machine.
Sixteen checks were added (152 → 168), and the count should be read
honestly: fourteen fail on the code before the change, and two — the
`tryboot: resetting` line and the reboot after it — passed before it
too, because `notyet.c`'s print and the `PM_RSTC` full reset predate
the mailbox handshake; they pin that path against regression and are
labelled so in the script. What only the board can prove, and has not
yet: that the firmware honours `SET_REBOOT_FLAGS` from this kernel and
boots the `[tryboot]` section, and that the section's `cmdline=` is
what reaches the kernel (the candidate's `boot: command line:` line is
the evidence for both; `tryboot: firmware acknowledged ...` on the way
out is the firmware's own word, meaningless under QEMU); that `PM_WDOG`
counts down and the reloads — the tick's after `spllo`, `microdelay`'s
poll before it — hold it off for 90 seconds (`bootwatchdog wdogtest`
on `cmdline.txt`, and the board should reset at 90 s and come back
with `pm:   rsts` showing the watchdog-reset bit 0x20); that the
`PM_RSTC` disarm write leaves the machine up; and the real length of
the firmware's command line against the 1024-byte buffer, which the
`boot: command line:` line now reports if it does not fit. The earlier
`boardtryboot` set bit 5 of `PM_RSTS` and called it the tryboot bit;
the downstream Linux tree shows the flag is a mailbox tag and bit 5 is
the watchdog reset-cause bit, and the code now does what Linux does.

### Network throughput: where the time actually went

The network worked correctly long before it worked quickly. Corrected
first -- zero overflows, a megabyte round-tripping byte-identical --
it still ran at a few hundredths of what the hardware can do, and the
time was not where any of the obvious answers put it.

What it measures now, on the board, against where it started:

    1MB TCP round trip, bytes verified	  20 KB/s  ->  340-450 KB/s
    board -> host, one way			  75 KB/s  ->  ~1.4 MB/s
    host -> board, one way			  55 KB/s  ->  ~580 KB/s

**Both fixes were in the collector, and neither was in the driver.**

`rungc()` ran a collection quantum after every Prog quantum. The
emulator has not done that for years -- `emu/port/dis.c` throttles on a
counter and falls back to collecting always once `memlow()` says the
heap is half gone -- and the two schedulers are otherwise the same
code. The divergence is visible in this tree: `gcbusy`, `gcidle`,
`gcidlepass` and `gcpartial` are declared in `os/port/dis.c` and none
of them was ever assigned, because the throttle that counts them never
came across. `memlow()` was likewise absent from `os/port/alloc.c`
beside the `memusehigh()` it mirrors.

That was worth having but was not the main cost: throttling it alone
moved the round trip from 20 to 28 KB/s.

The main cost was `execatidle()`, which ran the collector until it had
completed **three whole epochs** and only then let the machine sleep.
"Idle" there does not mean there is nothing to do -- it means no Limbo
process is ready this instant, which on an I/O-bound workload is just
the gap between one packet and the next. And an epoch is not a bounded
amount of work: `rungc()` ends one only when a full traversal finds
nothing left to propagate, so three epochs is however many passes the
mark phase needs to converge, three times over, with the interpreter
lock held and the Ethernet driver -- itself a Limbo process -- unable
to run until it ends.

    3 epochs (as it was)	 28 KB/s
    1 epoch			 79 KB/s
    none at all			324 KB/s

No knee to sit on; that is the cost of finishing a traversal at all.
So the bound is now on quanta rather than epochs -- `rungc()` visits at
most `MaxQuanta` blocks and returns, so a cap on quanta is a real cap
on the time before the sleep. Idle time still collects and the heap
stays flat under load: across 5MB of further traffic and 182,000
allocations it moved from 522944 to 523200 bytes.

**Two standing hypotheses died here, and both are worth not
re-testing.**

*The `multitrans` split.* The section above says that if networking on
the board is slow, the packet-at-a-time bulk OUT is the first place to
look. It was, and it is not the problem. A 1514-byte frame is three
channel operations, and all three together cost **188us** -- that is
the whole of `epwrite`, `qlock` and cache writeback included, measured
by `dump` on `#u/usb/ctl`. Interrupts arrive and are prompt: 609301
waits woken against one timed out, mean 60us. The USB layer is not
where the milliseconds are.

*The interpreter hand-back.* A process returning from a blocking system
call queues on `isched.vmq` and waits up to three Prog quanta to get
the interpreter back, which looks like exactly the thing to shorten.
Shortening it does not help -- see the note on `Vmcycles` in
`os/port/dis.c` for the measurements and for the harness regression it
costs. `release` and `acquire` together were separately measured at
64us.

**What is left is architectural.** The remaining per-frame cost is not
in USB, not in the collector, and not in the scheduler's hand-back: it
is the Limbo caller being descheduled between its own two clock reads
while other Dis processes run. The machine is busy rather than
stalled, and the work it is busy with is the 9P server path that every
single frame crosses -- `os/ip` to a 9P read or write on
`/net/ether0`, into `styxservers` in Limbo, into `etherusb`, into USB.

Shortening that means either moving the data path into the kernel as C
-- which gives up the property that made this design worth having, that
device protocols live outside the kernel -- or carrying more frames per
9P transaction so the fixed cost is amortised. The second was built,
both directions, as a second file beside `data`: `packed` carries
several frames per 9P message, each behind a two-byte length, and
opening it is the whole negotiation. Receive came first (~585-690 ->
~850-960 KB/s, 3.2 frames per read); then the write side, with
`etherbwrite` queueing to a kernel writer process instead of paying a
synchronous 9P transaction per frame -- that freed the TCP ack path
too, and took outbound from ~1.4 to ~1.9-2.2 MB/s. A 2MB round trip
verifies byte-identical at ~630 KB/s each way. The remaining distance
to wire speed is the per-message cost times how many messages remain;
the lever from here is deeper batches, not new machinery.

### RESOLVED: the "console wedge" was silent type-ahead loss

What looked like an intermittent hang -- the shell stops executing
lines mid-session, typed characters still echo -- was the kernel
discarding console input after echoing it, with a straight face.

A queue's limit is enforced against ALLOCATED bytes, and console input
arrives one character at a time: each one-byte qproduce allocates a
whole Block (header, headroom, alignment -- about 150 bytes), so
kbdq's 4K limit was really a type-ahead capacity of about 27
characters. Type thirty while the shell is busy and qproduce starts
returning -1, which kbdputc ignored -- after echoing. A command then
arrived without its newline, and the shell waited forever for the rest
of a line the kernel had already thrown away. Every layer below and
above that one branch was checked and proved correct first: run-queue
consistency, the Dis token protocol, sleep/wakeup, the interrupt-pool
and mainmem allocators. The byte ledger that closed it read: handed to
qproduce 460, accepted 451.

Why it bisected to the idle-collector bound: before it, the machine
ground the collector before every sleep, which throttled how fast the
uart drainer could stuff the queue -- accidental flow control. The
bound removed the grind and the forty-year-old capacity assumption
surfaced. The board rarely shows it because a human at 115200 baud
cannot type thirty characters into a busy second; a script driving
QEMU's pty can.

Three fixes, in devcons.c and the uart drainer:

- kbdq is 64K -- roughly 450 characters of real backlog -- with the
  BALLOC arithmetic written down where the number is chosen.
- kbdputc now says "kbd: input queue full, N dropped" (rate-limited)
  if the queue overflows anyway. Input must never vanish silently.
- The uart drainer, being a process and not an interrupt, now pauses
  while more than 512 bytes sit undelivered, leaving bytes in the
  PL011 FIFO where the emulator's chardev backpressure holds the rest
  at the source. Nothing is lost end to end.

Ten consecutive scripted shell sessions pass where one in four
survived before; the full harness is 147/147 twice over.

### The Ethernet data path is in the kernel (#l)

The architectural cost measured at the end of the throughput work --
every frame crossing the Dis interpreter and a 9P transaction -- is
gone: `os/port/devether.c` serves /net/ether0 from the kernel through
os/port/netif.c, with the frame walk and the USB read/write loops as
kernel processes. Board-to-host doubled to ~4MB/s; a 4MB TCP round
trip verifies byte-identical.

What stayed in Limbo is everything that runs once: enumeration, RNDIS
negotiation, the LAN78xx register bring-up. When the device is ready,
etherusb.b closes its endpoint fds and hands the open endpoints to #l
with one ctl write ("bind <family> <mac> <mbps> <burst> <in> <out>");
the endpoint paths are resolved in the writer's namespace, and
exclusive-open endpoints are the interlock that keeps both data paths
from ever attaching at once. Where #l does not exist the old 9P server
still runs -- the namespace decides, not a build flag.

Hunting lessons written in blood, for the next person here:

- devether.reset() must be called from main.c by hand -- this kernel
  has no chandevreset(), and an uninitialised netif is not a device
  that fails but a directory with an empty name that walks miss.
- The compiled-in root carries an EMPTY /net/ether0 stub for the 9P
  mount; a union bind of #l after /net leaves the stub in front and
  every walk lands in it. Bind #l/ether0 OVER the stub, MREPL.
- ethermedium writes "nonblocking" to every ether ctl; netifwrite
  rejects unknown tokens with -1, and escalating that to an error
  unwinds the whole ipifc bind. Accept it and ignore it, as the Limbo
  server always did.
- Limbo `fd = nil` did NOT close the endpoint before the kernel tried
  to take it -- the FD destructor provably did not run at the
  assignment (the ep stayed inuse until process exit). For a while the
  handoff closed by sys->dup of #c/null over the descriptor instead.
  RESOLVED 2026-09-05: it was the JIT. `comp-arm64.c` `macfrp()`
  decremented the refcount with `SUB_IMM`, which sets no flags, then
  `BCOND(NE)`'d on the flags the nil check had left -- always NE for
  a non-nil pointer -- so `rdestroy` was unreachable and compiled code
  never ran any destructor; every dropped fd waited for the
  collector. The macro now has comp-amd64.c's shape (compare with 1,
  branch to rdestroy on equal, else decrement and store), the dup is
  gone, and the handoff is a plain `fd = nil`. Pinned by
  `tests/fdclose_test.b` (hosted, both -c0 and -c1), by osinit's
  `init: fd:` self-checks, and by the harness asserting the "(kernel
  data path)" handoff line.

### Single-shot bulk transfers, and the two bugs that forbade them

The experiment the eptrans comment said never to run a third time ran
a third time, because both earlier failures finally had names: the
NAK-wake race (previous commits), and chandone() refusing the one
wakeup a multi-packet transfer depends on. This core halts a fresh
bulk IN after its FIRST packet with exactly Chhltd|Ack, then streams
the entire remainder once re-enabled (measured: 4+ packets per 50us);
chandone filtered Chhltd|Ack as "split phase, keep waiting" on every
channel, so that turning-point wakeup became a 200ms timeout, per
packet. The filter is now scoped to split channels, where it belongs.

Single-shot is opt-in per endpoint -- devusb ctl "singleshot 1", set
by etherusb.b for lan78xx only -- because QEMU's controller model
still cannot do it and the harness proved that three times. One
channel operation per transfer instead of one per 512 bytes.

The stats file's mbps is now read from the PHY's partner-ability
registers at link-up instead of being a hardwired 100: this board on
a gigabit switch negotiates 1000BASE-T (throughput is capped by USB2
regardless).

Measured on the board with all of this together, 8MB transfers:

	host -> board		2.3-2.6 MB/s, steady
	8MB round trip		2.17 MB/s each way, byte-identical
	framing errs		6 per 30k frames (0.02%)

### Where the CPU goes at 2.4MB/s, measured

A tick-driven sampling profiler now lives in clockintr (readout on
#l/ether0/ifstats; 64-byte buckets, offset->name via the build's ELF).
Profiling a sustained 32MB inbound push, with the idle signature
(excreturn/wfi) separated out, busy CPU divides roughly:

    ~36%  Dis garbage collector (markheap + rungc)
    ~27%  scheduler (ready + anyready + sched + splx)
    ~18%  genrandom (the pool-stirring kproc)
    < 6%  the entire network path: ptclbsum, memmove, chanio, qio

The kernel data path is nearly free. What remains is the CONSUMER:
the measurement endpoint is a Limbo cat, and its per-read allocations
keep the collector and scheduler busy -- the same architectural line
item as ever, now with numbers. Two parallel streams aggregate ~3MB/s
against 2.4 for one, confirming a shared CPU ceiling rather than a
per-stream window.

Levers from here, in order of expected value: a kernel-side sink for
measuring the wire path alone (the ~30MB/s USB2 budget is otherwise
unobservable through a Limbo endpoint); genrandom's appetite (since
pulled: `random.c` feeds the pool from the hardware generator); the
per-packet first-halt in singleshot transfers (2 channel ops per
transfer could be 1 if the fresh-channel Chhltd|Ack halt has a
register cause); and the GC/scheduler costs that INFR-404's earlier
collector work already halved once.

### The full speed ledger: a number for every layer

Measured on the board, 2026-09-01, each layer isolated:

    USB, instantaneous          ~28 MB/s   (13.8KB per 487us read,
                                            near-full bursts back to back)
    wire path, sustained        12.4 MB/s  (UDP flood into the driver's
                                            blackhole sink: USB + record
                                            walk + counter; single rx
                                            process; 3 framing errs per
                                            82k frames)
    full TCP through a Limbo
    consumer                    2.6-2.8 MB/s in, ~4 MB/s out,
                                1.8 MB/s round trip byte-verified

The gap between 12.4 and 2.6 is not the driver: a receive cycle is
~430us of USB and ~2.3ms of serialized IP/TCP/VM work on the same
core, and the cycle is their SUM because the reader parses before it
reposts. The levers, in order: overlap read with processing (a second
buffer and the parse moved off the repost path -- approaches the
12MB/s wire ceiling for kernel consumers), then SMP so the VM runs
beside the network instead of inside its cycle. SMP has since landed
(all four cores schedule); the throughput with it has not been
measured, and the review recorded in "Next" found that the secondary
cores do not yet tick, so the number is not worth taking until they do.

Two tools this bought, both permanent: `blackhole` on any ether ctl
toggles a surgical sink (IPv4/UDP/port-9 counted and dropped, control
plane untouched -- floods measure the wire path with nothing else in
frame), and `rxstats` prints and resets read-size/turnaround
accounting. The gap numbers exclude intervals over 50ms; the first
version summed idle time between test runs into "gap" and an
afternoon went into optimising that mirage -- including a parked-
channel NAK scheme whose autopsy is in the git history: the NAK wake
is the transfer DELIMITER, and every design that suppressed it
(tick-paced re-arm, ISR fast-lane re-arm) glued aggregates beyond
parsing. It is load-bearing; leave it.

### The portable timer chain never ran (fixed)

addclock0link() timers are dispatched by timerintr(), and nothing on
this port ever called it -- clockintr went straight to hzclock. The
whole runway was built (timersinit, todinit, a real timerset) and the
plane never landed; randomclock never ticked once in the life of this
port, unnoticed because the entropy pool grew a hardware source.
clockintr now calls timerintr(u, 0), whose periodic nil-tf entry
calls hzclock at HZ exactly as before; armtick's TVAL re-arm keeps
the tick fixed at the millisecond, which every ms-scale periodic is
fine with.

### OPEN: residual ~0.02% framing desync under burst

Down from ~0.5% at the start of the hunt: the NAK race, the stale
post-halt interrupt word, and the per-packet timeout chaos each fed
it. What remains is a handful per tens of thousands of frames,
TCP-healed, byte-verified end to end. Resume with the byte-capture
probe in devether.c's used<0 branch, never with theories.

### Smaller things still open

The `sprint()`/`PRINTSIZE` hazard once recorded here is fixed:
`os/port/dev.c` uses `snprint` with the buffer's real size. What is
still small and open is gathered under "Next", tier 1, item 6.

## The SD card is on SDHOST, and the Arasan is free (WiFi milestone 1)

**Status: proven under QEMU; ran on the board on 2026-09-06 (kernel cc7bf87a): the card came up on SDHOST as 118912 MB, high capacity, all six pins read back ALT0, the partition table parsed and the desktop loaded its userspace through it. Not yet measured on the board: sustained write throughput, and the parked-state handling in the transfer wait (which QEMU cannot exercise) under a long soak.** Every claim in
this section about the silicon is taken from the Linux bcm2835 driver
(there is no public SDHOST datasheet; the BCM2835 peripherals manual
documents only the Arasan), from Miller's Plan 9 driver, from 9front's,
and from QEMU's model -- the Linux driver that the Pi runs
every day; none of it has been observed on this board's SDHOST by this
kernel. The board test is the first thing to do with a serial cable.

**Two controllers, one set of pins.** The BCM2837 has two SD
controllers. The Arasan SDHCI block at `0x3F300000` (`EMMCREGS`, GPU
IRQ 62) is the one `start.elf` loads `kernel8.img` through, so it is
the one a kernel finds already running. The BCM2835 SDHOST block at
`0x3F202000` (`SDHOSTREGS`, GPU IRQ 56) is Broadcom's own older
design. The Pi 3B+ has two SD *devices*: the card slot on GPIO 48–53
and the CYW43455 WiFi chip, which speaks SDIO on GPIO 34–39. Only the
Arasan can be routed to 34–39, so a kernel that keeps the card on the
Arasan has no controller left for the radio. Moving the card to SDHOST
is the whole of this milestone; the radio itself is later work and
none of it is here.

**Pin mux.** Pins 48–53 reach SDHOST at ALT0 and the Arasan at ALT3.
The firmware leaves them at ALT3. `sdhost.c` writes ALT0 to all six
before touching a register, and that write is what moves the card —
on the silicon it re-routes the pads, and in QEMU `hw/gpio/bcm2835_gpio.c`
reparents the `sd-card` device from the SDHCI bus to the SDHOST bus
when, and only when, all six read 4. QEMU's mux recognises exactly two
settings: ALT0 (SDHOST) and function 0 (back to SDHCI, the reset
value). ALT3 means nothing to it. So "reclaim the Arasan" is ALT3 on
the board and 0 under emulation, and a runtime switch between the two
would pass the harness and fail on the board or the reverse. That is
why the choice is made at build time — `sdmmc.c` holds one pointer,
SDHOST by default, `-DSDCARD_ARASAN` for the other, the same shape as
`-DFBSCROLLTEST` — and why the Arasan backend does not write the mux
at all: "as the firmware left them" is the one setting that is right
in both places. The other reason there is no runtime choice is that
there is nothing to make it from: this port parses neither the device
tree nor `cmdline.txt`, and QEMU's `raspi3b` passes a bare `kernel8.img`
no device tree.

**The layers.** `sdmmc.c` is the card protocol — identification, the
CSD, one block in or out — written against the `SDio` vtable in
`board.h` and against no register. `sdhost.c` and `emmc.c` are the two
implementations of that vtable. `devsd.c`'s five entry points kept
their `emmc*` names so that nothing above them moved. Both backends
are always compiled; only the pointer changes.

**The raw response layout.** A 136-bit response (CID, CSD) is stored
differently by the two controllers, and the difference does not
produce an error. SDHOST stores it raw: `Sdrsp3` holds bits 127:96 of
the register as the specification numbers them. The Arasan drops the
CRC byte and stores bits 127:104 in its `RESP3`, 103:72 in `RESP2` and
so on — shifted by eight. A CSD parsed in the wrong layout reports a
plausible wrong capacity and then reads plausible wrong sectors. The
parse therefore exists once, in `sdmmc.c`'s `identify()`, in the raw
layout, and the Arasan backend shifts its responses into that layout
(`resp[0] = RESP0<<8`, `resp[1] = RESP0>>24 | RESP1<<8`, …), which is
what Miller's `emmc.c` does. The harness asserts the fixture's size —
`64 MB` — on both controllers for exactly this reason.

**FIFO thresholds and the busy interrupt.** `Sdedm` carries the
read and write FIFO thresholds; both are set to 4 words, the Linux
driver's value with its comment "limit fifo usage due to silicon
bug", and the driver moves data in bursts of up to 8 words after
reading the fill count once. `Sdhcfg`'s `Hcfgbusyinten` is set even
though this kernel takes no SD interrupt: the bit is not just a
delivery enable, it is what makes the controller *latch* the busy
completion of an R1b command (`Hstbusyint` after CMD7 and CMD12) at
all, in the controller as the Linux driver describes it and in QEMU's
model alike. Without it every card
select waits out its full bound and the driver looks like it has a
slow card. Interrupt 56 stays disabled in the VideoCore controller, so
the status bit rising is harmless. After a write, the card layer polls
CMD13 for `READY_FOR_DATA` rather than trusting either controller's
idea of busy.

**What the harness proves.** Section 3g of `tests/host/baremetal_test.sh`
boots the SDHOST kernel with the 64MB FAT16 image and checks: the
card-ready line names `sdhost` and says `64 MB`; GPIO 48–53 read back
`func=4`; the MBR reads and the partition table holds the values the
fixture was built with; no `sdhost:` fault line appeared. Then it asks
QEMU over QMP for `info qtree` and requires the `sd-card` device to be
listed under `bcm2835-sdhost-bus` and not under `sdhci-bus`. That last
check is the load-bearing one: a driver that prints `sdhost` and then
keeps talking to the Arasan passes every text check, because the card
works either way, and QEMU's device tree is the one witness that cannot
be talked round. The FAT16 and FAT32 shell sessions, the append test,
the kernel installing itself onto the card, and the write round trip
all run through SDHOST unchanged. A `-DSDCARD_ARASAN` kernel is built
and booted too: it must still identify the card at 64MB and read the
MBR, and the same QMP question must put its card under `sdhci-bus` —
the negative case, without which the bus check would not be known to
discriminate.

**What only the board can prove.** Whether the pads actually follow
the ALT0 write on this board; whether the pull-ups the firmware set
for the Arasan suit SDHOST (Linux's pinctrl uses pull-up on 49–53 and
none on 48; `gpiopull()` is there if they do not); whether the
divider computed from the mailbox's core-clock reading survives the
firmware scaling that clock (the divider is computed once, so a core
clock that rises later overclocks the card — pin `core_freq` in
`config.txt` if this bites, or compute from the maximum rate); the
FIFO behaviour of the real state machine at 25MHz; and the 4-bit bus,
which QEMU tolerates whether or not the card agreed. High-speed mode
(CMD6, 50MHz) is deliberately not attempted: 25MHz is the conservative
first thing to run on silicon that has never run this driver.

## Next

Revised 2026-09-05 from a review of the branch's 49 commits against the
tree, file by file, rather than from the commit messages. The previous
version of this list was written before the board arrived and had
drifted badly: it still called the JIT, LAN78xx and `os/ip` outstanding.
All three are done. What the review found instead is below, and the
ordering principle is: **make what exists correct and tested before
adding hardware.** Every item names the code so it can be checked
rather than believed.

The port lives on `feat/baremetal-pi`. `master` has no `os/` directory,
and no workflow in `.github/workflows` runs the harness. Until tier 2
is done, "it works" means "it worked on one board and one developer's
QEMU".

*Later the same day:* tier 1 was worked through, one branch per item,
each reviewed adversarially and re-run through the harness before it
was merged. Items 1, 2, 5 and the four non-SMP bullets of 6 are done;
4 is done except for the board; 3 is half done (the namespace, not the
user). Each carries a harness check that fails on the unfixed tree.
The merged tree passes 194 checks against 152 before, and the hosted
suite still passes with the JIT on. Every "DONE" note below says what
was verified and what was not; the board has run none of it yet.

### Tier 1 — defects the review found; worked through 2026-09-05

**1. The AArch64 JIT never runs a reference's destructor.**
`libinterp/comp-arm64.c` `macfrp()`: after the nil check, the refcount
is loaded, decremented with `SUB_IMM` — which does not set flags — and
stored, and then `BCOND(NE)` branches on the flags the *nil check* left,
which are always NE for a non-nil pointer. `rdestroy` is unreachable.
And if the branch were fixed alone it would still be wrong: `destroy()`
in `heap.c` decrements again, `Heap.ref` is unsigned, and the wrapped
value reads as "still referenced". `comp-386.c` and `comp-amd64.c` get
this right by branching at `ref == 1` *without* decrementing.

The consequence is exactly the "OPEN QUESTION" recorded under "The
Ethernet data path is in the kernel": a Limbo `fd = nil` did not close
the endpoint, and etherusb.b still carries the `sys->dup` of `#c/null`
workaround. Every last-reference drop in compiled code — `movp`,
`headp`, `tail`, frame destructors — leaks until a GC sweep. The
interpreter path in `xec.c` is correct, so a `-DCFLAG=0` kernel hides
it. **This is not a bare-metal bug: hosted macOS on Apple Silicon runs
the same macro under `-c1`,** and the macOS CI job runs the suite
without `-c1` — interpreter only — so nothing there would have caught it.

Fix: mirror the amd64 shape (compare with 1, branch to `rdestroy` on
equal, else decrement and return). Test: a Limbo test that drops an fd
in compiled code and checks `#u`'s endpoint `inuse` (or a pipe's other
end seeing EOF) *without* the dup workaround; then remove the
workaround. Run the hosted runner on macOS with `-c1` in CI. Half a day
of code; the test is the point.

**DONE 2026-09-05.** `macfrp()` now compares the refcount with 1 and
branches to `rdestroy` on equal without storing a decrement, else
decrements and stores; an audit of every other `BCOND` in the file
found each one directly preceded by its own compare. `tests/fdclose_test.b`
drops a pipe's write end by assignment, by frame return, through a ref
adt and through `tl` on a list cell, and reads EOF from the other end
within a bound; it also proves a second reference keeps the file open.
It passes on hosted Linux under both `-c0` and `-c1` (amd64 JIT). On
AArch64 the fixed macro is exercised by osinit's `init: fd:` self-checks
(assignment and return drops, each read to EOF) which the harness
asserts with the JIT on, and by the `#l` handoff in `etherusb.b`, which
is now a plain `fd = nil` -- the `#c/null` dup is gone and the harness
asserts the "(kernel data path)" line. The macOS `-c1` CI run is still
to do. Follow-up 2026-09-05: `dis/tests/fdclose_test.dis` added to
`tools/dis-manifest.txt`, the stale "not done" bullet at the top of this
file removed, and the hosted amd64 `-c1` `altrdy` SEGV that the first
draft of the test hit (unreproduced since) is recorded under "Open
faults" in `docs/JIT.md` so it gets its own ticket.

**2. Cores 1–3 have no clock tick.** `timersinit()`
(`os/port/portclock.c`) creates the one periodic Timer whose purpose is
to call `hzclock()`, and `timeradd()` puts it on `timers[m->machno]` —
core 0, where `clockinit()` ran. A secondary's `clockintr` calls
`timerintr`, which walks its own queue, which is empty. So on cores 1–3
there is no preemption, `m->ticks` never advances and `active.exiting`
is never checked; the comment in `secclockinit` (`clock.c`) claiming
otherwise is wrong, and the one in `squidboy` (`main.c`, "voluntary for
now") is right. With `lock()` never yielding when `nmach > 1`
(`taslock.c`), a process spinning at spllo on a lock whose holder was
preempted holds its core until the holder runs elsewhere.

Fix: each secondary adds its own periodic Timer in `secclockinit`, or
`clockintr` calls `hzclock` directly when `m->machno != 0`. Test: the
harness asserts `cpu1..3: up`, and a busy Limbo loop pinned by chance to
a secondary is preempted by a second one. Nothing in the harness
currently asserts that SMP came up at all.

**DONE 2026-09-05.** `secclockinit` now calls `timersinitmach()`
(`portclock.c`), which puts a periodic nil-`tf` Timer on the calling
core's own queue without re-running `todinit`; `checkalarms` already
tolerates concurrent callers (`canlock`) and the runq path is the one
the secondaries' schedulers already used. Observable as `/dev/sysstat`
(one `cpuN ticks T intrs I timers F` line per running core), asserted
by `osinit` ("init: clock ticks on 4 of 4 cores") and by a boot-time
preemption proof in `main.c` (`smpcheck`: a kproc wired to a spinning
core runs there within a tick budget, ~1ms with preemption, 250ms
without). The harness now checks `cpu1..3: up`, both lines, and the
shell's `cat /dev/sysstat`. Verified with the full harness under QEMU
raspi3b (159 checks, up from 152, all passing) plus five further boots
of the same image, each showing all four cores ticking, preemption
latencies of a few milliseconds and no fault.

**3. Every process is the host owner.** `main.c` sets the user to
`inferno`, which is `eve`, for every process, so `iseve()` is always
true, and `#S`, `#G` and `/dev/sysctl` are bound into the `/dev` the
desktop shares. Any desktop program — any agent tool — can `echo
tryboot > /dev/sysctl`, write `/dev/sdcard` raw, repartition through
`/dev/sdctl` (`sdaddpart` in `devsd.c` has no overlap check), or
rewrite `/dev/hostowner`. This is the opposite of the namespace
discipline the rest of InferNode is built on
(`docs/DESIGN-PRINCIPLES.md`).

Fix, smallest first: build the desktop's namespace in
`boot-baremetal.sh` without `#S`, `#G` and the console ctl (the
mechanism — `bind`, `newns` — already exists), then a non-eve user for
the desktop and agents. A week for the second; an afternoon for the
first.

*First half DONE 2026-09-05.* `boot-baremetal.sh` now forks its
namespace before anything of the desktop's starts, unmounts `#S` and
`#G` from `/dev`, binds `/dev/null` over `/dev/sysctl` and
`/dev/hostowner`, and refuses to start the desktop if `/dev/sdcard`,
`/dev/gpio` or a readable `sysctl` is still there afterwards. The
comment in the script is the record of what the desktop's `/dev`
holds (`#i` arrives through libdraw's own bind when logon opens the
display, as before) and of two things this does not close: the
desktop's own Quit writes `halt` into the null over `/dev/sysctl`, so
Quit now ends the desktop and leaves the board up — deliberate, and
the script says so on the console when lucifer returns; halting is
the serial console's — and `/n/dos`, config.txt and the kernel image,
stays read-write (Inferno has no read-only bind). Verified by a
harness session (`baremetal_test.sh`, "The desktop's namespace can be
narrowed") that reads the narrowing lines and the fail-closed check
out of the script — not a copy of them — and types them into a child
shell over the serial line with the FAT16 card attached: inside, the
card, the pins and sysctl are gone, the script's own check comes out
`narrowed 1`, and `echo halt > /dev/sysctl` does not stop the machine;
back in the console shell the card, `/dev/gpio/21/{ctl,level}` and the
kernel's sysctl are all still there. Nine checks, run to a green
summary (162 passed, 0 failed) on 2026-09-05. What the harness does
not run is the script itself — the kernel image carries no card
userspace — so its `$status` handling and retry loop are exercised
only on the hosted emulator against child shells (item 5). The
second half — a non-eve user, and a `/n` the desktop does not own —
is untouched.

**4. tryboot is a one-shot flag, not yet an A/B path.**
`cp /dev/bootimage /n/dos/infernode8.img` (`devboot.c`) overwrites the
file `config.txt` names — the known-good kernel. A/B exists only if the
operator hand-edits `tryboot.txt`. No watchdog is armed while a
candidate boots, so a candidate that *hangs* (the classic JIT icache
failure) needs the power switch; only a candidate that panics reboots
itself. And `boardtryboot` (`board.c`) is a PM_RSTS write that has not
been tested against the firmware; the harness has no tryboot check.

Fix: install to a candidate filename; arm the hardware watchdog in
`kmain` and clear it from `osinit` once the shell answers; prove the
PM_RSTS handshake on the board once, with the result written here; a
harness check for the flag write. Two or three days.

*DONE 2026-09-05, except the board.* The install is to `tryboot.img`,
the boot watchdog is armed in `kmain` for a boot whose command line
says `tryboot` and released by osinit's `booted` on `/dev/sysctl`, the
firmware flag is requested through the mailbox tag Linux uses rather
than a `PM_RSTS` bit (which turned out to be the watchdog reset-cause
bit), and `#B/bootargs` tells osinit which boot it is. The harness
checks the arming line, the release line, the candidate announcement,
`-append`-driven command lines and that `tryboot` on `/dev/sysctl`
resets QEMU; it cannot check the countdown or the firmware's answer,
because QEMU models neither — the recipe and the remaining board proof
are under "Working on the board without moving the card".

*Review follow-up, 2026-09-05.* Two reviewers read the change. The
budget analysis had a hole: the 64-tick reload cannot run until
`kmain`'s final `spllo`, so the whole pre-scheduler boot — the
three-second UART probe, up to five seconds waiting for secondary
cores, the card's two-second power-up — ran on the 15-second hardware
count alone, and the comments called that "a hang with interrupts
off". `microdelay()` and `probeuartin`'s loop now poll the reload
(`boardwatchdogpoll`, `board.c`) once five seconds have passed since
the last one. `mboxreboot` read the tag response out of the shared
mailbox buffer after the lock was dropped, so the "firmware
acknowledged" line — the board evidence — could have been a
framebuffer scroll's answer; `mboxprop1` now holds the lock through
the copy-back and returns the tag word. A command line longer than the
buffer was reported as "(empty)" and booted a candidate unarmed;
`mboxcmdline` now returns the firmware's length unclamped, the kernel
prints `UNREAD` with the length, and arms. The two shell-tryboot checks
that pass on the old code are labelled as pins, above and in the
script. Verification: the changed files compile under the harness's
flags, and the harness run made after the change had passed 85 of its
168 checks with no failure — the tryboot arming and reset checks among
them — when the orchestrating session was closed before it finished;
the full run should be confirmed at merge. None of the three fixes
changes QEMU output: the reload interval, the unread-line arming and
the lock's effect on the board line remain board results.

**5. The login screen is bypassable in two ways, one deliberate.**
`boot-baremetal.sh` treats `wm/logon` exiting 0 as a login. Escape
twice is a designed skip ("Keys won't persist") and exits 0 — fine,
but the script's comment claims fail-closed and it is not. Worse,
`headlessprompt()` in `logon.b` does nothing and returns normally when
the display or `/dev/keyboard` cannot be opened, which is precisely the
"logon died, desktop starts anyway" case the script says it blocks.
Also `if {! ~ $#skiplogon 0}` enables the skip for `skiplogon=0`, unlike
the hosted `~ $skiplogon 1`. Fix: distinct exit statuses for
logged-in / skipped / failed, and the script honours them. Hours.

*DONE 2026-09-05.* `logon.b` returns only on a login, raises
`fail:skipped` for the deliberate skip (Escape twice, or Escape after
a failed unlock or a failed first-boot setup, which now offers that
choice instead of exiting), and `fail:<reason>` when there is no
display, no form or no keyboard or the keyboard closes; the input
readers are killed before the raise on every path. `boot-baremetal.sh`
copies `$status` (an `if` resets it from every condition it runs,
`~` included), starts the desktop on a login, starts it on a skip with
a console line saying there is no factotum, and after three failures
refuses; the skiplogon test is `~ $skiplogon 1`. The hosted
`boot.sh` prints which of the three it was and goes on as before.
Verified on the hosted emulator with the boot-script logic run
against child shells raising the three statuses, and by reading
`builtin_if`; the display and keyboard paths of `logon.b` itself
could not be driven here — the Linux emulator on the build host has
no display backend and faults on the draw attach — so those are
compile-checked only.

**6. Smaller confirmed defects, each a line or two:**

- `irqorphan` (`intr.c`) is reset by *every* core's timer interrupt
  (`clock.c`), so a genuinely unhandled GPU interrupt on core 0 can be
  reported "spurious" by a tick on core 1 and storm silently.
  DONE 2026-09-05: per-core (`irqorphan[MAXMACH]`).
- `devusb.c` `CMdetach` releases every endpoint on every write; a
  second "detach" double-frees. `osinit` writes once today.
- `uart.c` zeroes the console mutex after a bounded spin even when it
  never acquired it; `uartputx`/`uartputd` and `dumpureg` bypass it.
  DONE 2026-09-05: `uartlock()`/`uartunlock()` release only what the
  caller took, are re-entrant per core, and `uartputx`/`uartputd`,
  `dumpureg` and `intrdump` emit under it as whole pieces. Review of
  that change found the owner-by-core rule unsound at spllo once every
  core preempts (the holding process could migrate mid-line and the
  old core would then write through unlocked), so the lock is now held
  at splhi, ilock-style: the holder cannot be preempted, so the core
  is the holder. Verified by the full harness under QEMU raspi3b (159
  checks passing, console output unshredded through four-core boot).
- Unlocked multi-core writers: `ticks++` and the profiler buckets in
  `clock.c`, `nspurious` and `irqenabled |=` in `intr.c`. Lossy at
  best; `irqenabled` from a kproc on another core is the one to fix.
  DONE 2026-09-05: `irqenabled` under an `ilock`; `nspurious` and the
  buckets through `ainc` (`arch.S`, ldxr/stxr); `ticks` is core 0's.
- `lock()` has two different spin bounds (1M with `up == nil`, 100M
  otherwise) and `schedinit`/interrupt-time wakeups use the short one
  against locks that are held across a memset.
- `etherusb.b`: `dhcpreader`, `pingreader` and `ntpreader` never exit;
  the UDP conversation on port 68 is never closed.
- `dossrv.b`: a real file whose name matches `badent-*` is removed
  without `truncfile`, leaking its clusters.
- `mailbox.c` says "single-threaded for now" over one shared request
  buffer; `fbcons` now calls it from the console path while draw and
  pointer run on other cores.
- `notyet.c` `postnote` is a stub, so a blocked reader cannot be
  kicked; the comment there already says it is "wrong to leave
  permanently".
- *DONE 2026-09-05.* `devgpio.c` `gpiogen` answered −1 for every
  `s >= 0` when called on a leaf (`ctl`, `level`), so `stat(2)` on
  `/dev/gpio/N/ctl` printed `devstat G <qid>` and failed "file does
  not exist" while the directory listing showed the file and reads
  worked (`devopen` takes gen's −1 as nothing to permission-check).
  `ls` on the leaf, or `ftest -e`, showed it; a harness check that
  probed the leaf tripped over it. A leaf now lists its pin's entries
  as the pin's directory does, and the harness stats
  `/dev/gpio/21/level`.
  DONE 2026-09-05 on the base (01f7324): `postnote` interrupts the
  target's sleep, which is the one effect os/ip asks of it.

**DONE 2026-09-05 -- the four non-SMP bullets** (`irqorphan`, the uart
mutex, the unlocked multi-core writers, the `lock()` bounds and
`postnote` are not covered by this note). `devusb.c` `CMdetach` makes
the Ddetach transition under `epslck`, so of two writers arriving
together exactly one runs the release loop -- the serial second write
was already refused by `ctlwrite`, which the review missed; the harness
now detaches the keyboard twice down one shell fd and requires the
driver to exit once and the shell to still answer. `etherusb.b`'s three
readers hand their pid to the spawner, which kills them through `/prog`
when the exchange is over (`killprog` finds them in Prelease and
`swiproc` wakes the read with "interrupted"); the boot log says `dhcp
reader N exited` and the harness checks for it. `dossrv.b` decides
"damaged" from the on-disk name (`rawstat`, `badname`) rather than from
the alias it hands out; the FAT32 fixture creates and removes a healthy
`badent-1` and a host-side walk of the image asserts no lost clusters.
`mailbox.c`'s "single-threaded" comment was stale -- a `lock()` had
been added -- but `panic()` reaches the mailbox through `screenputs`
with the interrupted holder on the same core, and `mboxfballoc` and
`setpower` read the shared buffer after unlocking; the mutex is now a
bounded `_tas` held with interrupts off across fill, post and copy-out,
with a two-second wait that proceeds unlocked for a holder that cannot
return. Verified by the harness under QEMU: 158 checks pass, 152
before, six added for these (two for the DHCP reader, two for the
double detach, two for `badent-1`).

**5. FT5406 touch** — done; seen working on the board 2026-09-06. The firmware
polls the panel's controller into a 64-byte buffer, so there is no I2C
driver; the split is the usual one. `os/bcm2837/devtouch.c` (`#T`, bound
as `/dev/touch`) does what a Limbo program cannot: asks for the buffer
with `0x0004000F` (GET, a buffer the firmware allocated in VideoCore
memory above ramtop, already Device-mapped so uncached) or, failing
that, hands it a cache-line-aligned buffer of ours with `0x0004801F`
(SET, accepted only if the firmware writes it within 200ms — a firmware
that takes the buffer and never writes it has no panel behind it), and
serves one read-only, exclusive-open file whose every read is one whole
frame, marked consumed as the firmware expects (point count := 99). The
byte layout is the panel's protocol and `os/init/touch.b` decodes it,
writing absolute `m x y b` events to `/dev/pointer`: first finger is the
pointer with button 1 held, lifting releases. Orientation, if the board
shows the panel mirrored, is an inversion flag in that program and never
a change to the kernel file. QEMU implements neither tag, so under
emulation the device refuses to attach, `/dev/touch` is absent, the
driver exits with one line, and the harness checks exactly that plus the
decoder's self-test (`touch -t`). On the board (2026-09-06, current firmware) GET answered with a
buffer at bus 0xff433000 that the firmware never wrote: the driver
polled it for minutes and the cursor never moved. SET was accepted and
the firmware wrote our buffer within 20ms, so the probe now tries SET
first and, on either path, plants the consumed mark and waits up to
200ms for the firmware to overwrite it before claiming a panel. Cursor
tracking follows the finger with the panel in its natural orientation
(no inversion needed), and taps and touch-scrolling work inside the Tk
desktop. The cost of the 60Hz poll on one core is the remaining board
measurement.

**6. WiFi** (CYW43455 over SDIO), which needs everything above plus an
SDIO driver on the Arasan and a firmware blob upload. Milestone 1 —
freeing the Arasan by moving the card to SDHOST — is done under QEMU;
see "The SD card is on SDHOST, and the Arasan is free" above for what
the board still has to confirm.

*What that verification does and does not show, 2026-09-05.* The
`dossrv` fix is the one check that discriminates: the old code leaves
one lost cluster, the new none, and the same fixture now runs hosted as
`tests/host/dossrv_badent_test.sh` (also asserting that a genuinely
damaged entry is still zapped with its cluster deliberately left),
which CI runs. The DHCP-reader check is behavioural: the "exited" line
is printed only after `/prog/N` has gone. The double-detach check does
NOT reach the `epslck` compare-and-set -- two writes typed in sequence
are serial, and the second was already refused by `ctlwrite`, so that
check passes on the unfixed kernel; it pins the refusal and the
driver-exits-once contract, and the race fix is correct by inspection
only (one assignment of Ddetach in the tree, `epslck` taken in process
context with nothing else held). The `mailbox.c` rewrite is likewise
inspection-only; the harness shows the mailbox still works, not that
the lock is right.

### Tier 2 — make what exists trustworthy

**7. Test what the board relies on.** The harness (`baremetal_test.sh`)
covers the kernel well and the userspace not at all: no check for
tryboot, `wm/logon`, `secstored`, the rootpath policy, `/usr`, or any
of the five dossrv fixes (its two FAT fixtures are read-only plus one
append). DHCP "passes" through the static fallback because QEMU's
user network never answers. SMP is not asserted. Add: a populated
FAT32 card image booting through rootpath to logon under QEMU; dossrv
rename/growroot/badent fixtures; four cores up; a DHCP server on the
QEMU side. Three or four days, and it is what makes tier 1 provable.

**8. CI, then master.** Add a Linux job with clang (`--target
aarch64-elf`), `ld.lld`, `llvm-objcopy`, `qemu-system-aarch64` with
`raspi3b`, the native `limbo` and python3; the harness already skips
when they are absent, so it is safe to add before it is green
everywhere. Remove the hard-coded personal path the harness falls back
to for `limbo`. Then merge `feat/baremetal-pi` to `master`. The branch
also changes hosted behaviour — Limbo `int` semantics in both JITs and
the interpreter, `runt.c` print bounds, `draw.h`'s `BGLONG` — and those
need the hosted suite on both architectures before the merge.

*Blocker found 2026-09-05:* the hosted runner under `-c1` on Linux
amd64 crashes every `asyncio_test` case in `altrdy` (`alt.c:98`) with
this branch's emulator and passes with `master`'s. The only suspect is
fb64f77, the Limbo-`int` sign-extension change to `comp-amd64.c`: the
fault address is a 32-bit value sign-extended into a pointer. Details
under "Open faults" in `docs/JIT.md`. Fix and prove it with the full
runner before merging; `intsem_test` and `jit_test` do not cover it.

**9. Network device lifecycle.** `#l` binds once, ever (`devether.c`);
its reader and writer kprocs exit on error without closing their
endpoints; `etherusb.b` has no detach handling although `#u` now
reports detach; `nif.link` is set to 1 at bind and never updated;
`lanphy` returns success without link; DHCP has no renewal. A NIC
unplugged is dead for the boot. Two or three days.

*Mostly DONE 2026-09-05, on `feat/baremetal-pi` itself (01f7324, merged
here):* `#l` unbinds when a data-path process dies or on an "unbind"
verb and rebinds; `etherusb` confines its DHCP, ping and time readers
to their descriptor and kills them when the exchange is over, closes
the control endpoint when done, and clears a stale interface before
making a new one; a replugged keyboard keeps its device; `postnote`
is real, so an interface unbind can wake its readers. The harness
releases the data path from the console and runs the driver again.
Mouse unplug and replug verified on the board. Still open: link
monitoring (`nif.link` is 1 for ever), `lanphy` returning success
without link, DHCP renewal.

**10. The DWC read path, hardware edition.** No cache *invalidate*
after DMA completes (`usbdwc.c` cleans before, `memmove`s after) —
speculative prefetch on an A53 across four cores can read stale lines,
and QEMU is coherent so the harness cannot see it. The residual ~0.02%
framing desync under burst is still open; resume with the byte-capture
probe in `devether.c`, not with theories. Completion is polled through
`tsleep` timeouts rather than interrupt-driven. Hubs are polled rather
than read through their status-change endpoint. About a week, and it
is where the next hardware-only bug lives.

**11. Kernel hygiene the review flagged:** the identity map ("for
now" in `mmu.c`, and JIT text is RWX); secondary scheduler stacks are
8K `malloc` with no guard word; `conf.nmach` is set before the cores
have answered; `up->inpreempt`-style invariants have no SMP
counterparts. Also `lastdev` in `osinit.b` is one global shared by
every hub watcher, so two hubs enumerating at once can cross names.
*`lastdev` DONE 2026-09-05:* `enumerate` returns `(status, name)`, the
name flows back through `portsetup`, and a device that failed to come
up is detached on the spot by `portsetup` and `usbwalk` instead of
holding its ep0 until unplugged -- or for ever, on the boot walk. The
hotplug and keyboard harness checks pass unchanged, which shows the
success path was not broken; the new detach-on-failure path is
exercised by nothing -- no QEMU session makes enumeration fail (no
descriptor timeout, no failed configure, no mid-walk unplug) -- and a
device that never answered `newdev` returns no name, so there is
nothing to detach and nothing is.

### Tier 3 — the machine as a product

**12. The userspace on the card.** `boot-baremetal.sh` starts
`secstored`, `logon`, `luciuisrv` and `lucifer`. Against the hosted
`boot.sh` it lacks `ndb/cs` (no name resolution — which is why
secstore is dialled by number), the plumber, `mntgen`, `llmsrv` (so
`/mnt/llm` is an empty mount point), `tools9p` at `/tool` (so Veltro
has no tools), `msg9p`, `wallet9p`, `lucibridge`. Order: `ndb/cs` and
the plumber first, because everything else assumes them. The mount
points already exist in the root skeleton.

**13. Throughput.** The ledger stands: 12.4 MB/s through the wire path,
2.6 MB/s through a Limbo TCP consumer. The levers are still the two
named there — a second receive buffer so USB and parsing overlap, and
the VM on another core — but the second waits on item 2, and the
number should be re-taken once it lands.

**14. Hardware not started, smallest first.** FT5406 touch via mailbox
tag `0x0004000F` (firmware polls the controller; hardware-only, QEMU
declares the tag and ignores it). A USB storage class driver in Limbo
over `#u`, the same shape as `etherusb.b`. WiFi: CYW43455 over SDIO on
the second controller, plus a firmware blob upload — the large one; the
EMMC driver exists for SD but SDIO is different. Audio (PWM or HDMI).
Bluetooth is on the PL011 the console uses; it would mean the
mini-UART for the console first.

**15. The next board.** BCM2711 (Pi 4) needs a GIC-400 interrupt
controller, xHCI over PCIe (the VL805) and the GENET MAC. The `#u`
boundary means `etherusb.b`, `kbdusb.b` and `mouseusb.b` carry over
unchanged above a new host controller driver; XHCI is an open
specification and should be smaller than `usbdwc.c`. The Zero 2 W and
CM3+ are this SoC and should boot this kernel, minus the hub (USB OTG
only) and plus WiFi. The Pi 5 is blocked on RP1 having no public
register documentation.

### Housekeeping the review also found

Comments that now say the opposite of the code, to fix as the files are
touched: `fns.h` says four board hooks and declares five; `dat.h` says
exception entry restores x28 (it deliberately does not) and that nothing
saves FPU state (`FPsave`/`FPrestore` exist); `main.c` "one core for
now" and "not yet exercised: sched()"; `taslock.c` "secondary cores are
parked"; `notyet.c` "tcp and udp are not here yet" and "nothing installs
a screenputs"; `etherusb.b` "never run against the silicon" and "bulk
endpoint assumed to be 2"; two conflicting `config.txt` recipes in this
file (under "Working on the board" and the old bring-up item), neither
mentioning `tryboot.txt` (unified 2026-09-05); `docs/TLS-ENTROPY.md` (the pool is
hardware-fed now) and `docs/PERSISTENCE.md` (the `/usr` question is
decided: on the card). The top-level `README.md` and `QUICKSTART.md`
still describe the Pi only as a hosted Linux target.

### What was on this list before, for the record

The JIT (validated on the board), hardware bring-up, the LAN78xx driver
and PHY, `os/ip`, `#e`. All done. `#d` (`/fd`) is still absent and
nothing has needed it.
