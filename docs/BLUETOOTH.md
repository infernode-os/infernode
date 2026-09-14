# Bluetooth for InferNode

Status: Proposed — issue [#615](https://github.com/infernode-os/infernode/issues/615). Branch `feat/baremetal-bt`, off `feat/baremetal-pi`.
Board: Raspberry Pi 3B+ (BCM2837, CYW43455 combo radio). Nothing here
applies to hosted `emu` except where it says so.

This is the design, written before the code, as
[DESIGN-PRINCIPLES.md](DESIGN-PRINCIPLES.md) "Proposing a new service or
tool" asks. The file interface is the design; review it first.

## What exists, and what does not

**In this tree: nothing.** The one mention is a line in the roadmap of
[os/bcm2837/README.md](../os/bcm2837/README.md): "Bluetooth is on the
PL011 the console uses; it would mean the mini-UART for the console
first." That sentence is correct and is where this document starts.

**In the Plan 9 family: nothing either.** A code search of 9front, Plan 9
4th edition and open Inferno for "bluetooth" finds a USB keyboard quirk
(`kb.c`, both trees), a WiFi driver (`etherwpi.c`), a PCI id, and one
`#define PHYSUARTBT` in Inferno's `os/cerf250/mem.h` — a memory-map
entry for a UART with a Bluetooth module behind it, and no driver. No
repository written in Limbo mentions Bluetooth at all. Vita Nuova sold
Inferno into embedded products that had Bluetooth; whatever stack they
had was never in the open tree. So there is no stack to port. There is,
however, a great deal of *shape* to inherit, and this tree has already
made the decisions that matter.

## Precedents this design inherits

1. **The mechanism/protocol line**, `os/bcm2837/README.md` §"Decision:
   device protocols live outside the kernel, mechanism inside". The
   kernel owns registers, DMA and interrupts, and resources every user
   must share. One device family's protocol is a program. Applied three
   times already: `#u` + `etherusb.b`/`kbdusb.b`/`mouseusb.b`;
   `ether4330.c` (SDIO, firmware upload) + `wpa.b`/`wpakey.b`/factotum
   `wpapsk`; `#l` + `etherusb.b`. The Ethernet data path moved into the
   kernel *only after a measurement* said the Dis + 9P per-frame cost
   was the ceiling. Bluetooth will follow the same rule and the same
   order: protocol in Limbo, kernel data path only if a number demands
   one. At HID and RFCOMM rates none will; audio is the only candidate
   and is out of scope here.

2. **The serial device is `#t`, and it is already specified.** Inferno's
   `os/port/devuart.c` serves `/dev/eiaN`, `/dev/eiaNctl`,
   `/dev/eiaNstatus` on top of a per-board `PhysUart` (`os/port/uart.h`);
   the hosted emulator's `emu/port/deveia-posix.c` serves the *same
   names* over host ttys; `man/3/eia` documents the ctl verbs (`b<n>`
   baud, `m<n>` CTS/RTS flow control, `r<n>`, `d<n>`, ...). This
   repository carried `os/port/devuart.c` (748 lines) and `uart.h` until
   the migration commit `e3914b1c7` (2026-01-21) deleted them with the
   rest of the 32-bit `os/` tree; the upstream copies are identical and
   MIT. Reinstating them is an import, like `ethermedium.c` was, not a
   design. The payoff is that Limbo code speaking to `/dev/eia0` runs
   unchanged on the board and in hosted emu against a USB-serial adapter.

3. **The mini-UART driver exists and is MIT.** Plan 9 4e and 9front boot
   the Pi 3 with the console on the AUX mini-UART (`sys/src/9/bcm/
   uartmini.c`, 274 lines in 9front), GPIO 14/15 on ALT5, *precisely so
   that the PL011 is free for the radio*. It is written to the `PhysUart`
   interface, so it slots under the imported `devuart.c` with a rename.
   Provenance policy is the one the README sets: take driver code from
   Plan 9 4e or 9front and cite it, never via a third-party fork.

4. **The enable line is already mechanism the kernel has.** `BT_ON` is
   pin 0 of the VideoCore's GPIO expander, reached through the mailbox
   (`mailbox.c` "A pin on the firmware's GPIO expander: 128 + n");
   `ether4330.c` drives `WL_REG_ON`, expander pin 1, through exactly
   that call. `#G` exposes pins one directory each so that a namespace
   can hand a program one pin; the expander's eight join it as
   `128..135`, the firmware's own numbering (and 9front's `egpset()`),
   so a power switch is a pin and there is one schema for pins. In
   every earlier port -- the old Inferno Pi port, Plan 9, 9front -- these
   lines were switched by a kernel-internal function call that nothing
   outside could see or ask; this is the first to make them files.

