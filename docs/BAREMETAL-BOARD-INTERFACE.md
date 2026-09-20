# What a board supplies: the bare-metal kernel's board interface

The native kernel is one kernel and, so far, three machines: a Raspberry
Pi 3B+ (`os/bcm2837`), a Raspberry Pi 4B (`os/bcm2711`) and QEMU's `virt`
(`os/virt`). Everything else —
`os/arm64`, `os/port`, `os/ip`, the libraries — is compiled from the
same files for both. This document is the contract between the shared
part and a board directory: exactly what a new `os/<board>` has to
contain before the kernel links, and what each piece is asked to do.

It is a reference, not a method. For how to go about a port — what
travels, what order to bring things up in, what emulation hides — read
[BAREMETAL-PORTING-LESSONS.md](BAREMETAL-PORTING-LESSONS.md). For what
the system is and how to run it, [BAREMETAL.md](BAREMETAL.md).

The interface was not designed. It is what was left when a second board
was compiled against the shared code and the compiler and linker said
what was missing; `os/virt/README.md`, "What the second board showed",
is the record of that. It should be read with the rule in
`os/arm64/fns.h` in mind: **a new hook is an argument for moving code
into `os/arm64`, not for widening the interface.**

## The shape of a board directory

The harness (`tests/host/baremetal_test.sh`) builds a kernel for board
`B` from:

    os/arm64/*.S  os/arm64/*.c      shared AArch64        (less $ARCHSKIP)
    $SHARED/*.c                     a family's shared drivers, if the board names one
                                    (os/bcm for the Raspberry Pis; less $SHAREDSKIP)
    os/B/*.S      os/B/*.c          the board
    os/port/*.c                     portable kernel   (less $PORTSKIP)
    os/ip/*.c                       TCP/IP
    lib*/…                          Dis VM, Tk, draw, crypto, math
    os/init/*.b, dis/…              the root filesystem, compiled in

with `-I os/B` **first** on the include path. That ordering is the whole
mechanism: shared files say `#include "mem.h"`, `"io.h"`, `"board.h"`
and get the board's. Every `.c` and `.S` in `os/B` is compiled and
linked — there is no file list to maintain — so a file that must *not*
be in the kernel (the Pi's `serialboot.*`) has to be excluded by name in
the harness.

A board directory must contain:

| file | what the shared code needs from it |
|-|-|
| `mem.h` | `BY2PG`, `BY2V`, `BY2WD`, `PGROUND`, `ROUND`; `HZ` and the tick conversions (`MS2TK`, `TK2SEC`, `MS2HZ`); `MAXMACH`; `KSTACK`; `CACHELINESZ`; `KZERO`, `KADDR`, `PADDR`; `KTZERO` (the address the image is linked at — the profiler subtracts it) |
| `io.h` | Nothing. It must exist, because shared files include it; what is in it is the board's own register map. |
| `board.h` | Declarations for what `os/port/devsd.c`, `os/arm64/screen.c` and `os/arm64/fbcons.c` call downward (below), plus whatever the board's own files share |
| `kernel.ld` | The link address, `.text.boot` first, and the symbols `_start`, `__data_start`, `edata`, `__bss_start`, `__bss_end`, `__datastash` (a `NOLOAD` region of `SIZEOF(.data)+16`), and `end` (page-aligned; the allocator's bank starts here). Copy `os/bcm2837/kernel.ld` and change the address. |
| `devtab.c` | `Dev *devtab[]`, nil-terminated: which devices this kernel includes |
| `board.c` | the hooks (next section) |

`MAXMACH` is 4 on both boards and `l.S` derives a core's number from
`mpidr_el1 & 3`; a board with more cores, or with core numbers in a
higher affinity field, has to change `l.S`, which is shared.

### Two drivers in `os/arm64` that are not every board's

`os/arm64/gic.c` (a GICv2) and `os/arm64/clockgt.c` (the generic timer,
delivered through one) are the architecture's, and two of the three
boards use them as they stand: they supply `intrinit`, `intrenable`,
`intrdisable`, `irqdispatch`, `intrdump`, `intrpending`, `clockinit`,
`secclockinit`, `microdelay`, `fastticks`, `timerset` and the rest of
rows 7, 8 and 15 below. A board using them puts `GICDREGS`, `GICCREGS`,
`Nirq`, `IRQspi`, `IRQcntpnsirq` and `IRQprobe` in its `io.h`. A board
with an interrupt controller of its own (`os/bcm2837`) names both files
in `$ARCHSKIP` and supplies those functions itself.

`probe32(addr, &v)` (`trap.c`) reads an address that may not exist and
returns -1 if it faulted, for the case where silicon and its emulator
disagree about what is there.

## What is assumed at entry

`os/arm64/l.S` is the reset path for every board. It assumes:

- Entry at `_start`, the first byte of the image, at **EL2 or EL1**
  (it drops from EL2 itself), MMU and caches off.
- **`x0` holds a device tree pointer.** It is saved to `dtbptr`;
  `confinit` reserves the blob if it lies inside the allocator's bank.
  Whether anything *parses* it is the board's business (`os/virt/fdt.c`
  does; bcm2837 asks its firmware instead).
- Any core may arrive at `_start`. Core 0 continues; the others park
  until released. A board whose firmware holds the secondaries
  elsewhere (both boards today) releases them to `secentry` instead —
  see `boardstartcpus`.
- The half megabyte **below** `_start` is free: the boot stack grows
  down into it.

## The hooks, in the order `kmain` calls them

All declared in `os/arm64/fns.h`. "Before the MMU" matters: until
`mmuinit` returns, memory is Device-nGnRnE — every access uncached,
**unaligned access faults**, and load/store-exclusive (so `lock()`,
`_tas`) faults on real silicon though QEMU permits it.

| # | call | when | what it must do |
|-|-|-|-|
| 1 | `uartinit()` | first thing | Make `uartputc` work. Nothing is initialised; do not allocate or lock. |
| | `boardname()`, `uartdescribe()` | banner | Strings. |
| 2 | `serialrecover()` | before the MMU | bcm2837: offer the way back to the serial loader. Otherwise empty. |
| 3 | `boardprobe()` | before the MMU | Earliest platform bring-up: read what firmware or the device tree has to say. Byte-wise reads only. |
| 4 | `boardbootwatchdog()` | before the MMU | Read the command line; arm a boot watchdog if this is a trial boot. `boardcmdline()` returns the command line from here on. |
| 5 | `mmuinit()` | | Build the tables and turn translation on. Also `mmuenable()` (secondaries call it), `mmuon`, `mmucaches`, `mmuramtop` (**the top of allocatable RAM — `confinit` and the trap path's sanity checks both use it**), `mmul1`, `mmumapped`, `mmutcr`, `mmumair`, `mmunormalnc`. |
| 6 | `boardlockon()` | MMU just on | Exclusives work now: board code that must not lock earlier may start. |
| 7 | `intrinit()` | allocators up | The interrupt controller. Then `intrenable(irq, f, arg, tbdf, name)` / `intrdisable` register handlers for the rest of boot. |
| 8 | `clockinit()` | after `intrinit` | Start core 0's tick at `HZ`; **must call `timersinit()` and `todinit()`** (see `clock.c` for the deadlock if it does not). Supplies `clockcount`, `clockfreq`, `clockticks`, `fastticks`, `timerset`, `microdelay`, `clockintr`. |
| 9 | `boardioprobe()` | process table up | Platform I/O bring-up that needs `print` and the allocators. virt scans its virtio slots and starts the entropy device here, **because `#c`'s init primes the random pool from `hwrandom()` shortly after.** |
| 10 | `boardclockcheck()` | in the clock probe | Cross-check `CNTFRQ_EL0` against an independent clock, if there is one. |
| 11 | `boardintrprobe()` | in the interrupt probe | Raise a device interrupt on demand and print whether a handler saw it. |
| 12 | `boardfbprobe()` | late | Framebuffer, then input. If there is a screen: `fbconsinit(&fb)`, set `screenputs = fbconsputs`, `consoleprint = 1`, `pointerbounds(w, h)`. |
| 13 | `boarddevprobe()` | after `etherdevtab.reset` has made its instances, before `#S` is bound | The devices found late: the card; a kernel network driver (fill in `etherinstance(n)`'s vtable). |
| 14 | `boardstartcpus(entry)` | in `launchsmp` | Release cores 1..`MAXMACH-1` to `entry` (`secentry`). Each finds its stack and `Mach` in its `smpboot[]` slot. Spin table on bcm2837; PSCI `CPU_ON` on virt. |
| 15 | `secclockinit()` | on each secondary | That core's interrupt-controller state and tick: **must call `timersinitmach()`** or the core ticks and never preempts. |
| 16 | `boardusblink()` | in the `usb` kproc | `addhcitype(...)` for the board's host controller; empty if none. |
| 17 | `displaywatch(void*)` | a kproc | Watch for a display arriving later; may simply return. |

And, called from devices rather than from boot:

| call | from | |
|-|-|-|
| `irqdispatch(Ureg*)` | `trap()` on every IRQ | Run the handlers; return 0 only for an enabled source with no handler (that panics). Maintain `irqorphan[]`, `nspurious`; supply `intrdump`, `intrpending`. |
| `hwrandom(p, n)` | `os/port/random.c` | Up to `n` bytes of real entropy; may return short, **must not spin**. |
| `genrandom`, `prng`, `prngtry` | libsec, `#c` | All `n` bytes, however long it takes. **Never pad** — libsec's key generators call these. |
| `boardreboot()`, `boardtryboot()`, `boardbooted()`, `boardcandidate()`, `boardwatchdogpoll()`, `boardwatchdogtick()` | `#c/sysctl`, `exit()`, `microdelay`, `clockintr` | Reset; A/B trial boot; the boot watchdog. All may be empty or a plain reset. |
| `getmacaddr(mac)` | `kmain` | An Ethernet address the *board* knows (the Pi's firmware derives one); `-1` if the network device carries its own. |
| `physuart[]`, `consuartputc` | `os/port/devuart.c` | The board's UARTs as `PhysUart`s, nil-terminated. The one marked `.console = 1` feeds `kbdq` through its `.putc`. |
| `uartputc`, `uartgetc`, `uartputstr`, `uartputx`, `uartputd`, `uartputs`, `uartlock`, `uartunlock`, `uartlockon` | everywhere, including the panic path | The polled console. Only the first two are really the board's; the rest are policy and are copies today (see below). |

## What the shared drivers call downward

Three files that were the Pi's serve any board, and ask these of
`board.h`:

**`os/port/devsd.c`** (`#S`: a disk as a file, with named ranges)

    int     sdblkpresent(void);
    uvlong  sdblknblocks(void);             /* 512-byte blocks */
    int     sdblkread(uvlong blk, void *buf);   /* one block; 0 or -1 */
    int     sdblkwrite(uvlong blk, void *buf);

