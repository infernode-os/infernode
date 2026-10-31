# Bare-metal BCM2712 (Raspberry Pi 5) port

**It runs on a board**: a Pi 5 Model B rev 1.0 (8GB), since 2026-10-31,
from a card that also holds Raspberry Pi OS. On that board: all four
cores through PSCI, the Dis JIT, userspace from the card, gigabit
Ethernet at 927 Mbit/s in and 903 out, USB host through RP1 (an Ethernet
gadget enumerated and took a lease), Wi-Fi joined with WPA2, Bluetooth
found a neighbour by inquiry, GPIO driven and read back, card writes
that survive a reboot. RP1's devices take real MSI-X interrupts, but for
the console's input, which is polled.

No emulator models a Pi 5: QEMU master has no `raspi5`. So this port goes
the other way from the Pi 4's: the board first, and each step asks the
hardware instead of assuming.

Not done or not proved: two screens at once; memory above 4GB, which the allocator's int-sized pools
could not use; audio, since a Pi 5 has no analogue output. The D0
stepping (2GB boards) moves the pin mux and is not handled. An overnight
soak with everything loaded has not been run.

## What is here

| file | |
|-|-|
| `io.h`, `mem.h` | addresses above 4GB as macros; the device windows; what the secure firmware owns |
| `rp1.c` | the PCIe link and RP1's MSI-X |
| `uartrp1.c` | the console: RP1's UART0 |
| `etherrp1.c` | the gigabit port: a Cadence GEM |
| `usbxhcirp1.c` | the USB ports: two DWC3s, as xHCI |
| `gpiorp1.c` | RP1's pins, under `../bcm/devgpio.c` |
| `emmc2.c` | the card: `../bcm/emmc.c` again |
| `radio.c` | Wi-Fi's pins, power and SDIO2 for `../bcm/ether4330.c`; Bluetooth's pins |
| `uartbt.c` | Bluetooth's UART, as `/dev/eia0` |
| `random.c`, `recover.c`, `intr.c`, `devtab.c`, `stubs.c`, `kernel.ld` | the rest of a board |
| `loader/` | `serialboot` for this board: the report (`probe.c`), and a loader carried in the kernel |

The other boards' kernels are byte-identical with or without this.

Building: `BAREMETAL_PLATFORMS=bcm2712 BAREMETAL_BUILD_ONLY=1
tests/host/baremetal_test.sh`. It only builds.

## The card

A FAT32 first partition holding `kernel_2712.img` (the loader),
`config.txt` (`card/config.txt`), and `bcm2712-rpi-5-b.dtb` and
`bcm2712d0-rpi-5-b.dtb` from raspberrypi/firmware. The firmware itself is
in the board's EEPROM, so there is no `start*.elf`.

| `config.txt` | |
|-|-|
| `os_check=0` | the firmware otherwise refuses a partition it thinks holds no compatible kernel |
| `enable_rp1_uart=1` | the firmware sets up RP1's UART0 at 115200 and leaves RP1 up |
| `pciex4_reset=0` | keep the bridge to RP1 as the bootloader configured it |
| `enable_uart=1`, `uart_2ndstage=1` | the firmware's own log, on the debug connector |

## The console

GPIO14/15 (header pins 8 and 10) are RP1's UART0, reachable only while
the PCIe link to RP1 is up. With `pciex4_reset=0` the firmware leaves RP1
at `0x1C00000000`, so the UART is at `0x1C00030000` (its log says so:
`RP1_UART 0000001c00030000`); Linux's `0x1F00000000` is Linux's own
programming of the bridge. The 3-pin debug
connector is `uart10`, on the SoC itself, at `0x107D001000`, and needs
nothing from RP1. The port should end up with both; the debug connector
is what will still talk when PCIe does not.

## What is different in kind from a Pi 4

From `bcm2712.dtsi`, `bcm2712-rpi-5-b.dts` and `rp1.dtsi` in
raspberrypi/linux rpi-6.12.y. None of it is proved on a board yet.