5. **Firmware lives on the card**, README §"The WiFi firmware lives on
   the card, not in the tree": asked for as `/n/dos/firmware/<name>`,
   never committed, never in a release artefact. The Bluetooth patch
   file has the same licence problem and gets the same answer.

6. **Keys live in factotum**, precedent `proto=wpapsk`: the supplicant
   asks factotum for the key and never sees it stored.

7. **`/net/<proto>/clone` is how Plan 9 spells a network.** `#I` serves
   `/net/tcp/clone` and conversation directories `N/{ctl,data,status,
   local,remote}`; `#l` serves `/net/ether0` the same way. Inferno's
   `sys->dial("net!addr!service")` is implemented against that shape:
   open `/net/<net>/clone`, write `connect addr!service`. A Bluetooth
   service that serves it inherits every program that already dials.

## Hardware facts (verified against the Raspberry Pi device tree)

From `bcm2837-rpi-3-b-plus.dts` and `bcm283x-rpi-wifi-bt.dtsi`
(raspberrypi/linux, `rpi-6.6.y`):

| signal | where | note |
|---|---|---|
| BT UART | **uart0 = PL011** | `compatible = "brcm,bcm43438-bt"`, `max-speed = <2000000>` |
| PL011 TXD0/RXD0 | GPIO **32/33** ALT3 | *not* the header pins |
| PL011 CTS0/RTS0 | GPIO **30/31** ALT3 | hardware flow control is required at speed |
| 32.768 kHz LPO | GPIO **43** GPCLK2 | whether `start.elf` leaves GPCLK2 running must be read from `CM_GP2CTL` on the board, not assumed |
| BT_ON | expander pin **0** | via mailbox, like WL_ON (pin 1) |
| header UART | **uart1 = mini-UART**, GPIO 14/15 ALT5 | the console's new home |

The console cable does not move: the same header pins carry TXD/RXD,
only the alternate function changes. What does change is the clock. The
mini-UART's baud divisor is derived from the VPU core clock, which the
firmware scales unless `config.txt` pins it (`enable_uart=1` does this
on the Pi 3, fixing `core_freq=250`). The PL011 runs from
`init_uart_clock`, which is why the current console never had this
problem (`uart.c` records the distinction). The card's `config.txt`
gains `enable_uart=1` and the README's config recipe is updated in the
same change.

This kernel's console today (`os/bcm2837/uart.c`, `os/arm64/main.c`
`uartkproc`) is polled in both directions with a 10 ms sleep, which is
why AGENTS.md has to warn that scripted writes lose everything past the
PL011's 16-byte FIFO. An interrupt-driven `#t` console fixes that as a
side effect; the harness should assert it.

## Layering

```
                    kernel (C)                    │      programs (Limbo)
                                                  │
  mailbox ── #G/gpio/128/level (BT_ON) ───────────┼──► bt9p ─────────────► /net/bt/...
                                                  │     │                   ctl addr status
  PL011  ── PhysUart pl011 ─┐                     │     │ h4 over            scan lescan
                            ├── devuart.c (#t) ───┼──► /dev/eia0 ◄──────── event hci
  mini   ── PhysUart mini  ─┘   /dev/eia0..1      │     (bttransport.m)     clone N/{ctl,data,...}
                  │                               │
             console (kbdq)                       │   factotum ◄── proto=btlink (link keys)
                                                  │
                                                  │   profiles compose above /net/bt:
                                                  │   bt/hid → /dev/keyboard (as kbdusb.b does)
                                                  │   bt/serial (RFCOMM SPP), later audio
```

**Kernel.** Three things, all mechanism: `#t` (the import), two
`PhysUart`s, and `#G` learning about the expander's pins. No Bluetooth
word appears in kernel code.

**Limbo.** One program, `bt9p`, owns the controller: it is the HCI host.
It opens a *transport* and serves `/net/bt`. Everything the Bluetooth
specification calls "the host" — HCI command/event flow control, the
Broadcom patch upload, inquiry, connection management, L2CAP, security
manager — is inside it, in a memory-safe language. That is not the
reason for the split (the README explains why fault isolation cannot
be), but it is a real property of the result: the parser facing an
over-the-air attacker is Limbo, not C, which `#I` cannot say.

