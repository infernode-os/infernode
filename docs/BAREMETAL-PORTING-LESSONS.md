# Lessons from the first bare-metal port, for whoever does the next

The BCM2837 port (`os/bcm2837`, `os/arm64`, `os/port`) took Inferno from
nothing to a Raspberry Pi 3B+ that passes acceptance batteries for
Ethernet, Wi-Fi, Bluetooth, GPIO and audio.
[os/bcm2837/README.md](../os/bcm2837/README.md) is the chronological
record, three thousand lines of it. This document is the other thing:
what a port to **any other hardware** should take from it. It assumes
nothing about the target. Another Raspberry Pi, a different ARM64 SoC, a
RISC-V board or an x86 machine will each keep a different share of the
tree, and section 1 is a way of working out which share before writing
code. Most of what follows is about the kernel and about method, and
holds wherever the port goes.

Every claim here has an issue or a commit behind it. Where a number is
given it was measured on the bench, and the measurement is named.

Companion documents: [PLAN9-C-UNDER-OTHER-COMPILERS.md](PLAN9-C-UNDER-OTHER-COMPILERS.md)
(what clang does to Plan 9 C; eight entries, all of which travel),
[BLUETOOTH.md](BLUETOOTH.md), and [tests/acceptance/README.md](../tests/acceptance/README.md).

## 1. Working out what travels

The tree is layered so that this question has an answer per directory.
Sort the target's hardware into four kinds and the answer follows.

| kind | lives in | travels when |
|---|---|---|
| Portable kernel: scheduler, allocator, namespace, devices with no hardware under them, the IP stack, the Dis VM | `os/port`, `os/ip`, `libinterp` and the libraries | always. Section 2 is about the faults found here, and they go wherever the code goes |
| Architecture: MMU, exception vectors, context switch, cache maintenance, SMP bring-up, the JIT back end | `os/arm64`, `libinterp/comp-*.c` | the target shares the instruction set. A new architecture needs a new directory of the same shape, and a JIT back end or the interpreter alone |
| SoC blocks: interrupt controller, timers, UARTs, GPIO, SD host, DMA, mailbox, display | `os/bcm2837` | the target has the same block, which is a fact about the silicon vendor's reuse, not about the board's name. Expect the base address and the pin mux to move even then |
| Devices behind a bus: the Ethernet MAC, the Wi-Fi/Bluetooth combo chip, USB devices | drivers in `os/bcm2837` and `os/port`, protocol in Limbo (`os/init/etherusb.b`, `appl/cmd/bt9p.b`, `wpa.b`) | the same part is fitted, on any bus the target can drive. The Limbo halves travel with no change at all |

Two design decisions make the last row cheaper than it looks, and a new
port should keep them. Device *protocols* live outside the kernel, in
Limbo, with only mechanism inside (the README's "Decision" sections give
the argument). And every device is a file tree, so a new driver that
serves the same files is invisible to everything above it: the batteries
in `tests/acceptance` run unchanged against a different NIC.

Before starting, fill in this list for the target. Each line was a
surprise on this port or would have been on the next.

- **Interrupt controller.** Which one, and do its mask registers have
  set/clear pairs (2.1)?
- **How each high-rate device is attached.** On the SoC with DMA rings,
  or behind a host controller? Section 3 is what "behind USB 2" cost.
- **DMA reach.** Can every device address all of RAM? If not, bounce
  buffers or a zoned allocator come before the first driver that needs
  them, not after.
- **Cache coherency for DMA.** Hardware-coherent, or maintained by the
  driver (2.2)?
- **Pins shared between controllers.** The 3B+ has two SD controllers and
  one can reach the radio's pins, which decided where the card went.
- **What the boot firmware leaves running.** Clocks, pin mux and a
  framebuffer inherited from firmware are state nobody wrote down.
- **What the emulator models.** QEMU carried this port a long way and
  was wrong about interrupts, timing and every USB corner that mattered.
  List what it cannot tell you (README, "QEMU vs real hardware").
- **How a bad kernel is recovered without hands** (section 4).

### One illustration: a Raspberry Pi 4

Offered only to show the method on a concrete case. It is not a plan,
and a different target will sort differently.

| subsystem | 3B+ | Pi 4 | carries? |
|---|---|---|---|
| CPU, MMU, SMP, scheduler | Cortex-A53 | Cortex-A72, same ARMv8-A | yes |
| interrupt controller | BCM2836 local + legacy | GIC-400 | no: new driver |
| Ethernet | LAN7515 behind USB 2 | MAC on the SoC, DMA rings | no: new driver, and section 3's class of problem does not arise |
| USB host | DWC2 | xHCI behind PCIe | no: the largest new piece |
| Wi-Fi / Bluetooth | CYW43455 | the same part | yes |
| SD card | SDHOST | a second SDHCI | mostly |
| GPIO, UARTs, PWM audio, mailbox, framebuffer | BCM2835 blocks | the same blocks at a new base | yes |
| DMA reach | all of RAM | legacy blocks reach the low 1 GB only | new constraint |

## 2. Lessons that are about the kernel, not the board

