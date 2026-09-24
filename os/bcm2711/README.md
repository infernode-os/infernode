# Bare-metal BCM2711 (Raspberry Pi 4B) port

The native kernel on a Raspberry Pi 4. **It has never run on one.** Every
claim in this file was established under QEMU's `raspi4b` machine, there
is no Pi 4 on the bench yet, and the second half of this file is a list
of what that means. Read it before trusting anything here on hardware.

Under QEMU it is a machine: all four Cortex-A72 cores scheduling, the
JIT, a FAT32 card mounted and the system's userspace taken from it, a
USB hub with a keyboard, a mouse and an Ethernet adapter behind it, a
framebuffer, and the Lucifer desktop.

`docs/BAREMETAL.md` is the manual for all the machines;
`os/bcm2837/README.md` is the history of nearly every line this kernel
runs. This file is only what is this board's.

## Almost none of it is new

| | lines | |
|-|-:|-|
| `os/arm64`, `os/port`, `os/ip`, the libraries | ~190,000 | every board's |
| `os/bcm` | ~14,000 | the Raspberry Pi SoCs' shared drivers: what the Pi 3 runs |
| `os/arm64/gic.c`, `clockgt.c` | ~700 | what QEMU's `virt` runs — a Pi 4's interrupt controller is a GIC-400 |
| **`os/bcm2711`** | **~2,100** | this directory — 1,600 of them two drivers of 9front's that no emulator can run |

That is the point of the arrangement (upstream Inferno's: `os/sa1110`
beside `os/ipaq1110` and `os/cerf1110`). What is here:

| file | |
|-|-|
| `io.h` | the peripheral window (`0xFE000000`), the GIC's addresses, and **the interrupt numbers**: VideoCore interrupt *n* is GIC interrupt 96+*n*; "ARMC" source *n* is 64+*n*; the timer is 30 |
| `mem.h` | the BCM2837's, but for `MAPGB` (4) and the SD controller choice |
| `random.c` | the RNG200 — a different generator from the BCM2837's |
| `emmc2.c` | the card's SDHCI controller: a second instance of `../bcm/emmc.c`, six lines |
| `ethergenet.c` | the gigabit Ethernet MAC, from 9front. **Never run**: see below |
| `pcibcm.c` | the PCIe bridge, from 9front. **Never run**: see below |
| `soc.c` | the probe for what this SoC has and the family does not |
| `intr.c` | not the controller (that is `../arm64/gic.c`), only the boot-time question asked of it |
| `devtab.c` | the device list: the Pi 3B+'s, today |
| `recover.c` | an empty `serialrecover`: there is no serial loader for this board |
| `kernel.ld`, `board.h` | the BCM2837's |

## Running it

    BAREMETAL_PLATFORMS=bcm2711 BAREMETAL_BUILD_DIR=/tmp/bm ./tests/host/baremetal_test.sh

    qemu-system-aarch64 -M raspi4b -kernel /tmp/bm/bcm2711-kernel.img \
        -serial null -serial stdio \
        -netdev user,id=n0 -device usb-net,netdev=n0 -device usb-kbd -device usb-mouse \
        -drive file=card.img,if=sd,format=raw

QEMU 9.0 or later: `raspi4b` does not exist before it. The card image
must be a power of two in size (`tools/mkcard.py card.img 256 …`). Two
`-serial`s, as on `raspi3b`: the console is the mini-UART, the second.

## What QEMU's model has, and so what has been tested

Measured on QEMU 9.2.4 (`info qtree` on a paused machine):

**Modelled:** the GIC-400, PL011, the mini-UART, the mailbox and its
property interface, the framebuffer, SDHOST, two SDHCI controllers, the
DWC2 USB controller, the system timer, GPIO, DMA, power management and
the watchdog, 2GB of RAM.

**Not modelled:** the GENET gigabit Ethernet MAC (`ethergenet.c` notices); PCIe, and therefore
the VL805 USB 3 controller **which is where a real Pi 4's four USB-A
ports are**; the RNG200; the ARM timer; thermal, and eleven other
blocks that are stubs.

Three places where the model and the silicon differ, and what the
kernel does about each — in every case it *says*, on the console, which
world it found itself in:

- **The SD card.** A Pi 4's is on EMMC2 (`+0x340000`). QEMU wires it to
  the first SDHCI controller (`+0x300000`), as if the board had a Pi 3's
  pin mux. `../bcm/emmc.c` looks at the board's controller first and
  falls back only if that one reports no card and the other reports
  one: `sd: no card on the board's SD controller; one on the OTHER…`.
  On a board that line must not appear.