**Transport independence is the portability argument.** HCI is defined
over several transports (Core Spec Vol 4): H4 over UART (Part A), USB
(Part B), SDIO (Part D). `bt9p` takes its transport as an argument:

    bt9p -t /dev/eia0                the board: H4 over the PL011
    bt9p -t tcp!host!port            hosted emu: H4 over a socket to a
                                     bridge or a mock controller
    bt9p -t '#u/usb/ep3.0' ...       later: a USB dongle over #u, the
                                     kbdusb.b shape

`module/bttransport.m` is a channel of typed packets (command, event,
ACL, SCO) in each direction; `h4` is the first implementation and is
the only one this document commits to. The same `bt9p` then serves a
Pi 3, a Pi 4/5 (still UART) or any machine with a dongle. WiFi got no
such gift; `ether4330.c` is welded to one chip's SDIO protocol.

## Namespace sketch

### `#t` — serial ports (kernel; reinstated Inferno interface)

    #t/eia0          PL011: the radio            data, exclusive open
    #t/eia0ctl       b<n> m<n> r<n> ... as man/3/eia
    #t/eia0status    "b115200 c0 d0 e0 l8 m1 p n r1 s1 ..."  errors, queue lengths
    #t/eia1          mini-UART: the console (bound to kbdq at boot)
    #t/eia1ctl
    #t/eia1status

Bound at `/dev`. Nothing new to design; the interface is `man/3/eia`.
Only what the PL011 cannot do is refused (`p e`, `l7` may be; `m1`
must work).

### `#G/gpio/128..135` — the firmware GPIO expander (kernel; same schema)

    #G/gpio/128/level   read "0\n"|"1\n" (or "?\n" if the firmware will not say
                        and nothing was written); write "1" drives BT_ON
    #G/gpio/128/ctl     read "function out\npull none\n" as the firmware reports;
                        write refused: "no function select or pull to set"
    #G/gpio/129/level   WL_ON -- claimed by ether4330: reads, refuses writes
    #G/gpio/131/level   LAN_RUN, the Ethernet chip's reset -- unclaimed until
                        something needs to own it
    #G/gpio/132/level   HDMI hot-plug, an input: "not an output" on write

Same directory, same two files, same claiming rule as the SoC pins:
a driver that owns a line makes `#G` refuse it by name, so a stray echo
cannot power the WiFi radio off under its driver, and WiFi's power
becomes *readable* as a side effect. A namespace can hand `bt9p`
exactly `#G/gpio/128` and `/dev/eia0` and nothing else. What the
expander cannot do is refused truthfully rather than modelled.

Ethernet, WiFi and Bluetooth are thereby consistent: each radio or
chip has a power/reset line that is a pin in `#G`, owned by its
driver if the driver is in the kernel (`ether4330`, 129) and by a
program if the driver is a program (`bt9p`, 128). Firmware *power
domains* (the USB block, SD, the UARTs) are a different resource,
switched by a different mailbox tag, and are deliberately **not**
pins; they are a separate proposal.

