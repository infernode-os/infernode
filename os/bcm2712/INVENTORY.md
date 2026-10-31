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
| Debug connector (uart10) | no | `uartrp1.c` | Console output, out of the firmware's 115200; bytes leave the FIFO, nobody has read them. Wants the Debug Probe. No input: unplugged, its receiver fills with noise |
| SD read | yes | `emmc2.c` | **Proved**: 19 MB/s at High Speed, 50MHz, PIO. A 64MB region hashes as it does from Linux |
| SD write | yes | `emmc2.c` | **Proved**, persisted over a reboot |
| Gigabit Ethernet | yes | `etherrp1.c` | **Proved**, 927 in, 903 out |
| Ethernet speed changes, 100/10 | yes | `etherrp1.c` | **Proved**, by advertising less (`ether100`, `ether10` on the command line): 95 in, 94 out; 10 in, 9 out. The block divides its own tx clock |
| USB host, high speed | yes | `usbxhcirp1.c` | **Proved** on one USB-3 port |
| USB SuperSpeed | untested | shared | Not tested; the gadget was high speed |
| Second controller, other ports | n/a | `usbxhcirp1.c` | Controller up; no device tried |
| USB keyboard, mouse | yes | shared | **Proved** by a person, on the desktop |
| USB disk | yes | shared | Not tested on this board |
| RP1 MSI-X | n/a | `rp1.c` | **Proved** with Ethernet and USB |
| Wi-Fi, 5GHz WPA2 | yes | `radio.c` | **Proved** |
| Wi-Fi, TKIP group cipher | no | shared | Not supported, any board (`wpa.b`) |
| Bluetooth classic | yes | `uartbt.c` | **Proved** by inquiry |
| Bluetooth LE scan | yes | shared | **Proved**: `/net/bt/lescan` found 13 neighbours |
| Bluetooth pairing, L2CAP | yes | shared | **Proved** against a Jetson: Just Works pairing, then an L2CAP channel out and an SDP query answered |
| GPIO function, level, pull | yes | `gpiorp1.c` | **Proved** |
| GPIO edge events | yes | `gpiorp1.c` | **Proved** across a jumper, GPIO 5 to GPIO 0 |
| `#P` temperature, throttling | yes | shared | **Proved** |
| Serial recovery loader | yes | `loader/` | Standalone **proved**; embedded copy built |
| Framebuffer, desktop | yes | shared | **Proved** on HDMI0 and HDMI1, one monitor at a time: Lucifer, right size and colours. Needs `framebuffer_depth=32`. The mode comes from the EDID, by the firmware-KMS tags (`../bcm/fb.c`). Two screens at once not tried |
| Audio (PWM jack) | yes | none | No jack on a Pi 5; HDMI audio or I2S instead |
| DSI panel, touch | yes | none | Not done; DSI is RP1's here |
| Camera device (`#V`) | simulated | shared | Compiled in; simulated sensor only |
| Memory above 4GB | no | `../bcm/mmu.c` | **Proved**: found at boot from the device tree, every bank mapped at run time, no constant to change for a bigger board. 7.1GB free, 3.76GB of Dis heap touched. `memlimit=N` runs as a smaller board: 4, 2 and 1GB boots proved |

## What only a Pi 5 has

| Block | Where | State |
|---|---|---|
| Real-time clock | the firmware, `#r/rtc`, `#r/battery` (`devrtc.c`, `rtcfan.c`) | **Proved** across a reset, and sets the clock at boot; across power off wants the battery connected |
| External PCIe (FPC connector) | `pcie1.c` | **Proved at gen 2**: drops once about 1.6s after training, recovered, then held under six minutes of everything. Four resets send it to gen 1; `pciegen1` asks from the start; `nvmeslow` in `#S/sdctl` does it by hand, proved |
| NVMe | `nvme.c`, `#S/nvme0`, `#S/nvmestat`, GPT or MBR as `nvme0p1` on, `nvmepart` ranges | **Proved** on a WD SN7100: both table formats read, 370 MB/s at gen 2, writes hashed back, recovery from a lost command and from a real link drop, a killed reader leaves the queue in step, a clean shutdown (the drive's unsafe count stays still), kfs across 1.8TB, FAT read by Linux, userland from the drive with `nvmeroot`. firmware boot from the drive with Linux as the way back, and no card (simulated) |
| Fan connector | RP1 PWM1 channel 3, `#P/fan`, `#P/fanrpm` | **Proved**: follows temperature by the device tree's trips; a written level overrides, `auto` restores |
| Power button | SoC GPIO 20, `#P/button`; init halts on a press | **Proved** by a person: press, drive shut down, PSCI off, red LED; a press starts it again. `POWER_OFF_ON_HALT=0` leaves it in standby, not fully off |
| Status LEDs | ACT AON GPIO 9, `#P/led`; PWR RP1 GPIO 44, `#G` | ACT **proved** by a person. PWR written, not watched |
| Debug UART connector | `uart10` | Output only, unread: see above |
| Second console | RP1 UART4, GPIO 12, 13 (pins 32, 33) | **Proved**, in and out |
| Two HDMI, DSI/CSI connectors | HVS, RP1 | Either HDMI, one at a time. Two together, DSI and CSI not done |
| RTC battery charging | the firmware, `trickle-charge-microvolt` | Not done; off unless asked for, which is right for a primary cell |

## RP1's blocks

| Block | Count | State |
|---|---|---|
| UART | 6 | UART0 console only |
| I2C | 7 | `devi2c.c`, `#J`, i2c0 and i2c1 at 100 and 400kHz. **Proved** on the wire: i2c1 scans clean with nothing on it, i2c0's address byte seen at 10.0us a bit through the jumper. No device has answered yet: nothing is on the bus. 400kHz set, too fast for the edge interrupt to time |
| SPI | 9 | `devspi.c`, `#Q`, SPI0, two chip selects. **Proved** in the block's own loopback: 8192 bytes back intact at 1 and 10MHz, in the time they should take. No device on the wire yet |
| PWM | 2 | `devpwm.c`, `#W`, PWM0's four channels. **Proved**: 10ms period, 2.5ms duty measured at the pin to the microsecond. PWM1 is the fan's |
| I2S | 3 | Not done |
| ADC | 1 | Not done: reading it with its clock off hangs the reader, and the clock's register is not in hand |
| PIO | 1 | Not done; needs RP1's mailbox |
| DMA | 1 | Not done; CPU copies today |
| SDIO | 2 | Not done; wired to the header pins |
| CSI, DSI, DPI, VEC | 2, 2, 1, 1 | Not done |
| Audio out | 1 | Not done |

## Blocks probably left alone

V3D GPU, HEVC decoder, the IOMMUs, the SoC's DMA engines, the PiSP
image pipeline: real work, with nothing in the system to use them yet.