`#S` refuses to attach while `sdblkpresent()` is zero, so `boarddevprobe`
must have found the disk before `kmain` binds `#S`. Requests arrive one
block at a time, under `devsd`'s own `QLock`, from process context —
and from `kmain` before the scheduler runs, so the driver must be able
to poll.

**`os/arm64/screen.c`** (what `#i` draws on, and the software cursor)

    Fbinfo* boardfb(void);      /* nil: no display */

An `Fbinfo` describes a **linear, 32-bit, XRGB** framebuffer (a 32-bit
little-endian load reads `0x00RRGGBB`): `base`, `size`, `pitch`,
`width`, `height`, `depth`, `disp`. If the device reads that memory
without seeing the CPU's caches, the board must have mapped it
non-cacheable (`mmunormalnc`).

**`os/arm64/fbcons.c`** (the kernel's text on that framebuffer)

    void    fbfill(Fbinfo*, u32int colour);
    int     fbdisplay(u32int disp);         /* select a display; <0 if there is no such */
    int     fbvoffset(u32int x, u32int y);  /* move the scanout window; returns y, or <0 */

`fbvoffset` is how the Pi scrolls without copying: its firmware can move
the visible window down a buffer taller than the screen. A board that
cannot says `-1`, and `fbcons` scrolls by copying, several lines at a
time.

## Optional pieces

- **`os/port/devaudio.c`** needs a dozen `audio_*` functions and tables
  from the board. A board with no audio leaves the file out: the
  platform's function in the harness sets `PORTSKIP="devaudio.c"`, and
  its `devtab.c` omits `audiodevtab`.
- **A kernel network driver** fills in `etherinstance(n)` from
  `os/port/etherif.h`: `attach`, `transmit`, `ifstat`, optionally `ctl`
  and `shutdown`; sets `ea`, `nif.addr`, `nif.alen`, `nif.bcast`,
  `nif.mbps`, `nif.link`; delivers received frames with `etheriqb` **from
  process context** (it may allocate). Instance 0 is `/net/ether0`;
  `osinit` notices that its address is non-zero at boot and configures
  it. `os/virt/ethervirtio.c`, `os/bcm/ether4330.c` and
  `os/bcm2711/ethergenet.c` are the examples; the last needs
  `os/port/ethermii.c`, which the others skip.
- **PCI.** `os/port/pci.c` (9front's) enumerates, sizes and places; a
  board with a host bridge supplies, per `os/port/pci.h`, the three
  `pcicfgrw*` configuration accessors, `pciintrenable(Pcidev*, f, a,
  name)` — however the bridge delivers interrupts, wires or messages —
  and `pcibusaddr(va)`, the address a device must be given to reach
  kernel memory. It sets `pcimaxdno`, calls `pciscan` and `pcibusmap`
  from its link function, and says what it found. `os/virt/pciecam.c`
  is the one that runs; `os/bcm2711/pcibcm.c` is the one that cannot
  yet. A board without PCI has `pci.c` in `PORTSKIP`.
- **Input** goes to `kbdputc(kbdq, rune)` and
  `mousetrack(buttons, x, y, isdelta)`, from process context.

## Teaching the harness about a board

A board gets a function in `tests/host/baremetal_test.sh` beside
`run_platform` (bcm2837) and `run_virt`. It sets `PLAT`, `SRC`,
`QEMUARGS`, `SERIALARGS` (which `-serial` is the console) and
`PORTSKIP`, calls `platform_flags` and `build_kernel`, and then asserts
on the boot log. `make_sd_image` and `tools/mkcard.py` make card images;
`boot_kernel` and `shell_session` boot one and type at it. Add the
board's name to `want_platform`'s default list. **Every platform's
function sets every one of those globals**, even to empty: they run one
after another in one shell, and a `SHARED` left over from the last
machine is a kernel built from the wrong files.

### A family of boards

When two boards share silicon, the shared drivers get a directory of
their own and each board builds its kernel from it: `os/bcm` beside
`os/bcm2837` and `os/bcm2711`, as upstream Inferno has `os/sa1110`
beside `os/ipaq1110` and `os/cerf1110`. The shared drivers are compiled
once per board, against that board's `io.h` — which defines the
peripheral window and the interrupt numbers and then includes the
family's register layouts (`os/bcm/bcmio.h`) — and the board's `board.h`
includes the family's declarations (`os/bcm/bcm.h`). A shared driver
names no address and no interrupt number of its own.

`BAREMETAL_BUILD_ONLY=1` stops after the link. The first thing worth
doing with a new board directory is that, repeatedly: the undefined
symbols are this document, in the order the linker found them.

## Copies that are waiting to be shared

`os/virt` has four files that are the Pi's with the Pi taken out:
`uart.c` (everything below `consuartputc` is console *policy* and
identical), most of `clock.c` (the generic timer is architectural),
`uartpl011.c` (the same part) and `mem.h`. They belong in `os/arm64`
with the pins, the clock rate and the timer routing behind hooks, and a
third board should do that move rather than make a third copy.