### `/net/bt` — the controller and its links (Limbo, `bt9p`)

    /net/bt/
      addr        read  "b8:27:eb:xx:xx:xx\n"           the local BD_ADDR
      status      read  one field per line:
                        up 1
                        name infernode
                        hci 4.2 lmp 4.2 manufacturer 15
                        firmware BCM4345C0 1.0.0
                        transport /dev/eia0 3000000
                        connections 1
      ctl         write "up" | "down" | "reset"
                        "name <string>"
                        "class <hex>"
                        "discoverable on|off"   "connectable on|off"
                        "firmware <path>"        the .hcd, named by the caller
                                                 (kernel and bt9p name no path;
                                                 boot script says /n/dos/firmware/BCM4345C0.hcd)
                        "baud <n>"               the controller, then the transport's ctl
                        "bdaddr <addr>"          Broadcom Write_BD_ADDR; the patch leaves a default
                        "iocap none|display|yesno|keyboard"   default none: Just Works
                        "pairable on|off"        default off: no uninvited pairing
                        "forget <addr>"          the link key, from factotum and the keys file
      pair        read  pairing prompts while held open: "confirm <addr> <n>",
                        "passkey <addr> <n>", "passkey? <addr>", "paired <addr>",
                        "failed <addr> <why>"; write "yes <addr>" | "no <addr>" |
                        "passkey <addr> <digits>". Nobody reading is a no. Root only.
      scan        read  runs a BR/EDR inquiry; one line per device:
                        "<addr> <class> <rssi> <name>", written once the
                        name is known (EIR, or a Remote Name Request after
                        the inquiry; "-" if it will not say); EOF after the
                        last (default 10 s; "scan <secs>" on ctl adjusts)
      lescan      read  same for LE advertising: "<addr> public|random <rssi> <name-or-->"
                        EOF when the scan time is up
      event       read  the HCI event stream as text, one event per line,
                        for debugging -- what btmon shows. Root only.
      hci         read/write raw H4 packets. Exclusive open; takes the
                        transport away from the stack while held. For
                        bring-up and tests. Root only, never granted.
      clone       open  yields a new conversation N
      N/ctl       write "connect <addr>!<psm>"           L2CAP, as a dial string
                        "connect <addr>!rfcomm<chan>"    RFCOMM (milestone 7)
                        "announce <psm>"                 listen
                        "hangup"
      N/data      read/write. L2CAP: one SDU per read or write.
                  RFCOMM: a byte stream.
      N/status    read  "Connected\n" | "Listen\n" ... as /net/tcp
      N/local     read  "<addr>!<psm>"
      N/remote    read  "<addr>!<psm>"
      N/listen    open  accept the next inbound connection (as /net/tcp)

Because `clone` exists, `sys->dial("bt!b8:27:eb:11:22:33!17")` works
with no change to `dial`. So does `listen`.

Placement: `/net`, not `/mnt`. This is a network — the tree's own
precedent is `/net/ether0` served by `#l` and `/net/tcp` by `#I`, and
the dial string is the interface. Profiles that *interpret* a link
(keyboard, serial port, audio) invent schema and therefore go under
`/mnt/bt/<profile>` or, where a precedent says otherwise, where the
precedent says: `bt/hid` writes into the console the way `kbdusb.b`
does, and an RFCOMM serial port has every reason to present as
`eiaN`-shaped files.

### Example session

    ; bind -a '#t' /dev
    ; echo 1 > '#G/gpio/128/level'
    ; bt9p -t /dev/eia0 -k /n/dos/btkeys
    ; echo 'firmware /n/dos/firmware/BCM4345C0.hcd' > /net/bt/ctl
    ; echo up > /net/bt/ctl
    ; cat /net/bt/addr
    b8:27:eb:5a:6b:7c
    ; cat /net/bt/scan
    94:bb:43:44:61:04 0x1c010c -61 hephaestus
    ; dial -A 'bt!94:bb:43:44:61:04!4097' sh -c 'echo -n hello; read 100 >[1=2]'

### What it composes with, and does not do

- **factotum** holds link keys, `proto=btlink addr=<remote> type=<n>
  !key=<hex>`, and pre-shared PINs, `proto=btpin [addr=<remote>]
  !pin=<digits>`. A missing PIN is factotum's `needkey` like any other
  missing key. A numeric comparison is a line on `/net/bt/pair` for
  whoever holds it open; with `iocap none` there is none. `bt9p`
  writes a key to one file only: the keys file named by `-k`, in
  factotum's syntax, because factotum cannot be read back for secrets
  and whoever receives the key is the only one who can persist it --
  Plan 9's `factotum -S` and NVRAM, the same shape.
- **audit**: `up`, `down`, pairing and connection events are logged the
  way `#l`'s attach is; nothing new.
- It does **not** do audio, mesh, GATT beyond scanning, or any kernel
  data path.

### Agents

`/net/bt` is not in a confined agent's namespace unless granted, the
same as `/net`. If granted: conversation directories `N/` are
grantable (a pipe to one peer); `ctl`, `hci`, `event`, `scan` are
control plane and are not — `scan` in particular pairs a sensitive read
(who is nearby) with nothing an agent needs. `#G/gpio/128` is a power
switch and is never granted.

## Firmware

