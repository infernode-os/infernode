# Acceptance batteries: standard tests, run from a tester against the board

`tests/host/baremetal_test.sh` proves the kernel under QEMU; the Limbo
suites and `tests/inferno/` prove the code against mocks. Neither is
acceptance. Acceptance is the standard batteries the industry holds a
device to -- the Bluetooth SIG's PTS cases, RFC 2544, hostap's `hwsim`
scenarios, USB-IF's transfer tests -- and those are what this directory
approximates, with one design rule: **nothing is ported to the board.**
The standard tools stay on a Linux tester (the Jetson, today) and the
board is asked only to be a peer, which `listen(1)` makes it in one
line. Each check names the standard case it stands in for, so a formal
run of the real battery later maps onto it directly.

| battery | standard | tester tools | board side |
|---|---|---|---|
| `ethernet.py` | RFC 2544 26.1-26.5 (adapted for an end system), TCP behaviour | `ping`, Python sockets | `listen -A tcp!*!5001 {cat > /dev/null}`, a source |
| `bluetooth.py` | Bluetooth SIG PTS: GAP/DISC, GAP/IDLE/NAMP, L2CAP/COS/{ECH,CED,CFD}, SDP/SR/{SA,SS}, RFCOMM/DLC, SPP, GAP/SEC | BlueZ `hcitool l2ping l2test rctest sdptool bluetoothctl` | `listen -A 'bt!*!<psm>' {cat >> file}`, `bt!*!spp` |
| `wifi.py` | hostap `hwsim` scenarios: WPA2-PSK, WPA3-SAE, PMF, re-association, DHCP after roam; 24 h association soak | `hostapd` on the tester's radio (AP mode is supported: `iw list`), `iperf3` | the station; `/n/dos/wifi` |
| (to do) `usb.py` | Linux `usbtest`/`testusb` patterns against a gadget; enumeration matrix; plug/unplug under load | a Pi Zero running `g_zero` | the host controller |
| `gpio.py` | no official Pi suite; a loopback jig (eight pairs of header pins jumpered; the map is in the file): drive/read both ways, pull-up/down, ctl read-back, crosstalk, the kernel's own pins refusing | network console only | `#G/gpio/N/{ctl,level}` |
| (to do) `hdmi.py` | HDMI CTS approximated: an HDMI-to-USB capture on the tester; mode, pixel order, tearing | `v4l2` | the framebuffer |
| (to do) `audio.py` | the 3.5 mm jack: tone/sweep played, measured at a line-in (frequency, level, THD, separation) | `arecord`, FFT | PWM audio |

Each battery prints `PASS:`/`FAIL:`/`SKIP:` lines and a `Passed:/Failed:`
summary as the QEMU harness does, and with `--serial-log` pointed at the
serial capture, anything alarming the kernel says during the run --
`panic`, `ether0rx`, `won't halt`, the #622 detectors -- is a FAIL of
its own. Thresholds are deliberately loose where the number is what
matters (throughput records the figure; it gates only on absurdity).

```
tests/acceptance/ethernet.py  --board 192.168.1.104 --serial-log ~/captures/serial/today.log [--frag-via minipc]
tests/acceptance/bluetooth.py --board 192.168.1.104 --bdaddr b8:27:eb:ca:4c:8e
```

`board.py` is the shared driver: commands over the board's network
console (`osinit.b` netshell, token file `~/pitools/netcons.token` or
`--token`), the serial capture for the kernel's words, the PASS/FAIL
bookkeeping. `BOARD`, `BOARD_TOKEN`, `BOARD_SERIAL` in the environment
set the defaults.

## Tester prerequisites

- BlueZ's tools (`bluez` package; the Jetson has them). `l2ping` opens a
  raw L2CAP socket and `btmon` the monitor channel; both need
  `CAP_NET_RAW`, or their checks print as SKIP with this instruction.
  `setcap` takes the capability before EACH file:
  `sudo setcap cap_net_raw+ep /usr/bin/btmon cap_net_raw+ep /usr/bin/l2ping cap_net_raw+ep /usr/bin/l2test`
  The information-request check is read off the wire with `btmon`:
  `l2test -z` hangs on this kernel even while the board answers, because
  the kernel's L2CAP consumes information responses itself.
