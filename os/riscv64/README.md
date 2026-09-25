# RISC-V (RV64GC)

InferNode on 64-bit RISC-V, two ways:

- **Hosted**: `emu` on riscv64 Linux, with a Dis JIT
  (`libinterp/comp-riscv64.c`). It runs on any RVA20-or-later Linux board
  (BeagleV-Fire, VisionFive 2 and the like), or under `qemu-riscv64`.
- **Bare metal**: this directory is the architecture (`os/riscv64`), with
  two boards on top of it:
  - `os/riscvvirt`: QEMU's RISC-V `virt` machine.
  - `os/mpfs`: the Microchip PolarFire SoC, which is the BeagleV-Fire and
    the Icicle Kit.

The kernel core is the one every other native port uses (`os/port`,
`os/ip`, the libraries). What lives here is only what RISC-V needs:
entry, traps, the SBI, the PLIC, spl and locks, the 16550 console, and
the process switch.

## Hosted

    # cross, from amd64 (or arm64)
    apt-get install gcc-riscv64-linux-gnu libc6-dev-riscv64-cross qemu-user
    ./build-linux-amd64.sh headless        # once: host mk and limbo, and dis/
    ./build-linux-riscv64.sh
    qemu-riscv64 -L /usr/riscv64-linux-gnu emu/Linux/o.emu -c1 -r$PWD sh -l

    # native, on the board
    ./build-linux-riscv64.sh

Libraries build their `.o` files in the source directories. So after a
cross build, clean before building for the host again
(`build-linux-riscv64.sh` cleans before it builds, for the same reason).

What says the JIT is right:

- `tests/jittest.b`: 182 opcode cases.
- `tests/jit_fault_test.b`: zero divide, bounds, nil, unwinding, and
  which handler catches.
- `tests/host/jit_boot_test.sh` and `jit_interp_handoff`.

Under qemu-user a full `runner.dis -c1` pass is slow but works. The one
crash seen in it (`cipher_matrix_test`: a jump into a freed module's code)
reproduces on the amd64 JIT too. It is a shared module-lifetime bug, not
one of this port's.

## Bare metal: the boot contract

The kernel runs in S-mode under SBI firmware:

- OpenSBI on QEMU.
- On a PolarFire SoC, the OpenSBI that the Hart Software Services (HSS)
  gives the U54s.

It has no paging (`satp` Bare) and addresses memory physically. One hart
enters `_start` with the hart id in `a0` and the device tree in `a1`. The
others are started with SBI HSM (`launchsmp`). `tp` holds the hart's
`Mach` and the trap path never restores it.

That is exactly the Linux RISC-V entry contract. `l.S` also opens with
the Linux Image header, so whatever boots a Linux `Image` boots this
kernel. The kernel is linked at `0x80200000`, is not relocatable, and
must be loaded there.

What the kernel takes from the device tree:

- `/memory`: the RAM.
- `/reserved-memory` and the memreserve block: kept out of the allocator
  (`confinit`).
- `/cpus`: which harts to start. On a PolarFire, hart 0 is the E51
  monitor core, and the firmware keeps it.
- The timebase and `/chosen/bootargs`.

## Building and running under QEMU

    ./tests/host/baremetal_riscv64_test.sh                    # both boards
    BAREMETAL_RV_PLATFORMS=mpfs BAREMETAL_BUILD_DIR=/tmp/bm \
        ./tests/host/baremetal_riscv64_test.sh

This builds `/tmp/bm/<board>-kernel.img` (and the `.elf` for symbols) and
boots each board.

- **riscvvirt** checks:
  - the shell and 4 harts;
  - a virtio card for userspace, and DHCP over virtio-net;
  - `jittest` and `jit_fault` on the bare-metal JIT;
  - a ramfb screen with virtio keyboard and tablet, with the graphical
    logon drawn on it (checked by a QMP screendump);
  - that U-Boot's `booti` boots the image (`qemu-riscv64_smode`).
- **mpfs** boots QEMU's `microchip-icicle-kit`, which models the MSS but
  not the fabric. It has no device tree of its own, so
  `os/mpfs/qemu-icicle.dts` is compiled with `dtc` and passed with
  `-dtb`. The run uses 5 harts and 2GB. mpfs checks:
  - userspace off the SD card (Cadence SD4HC, `sd4hc.c`);
  - the PHY over MDIO, and DHCP through the GEM (`ethergem.c`);
  - that the fabric buffer in `/reserved-memory` is not allocated.

## BeagleV-Fire

The board ships with this boot chain:

- the HSS on the E51;
- OpenSBI;
- U-Boot in S-mode on the U54s;
- then a Linux Image from the eMMC's boot partition, or from a card.

InferNode sits in the Linux Image's place:

1. Put `mpfs-kernel.img` on a FAT partition U-Boot can read (the eMMC's
   boot partition, or a microSD card) as `infernode.img`.
   `tools/mkcard.py` builds a card with the userspace trees too.
2. At U-Boot's prompt:

       load mmc 0:1 0x80200000 infernode.img
       booti 0x80200000 - ${fdt_addr_r}

   The address must be `0x80200000` (see above). If U-Boot says it cannot
   reserve memory for the fdt, move the tree first:
   `fdt move ${fdtcontroladdr} ${fdt_addr_r} 0x10000`.
3. The console is MMUART0 (the debug header, 115200 8N1).

The other way is to make the kernel the HSS payload itself, with no
U-Boot. Build the payload with `hss-payload-generator`, with the U54s'
entry and load address at `0x80200000`, S-mode, and the board's tree as
the ancillary data.

None of this has been on a real board yet. Everything above is proved
under QEMU only. The things QEMU cannot show are listed next.

## Not done yet

- **Entropy, on silicon.** `os/mpfs/random.c` asks the system
  controller's nonce service (a TRNG-seeded DRBG) through the mailbox.
  QEMU fails every service, so only the refusal path is proved: the
  kernel then says loudly that it has NO ENTROPY SOURCE. The success
  path has not run on a board yet.
- **RTC.** The MSS RTC is not read, so the time of day comes from the
  network or not at all.
- **GEM PHY, on silicon.** `ethergem.c` finds the PHY over MDIO
  (Clause 22), autonegotiates, and sets the MAC's speed and duplex from
  the result. It keeps the SGMII/PCS bits the firmware set. Under QEMU
  that is the GEM model's 88E1111. The Fire's own PHY and the MSS SGMII
  block behind it are untested.
- **DMA coherence.** The GEM and SD4HC descriptors and buffers are
  ordinary cacheable memory, and there is no cache maintenance around
  DMA. Whether the MSS DMA masters see the U54s' caches on the Fire's
  DDR window is not verified on silicon. QEMU cannot tell.
- **The fabric.** The FPGA gateware's devices (the cape GPIO, and any
  accelerator the user loads) have no drivers. Its reserved buffers are
  honoured.
- **A screen on the Fire.** riscvvirt draws on QEMU's ramfb
  (`../virtio/ramfb.c`, shared with arm64 virt), all the way to the
  graphical logon. The BeagleV-Fire has no display controller in the MSS:
  a screen there would be gateware in the fabric, or USB.