The CYW43455's Bluetooth core boots from ROM and takes a patch RAM
image over HCI: `BCM4345C0.hcd`, from `RPi-Distro/bluez-firmware`,
under the same Cypress/Broadcom binary-redistribution stanza as the
WiFi blobs. Not committed, not in any artefact, asked for by the boot
script as `/n/dos/firmware/BCM4345C0.hcd`. Without it the controller
still answers HCI at 115200 with its ROM firmware and a default
address, so `addr` and `status` work before the patch and are the
first thing to see on the board.

The upload sequence is Broadcom vendor HCI (opcodes 0xFC2E
Download_Minidriver, 0xFC4C Write_RAM per `.hcd` record, 0xFC4E
Launch_RAM, then 0xFC18 Update_UART_Baud_Rate), as BlueZ's `hciattach
bcm43xx` and Linux `btbcm.c` perform it. Those are GPL and are
references for *behaviour*, not sources of code; the sequence itself is
Broadcom's documented vendor interface and the `.hcd` format is a
sequence of HCI command packets.

## Development without the board

**QEMU cannot emulate the controller.** The whole Bluetooth subsystem
was removed from QEMU in 5.1, and `raspi3b` never modelled the radio.
What QEMU does model is both UARTs, so milestones 0–1 are exercised
there, and the PL011 can be pointed at a host socket for a *mock*
controller. This box's QEMU is 6.2.0, whose `raspi3b` does not deliver
`-append` (7 harness assertions fail for that reason alone, none
tree-related); a newer QEMU is milestone 0. Under QEMU the PL011 is
`-serial` #0 and the AUX mini-UART is `-serial` #1 (to be confirmed by
the first boot, and the harness then passes both).

**A real controller is on the development host.** This Jetson has a USB
Bluetooth radio, `hci0`. Linux's `HCI_CHANNEL_USER` hands a raw HCI
socket to one process with the device down; `tools/hci-h4-bridge.py`
presents it as H4 over TCP, and `bt9p -t tcp!127.0.0.1!5555` in hosted
emu then drives real silicon with no board and no kernel:

    sudo hciconfig hci0 down
    sudo ./tools/hci-h4-bridge.py 0 5555
    ./emu/Linux/o.emu -r. sh -c 'bt9p -t tcp!127.0.0.1!5555; echo up > /net/bt/ctl; cat /net/bt/status; cat /net/bt/lescan'

It needs root once and takes `hci0` away from `bluetoothd` while it
runs (the kernel gives it back on exit). It is the fastest loop for
milestones 2 and 4–7 and is not a substitute for milestone 3. Not yet
run: it needs a root shell, which this session does not have.

**A mock controller** for the Limbo unit tests: a fake H4 peer that
answers Reset, Read_Local_Version, Read_BD_ADDR and the vendor
commands, and emits Inquiry_Result events. Enough to pin command flow
control, event parsing and the patch-upload state machine in
`tests/bt_*_test.b` with no hardware at all.

## Milestones

Each lands separately, with tests, and each leaves the board no worse.

**M0 — a QEMU that models the machine.** *Done 2026-09-13.* QEMU 9.2.4
built from source into `~/.local` on the development host (Ubuntu
22.04's 6.2 does not deliver `-append` to `raspi3b`); the 7 failing
harness assertions pass. `raspi3b` gives `-serial` #0 to the PL011 and
#1 to the mini-UART (`hw/arm/bcm2835_peripherals.c`), confirmed from
source and by boot.

**M1 — the console moves to the mini-UART; `#t` returns.** *Landed
under QEMU 2026-09-13; on the board the same night: console clean at
115200 first boot, core clock 400MHz (asked, not assumed), PL011 receive
path proven byte for byte.* `os/port/devuart.c`
and `uart.h` reinstated with the locks named; `os/bcm2837/uartmini.c`
(from 9front, MIT) and `uartpl011.c` as `PhysUart`s; `uart.c` reduced
to console policy over the polled mini-UART. Console input arrives on
the mini-UART's receive interrupt through `consuartputc`; the 10ms
polling kproc is gone. Both drivers ask the mailbox for their clock.
The PL011's level-triggered TXI is masked except while bytes remain.
Harness: banner on `-serial` #1, six files under `#t`, `eia0ctl` takes
`b921600`/`m1` and refuses a bad verb, a socket peer on the PL011 sees
two writes come back through the receive path in order, a 157-byte line
typed at the console arrives whole. `os/bcm2837/README.md` "The console
is on the mini-UART" records what QEMU could not show, for the first
board session: `enable_uart=1` on the card, `dtoverlay=disable-bt`
removed, serialboot unaffected (it muxes 14/15 itself).
`#G/gpio/128..135` landed the same day: the expander as pins, `ether4330`
claiming 129, seven harness checks.

