# Bare-metal QEMU `virt` port

The same native kernel as `os/bcm2837` — `os/arm64`, `os/port`, `os/ip`
and the libraries are compiled from the same files — on the machine QEMU
invented for guests that do not care what they run on. No Raspberry Pi is
involved and none is needed: this port exists so that the bare-metal
kernel can be built, booted and tested on any machine that has QEMU,
including CI.

[docs/BAREMETAL.md](../../docs/BAREMETAL.md) is the manual for both
machines — how to build, run and control them. `os/bcm2837/README.md` is
the history and the reasoning of the kernel. This file is only what is
different here.

## What it is for, and what it is not

Three things `-M raspi3b` cannot be:

- **A machine with a network card and a disk that need no USB stack.**
  QEMU's Pi model has no NIC at all, so under emulation the board's
  kernel has only ever had a USB one. Here Ethernet and the card are
  virtio queues; everything above the driver — `os/ip`, DHCP, dossrv, 9P,
  the desktop — runs at host speed, and "is `os/ip` slow or is the bus
  slow" has an answer.
- **The architecture's interrupt controller.** A GICv2, which is what a
  Pi 4 has (GIC-400) and what nearly every other 64-bit ARM board has.
  `gic.c` is that driver, written and tested before such a board is on
  the bench.
- **A second machine.** A bug on both is in `os/port` or `os/arm64`; a
  bug on one is board code. It is also what finds out which lines of
  `os/arm64` were really the BCM2837's — see "What the second board
  showed".

What it is **not** is evidence about the board. Nothing here has timing,
a cache, a bus that can NAK, DMA that needs invalidating or a card that
wears. A fix proved only here is proved for software. The bcm2837 harness
and `tests/acceptance` remain what says the Pi works.

## Running it

Built by `tests/host/baremetal_test.sh`, like the board's, and for the
same reason (`os/bcm2837/README.md`, "Building"):

    BAREMETAL_PLATFORMS=virt BAREMETAL_BUILD_DIR=/tmp/bm ./tests/host/baremetal_test.sh

leaves `/tmp/bm/virt-kernel.img` (and `.elf`, for symbols). By hand:

    qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 1024 \
        -kernel /tmp/bm/virt-kernel.img -nographic \
        -device virtio-rng-device \
        -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
        -drive file=card.img,if=none,format=raw,id=sd -device virtio-blk-device,drive=sd

and for a screen, drop `-nographic` and add

        -device ramfb -device virtio-keyboard-device -device virtio-tablet-device -serial stdio

`Ctrl-A x` leaves a `-nographic` QEMU.

`card.img` is a Raspberry Pi's card: same partition table, same trees,
same `rootpath`. `tools/mkcard.py` builds one from this tree, with no
root and no mtools:

    printf 'local\n' > /tmp/rootpath; : > /tmp/skiplogon
    tools/mkcard.py card.img 192 /dis=dis /lib=lib /fonts=fonts /icons=icons /usr= \
        /rootpath=/tmp/rootpath /skiplogon=/tmp/skiplogon

Booted with a screen, that card comes up in the Lucifer desktop, by the
road the board takes: `osinit` mounts the FAT partition through `#S` and
dossrv, `rootpath` unions the card's `dis/`, `lib/`, `fonts/` and
`icons/` over the kernel's recovery root, and `/lib/sh/profile` runs
`boot-baremetal.sh`. Leave `skiplogon` out for the login screen.

Every one of those choices has a way to go wrong that says nothing:

| | |
|-|-|
| `-cpu cortex-a53` | `-M virt` defaults to cortex-a15, a **32-bit** CPU, even under `qemu-system-aarch64`. An AArch64 kernel on it prints nothing at all. A53 is also the board's core, so the JIT emits for the same part. |
| `-kernel …img`, not `.elf` | QEMU passes the device tree in `x0` only to a flat image (the Linux boot protocol). Given the ELF it loads and runs it with no tree; the kernel says so. |
| `virtio-*-device` | The MMIO transport, which `virtio.c` drives. `virtio-net-pci`, and whatever `-drive if=virtio` makes, are PCI devices on a bus this kernel does not walk. |
| `-device virtio-rng-device` | The kernel's entropy. Without it the kernel boots, says **NO ENTROPY SOURCE** in capitals, and every key it makes is predictable. |
| `-smp 4` | `MAXMACH` is 4, as on the board. With fewer, the missing cores are reported as not answering. |
| `-device qemu-xhci` (or `nec-usb-xhci`) | Optional, and a PCI device: the only kind on this machine that is. `-device …-pci` anything is found by the bus scan; only what has a driver does anything. |
| GICv2 | virt's default up to eight cores. With `gic-version=3` there is no memory-mapped CPU interface; `intrinit` says so. |