- **Everything is above 4GB.** `PHYSIO` is `0x107C000000`, which does not
  fit the `int` enums of `../bcm/bcmio.h`, and the blocks are not at the
  old offsets from it (the mailbox is +0x13880). `../bcm/mmu.c` needs
  several device windows, not one `PCIWIN`, and a 40-bit `MMUIPS`.
- **Core number.** The cores are `0x000`, `0x100`, `0x200`, `0x300`: an
  A76's number is in MPIDR Aff1, and the arm64 code reads Aff0.
- **Starting cores.** `enable-method = "psci"`, not the spin table that
  `../bcm/board.c` uses.
- **The first 512KB is not ours.** It is reserved for the secure
  firmware, and is not mapped.
- **Nearly all I/O is on RP1**, behind PCIe: UART, GPIO, Ethernet
  (Cadence GEM, `0x1F00100000`), USB (two DWC3 xHCIs, `0x1F00200000` and
  `0x1F00300000`). RP1 reaches RAM at PCIe address `0x10_0000_0000`, and
  its MSIs go through the MIP at `0x1000130000`, not GICv2m.
- **GPIO** is RP1's block, so `../bcm/gpio.c` does not apply.
- **The clock**: `clockgt.c` reads the generic counter's frequency, and
  the report prints it, with a check against the system timer.

What should carry over: `../arm64/gic.c` (a GIC-400, at `0x107FFF9000`),
the mailbox and firmware framebuffer, the SDHCI core of `../bcm/emmc.c`
(at `0x1000FFF000`), `../port/usbxhci*.c`, the RNG200.

## What the board said

First run 2026-10-31: a Pi 5 Model B rev 1.0, revision `d04170`, 8GB,
bootloader of 2026-05-26. `report` is that run of `probe.c`.

| | |
|-|-|
| CPU | Cortex-A76 r4p1, entered at EL2 with the MMU off; x0 is the device tree, at `0x2EFEC500`: inside the RAM the kernel would allocate |
| cores | PSCI 1.1 by SMC; 1, 2, 3 start at MPIDR `0x81000100`, `0x200`, `0x300`, at EL2 |
| mailbox | at `0x107C013880`; buffers with the `0xC0000000` alias, as on a Pi 4 |
| memory | ARM block `0`-`0x3FC00000`; the VideoCore's is `0xFDB00000`, 33MB, near the top of 4GB and not below 1GB; RAM held at each address tried, up to 7GB |
| bridge | link up; outbound window CPU `0x1C00000000`, 1GB, to PCIe `0x80000000`; `rc_bar2` `0x15` |
| RP1 | chip id `0x20001927`, at `0x1C00000000` |
| GIC | GIC-400, 320 interrupts, 4 CPUs |
| clocks | generic counter 54MHz; the system timer agrees to the microsecond over 100ms; ARM 1.5GHz |
| uart10 | enabled by the firmware, CR `0x301` |

## The plan

Done: the report; a console and all four cores through PSCI; the GIC,
the timer, the JIT, to the shell.

Things found on the way, each silent until the board showed it:
the firmware puts the kernel at 0x80000 whatever `kernel_address` says,
so l.S moves it to 2MB, backwards because the two overlap; the A76 faults
exclusives and unaligned accesses in the Device memory everything is
before the MMU, so this board builds with `-mstrict-align`; and the
kernel links at 2MB because every stack check assumes the boot stack is
below `_start`, which at 0x80000 is the secure firmware.

Also done: console input, polled from the clock (`uartrp1.c`); the card,
read so far (`emmc2.c`); the Ethernet MAC, polled from a kproc
(`etherrp1.c`).

The kernel keeps the firmware's PCIe setup rather than doing its own,
and `rp1.c` finishes what the firmware has no need of. RP1 masters RAM at
the physical address, not at Linux's `0x10_0000_0000`, and only below
`0x80000000`, where its own registers are.

## The plan

1. An overnight soak with USB, the card, Wi-Fi and Bluetooth loaded.
2. The display, on a monitor; GPIO edges on a wire.
3. What only this board has: the external PCIe connector, the power
   button, the LEDs, the debug UART, a fan curve. The clock (`#r`) and
   the fan (`#P`) are in.