- **The random-number generator.** There is none in the model, and a
  read of a register that is not there is an external abort. `random.c`
  asks first (`probe32`, `../arm64/trap.c`) and, finding nothing,
  announces **NO ENTROPY SOURCE** in capitals and hands out a labelled
  counter. On a board that line must not appear either — and if it
  does, the RNG200's address or layout here is wrong.
- **The interrupt probe.** The kernel proves interrupts work by making a
  system-timer channel match. QEMU's `raspi4b` does not connect that
  timer's interrupt to its GIC (the timer matches; nothing becomes
  pending — the kernel prints the GIC's state to show it). So the probe
  then asks the GIC to raise an interrupt by itself, which passes. On a
  board the *first* should pass; if only the second does, the interrupt
  numbers in `io.h` are wrong.

## What has NOT been tested, because it cannot be here

Everything below will be met for the first time on the board.

1. **The interrupt numbers.** They are derived from Linux's
   `bcm2711.dtsi` and agree with QEMU's wiring for the UARTs and USB,
   which work. Every other one is unexercised.
2. **The RNG200 driver.** Written from Linux's `iproc-rng200.c`. Not one
   line of it has executed.
3. **The SD card on EMMC2.** The driver is the Pi 3's Arasan driver
   pointed at a different base. EMMC2 is a different controller
   revision: its clock comes from a different mailbox clock id (12,
   assumed), it may want its 1.8V/3.3V regulator handled, and its quirks
   are unknown to this tree.
4. **DMA above 1GB — a trap QEMU cannot spring, so the kernel springs
   it on itself.** Several of this SoC's DMA masters (the DMA engine,
   the DWC2 USB controller, the mailbox) address only the first
   gigabyte; QEMU lets them reach everything; and the drivers in `../bcm`
   were written on a BCM2837, where every address is reachable. A kernel
   that ignored this would pass every check here and corrupt memory on
   a 4GB board. `../bcm/dmamem.c` is the answer, in three parts:
   `busaddr()`, the only way an address reaches a device, **panics** on
   one beyond the limit, under emulation as on a board; `dmaalloc()`
   gives memory from an arena reserved below the limit *before* the
   high memory is added; and the kernel's own allocations are taken from
   *above* the limit first (`xallocpref`), which both keeps low memory
   for devices and means that under QEMU a USB transfer's buffer really
   is unreachable and really is bounced — 750 of them on a boot to the
   desktop. What that does **not** show is that the limit is where this
   file says it is for each master, or that the bounce's copies are
   coherent with a real cache. The kernel uses memory up to `0xFC000000`;
   an 8GB board's memory above 4GB is not used.
5. **Caches and the JIT.** QEMU has no caches. The instruction-cache
   maintenance the JIT depends on was proved on a Cortex-A53; an A72 has
   a different cache hierarchy and the same code has not run on one.
6. **Wi-Fi and Bluetooth.** Same CYW43455 as the Pi 3B+, same driver,
   and the plumbing is there: the card is driven by a second instance of
   the SDHCI driver (`emmc2.c` — `../bcm/emmc.c` compiled again with a
   different base), so the Arasan is the radio's, as on a Pi 3, and the
   two run at once. **Nothing has ever answered on either.** QEMU has no
   radio, and it puts the *card* on the Arasan, so under emulation the
   EMMC2 instance falls back to the Arasan's registers and tells the
   radio's driver to keep off (`sdarasantaken`). A real EMMC2 has never
   been addressed by this code; the radio's firmware, its pins (GPIO
   34-39, ALT3, assumed the same as the 3B+) and its power enable on the
   firmware's GPIO expander (whose pin numbers differ on this board and
   have NOT been checked) are all untried.