- For `GAP/SEC`, the tester must already be bonded with the board:
  `echo pair <tester-bdaddr> > /net/bt/ctl` on the board once.
- `hostapd` for the Wi-Fi battery (not yet installed on the Jetson).

## What the first runs found (2026-09-17)

The point of a battery is what it finds that device-hunting did not,
so, for the record, the first run of each:

- Ethernet: **fragmented IPv4 datagrams are never answered** (0/20 at
  4000 bytes; every unfragmented size 100%), and TCP receive is ~6x
  slower than transmit (18-28 vs 113 Mbit/s) -- #633. Latency 1.3-2 ms,
  0% loss over 2000 back-to-back full frames, 200 simultaneous
  connections fine, RST on a closed port immediate.
  **Both resolved 2026-09-19.** The fragments were the tester: this
  host's never leave it, and from a second host (`--frag-via minipc`)
  the board answers 20/20 at 4000 and 20000 bytes. Receive is now 164
  Mbit/s (143 out). 60000-byte echoes pass at 100 Mb/s and are a stated
  hardware limit at 1000; see
  [docs/BAREMETAL-PORTING-LESSONS.md](../../docs/BAREMETAL-PORTING-LESSONS.md),
  section 3. Battery: 16 pass, 0 fail.
- Bluetooth, first run: **569 conversations leaked** by two 20-second
  connect/disconnect storms (accepted, hung up by the peer before a
  listen took them), and a listener's close not seen by a real BlueZ
  peer -- #632. After the fixes (a call nobody read is freed when the
  peer hangs up; a flushed listen open counts off its listener; a
  peer's fresh RFCOMM session displaces its closing one): **18 pass,
  2 fail, 0 conversations leaked**, the close seen. Left: the RFCOMM
  reconnect storm still sees a refusal on some cycles (one per
  reconnect that arrives inside the previous session's teardown), and
  the last ACL of a storm takes its idle timer to go.
- The chain that led to #635: the fixed `bt9p` raised "module not
  loaded" (its new `hid` library was not on the card) past `osinit`'s
  `"fail:*"` block, and the kernel's exception handler took a
  non-matching block for a handler at pc -1. `tests/exception_test.b`
  now runs inside the QEMU kernel as a harness check.

- Wi-Fi (hostapd on the Jetson's radio, 2026-09-17): **12 pass / 6 fail**.
  WPA2-PSK authenticates in 19 s -- the AP's own log shows
  `EAPOL-4WAY-HS-COMPLETED` for the board, a third stack's word for the
  supplicant -- hidden SSID too, wrong passphrase refused without
  wedging the radio, 30/30 echoes and 26.7 Mbit/s TCP over the radio
  alone. The failures: an **open network cannot be joined** (`crypt
  off` + `essid`: "join failed", every time); on **5 GHz** the handshake
  completes (109 s) but no frame crosses afterwards; the station does
  **not re-join on its own** within two minutes after the AP goes away
  and returns; PMF-required and WPA3-SAE are refused (the station
  implements neither, as expected). Two lessons the battery had to
  learn before it could run, both already in AGENTS.md: write `essid
  default` to a conversation before a supplicant, or it re-joins the
  OLD network; and bind `/tmp` over `/mnt` so `ip/wpa` finds factotum.
  DHCP over the radio is a SKIP: the boot's own client holds UDP 68.
  The run's last scenario also triggered #635 -- ten misaligned-PC
  breaks and a panic in JIT-emitted code -- which is what the serial
  check is for.
- GPIO (jig wired 2026-09-17): **45/45** -- every pair drives and reads
  both ways, pulls hold, no crosstalk, the console UART's pins refuse a
  function change, the firmware expander reports its lines. (One pair
  read open on the first run and passed after reseating: the battery
  is also a jig checker.)

Neither of the first two would have been found by pairing another
speaker.
