# BCM2712 inventory: what a Pi 5 has, and where this port stands

From Linux's `bcm2712.dtsi`, `bcm2712-ds.dtsi`, `bcm2712-rpi-5-b.dts` and
`rp1.dtsi` (rpi-6.12.y) and this tree, on 2026-10-31. **Proved** means seen
working on the bench board (8GB, rev 1.0). **Built** means the code exists
and has not run to any effect. The Pi 4 column is whether a Pi 4 kernel
has the feature, which is what parity means.

## Existing features: parity with a Pi 4

| Feature | Pi 4 | Pi 5 | State |
|---|---|---|---|
| CPU, 4 cores, SMP | yes | `l.S`, PSCI | **Proved** |
| JIT | yes | shared | **Proved** |
| MMU, windows above 4GB | n/a | `mmu.c` | **Proved** |
| GIC, generic timer | yes | shared | **Proved** |
| Mailbox | yes | shared | **Proved** |
| Watchdog, reboot | yes | shared | **Proved** |
| RNG200 | yes | `random.c` | Read: two samples differ; not tested beyond that |
| Console out (GPIO14/15) | yes | `uartrp1.c` | **Proved** |
| Console in | interrupt | `uartrp1.c` | **Proved**, by interrupt |
| Debug connector (uart10) | no | none | Not done; wants the Debug Probe |
| SD read | yes | `emmc2.c` | **Proved**; PIO at identification-to-default speeds, unmeasured |
| SD write | yes | `emmc2.c` | **Proved**, persisted over a reboot |
| Gigabit Ethernet | yes | `etherrp1.c` | **Proved**, 927 in, 903 out |
| Ethernet speed changes, 100/10 | yes | `etherrp1.c` | Not tested; RP1's tx clock may need setting |
| USB host, high speed | yes | `usbxhcirp1.c` | **Proved** on one USB-3 port |
| USB SuperSpeed | untested | shared | Not tested; the gadget was high speed |
| Second controller, other ports | n/a | `usbxhcirp1.c` | Controller up; no device tried |
| USB keyboard, mouse | yes | shared | **Proved** by a person, on the desktop |
| USB disk | yes | shared | Not tested on this board |
| RP1 MSI-X | n/a | `rp1.c` | **Proved** with Ethernet and USB |
| Wi-Fi, 5GHz WPA2 | yes | `radio.c` | **Proved** |
| Wi-Fi, TKIP group cipher | no | shared | Not supported, any board (`wpa.b`) |
| Bluetooth classic | yes | `uartbt.c` | **Proved** by inquiry |
| Bluetooth LE, pairing, L2CAP | yes | shared | Not tested on this board |
| GPIO function, level, pull | yes | `gpiorp1.c` | **Proved** |
| GPIO edge events | yes | `gpiorp1.c` | **Proved** across a jumper, GPIO 5 to GPIO 0 |
| `#P` temperature, throttling | yes | shared | **Proved** |
| Serial recovery loader | yes | `loader/` | Standalone **proved**; embedded copy built |
| Framebuffer, desktop | yes | shared | **Proved** on HDMI0 and HDMI1, one monitor at a time: Lucifer, right size and colours. Needs `framebuffer_depth=32`. The mode comes from the EDID, by the firmware-KMS tags (`../bcm/fb.c`). Two screens at once not tried |
| Audio (PWM jack) | yes | none | No jack on a Pi 5; HDMI audio or I2S instead |
| DSI panel, touch | yes | none | Not done; DSI is RP1's here |
| Camera device (`#V`) | simulated | shared | Compiled in; simulated sensor only |
| Memory above 4GB | no | none | Pools are int-sized; shared-code work |

## What only a Pi 5 has

| Block | Where | State |
|---|---|---|
| Real-time clock | the firmware, `#r/rtc`, `#r/battery` (`devrtc.c`, `rtcfan.c`) | **Proved** across a reset, and sets the clock at boot; across power off wants the battery connected |
| External PCIe (FPC connector) | `pcie1.c` | **Proved at gen 1**: link, bridge windows, DMA. At gen 2 the link drops about 1.6s in; `pciegen2` to test |
| NVMe | `nvme.c`, `#S/nvme0`, `nvmepart` ranges | **Proved** on a WD SN7100: 194 MB/s at gen 1, 378 at gen 2, MSI-X, one queue. Writes checked at the start, middle and end of 2TB. kfs in a 4GB range survives a reboot; kfs on all 2TB takes too long to ream to be any use |
| Fan connector | RP1 PWM1 channel 3, `#P/fan`, `#P/fanrpm` | **Proved**: follows temperature by the device tree's trips; a written level overrides, `auto` restores |
| Power button | SoC GPIO 20, `#P/button` | Level read; a press not yet tried; nothing acts on it |
| Status LEDs | ACT AON GPIO 9, `#P/led`; PWR RP1 GPIO 44, `#G` | Written; not watched by anyone |
| Debug UART connector | `uart10` | Not done |
| Second console | RP1 UART4, GPIO 12, 13 (pins 32, 33) | **Proved**, in and out |
| Two HDMI, DSI/CSI connectors | HVS, RP1 | Either HDMI, one at a time. Two together, DSI and CSI not done |
| RTC battery charging | the firmware, `trickle-charge-microvolt` | Not done; off unless asked for, which is right for a primary cell |

## RP1's blocks

| Block | Count | State |
|---|---|---|
| UART | 6 | UART0 console only |
| I2C | 7 | Not done |
| SPI | 9 | Not done |
| PWM | 2 | Not done |
| I2S | 3 | Not done |
| ADC | 1 | Not done; board monitoring |
| PIO | 1 | Not done; needs RP1's mailbox |
| DMA | 1 | Not done; CPU copies today |
| SDIO | 2 | Not done; wired to the header pins |
| CSI, DSI, DPI, VEC | 2, 2, 1, 1 | Not done |
| Audio out | 1 | Not done |

## Blocks probably left alone

V3D GPU, HEVC decoder, the IOMMUs, the SoC's DMA engines, the PiSP
image pipeline: real work, with nothing in the system to use them yet.
