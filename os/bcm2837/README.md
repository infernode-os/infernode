# Bare-metal BCM2837 (Raspberry Pi 3B+) port

Tracked as **INFR-404**. This is InferNode running *native* — as the
firmware on the board, with no host OS underneath — rather than *hosted*,
which is what everything under `emu/` does.

Status: **there is a shell, networking, and a JIT.** The system boots to
an interactive prompt, runs pipelines and command substitution as
JIT-compiled AArch64, answers pings and completes TCP connections over
its own IP stack, and enumerates the USB bus end to end.

Working:

- boot, secondary-core parking, EL2 → EL1, PL011 console
- AArch64 exception vectors, ESR decoding, register dump on fault
- MMU with an identity map, caches on, correct memory attributes
- VideoCore mailbox; framebuffer, verified pixel-exact; GPIO
- ARM generic timer at 100Hz; device interrupts through the VideoCore
  controller, asserted at boot rather than assumed
- `xalloc`, the pool allocator (`malloc`/`free`), Blocks
- the scheduler: process table, context switch, blocking locks
- namespace: channels, path composition, process groups, the root
  device, `kopen`/`kread`/`kwrite`/`kbind`
- a console on `/dev/cons`, `#p` (processes), `#|` (pipes)
- the Dis VM, and the **JIT**: 27× the interpreter, bit-identical results
- an interactive shell: pipelines, command substitution, `for` loops
- **`os/ip`**: ICMP and TCP over loopback, route table, `ptclbsum`
- **USB**: `#u`, the DWC OTG host stack, and enumeration through a hub
  to the CDC Ethernet device behind it

Not done: no packet has yet been sent or received on a real network —
that needs the class driver described under "Decision: device protocols
live outside the kernel, mechanism inside". And **nothing here has run
on real hardware**; everything above is QEMU. The JIT in particular is
not accepted until it has, because TCG does not model split I/D caches,
so missing icache maintenance is invisible in emulation.

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
is an addition rather than a rewrite. **That last step is no longer the
plan** — see "Decision: device protocols live outside the kernel,
mechanism inside" below. `usbdwc.c` and `devusb.c` were imported;
`etherusb.c` will not be, because it is an in-kernel `Ether` driver and
that layer is now a program.

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
- **To write:** a Dis program speaking CDC (for QEMU's `usb-net`) and
  LAN78xx (for the board), serving the ether interface sketched above.

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

### Networking works, intermittently (open)

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

`serialboot` lives on the card and pulls the kernel over the UART on
every reset -- see the commit that added it. The loop is: build, send
(about a minute for 618KB at 115200), watch. `reboot()` is implemented
via the watchdog, since this SoC has no reset line, so once the
console accepts input the loop needs nobody at the power switch.

The `config.txt` recipe that works, with `init_uart_clock` pinned
because uart.c divides for 115200 assuming 48MHz and the firmware, not
the kernel, decides what that reference is:

    kernel=serialboot.img
    arm_64bit=1
    dtoverlay=disable-bt
    init_uart_clock=48000000

`infernode8.img` is kept alongside as a fallback: swapping the
`kernel=` line boots a kernel directly, without a host feeding one.

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
  assignment (the ep stayed inuse until process exit). The handoff
  closes by sys->dup of #c/null over the descriptor, which replaces
  the chan inline. WHY the destructor is late is an OPEN QUESTION that
  implies every dropped fd on this kernel leaks until its process
  exits.

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
unobservable through a Limbo endpoint); genrandom's appetite; the
per-packet first-halt in singleshot transfers (2 channel ops per
transfer could be 1 if the fresh-channel Chhltd|Ack halt has a
register cause); and the GC/scheduler costs that INFR-404's earlier
collector work already halved once.

### OPEN: residual ~0.02% framing desync under burst

Down from ~0.5% at the start of the hunt: the NAK race, the stale
post-halt interrupt word, and the per-packet timeout chaos each fed
it. What remains is a handful per tens of thousands of frames,
TCP-healed, byte-verified end to end. Resume with the byte-capture
probe in devether.c's used<0 branch, never with theories.

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

**1. The JIT — done in emulation, hardware validation outstanding.**

Dis is compiled to AArch64 rather than interpreted. Measured on the
same kernel, differing only by `-DCFLAG=0`:

    JIT:    2000000 iterations in   80 ms (acc=1048429888)
    no JIT: 2000000 iterations in 2160 ms (acc=1048429888)

**27×**, against 10× measured for the same code generator in the hosted
emulator on an M-series Mac. That direction was predicted and the
reason holds: `xec`'s inner loop costs two indirect calls per Dis
instruction, and an in-order Cortex-A53 cannot hide them the way an
out-of-order core does. 12/12 clean boots; the shell, pipelines and
command substitution all run as compiled code.

The suite checks two things that are not the same: that compiled code
computes the **same answer** as the interpreter, bit for bit, and that
it is faster. A JIT that is merely fast is a miscompilation waiting to
be found. The interpreter stays the reference, so any disagreement is
bisectable against it.

`comp-arm64.c` gained an `INFERNO_NATIVE` arm beside the `APPLE_JIT`
one it already had. Its only host dependencies were `mmap(PROT_EXEC)`
and an icache flush; this kernel maps all RAM without PXN/UXN so
`malloc()` returns executable memory, and `cacheiflush()` is
CTR_EL0-driven.