**M2 — `bt9p` exists and speaks HCI.** *Done 2026-09-13, against the
mock.* `module/bthci.m` + `appl/lib/bthci.b`: the Deframer, event and
Inquiry Result decoders, and an `Hci` that queues commands under
Num_HCI_Command_Packets, matches Command Complete/Status by opcode,
times out, and survives a stingy, silent or dead controller
(`tests/bthci_test.b`, 14 checks). `module/btmock.m` + `appl/lib/
btmock.b`: the fake controller, bytes in and out, also served as a
file by `btmock(4)`. `appl/cmd/bt9p.b` serves `/net/bt/{addr,status,
ctl,scan,event,hci}` -- `scan` came forward from M4 because the
streaming-read idiom was needed for `event` anyway; names are `-`
until M4 asks for them. `tests/inferno/bt_ns_test.sh` is the contract
test: modes, refusals, `up`, a two-device scan twice, the event
stream, the exclusive `hci`. `man/4/bt9p`. "No controller" is
`up`'s error when the reset goes unanswered. The transport is one
name: `-t /dev/eia0`, `-t tcp!host!port`, `-t /chan/btmock`.

**M3 — first light on the board.** `#G/gpio/128` up, ROM firmware answers at
115200, `.hcd` uploaded, baud raised to 921600 then 3 Mbaud with
`m1`, `Read_BD_ADDR` returns the board's own address. The first
hardware milestone and the first that needs the board at all.
*Done on the board 2026-09-14.* The ROM answered once two things
were understood: the controller holds its transmitter until CTS is
asserted (`bt9p` now sets `m1` on any serial transport itself), and a
`bt9p` left over from an earlier console session was reading the
port (`os/bcm2837/README.md`, "What the board showed"). `firmware`
uploaded the 323 records of `BCM4345C0.hcd`; the controller came back
as `BCM43455 37.4MHz Raspberry Pi 3+-0190`, HCI 5.0, Cypress. Its
address after the patch is the patch's default `43:45:c0:00:1f:ac`;
a `bdaddr` verb (Broadcom `Write_BD_ADDR`) for the board's own is
still to write. `baud` above 115200 has not been tried on silicon.
Also found on the way: the firmware's mailbox reply word trails its
mailbox reply, so `#G/gpio/128/level` reported *refused* for writes
that took effect; `mboxcall` now waits for it.

**M4 — discovery.** `scan`, `lescan`, remote name requests. *Done
against the mock 2026-09-13:* a device's `scan` line is written once
its name is known -- from the EIR, or from a Remote Name Request made
after the inquiry, one at a time, `-` on a page timeout -- and
`lescan` is an active LE scan for the `scan` time, one line per
device heard with its address type and the name from its advertising
data. *On silicon 2026-09-14:* the board's `scan` found the host's
controller (behind the bridge, made discoverable by a hosted `bt9p`)
at -33dBm with its name; `lescan` ran clean and heard nothing, there
being no LE advertiser in the room to hear.

**M5 — L2CAP and conversations.** `clone`, `N/`, `dial` and `listen`
over L2CAP; SDP client as a library (`sdp.m`); the board and the host
exchange bytes. *Done against the mock 2026-09-13, SDP excepted:*
`module/l2cap.m` + `appl/lib/l2cap.b` is basic-mode L2CAP as a state
machine with no I/O (`tests/l2cap_test.b`, two Links against each
other through 27-byte fragments); `bt9p` has links (Create_Connection,
Accept, Disconnect, Number_Of_Completed_Packets credits per handle,
reclaimed at Disconnection Complete), `clone` and `N/{ctl,data,status,
local,remote,listen}` with `/net/tcp`'s semantics, and a link is torn
down when its last channel goes. The mock has a peer side: an L2CAP
echo service on PSM 0x1001, an incoming call on request, and it
records what it is sent. The contract test connects, echoes, hangs up,
is refused by PSM and by page timeout, announces and takes a call,
and runs the kernel's `dial(2)` against the tree with no change to
`dial`. SDP is deferred to when a profile needs it (M7). *On silicon
2026-09-14:* the host's `dial(2)` on `bt!<board>!4099` against a
hosted `bt9p` on the bridge, the board's `listen` accepting, and a
line each way over the air; the board reported `Hangup remote hangup`
after. The one thing real controllers corrected: the Disconnect
command's reason was 16r16, which the mock accepted and a Realtek
refused as a parameter error -- 16r13 is the reason a host gives, and
the mock now refuses the rest as the controller did.