7. **Gigabit Ethernet: a driver that has never met its hardware.**
   `ethergenet.c` is 9front's GENET driver (MIT) — the MAC, its two
   interrupt lines, its descriptor rings, and the BCM54213PE PHY over
   MDIO through `../port/ethermii.c`, 9front's too — fitted to this
   tree's `Ether`. QEMU has no GENET, so **not one line of it has run**:
   under emulation it asks whether anything is at `0xFD580000`
   (`probe32`), is told no, prints `genet: NO ETHERNET MAC…` and leaves
   `ether0` to USB Ethernet, which is what the harness checks. On a
   board it should print the MAC's revision and the board's address,
   and `osinit` will then configure it as it does `virt`'s network
   card. It was kept as close to the original as this tree allows
   precisely because it could not be tried; the file's header lists
   every difference. The ones to suspect first: the cache maintenance
   around receive buffers (9front has aligned block pools, this tree
   aligns inside `allocb`'s blocks), the interrupt numbers (GIC_SPI
   157/158 from Linux's device tree), and that the firmware has left
   the MAC's clocks on. `cat /net/ether0/ifstats` shows interrupt,
   frame and MDIO-timeout counts and the PHY's state, for that day.
8. **PCIe and the USB-A sockets: a bridge driver that has never met
   its bridge, under an xHCI driver that has run elsewhere.** The four USB-A sockets are a VL805 xHCI controller on the
   SoC's one PCIe lane. `pcibcm.c` is 9front's driver for the bridge
   (reset, link training, the outbound window at `0x6_0000_0000` —
   which `../bcm/mmu.c` now maps, with a 36-bit physical address size —
   an inbound window of the first gigabyte, MSI), plus the mailbox call
   that has the VideoCore reload the VL805's firmware after the reset.
   **None of it has run.** Under QEMU it asks (`probe32`), is told
   there is no bridge, and says `pci: NO PCIe BRIDGE…`. What *has* run
   is everything above it: `../port/pci.c`, 9front's too, enumerates
   QEMU's `virt` machine on every harness run (`../virt/pciecam.c`). On
   a board the log should show the bridge's revision, a bus listing
   with `1106 3483` on it, and the firmware's answer. To suspect first:
   the link not coming up (it prints the status register), and
   `pcibusaddr()`, which holds PCI devices to the same first-gigabyte
   DMA limit as the rest of the SoC — it panics on a buffer beyond it.
   Above the bridge is `../port/usbxhci.c`, 9front's xHCI driver, which
   **has run — on QEMU's `virt` machine, against QEMU's controller, not
   a VL805**: a hub, a keyboard behind it, a mouse and a network
   adapter, with every buffer forced through the bounce path this SoC's
   DMA limit requires (`os/virt/README.md`, "USB"). What is the VL805's
   alone is untried: its firmware load, its scratchpad buffers (QEMU
   asks for none), 64-byte contexts if it uses them, MSI through *this*
   bridge, and what it does with a transfer to a device that has been
   unplugged (QEMU's drops it silently, and the driver no longer needs
   better). MSI itself — `../port/pci.c`'s setup of it and the driver
   living on it — has run on `virt`, through the GIC's MSI frame; so
   have hot-plugging, pulling a hub with a device in it, the
   controller-reset recovery path, and isochronous output against
   QEMU's USB audio device (paced at the sample rate: a USB headset on
   this board has a driver-level path that has run, and no driver); and a USB disk, which `diskusb`
   (`os/init/diskusb.b`) serves as `/chan/usbdiskN` and mounts on
   `/n/usbN` — on this board only once the xHCI is real, since the gate
   is "the machine has an xHCI" and QEMU's `raspi4b` has none.
   `echo dump > /usb/usb/ctl` prints
   the controller's status and every port's. Under QEMU the DWC2
   controller stands in for all this; on a board the DWC2 is only the
   USB-C port, and is `#u/usb/ep1.0` — the xHCI is `ep2.0`.
9. **Two HDMI outputs.** `fbcons` and `displaywatch` already handle a
   second display (the Pi 3's DSI panel plus HDMI) through the
   firmware's display-select call. Whether a Pi 4's second HDMI answers
   to the same call has not been asked.
10. **Boot.** A Pi 4 boots from an EEPROM bootloader, not `bootcode.bin`;
   needs `arm_64bit=1` and must **not** have `enable_gic=0`; and whether
   the firmware's spin table is where QEMU's is (`0xd8`) is assumed.
   Tryboot and the watchdog are the BCM2837's code and the same block.

## A finding that is not this board's

DHCP over QEMU's emulated USB Ethernet answers about two boots in five
— measured identically on the Pi 3's kernel (2 of 5) and this one (2 of
5). The OFFER reaches the emulated adapter (seen in a packet capture)
and the bulk IN endpoint never returns it. `etherusb` then falls back to
QEMU's well-known address, which is why no harness check has ever
failed on it. Whether that is QEMU's DWC2/usb-net model or this tree's
receive path under emulation is not known; the board's receive path was
measured at 164 Mbit/s and is a different matter. The `virt` machine's
virtio network gets a lease every time.
