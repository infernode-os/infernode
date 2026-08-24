# Bare-metal QEMU `virt` (AArch64)

Tracked as **INFR-404**, alongside [os/bcm2837](../bcm2837/README.md).
Same kernel, second machine.

Status: **the Dis VM runs**, the same way it does on BCM2837 — Limbo
bytecode loaded from the in-kernel root filesystem, executing, reaching
`/dev/cons` through the namespace, and running to completion.

## Why a second board

`virt` is not a simulation of any real hardware. It is a synthetic
machine defined by QEMU's `hw/arm/virt.c` and described to the kernel by
a device tree. That makes it a poor *hardware* target and the better
*development* one, for three reasons that are worth stating because they
are what justify carrying a second platform at all.

**It has a GIC.** BCM2837 routes its per-core timer through a small
vendor block: one register, one bit per timer, no priorities, no
acknowledge cycle. `virt` uses the architectural GICv2, which is also
what the Pi 4 (GIC-400) and Pi 5 use. So `gic.c` is not scaffolding for
an emulator — it is the interrupt-controller driver a Pi 4 port needs,
written and debugged before anyone owns a Pi 4.

**It has virtio-mmio.** A network interface, a block device, a GPU and a
multitouch input device are all reachable. None of them are on QEMU's
`raspi3b`: it models no NIC at all, and the Pi's own touchscreen path
(firmware tag `0x0004000F`) is *declared* in QEMU's
`include/hw/arm/raspberrypi-fw-defs.h` but not implemented in
`hw/misc/bcm2835_property.c` — it falls through to `LOG_UNIMP`. So
`os/ip` and any GUI input work can be developed here and nowhere else in
emulation.

**It is a second machine that does not share BCM2837's quirks.** A bug
that reproduces on both is in `os/port` or `os/arm64`; one that
reproduces on neither is in the board code. That is a cheap and
surprisingly sharp diagnostic, and it is why the test harness runs both
rather than offering a choice.

What `virt` is *not* is a substitute for the board. Nothing here models
caches, and a synthetic machine has no errata.

## Tree layout

```
os/arm64/    shared by every AArch64 board: boot stub, exception
             vectors, trap decoding, spl, the device-tree parser, the
             portable probes, and kmain itself
os/virt/     this machine: memory map, PL011, GICv2, timer, MMU, and
             the five board hooks ../arm64/fns.h declares
os/bcm2837/  the Pi 3B+ equivalent
os/port/     upstream Inferno's native kernel core, ported to 64-bit
```

Adding this port is what forced the `os/arm64` split. A fifth board hook
should be read as an argument for moving code into `os/arm64`, not for
widening the interface.

## Entry contract

Established empirically rather than from documentation, because three of
these four differ from the Pi and each one fails silently:

| | `virt` | `raspi3b` |
|---|---|---|
| load / entry address | `0x40080000` (RAM base + 0x80000) | `0x80000` |
| entry PC | the load address, directly | `0x0`, behind a firmware shim |
| exception level | EL1 | EL2 |
| `x0` at entry | flattened device tree pointer | flattened device tree pointer |

`-M virt` has no EL2 at all unless `virtualization=on`, so `l.S`'s
EL2→EL1 drop is simply not exercised here; the "already at EL1" path it
already had covers it.

## Building and running

There is deliberately no mkfile or build script — see the
[BCM2837 README](../bcm2837/README.md#building) for why, and for the
toolchain discovery. The test harness builds both ports; to do it by
hand, take the commands from `tests/host/baremetal_test.sh` and set
`SRC=os/virt`.

```sh
qemu-system-aarch64 -M virt -cpu cortex-a53 -m 1024 \
    -kernel kernel.img -display none -serial stdio
```

With devices, to exercise the transport scan:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a53 -m 1024 \
    -kernel kernel.img -display none -serial stdio \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
    -device virtio-gpu-device -device virtio-multitouch-device
```

`-s -S` gives a GDB stub on `:1234` with the CPU halted before the first
instruction. macOS ships `lldb` rather than `gdb`:

```sh
lldb kernel.elf -o 'gdb-remote 1234' -o 'breakpoint set --name kmain' -o continue
```

Unlike `raspi3b`, `virt` can in principle be accelerated — but not here:
`raspi3b` enables EL3 and HVF refuses outright ("Cannot enable HVF when
guest CPU has EL3 enabled"), and this kernel wants EL1 with a GIC it
programs itself. TCG is the loop for both.

## Traps that cost time

Each of these presents as something other than what it is.

**`-M virt` defaults to `cortex-a15`, a 32-bit ARMv7 CPU, even under
`qemu-system-aarch64`.** Boot an AArch64 image without `-cpu
cortex-a53` (or `max`) and there is no error and no output whatsoever —
the CPU is decoding the image as ARM32. This is the first thing to check
when a `virt` kernel is silent.

**The PL011 drops writes to a disabled UART.** Writing `DR` with
`CR.UARTEN` clear produces nothing, silently. A kernel that runs
perfectly and prints nothing has usually skipped the enable, not
crashed.

**Peripherals are BELOW RAM, the inverse of the Pi.** BCM2837 has RAM at
0 with peripherals above it, so its `mmu.c` maps "below ramtop" as
Normal cacheable. Reuse that test here and the entire peripheral
region — GIC included — is mapped cacheable. It fails in the least
useful way available: the console still works, because the first writes
sit in a dirty line and drain eventually, and the GIC does not, so the
kernel hangs with nothing in the log.

**virtio-mmio slots populate from the TOP down.** QEMU puts the first
`-device` on the command line in slot 31. A scan that stops at the first
empty slot reports no devices at all and looks like "virtio is broken".

**Forgetting the GIC EOI does not fail — it half-works.** Reading
`GICC_IAR` both identifies the interrupt and masks it until the same
value is written back to `GICC_EOIR`. Miss that and you get exactly one
interrupt, ever: the kernel boots normally and then never preempts
anything. Every path out of `irqdispatch()` has to reach the EOI,
including the ones that decided the interrupt was unclaimed.

**`x0` survives for exactly one instruction.** The device tree pointer
is in `x0` at reset, and `x0` is the first register anything reaches
for. `l.S` parks it in `x19` as its first instruction and stores it to
`dtbptr` only after `.bss` is cleared — storing it earlier would zero
it.

## Not done

- **No framebuffer.** There is no VideoCore and no mailbox. The two
  routes are `ramfb`, configured through fw_cfg and the smaller job, and
  `virtio-gpu`, which is the real one and would bring `virtio-input`
  (and therefore multitouch) within reach at the same time. This is the
  natural next step for this port and the reason it exists.
- **No virtio drivers.** `boardioprobe()` scans the transports and
  reports what is attached; nothing is driven. `virtio-net` is the one
  that matters, because it unblocks `os/ip` — neither Pi machine models
  a NIC, so there is no other way to develop it in emulation.
- **No PSCI.** Secondary cores are left parked. `virt` starts them
  through PSCI rather than the Pi's spin tables, so bringing up SMP
  means implementing a second mechanism, not reusing one.
- **No JIT.** Excluded on both ports for the same reason: it needs a
  bare-metal W^X allocator. Worth noting that this is the one place
  `virt` would be actively misleading if it were enabled — TCG does not
  model split I/D caches, so a JIT missing its `DC CVAU` / `IC IVAU` /
  `DSB` / `ISB` sequence runs correctly here and fails on silicon.