`-append "fb=1024x768"` sets the screen size; the default is 1280x720.
`-global virtio-mmio.force-legacy=false` gives modern virtio transports;
both kinds work and the boot log says which each device is.

## What is here

| file | |
|-|-|
| `mem.h`, `kernel.ld` | RAM starts at `0x40000000`; the image loads `0x80000` above it |
| `io.h` | the memory map (it is *below* RAM) and interrupt numbers |
| `mmu.c` | identity map: `[0,1GB)` Device, `[1GB,ramtop)` Normal, the rest unmapped |
| `fdt.c` | just enough device tree: memory size, `/psci` method, `/chosen/bootargs` |
| `../arm64/gic.c` | GICv2: distributor, per-core CPU interface, `intrenable`, `irqdispatch`. Written here; moved when a Raspberry Pi 4, whose controller is a GIC-400, needed it |
| `../arm64/clockgt.c` | the generic timer, per core, on PPI 30. Likewise |
| `uart.c`, `uartpl011.c` | the PL011: polled console, and `#t`'s `eia0` with receive interrupts |
| `board.c` | the hooks in `../arm64/fns.h`; PSCI (SMP, reset, power off); the PL031 RTC |
| `virtio.c`, `virtio.h` | the MMIO transport (legacy and modern) and virtqueues |
| `random.c` | `hwrandom` from virtio-rng, polled; RNDR if the CPU has it |
| `blkvirtio.c` | the blocks under `#S` (`../port/devsd.c`) |
| `ethervirtio.c` | `/net/ether0`, as `devether`'s instance 0 |
| `ramfb.c` | a linear framebuffer, configured through fw_cfg, under `../arm64/screen.c` and `fbcons.c` |
| `inputvirtio.c` | keyboard and tablet to `kbdputc` and `mousetrack` |
| `pciecam.c` | the PCIe host bridge: configuration space as an array in memory, four interrupt wires. `../port/pci.c` (9front's) does the enumeration; `../port/usbxhci.c` and `usbxhcipci.c` are the one driver on the bus |
| `devtab.c` | the device table: the board's, less GPIO, touch and audio |

## USB, and why it is here

    -device qemu-xhci -device usb-hub,port=1 -device usb-kbd,port=1.2 \
        -device usb-mouse,port=2 -netdev user,id=u0 -device usb-net,netdev=u0,port=3 \
        -drive if=none,id=ud,file=card.img,format=raw -device usb-storage,drive=ud,port=4

`../port/usbxhci.c` is 9front's xHCI driver, and this machine is where
it has run: every harness boot initialises the controller, and one
boots the line above — a hub, a keyboard *behind* the hub, a mouse and
a network adapter — and types on the keyboard, pings through the
adapter, and reads the controller's state back.

It is here for the Raspberry Pi 4, whose USB-A sockets are a VL805 xHCI
controller behind a PCIe bridge that QEMU's `raspi4b` does not have.
Three things were wanted of this machine for that:

- **The driver, run.** It found a bug on its first hub: 9front issues
  Configure Endpoint with the ep0 flag set when it tells the controller
  a device is a hub; the specification says that flag must be clear
  (4.6.6), real controllers evidently let it pass, and QEMU's answers
  TRB Error. Linux sends the slot flag alone, and now so does this.
- **The rest of the tree made ready for it.** This tree's `devusb` is
  Plan 9's, which addresses devices by number; an xHC routes by
  topology. `devusb.c` now computes a device's route string, root port
  and TT hub (9front's arithmetic, in `settopology`), takes `hub N ttt
  mtt` as well as `hub`, and has two hooks (`devclose`, `hubupdate`)
  that are nil for the Pi 3's DWC OTG. `osinit`'s walker, which knew one
  root hub with one port because a Pi 3 has exactly that, walks every
  port of every controller.
- **Things plugged in and pulled out.** On a Pi 4 the sockets are root
  ports, and every device in the boot above was there from the start.
  The harness now plugs a hub into a root port, a keyboard into the
  hub, types, and pulls the *hub*; then the same with a keyboard in a
  root port; with a mouse that must sit through it all. It found four
  things, none of them QEMU's fault and two of them not xHCI's:
  - a driver asleep in a read of an interrupt endpoint has no timeout,
    and an xHC does not end a transfer because the device left: it
    slept for ever holding the endpoint, the device and the slot.
    `devusb` now asks the controller to stop a detached device's
    endpoints (`epstop`, 9front's, which had been folded away);
  - 9front's driver, when a transfer times out, stops the endpoint,
    waits five seconds more, and then **resets the controller** — and
    waits for every device on it to be unplugged. A control request in
    flight to a pulled hub did that to the whole bus. A stop command
    that succeeds and wakes nobody now means the transfer is gone, and
    only that (`waittd`);
  - *(the walker's)* a pulled hub's watcher polled
    the dead hub for ever, holding its endpoint, and never told devusb
    that what was plugged into it had gone;
  - *(likewise)* a device plugged in **while a hub was being walked at
    boot** was never enumerated: the walk had passed its port, the
    watcher's first look found it already there, and "there, as
    before" is not a change. The watcher now starts from what the walk
    saw.

  The last two are in `osinit`'s walker, which a Pi 3 runs too, and are
  as true there in principle. **They are fixed only on a machine that
  has an xHCI** (`havexhci`): the Pi 3 is in production on the watcher
  it has, the first of the two *detaches devices* on the strength of
  failed status reads — on a 3B+ the hub being judged carries the
  Ethernet — and nobody has measured on a board how often those reads
  fail. #679 has the reproduction and what trying them there would
  take.
- **A USB disk** (`os/init/diskusb.b`: mass storage, bulk-only, SCSI —
  a program, like the other USB class drivers). `usb-storage` above is
  the card image again, as a stick: the driver reads INQUIRY and the
  capacity, serves the disk as `/chan/usbdisk0` and mounts its FAT on
  `/n/usb0` for init; the harness then mounts it in the shell (`dossrv
  -f /chan/usbdisk0 -m /n/usb0`), reads `HELLO.TXT`, writes a file,
  reads it back, and checks the bytes reached the image. Every transfer
  goes through the bounce path. It has met QEMU's disk and no other.
  Gated to machines with an xHCI: a Pi 3 names the disk and leaves it.
- **The Pi 4's interrupts.** Its bridge delivers nothing but messages
  (MSI). `pciecam.c` gives a device that has the MSI capability one —
  an interrupt of the GIC's MSI frame (GICv2m), made edge-triggered
  with `gicedge()` — and a wire otherwise. `qemu-xhci` has only MSI-X
  and gets a wire; `-device nec-usb-xhci` has MSI, as the VL805 does,
  and the harness boots the whole USB line above on it as well. The
  boot log says which each device got; `-append pcinomsi` forces wires.
- **The Pi 4's constraint, imposed.** There a PCI device reaches only
  the first gigabyte, and every structure and buffer the driver hands
  the controller must come from the DMA arena or be bounced
  (`pcidmaalloc`, `pcidmaok`: `../port/pci.h`). Here everything is
  reachable, so that path would never run. `-append pcibounce` makes
  this bridge refuse every buffer, the harness's USB boot runs that way,
  and `echo dump > /usb/usb/ctl` reports how many transfers bounced.

## What the second board showed

Lines of `os/arm64` that were the BCM2837's, found by compiling the
shared code against this directory and by booting it. Each became a hook
in `../arm64/fns.h`, with the code moved — not rewritten — into
`os/bcm/board.c`:

- the device table named GPIO, the touch panel, the SD card and the audio
  jack (`devtab.c`, per board)
- the interrupt probe drove a BCM system-timer channel (`boardintrprobe`)
- `launchsmp` wrote the firmware's spin table at `0xd8` (`boardstartcpus`;
  here it is PSCI `CPU_ON` to the same `secentry`)
- `mboxlockon` and `usbdwclink` were called by name (`boardlockon`,
  `boardusblink`)
- a debug print in `squidboy` read the BCM local-timer routing register
  by its address, `0x40000040`; here that is ordinary RAM. Removed.

And one thing that was nobody's bug until there was a GIC: **`hzclock()`
calls `sched()` from inside the timer interrupt.** The BCM2837's
controller has no acknowledge cycle, so that is harmless there. A GIC
interrupt is *active* from the read of `IAR` until the write of `EOIR`,
and a handler that switches process in between leaves the core at the
timer's running priority — deaf — until the preempted process is next
run, possibly on another core, where its `EOIR` ends the wrong core's
interrupt. `main.c`'s preemption check caught it on the first boot: one
core, a different one each time, where a wired kproc waited a hog's whole
quarter second. `gic.c` ends the timer *before* its handler. A Pi 4 port
would have met this on hardware.

## What moved to shared directories

Three of the board's files needed nothing changed to serve a second
machine, which is the best evidence there is that they were never the
board's. They moved, byte for byte apart from a note at the top:

- `os/bcm2837/devsd.c` → `os/port/devsd.c`. `#S` asks four things of
  whatever is under it; here that is `blkvirtio.c`.
- `os/bcm2837/screen.c`, `fbcons.c`, `screen.h` → `os/arm64/`. They ask
  a board for an `Fbinfo`; here `ramfb.c` makes one.

The calls they make downward were named for the Pi's hardware
(`emmcread`, `mboxfbvoff`) and are not any more: `#S` asks for
`sdblkread` and friends, `fbcons` asks `fbdisplay` and `fbvoffset`, and
each board answers with what it has. `boardsdprobe`, which on the Pi
also probed the radio, is `boarddevprobe`.

## Copies that want to be one file

`uart.c` (everything below `consuartputc`), most of `clock.c`,
`uartpl011.c` and `mem.h` are the board's with the board taken out. They
are copies, not moves, because unlike the three above they need a hook
cut into them first — the pins, the clock rate, the timer routing — and
the Pi's files were left alone while it is being stabilised. Their home
is `os/arm64`.

## Decisions worth a second look

- **The keymap is in the kernel** (`inputvirtio.c`). On the board it is
  in Limbo (`kbdusb.b`), by this tree's rule that device protocols stay
  out of the kernel. A virtio input event is already a keycode, so there
  is no protocol to keep out — but the alternative, a device serving raw
  events to a Limbo program, would keep the two boards the same shape.
- **`etherusb -k`.** IP configuration (ipifc bind, DHCP, routes) lives in
  `etherusb.b`, so a machine with no USB Ethernet runs a program named
  for USB to configure a virtio card. It wants splitting out
  (`netconfig` is already a separate function).

## Not done

- **PCI devices' drivers, but for one.** The bus is there
  (`pciecam.c`): it is scanned, BARs are placed in the 32-bit window at
  `0x10000000`, and the boot log lists what was found. It exists for the
  sake of a machine that is not this one — a Raspberry Pi 4's USB
  sockets are an xHCI controller behind a PCIe bridge, QEMU's `raspi4b`
  models neither, and here both can be had with `-device qemu-xhci`.
  NVMe and e1000 would be found and have no driver. Devices behind a
  PCI-PCI bridge get no interrupt (root bus only), and the 512GB window
  above RAM is not used.
- **USB only if asked for**: `-device qemu-xhci`, then `-device usb-kbd`,
  `usb-mouse`, `usb-hub`, `usb-net` as wanted (see "USB" above). Without
  it `#u` is an empty bus. SuperSpeed hubs, streams and USB storage are
  not done.
- **No audio, GPIO, touch, Wi-Fi, Bluetooth, tryboot or boot watchdog.**
  They are the board's.
- **GICv3**, which virt needs above eight cores and newer boards have.
- **KVM.** Untried. On an arm64 host it should simply work and be fast;
  `-cpu host` then, and RNDR may appear.