**M6 — pairing through factotum.** `proto=btlink`; SSP numeric
comparison via the confirmation path; legacy PIN for old peripherals.
*Done against the mock 2026-09-13, the WiFi way.* factotum is the only
source of secrets (`auth/proto/btlink`, `auth/proto/btpin`); a link
key the controller makes goes to factotum's ctl and, with `-k`, to the
keys file in factotum's own syntax, which `bt9p` loads at start one
write per key -- the card is the persistence, factotum the runtime
holder, exactly `/n/dos/wifikeys` (#606). Nothing prompts unless a
file is being read: `iocap none` (default) is Just Works; `pairable
off` (default) refuses pairings we did not ask for; `iocap yesno`
turns confirmations into lines on `/net/bt/pair`, and nobody holding
it open is a no. `forget <addr>` removes a key from both places. The
mock demands a PIN or SSP per device and remembers the keys it
issued, so the contract test pairs, reconnects on the key, forgets,
confirms through the file, and is refused when pairable is off.

**M7 — first profiles.** `bt/hid` (a keyboard at the board, the
`kbdusb.b` shape) and RFCOMM SPP.

## Test plan

- **Limbo unit tests** (`tests/bt_hci_test.b`, `bt_h4_test.b`,
  `bt_l2cap_test.b`, `bt_hcd_test.b`): framing, flow control, the
  patch state machine, SDU reassembly, against the mock transport.
- **Namespace contract tests** (`tests/inferno/bt_ns_test.sh`): `/net/bt`
  has exactly the files above with the modes above; `ctl` rejects
  malformed verbs with an error, not silence; `hci` is exclusive.
- **Host harness** (`tests/host/baremetal_test.sh`): M1's assertions;
  later, a mock controller on the PL011 socket so `bt9p` reaches
  `addr` under QEMU with no radio.
- **Board runbook** in `os/bcm2837/README.md`, as every other subsystem
  has: what was measured, on which kernel, and what QEMU could not
  have shown.

## Open questions for review

1. *Closed:* the power line is `#G/gpio/128`, not a `power` verb on
   `eia0ctl` and not a separate `#G/exp/N` directory. One schema for
   pins; a radio's switch is a pin whoever drives it.
2. *Closed:* `scan` is a streamed read; `cat` does the whole job. One
   refinement from building it: a device's line waits for its name,
   so a line is complete when it appears and there are no corrections.
3. Whether RFCOMM belongs in `bt9p` or in a separate `bt/rfcomm`
   composing over L2CAP conversations. Proposed: separate, decided at
   M7 when there is a measurement of what the extra hop costs.
4. *Closed:* `bt9p`, following `msg9p`/`wallet9p`/`tools9p`.

## References

- Bluetooth Core Specification v5.x, Vol 4 Part A (UART transport,
  H4), Part E (HCI); Vol 3 Part A (L2CAP), Part B (SDP), Part H
  (Security Manager). RFCOMM (Bluetooth SIG, TS 07.10-derived).
- Plan 9 4e / 9front `sys/src/9/bcm/uartmini.c` (MIT) — the mini-UART
  `PhysUart`, and the choice of console.
- Inferno `os/port/devuart.c`, `os/port/uart.h`, `os/pxa/devuart.c`
  (MIT; also in this repository's history at `e3914b1c7^`) — `#t`.
- This tree: `emu/port/deveia-posix.c`, `man/3/eia`, `os/port/devgpio.c`,
  `os/bcm2837/mailbox.c`, `os/init/etherusb.b`, `os/bcm2837/README.md`.
- raspberrypi/linux `arch/arm/boot/dts/broadcom/bcm2837-rpi-3-b-plus.dts`,
  `bcm283x-rpi-wifi-bt.dtsi` — pins and the enable line.
- BlueZ `tools/hciattach_bcm43xx.c`, Linux `drivers/bluetooth/btbcm.c`
  (GPL) — behaviour reference for the patch upload, not code.
- Zephyr `subsys/bluetooth/host` (Apache-2.0) — a compact, readable
  host implementation, for cross-checking state machines.
