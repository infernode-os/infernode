# `os/bcm` — drivers the Raspberry Pi SoCs share

Not a kernel. This directory is never built on its own: it is the
silicon the Broadcom BCM283x/BCM2711 family has in common, compiled into
each board's kernel (`os/bcm2837`, `os/bcm2711`) against **that board's**
`io.h`, which says where the peripheral window is (`PHYSIO`) and what the
interrupt numbers are. The blocks are the same from the first Pi to the
Pi 4; what moves is the window and how interrupts arrive.

It is upstream Inferno's arrangement: `os/sa1110` holds the StrongARM's
clock, DMA, GPIO and UART, and `os/ipaq1110` and `os/cerf1110` — two
boards on that chip — each build a kernel from it plus their own
Ethernet chip, their own `arch*.c` and their own list of devices.

| here | |
|-|-|
| `board.c` | the hooks `../arm64/fns.h` asks of a board, for any Pi: the boot watchdog and tryboot, the command line, framebuffer and card bring-up, the spin-table release of the secondary cores. The one thing in its 1,100 lines that names a board is the banner, which is `BOARDNAME` from the board's `io.h` |
| `mmu.c` | the identity map: RAM Normal, everything else Device. How many gigabytes is `MAPGB`, the board's |
| `timers.c` | the system timer and the ARM timer — neither is anyone's clock |
| `mailbox.c`, `fb.c` | the VideoCore property interface; framebuffers from it |
| `uartmini.c`, `uart.c` | the mini-UART, and the console's policy over it |
| `uartpl011.c` | the PL011 as `/dev/eia0` — the Bluetooth radio's line |
| `gpio.c`, `devgpio.c` | pins, and `#G` |
| `dma.c` | the DMA engine |
| `sdhost.c`, `emmc.c`, `sdmmc.c` | both SD controllers, and the card protocol over either |
| `usbdwc.c`, `dwcotg.h` | the DWC2 USB host controller |
| `audiopwm.c` | the headphone jack: PWM through DMA |
| `devtouch.c` | `#T`, the DSI panel's touch buffer |
| `ether4330.c` | the CYW43455 radio — a chip on the board, not in the SoC, but on every board so far |
| `bcmio.h` | register layouts, relative to `PHYSIO`; included by a board's `io.h` |
| `bcm.h` | what these drivers and their boards declare to each other; included by a board's `board.h` |

What is **not** here is what differs between the SoCs: the interrupt
controller, the peripheral window and interrupt numbers, the timer's
routing, the random-number generator, and the list of devices. Those
are the board directory's, and they are most of what a board directory
is: `os/bcm2711` is about five hundred lines.

A driver here must not name an address or an interrupt number of its
own. If one needs to know which SoC it is on, that is a sign the
difference belongs in the board's `io.h` or behind a function in `bcm.h`.

The history of every file here is in `os/bcm2837/README.md`, which is
where they lived until a second SoC needed them.