These will be met again on any multi-core ARM64 target.

### 2.1 A register shared by several channels needs a lock; `splhi` is not one

`usbdwc` wrote `haintmsk`, one bit per host channel, read-modify-write
from whichever core started a wait and from the interrupt handler
clearing the bit of the channel it was waking. A handler that read the
register before a waiter's store and wrote after it erased the bit just
set. That channel then completed without interrupting, and its waiter
slept out the full 200 ms timeout. The driver this one descends from
holds a lock there; the port had dropped it because `splhi` "was already
held". `splhi` stops the local core only.

How it showed: a bulk OUT measured at 199937 us, the timeout to the
microsecond, and TCP retransmission timeouts with no loss to explain
them. How to look for the next one: any register with per-unit bits
(interrupt masks, enable sets, GPIO function selects) written from more
than one context. Hardware with separate set and clear registers is
immune by design, and a good interrupt controller has them; older
peripheral blocks usually do not. (commit d953155ec, #633)

### 2.2 Cache maintenance goes on both sides of a receive DMA

`epread` cleaned and invalidated the bounce buffer before the transfer
and did nothing after it. While the buffer was armed for a microframe
nobody noticed. Once it stayed armed for up to 200 ms, lines of it were
loaded in the window (a prefetcher running off a neighbouring block is
enough) and were clean, valid and stale when the device wrote beneath
them: 91 framing errors, 6 ICMP checksum errors and one echo request
answered twice in 2200 frames. The rule for a device-to-memory transfer
is clean before, invalidate after, unless the platform's DMA is
hardware-coherent. A descriptor-ring NIC keeps its buffers armed
indefinitely, so there the long window is the normal case from the first
packet, not a corner. (commit d953155ec)

### 2.3 A preempted process resumes on the core it was taken from

clang copies `m` (x28) into a scratch register before loading `up`, and
the trap path restores everything but x28. A process interrupted between
those two instructions and resumed on another core reads the old core's
`Mach`. It was caught in `tsleep`: two reads of the same field in one
statement, two answers. `-ffixed-x28` cannot prevent the copy, so
`schedinit` pins a preempted process for one resume (`samecore`).
(#622; entry 1 of the compiler document)

### 2.4 A spinning `lock()` must yield, or the pin in 2.3 becomes a deadlock

With `samecore` in place, a lock holder preempted on core A could not run
elsewhere, and a spinner at equal priority on core A never let it back
in: "lock loop ... held by pc 0x0". The spinner now calls `sched()` every
1024 spins (every spin on one core). Bisection by halves found nothing
because the fault was in the interaction, not in either change.
(commit fdb73fd8f)

### 2.5 `hzclock` preempts for equal priority only

`anyready()` tests the current priority's run queue alone. A kproc raised
above normal priority does not preempt a normal one at the tick. Raising
a driver kproc's priority to fix latency will therefore not work as it
stands, and measuring showed it was not needed: every interrupt-to-waiter
wake on the bulk IN was under 100 us.

### 2.6 Width: the constant that did not follow `ulong` to 64 bits

`#define NOPC 0xffffffff` compared against `(ulong)-1` never matched on
LP64, so an exception block with no matching clause was taken as a
handler at pc -1. It was killing the board daily (#635). The emulator's
copy of the same file had been fixed five months earlier, which is 2.7.

### 2.7 Two copies of one file are two bugs

`os/port` began as a copy of `emu/port` on 2026-08-24, 26 files in
common. Fixes landed in one and not the other in both directions: the
NOPC fix, a constant-time digest compare in `devssl`, the read-only
namespace enforcement for Veltro, `statcheckbuf`. #640 reconciled them
by three-way merge with the copy point as base. A new port should share
source with `#ifdef` where it must differ, not copy.

### 2.8 What is switched off for debugging stays off until someone looks

The "memory leak" of #641 was two things: the acceptance battery's own
source loop, and `freetypecode()` having been stubbed out during the #635
hunt so that JIT-compiled type code was never freed. Every diagnostic
disablement needs an issue that outlives the hunt it served.

## 3. A case study: the Ethernet receive path on the 3B+ (#633, #610)

This section is specific to one board, and is kept in full for two
reasons. Any target whose NIC sits behind a host controller, or has a
small FIFO, will meet the same shape of problem. And the way it was
found, by reading the device's own counters and eliminating hypotheses
by measurement, is the part that travels everywhere.

Inbound TCP ran at 7 to 32 Mbit/s against about 115 outbound for weeks.
It is now 164 in and 143 out at 1000 Mb/s. The frames were being dropped
**inside the LAN78xx**, which is why no counter above it showed loss.
The part's receive FIFO is 12 KB (`FCT_RX_FIFO_END` = 0x17, the hardware
maximum), one millisecond of a 100 Mb/s wire.

| fault | evidence | fix |
|---|---|---|
| Each empty bulk IN ended on the first NAK and the reader slept a tick with nothing posted | UDP bursts of 4: 0 of 3000 lost. Bursts of 10: 361 lost, all in the chip's `rx dropped frames` | wait on `Chhltd` alone; the DWC2 retries NAKs in hardware and interrupts only on completion, as upstream always did |
| the `haintmsk` race of 2.1 | a 199937 us bulk OUT | `ilock` in both writers |
| no invalidate after DMA, 2.2 | 24% ping loss once reads stayed armed | invalidate after |
| no TCP SACK | Linux sender, 16 MB: 24 RTOs, 22 Reno failures, about 250 needless segments | receiver-side RFC 2018, plus an immediate ACK when a hole fills (RFC 5681 4.2) |
| `BULK_IN_DLY` of 4 ms | swept live: 42-58 Mbit/s at 4 ms, 70-90 at 1 ms and below | Linux's 1 ms |

Eliminated by measurement, so nobody tries them again: 802.3x pause
(implemented and advertised, but this bench's switch advertises
asymmetric pause only and ignores ours); re-posting the read at once
while still waking on NAK (an interrupt storm: 7-12 Mbit/s in, 26 out);
record desyncs in the unwrapper (one per 16 MB); scheduler latency (2.5).

**The residual limit.** At 1000 Mb/s the part still drops about 1.5% of a
burst, because USB 2 cannot drain as fast as the wire fills 12 KB. TCP
recovers through SACK without timeouts. Fragmented datagrams cannot: one
lost fragment loses the datagram.

| echo size | fragments | 1000 Mb/s | 100 Mb/s |
|---|---|---|---|
| 4000 | 3 | 20/20 | |
| 20000 | 14 | 20/20 | |
| 40000 | 28 | 7/20 | 20/20 |
| 60000 | 41 | 0-1/20 | 19/20 |
| 65000 | 44 | | 20/20 |

The stack reassembles correctly; the large sizes fail in the chip (226
`rx dropped frames` in one run of 40). A switch that honours pause would
be expected to close this. Gigabit is kept because nearly everything on
this system is TCP. To hold a board to 100 Mb/s, clear bits 9:8 of MII
register 9 before restarting autonegotiation in `lanphy()`.

What generalises: **TCP without SACK is not a finished TCP** on any link
that drops in bursts, and the stack's SACK is now in `os/ip/tcp.c` for
every port. And a NIC's own statistics block is the first thing to read,
not the last.

## 4. Instruments that paid for themselves

Build these early on a new board. Each found something nothing else did.

- **A/B kernel boot** (`tryboot.img`, a one-shot flag, the watchdog, and
  `/dev/bootimage` to verify by size what is actually running). A bad
  kernel costs a reboot, not a card pull. Promote only after the
  candidate answers on its own console.
- **A network console** with a token (`netshell`, tcp 17010) beside the
  serial one. Sessions are separate namespaces; a loop started with `&`
  dies with its session, so a soak holds one connection per loop.
- **`/dev/memtags`**: live main-pool blocks by allocating PC. It turned
  #641 from a theory into a list of call sites in one read.
- **`lan78stats`**: the NIC's statistics block, and `reg addr [value]` to
  read or write device registers on a live link. The bulk-in delay sweep
  and the gigabit retest took minutes, against six per point by reboot.
  Any NIC driver should expose the same two things as files.
- **Histograms, not means**, where a buffer is a millisecond deep:
  `echo rxstats > /net/ether0/clone` and `echo dump > /usb/usb/ctl`. The
  mean read cost was fine throughout; the 200 ms outliers were the fault.
- **Detectors left in the kernel**: the Type-reference checks, the
  error-stack guards, the scheduler soak. They are the oracle for "has
  #622 come back", and they cost nothing measurable.
- **Acceptance batteries with a tester beside the board**
  (`tests/acceptance`), following a published method where one exists
  (RFC 2544 for Ethernet). A battery line is SKIP with a reason, never a
  silent pass.

## 5. The test rig lies too

A third of the "board bugs" in this campaign were the tester.

- The Jetson's IP fragments reach no wired host, not even its gateway.
  #633's "fragments are not answered" was that. The battery now checks
  the tester first and takes `--frag-via HOST`.
- BlueZ reports `EBUSY`, `ECONNREFUSED` and `ECONNRESET` from its own
  session teardown during an RFCOMM reconnect storm. The board's refusal
  counter in `/net/bt/status` read zero throughout (#632).
- `bluetoothd` keeps a stale "Connected" after a killed run and the next
  battery inherits it; `l2test -z` hangs on this tester's kernel.
- The "leak" of #641 was in part the battery's own `while` loop.

The rule that came out of it: give the board a counter for the thing the
tester is accusing it of, and read that before believing either side.

## 6. Order of work that would have been faster

1. Serial console, then A/B boot and the network console, before any
   driver work. Every later step is cheaper for it.
2. SMP and preemption under a scheduler soak before anything concurrent
   is debugged on top. #622 and #635 disguised themselves as faults in
   Ethernet, Bluetooth and the JIT for a fortnight.
3. For each device: the driver, its statistics as files, then its
   battery, then throughput. "Work on getting tests passing before
   optimising anything for speed" was the right call every time.
4. A multi-day soak with load on every path, including network receive,
   as the release gate.
