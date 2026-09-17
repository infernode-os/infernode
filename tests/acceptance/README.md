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
| (to do) `wifi.py` | hostap `hwsim` scenarios: WPA2-PSK, WPA3-SAE, PMF, re-association, DHCP after roam; 24 h association soak | `hostapd` on the tester's radio (AP mode is supported: `iw list`), `iperf3` | the station; `/n/dos/wifi` |
| (to do) `usb.py` | Linux `usbtest`/`testusb` patterns against a gadget; enumeration matrix; plug/unplug under load | a Pi Zero running `g_zero` | the host controller |
| (to do) `gpio.py` | no official Pi suite; a loopback jig (pins paired with jumpers): drive/read, pulls, alt functions, edges | serial console only | `#G`, the expander |

Each battery prints `PASS:`/`FAIL:`/`SKIP:` lines and a `Passed:/Failed:`
summary as the QEMU harness does, and with `--serial-log` pointed at the
serial capture, anything alarming the kernel says during the run --
`panic`, `ether0rx`, `won't halt`, the #622 detectors -- is a FAIL of
its own. Thresholds are deliberately loose where the number is what
matters (throughput records the figure; it gates only on absurdity).

```
tests/acceptance/ethernet.py  --board 192.168.1.104 --serial-log ~/captures/serial/today.log
tests/acceptance/bluetooth.py --board 192.168.1.104 --bdaddr b8:27:eb:ca:4c:8e
```

`board.py` is the shared driver: commands over the board's network
console (`osinit.b` netshell, token file `~/pitools/netcons.token` or
`--token`), the serial capture for the kernel's words, the PASS/FAIL
bookkeeping. `BOARD`, `BOARD_TOKEN`, `BOARD_SERIAL` in the environment
set the defaults.

## Tester prerequisites

- BlueZ's tools (`bluez` package; the Jetson has them). `l2ping` and
  `l2test -z` open raw L2CAP sockets and need `CAP_NET_RAW`:
  `sudo setcap cap_net_raw+ep $(which l2ping)` (and `l2test`), or they
  print as SKIP with that instruction.
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
- Bluetooth: **569 conversations leaked** by two 20-second connect/
  disconnect storms (accepted, hung up by the peer before a listen
  took them), and a listener's close is not seen by a real BlueZ peer
  though it is by the mock -- #632. Discovery, name, SDP browse/search,
  L2CAP configuration at MTU 672, data both ways, bonding: all pass.

Neither would have been found by pairing another speaker.