**Still gated on hardware.** QEMU's TCG does not model split I/D
caches, so a JIT that skips its icache maintenance works perfectly in
emulation and executes stale instructions on a Cortex-A53. Acceptance
is not complete until JIT-generated code has run on the board.

*Two harness bugs it exposed, both stale build state:* libinterp ships
ten `comp-*.c` files each defining `compile()`, and excluding only
`comp-amd64.c` left the linker free to pick `comp-68020.c` — so the
first time `cflag` went above zero, the kernel compiled a Dis module
with a 68020 code generator and branched into it. Then, after
narrowing the build, it *still* did: `ar r` replaces and adds members
but never removes one, so the stale object was still in `libkern.a`.
That is the third time on this branch that stale build state has
produced confident wrong behaviour.

*And a real kernel bug,* found stress-testing the JIT through the
shell: a backquote substitution killed the machine with
`panic: devno | 0x7c`. `kpipe()` reached `devtab` through
`devno('|', 0)`, and `devno` panics on a miss when `user == 0` — so any
Limbo program calling `sys->pipe()` on a kernel without `#|` took the
system down. Both halves fixed: `#|` imported, and a missing device is
now an error to the caller rather than a panic.

**2. Hardware bring-up.** The card needs a FAT32 partition holding the
Broadcom blobs (`bootcode.bin`, `start.elf`, `fixup.dat` from
raspberrypi/firmware), a `config.txt`, and this kernel named
`kernel8.img`:

    BAREMETAL_BUILD_DIR=/tmp/bm ./tests/host/baremetal_test.sh
    cp /tmp/bm/bcm2837-kernel.img /Volumes/<card>/kernel8.img

`config.txt` wants four lines:

    arm_64bit=1
    enable_uart=1
    dtoverlay=disable-bt
    init_uart_clock=48000000

The last one is not optional here even though it is often described as
a default. `uart.c` divides for 115200 assuming a 48MHz reference --
IBRD 26, FBRD 3, which is 48000000/(16*115200) = 26.04 -- and the
firmware, not the kernel, decides what that reference actually is. If
it differs, the divisor is wrong by the same ratio and the console
produces framing errors and garbage rather than nothing, which reads
as a broken kernel rather than a misconfigured clock. Pinning it costs
one line.

The third is the one that costs an afternoon if it is missing. On a Pi
3 the PL011 is wired to Bluetooth by default and the mini-UART is on
the header instead -- so the console comes out of a different device at
a different clock, and the symptom is a board that boots to silence.
`kernel.ld` links at 0x80000, which is where the boot ROM loads
`kernel8.img` in 64-bit mode, so no `kernel_address` is needed.

Console is a 3.3V USB-serial adapter on GPIO 14/15 (pins 8 and 10),
ground to pin 6. **Not 5V**: the Pi's GPIO is not 5V tolerant.

Two things are known to be untested on hardware and are the first to
watch. The JIT has never run on a real Cortex-A53, and QEMU's TCG does
not model split I/D caches, so missing icache maintenance is invisible
in emulation and would present as executing stale instructions. And
every USB finding on this branch is against QEMU's DWC model; the
board's controller is the real thing behind a real high-speed hub, so
the split-transaction paths that never execute under emulation will
execute there.

**3. USB — a class driver exists; LAN78xx is unvalidated.** The RNDIS
family works end to end under QEMU. The LAN78xx family, which is what
the 3B+'s LAN7515 actually speaks, is written but **has never been run
against the silicon**, and its register map came from knowledge rather
than from a datasheet on the desk. It is built to fail loudly rather
than half-work: `lansetup()` reads ID_REV first and refuses a device
that answers 0 or all-ones, and refuses again if the MAC reads back as
all zeroes, because a NIC that is misprogrammed comes up and silently
carries nothing.

The PHY is not done. Link needs the internal PHY brought up and
auto-negotiation completed through MII_ACC and MII_DATA, which is more
than a handful of writes; the driver says so on the console rather
than leaving it to be inferred from a dead interface.

**3a. The old item, for reference —** The 3B+'s
LAN7515 sits behind USB, so a DWC2 host stack gates wired Ethernet
*and* WiFi. `usbdwc.c` and `devusb.c` are imported and the bus
enumerates end to end under QEMU: root hub, a real hub addressed and
interrogated over the wire, and the CDC Ethernet device behind it.

The design decision this item used to be waiting on is made and written
up — see "Decision: device protocols live outside the kernel, mechanism
inside". The class driver is a Dis program, not `etherusb.c`. Remaining:
`ethermedium.c` and `chandial.c` into `os/ip`, then the program itself,
speaking CDC against QEMU's `usb-net` and LAN78xx against the board.

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
root, cons, prog and pipe, so there is still no `/env` (`#e`) and no
`/fd` (`#d`). `sysfile.c:514` reaches the mount device through
`devno('M', 0)` — the same panic-on-miss hazard `#|` had, harmless only
while nothing mounts anything. `sprint()` in `devcons.c` still assumes
every caller's buffer is `PRINTSIZE` while `os/port/dev.c:105` hands it
a `smalloc(4+strlen(spec)+1)` — it fits today and will not survive the
first longer format.
