# InferNode on bare metal: the manual

InferNode usually runs *hosted*: `emu` is a program on macOS, Linux or
Windows, and the host's kernel does the scheduling, the memory and the
devices. This is the other way of running it — **native**, as the
operating system itself, with nothing underneath. The kernel boots, brings
up the hardware, starts the Dis virtual machine, and runs the same Limbo
bytecode the hosted emulator runs: the same shell, the same Tk, the same
Lucifer desktop.

It runs on three machines. Two are below; the third, the **Raspberry Pi
4B** (`os/bcm2711`), boots to the desktop under QEMU's `raspi4b` and has
never run on a board — [os/bcm2711/README.md](../os/bcm2711/README.md)
says exactly what that does and does not establish.

| | Raspberry Pi 3B+ (`os/bcm2837`) | QEMU `virt` (`os/virt`) |
|-|-|-|
| what it is | a real board, and QEMU's `raspi3b` model of it | a machine that exists only in QEMU |
| what it is for | the product | testing the kernel anywhere QEMU runs, CI included |
| network | LAN7515 over USB; CYW43455 Wi-Fi | virtio-net |
| storage | SD card | virtio-blk (the *same card image*) |
| display, input | HDMI/DSI; USB keyboard and mouse; touch | ramfb; virtio keyboard and tablet |
| also | Bluetooth, GPIO, audio, A/B kernel update, boot watchdog | a real-time clock |
| interrupts | the BCM2837's own controller | GICv2 — what a Pi 4 has |

This document is how to run it, what controls it, and where things are.
It deliberately does not say *why* things are as they are; three other
documents do:

- **[os/bcm2837/README.md](../os/bcm2837/README.md)** — the engineering
  journal: every decision, measurement and war story, in the order they
  happened. Three thousand lines. Search it; don't read it through.
- **[os/virt/README.md](../os/virt/README.md)** — what the second machine
  is for, what it found, and the QEMU flags that fail without saying so.
- **[BAREMETAL-PORTING-LESSONS.md](BAREMETAL-PORTING-LESSONS.md)** — what
  a port to other hardware should take from this one.

and [BAREMETAL-BOARD-INTERFACE.md](BAREMETAL-BOARD-INTERFACE.md) is the
exact contract a new board directory has to meet.

## 1. How it is put together

    appl/ → dis/            Limbo programs: sh, Tk apps, Lucifer, Veltro…   (identical to hosted)
    ───────────────────────────────────────────────────────────────────────
    os/init/                the first Limbo: osinit, USB class drivers
    lib*/                   Dis VM + ARM64 JIT, Tk, draw, crypto, math
    os/port  os/ip          the portable kernel and TCP/IP, from upstream Inferno
    os/arm64                boot, traps, SMP, kmain — any AArch64 board
    os/bcm                  what the Raspberry Pi SoCs share: drivers (mailbox, UARTs, SD, USB, GPIO…), board.c, the MMU map
    os/bcm2837 │ os/bcm2711 │ os/virt
                            one board each: addresses, interrupt numbers, RNG, device list

The kernel image carries a small **recovery root** compiled into it —
`osinit`, the shell and its builtins, file utilities, `dossrv`, the USB
and Ethernet drivers — enough to reach the card and to give you a usable
console if the card is bad. Everything else, including the whole
desktop, comes off the card (or a file server) at boot: see `rootpath`
in section 5.

### Headless, or with a desktop

Both are ways of running it, and the machine decides which at boot by
one question: **is there a screen?**

**Headless** is what the port was for its first weeks and what a board
in a cupboard is for ever. No HDMI or DSI panel on a Pi; no
`-device ramfb` under QEMU. The machine boots to a shell on the serial
console with the full namespace; brings up Ethernet by DHCP (and Wi-Fi
and Bluetooth if the card says to); mounts the card and takes its
userspace from it, so every command in `dis/` is there; and listens on
the network console if the card has a `netconsole` file. The boot script
says one line —

    boot: no display -- running headless; not starting the desktop. This console is the machine's shell.

— and starts nothing else. A headless machine is administered over the
serial line, the network console, or whatever it is told to serve: it is
an Inferno system, so `listen`, `styxlisten` and `mount` are how it
offers and takes services. Nothing about it is degraded.

**With a desktop**: a screen is present, so the same boot goes on to
`wm/logon` (or straight past it, with `skiplogon`) and the Lucifer
desktop. The serial console is *still* a shell with the full namespace —
the desktop runs in a narrowed copy (section 6) — so a machine with a
desktop is a headless machine with a desktop as well.

With **no card at all** either kind still boots, to the recovery root
compiled into the kernel: a shell, the file utilities, the network. That
is what the image carries them for.

## 2. Building

There is one supported way to build the kernel, and it is the test
harness: it generates headers with the Limbo compiler, compiles the
Limbo that goes in the image, builds the root filesystem, and refuses to
leave a stale image behind a failed build.

    export ROOT=$PWD
    export PATH=$ROOT/<SYSHOST>/<OBJTYPE>/bin:$PATH      # the native mk and limbo
    for d in appl appl/mpeg appl/veltro tests; do (cd $d && mk install); done

    BAREMETAL_BUILD_DIR=/tmp/bm ./tests/host/baremetal_test.sh

| variable | |
|-|-|
| `BAREMETAL_BUILD_DIR=dir` | keep the artefacts there (otherwise a temp dir, deleted) |
| `BAREMETAL_PLATFORMS="bcm2837 virt bcm2711"` | which machines; the default is all three. Name one to work on it. |
| `BAREMETAL_BUILD_ONLY=1` | (virt) stop after the link |
| `EXTRACFLAGS=-D…` | extra compiler flags for an experiment, without editing anything |

It needs `clang` (any; it is asked for `--target=aarch64-elf`), `ld.lld`,
`llvm-objcopy`, `llvm-ar`, `python3`, the native `limbo`, a built `dis/`
(all four directories above — the image takes a module from `tests/`),
and `qemu-system-aarch64`. **If clang, lld or QEMU is missing the harness
skips and exits 0**: a run that says nothing about the kernel means the
toolchain was not found, not that everything passed.

What it leaves in the build directory:

| file | |
|-|-|
| `bcm2837-kernel.img`, `virt-kernel.img` | the kernels |
| `*-kernel.elf` | the same, with symbols: `llvm-nm -n` or `addr2line` turns a panic's addresses into names |
| `bcm2837-nojit.img` | the Pi kernel with the JIT off, for comparison |
| `cc.log` | every compiler, linker and tool diagnostic |
| `*-boot.txt`, `*-full.txt`, `*-desktop.txt`, `*.ppm` | serial logs and screens from the boots it made |

The bcm2837 half takes 18–35 minutes depending on the machine; the virt
half four to twelve. **CI runs both**, a job each, on every pull request
that touches the kernel, its libraries, the harness or the image tools
(`.github/workflows/baremetal.yml`). Because the harness skips when its
tools are missing, the jobs do not trust its exit status: they require
zero skipped, a floor on the number passed, and a named check near the
end of each machine's list.

## 3. Running it under QEMU

### `virt` — the quick way to a desktop

    # a card: the trees a Pi's card holds, as a FAT32 image. No root, no mtools.
    # 256: virt takes any size, but QEMU's SD card model (raspi3b, below)
    # refuses one that is not a power of two.
    printf 'local\n' > /tmp/rootpath;  : > /tmp/skiplogon
    tools/mkcard.py card.img 256 /dis=dis /lib=lib /fonts=fonts /icons=icons /usr= \
        /rootpath=/tmp/rootpath /skiplogon=/tmp/skiplogon

    qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 1024 \
        -kernel /tmp/bm/virt-kernel.img -serial stdio \
        -device virtio-rng-device \
        -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
        -drive file=card.img,if=none,format=raw,id=sd -device virtio-blk-device,drive=sd \
        -device ramfb -device virtio-keyboard-device -device virtio-tablet-device

A window opens on the Lucifer desktop in under a minute, and the terminal
you started QEMU from is the serial console — a root shell, the whole
time. Leave `skiplogon` out for the login screen.

**Headless**: use `-nographic` in place of `-serial stdio` and drop the
last line (`Ctrl-A x` quits). Same kernel, same card; it notices there
is no screen and boots to the shell and the network. Drop the `-drive`
line as well and it boots from the recovery root alone — the fastest way
to a prompt there is.

Each of those flags matters and most fail silently when wrong;
`os/virt/README.md` has the table. The two that catch everyone:
**`-cpu cortex-a53`** (without it `-M virt` is a 32-bit CPU and prints
nothing at all) and **`-kernel …img`, not `.elf`** (QEMU passes the
device tree only to a flat image).

### `raspi3b` — QEMU's model of the board

    qemu-system-aarch64 -M raspi3b -kernel /tmp/bm/bcm2837-kernel.img \
        -display none -serial null -serial stdio \
        -netdev user,id=n0 -device usb-net,netdev=n0 \
        -drive file=card.img,if=sd,format=raw

The same card comes up in the same desktop, at 640x480 (QEMU's default
framebuffer for this machine); drop `-display none` to see it.

**Two `-serial`s**: the first is the PL011, which on a Pi 3 belongs to
the Bluetooth radio; the console is the second, the mini-UART. With one
`-serial stdio` the machine appears to hang. The card image must be a
power of two in size. QEMU 6.2 does not pass `-append` to this machine
and fails checks for that alone; CI passes every check on 8.2.2, and 9.2
is what the port is developed against.

### Debugging a boot

`-s -S` halts before the first instruction with a GDB stub on `:1234`:

    lldb /tmp/bm/virt-kernel.elf -o 'gdb-remote 1234' -o 'breakpoint set --name kmain' -o continue

A panic prints a register dump and return addresses;
`llvm-nm -n the.elf` finds the functions. **Symbolise against the ELF of
the kernel that actually ran** — reading one build's addresses against
another's symbols has produced confident wrong answers here more than
once.

## 4. Putting it on a Raspberry Pi 3B+

The card is FAT32, partition at sector 2048 (what every imaging tool
makes). On it:

**From Broadcom** (not in this tree): `bootcode.bin`, `start.elf`,
`fixup.dat`.

**`config.txt`** — this, exactly:

    arm_64bit=1
    enable_uart=1
    init_uart_clock=48000000
    kernel=infernode8.img
    cmdline=cmdline.txt

    [tryboot]
    kernel=tryboot.img
    cmdline=tryboot.cmd

`tryboot.cmd` holds the single word `tryboot`. `cmdline.txt` may be empty
or absent. Do **not** add `dtoverlay=disable-bt`: the PL011 is the
radio's now. (On firmware too old to know `[tryboot]`, a `tryboot.txt`
that is `config.txt` with the two lines substituted does the same.)

**The kernel**: `bcm2837-kernel.img`, on the card as **`infernode8.img`**.

**Userspace**, from a built tree: `dis/`, `lib/`, `fonts/`, `icons/`, and
an empty `usr/` (it becomes the machine's writable home: secstore
accounts, keyrings).

**Radio firmware**, if you want Wi-Fi: `tools/pi-firmware.sh` fetches the
three `brcmfmac43455-sdio.*` files, checks them against pinned SHA-256s
(`tools/pi-firmware-manifest.txt`) and puts them in `firmware/`. Bluetooth
also wants `firmware/BCM4345C0.hcd`, which no tool here installs.

**Control files**, all optional: section 5.

You need a **3.3 V USB-serial cable on GPIO 14/15** (115200 8N1). The
console is mirrored to HDMI once the framebuffer is up, but everything
before that, and every panic, is on the serial line only.

### Changing the kernel without pulling the card

Never overwrite `infernode8.img` in place; it is the kernel you know
works. Install a **candidate** instead:

    cp /n/remote/new-kernel.img /n/dos/tryboot.img      # however it gets there
    echo tryboot > /dev/sysctl

The firmware boots `tryboot.img` **once**. The candidate arms a 90-second
hardware watchdog before doing anything slow; `osinit` releases it when a
shell can be typed at. It then prints what to do:

    mv /n/dos/tryboot.img /n/dos/infernode8.img     # keep it
    echo reboot > /dev/sysctl                       # or reject it

A candidate that panics or hangs is reset, the firmware's one-shot flag
is spent, and the machine comes back on `infernode8.img`. (`cp
/dev/bootimage /n/dos/tryboot.img` installs the *running* kernel — that
is how a kernel loaded over the serial line gets onto the card.)

What this rests on that only hardware can show — the firmware honouring
the flag, the watchdog actually counting — is discussed in the journal
under "Working on the board without moving the card". If a boot that
should have been a candidate says `wdog: not armed`, put `bootwatchdog`
in `cmdline.txt`.

## 5. Files on the card that control the machine

The card is mounted at `/n/dos`. Policy is **data on the card, never the
build**: the same kernel image is a thin client, an autonomous node or a
bench machine depending on what these say. All are optional.

| file | format | effect |
|-|-|-|
| `rootpath` | lines: `local`, or `net tcp!host!port` | Where userspace comes from, applied top to bottom. `local` unions the card's `dis/ lib/ fonts/ icons/` *after* the kernel's recovery root and binds `usr/` writable over `/usr`. `net …` mounts a Styx server (**no authentication**) on `/n/remote` and does the same from there. Absent = `local`. |
| `skiplogon` | existence only | The desktop starts without `wm/logon`, factotum or secstore. Keys will not persist. Delete it for the login screen. |
| `wifi` | `essid <name>` and `password <phrase>`, one per line; the value is the rest of the line | Join at boot, before anyone logs in. **The card is FAT: no permissions, and this is a passphrase in clear text.** Absent = the radio is left alone. |
| `bt` | one `/net/bt` ctl line per line (`#` comments). Typically `firmware /n/dos/firmware/BCM4345C0.hcd`, `up`, `name …`, `pairable on`, `discoverable on` | Bluetooth, via `bt9p` on `/dev/eia0`. `firmware` must precede `up`. Absent = no Bluetooth. See [BLUETOOTH.md](BLUETOOTH.md). |
| `btkeys` | factotum key syntax | Where `bt9p` keeps link keys so pairings survive a reboot. |
| `netconsole` | empty, or a token on the first line | A shell on **TCP 17010**, section 7. Absent = off. |
| `firmware/` | | Radio firmware, as above. |
| `infernode8.img`, `tryboot.img`, `tryboot.cmd` | | The kernel, a candidate, and the word `tryboot` — section 4. |

### The kernel command line

`cmdline.txt` on the Pi; `-append "…"` under QEMU. Whole words only. It
can be read back from `/dev/bootargs`.

| word | |
|-|-|
| `tryboot` | this boot is the candidate: arm the boot watchdog. (The firmware supplies it, from `tryboot.cmd`.) |
| `bootwatchdog` | arm the watchdog on an ordinary boot too |
| `nowatchdog` | never arm it; wins over the others |
| `wdogtest` | arm it and ignore the release, to watch the reset happen |
| `fb=WxH` | (virt) the screen size; default 1280x720 |

Nothing else is consulted. In particular which SD controller is used is
a build-time choice (`-DSDCARD_ARASAN`), not a word here.

## 6. What happens at boot

**`kmain`** (`os/arm64/main.c`): console; exception vectors; read the
command line and arm the watchdog if asked; MMU and caches; allocators;
interrupt controller; clock; process table; **a battery of self-tests**
(allocator, locks, channels, timer, a device interrupt, a three-second
wait for a keypress on the UART — they cost about four seconds and are
all asserted by the harness); framebuffer; the card and network devices;
the secondary cores; the Dis VM, running `/osinit.dis`.

**`osinit`** (`os/init/osinit.b`), in order: a few more self-checks (the
kernel image's SHA-1, GPIO, every core ticking, a JIT stress run) → bind
`#I #p #e #u #s #A` → loopback → **read the card's partition table, name
the partitions to `#S`, start `dossrv`, mount `/n/dos`** → apply
`rootpath` → hand the Wi-Fi firmware to the radio → an 8 MB memory
filesystem on `/tmp` → `wifi` → `bt` → the touch panel → a kernel network
card, if there is one (virt) → *spawn* the USB bus walk (keyboard, mouse,
Ethernet arrive when they arrive) → *spawn* the network console → tell
the kernel `booted` → **`sh -l` on the serial console.**

**`/lib/sh/profile`** (`os/init/profile`): `load std`; start
`auth/secstored`; run `/lib/lucifer/boot-baremetal.sh` in the
background, so the serial console stays an interactive shell.

**`boot-baremetal.sh`**: fork the namespace and **take the raw card, the
GPIO pins, `/dev/sysctl` and `/dev/hostowner` out of it** — then check
that they are really gone, and refuse to start the desktop if not. Then
ask the draw device whether there is a screen: **if not, say so in one
line and stop — the machine is headless.** Otherwise `wm/logon` (three
attempts; or `skiplogon`), `luciuisrv`, `lucifer`.
When the desktop exits the machine is still up: its `/dev/sysctl` is
null, so it cannot halt the board. The serial console can.

## 7. Getting at a running machine

**The serial console** is a shell with the full namespace, always.

**The network console**: create `/n/dos/netconsole` and connect to TCP
**17010**. An empty file means **no token — anyone who can reach the
port gets a shell**, and the boot log says so loudly. With a first line,
that line is a token: the server prompts `token: ` and drops a wrong
answer before giving it anything. The token crosses the network in the
clear; it stops a port scan and a curious neighbour, nothing more. Each
connection gets its own forked namespace and a plain `sh` (no profile,
so `load std` yourself); a mount made in a session dies with it.

**`/dev/sysctl`** (host owner only). Reading gives the version string.

| write | |
|-|-|
| `reboot` | reset |
| `tryboot` | reset into the candidate kernel (Pi); a plain reset (virt) |
| `booted` | release the boot watchdog. `osinit` does this. |
| `halt` | **resets after three seconds — it does not stop the machine** |
| `panic` | panic, deliberately |
| `console on` / `console off` | whether console text is also drawn on the screen |
| `broken` / `nobroken` | keep broken processes for inspection, or not |

**Debug keys** on the serial console: `Ctrl-T Ctrl-T` then

| key | | key | |
|-|-|-|-|
| `?` | list these | `p` | processes |
| `r` | reset, **from interrupt level** — works when the shell is dead | `m` | memory pools |
| `q` | panic | `l` | main pool, by allocation site |
| `S` | the screen, as shaded characters | `x` | xalloc |
| `D` | the screen, as hex (slow) | `f` | open files of process 6 |
| `\|` | toggle: one `Ctrl-T` suffices from now on | | |

From a script: `printf '\x14\x14r' > /dev/ttyUSB0` reboots a board that
no longer answers anything else.

## 8. Devices

Kernel devices (`#x`) and where they appear. "Pi" and "virt" say which
kernel includes them (`os/<board>/devtab.c`).

The ones that exist only in the native kernel have manual pages:
`sd(3)`, `boot(3)`, `ether(3)`, `gpio(3)`, `bench(3)`, `touch(3)`; with
`eia(3)`, `audio(3)`, `cons(3)`, `pointer(3)` and `draw(3)` for the rest.
`osinit(8)` is the boot sequence and the card's control files as a
reference page, and `mkcard(10.1)` the image tools. (`man 3 gpio` inside
Inferno; `groff -man -Tutf8 man/3/gpio` on the host.)

| | where | files | |
|-|-|-|-|
| `#c` | `/dev` | `cons consctl sysctl hostowner keyboard time random notquiterandom memory memtags sysstat sysname user jit` … | both |
| `#S` | `/dev` | `sdcard` (the whole device), `sdctl`, and one file per named range | both |
| `#B` | `/dev` | `bootimage` (the running kernel, byte for byte), `bootargs` | both |
| `#b` | `/dev` | `busec` — microseconds, for timing things honestly | both |
| `#m` | `/dev` | `pointer` | both |
| `#i` | — | the draw device. **Not bound at boot**: attaching it takes the screen from the text console. `bind '#i' /dev` when you mean it. | both |
| `#l` | `/net/ether0` | `clone addr stats ifstats n/{data,ctl,type}` — wired Ethernet | both |
| `#l1` | `/net/ether1` | the same, for Wi-Fi | Pi |
| `#I` | `/net` | `tcp udp icmp ipifc iproute arp` … | both |
| `#t` | `/dev` | `eia0 eia0ctl eia0status` (PL011), `eia1…` (mini-UART). Bound only when the card has a `bt` file. | both; virt has `eia0` only |
| `#u` | `/usb` | USB endpoints | both; empty on virt |
| `#G` | `/dev/gpio/N/` | `ctl` (`function in\|out\|alt0-5`, `pull up\|down\|none`, `edge rising\|falling\|both\|none`), `level`, `event` (blocks for an edge; `<µs> <level>`) | Pi |
| `#T` | `/dev` | `touch` — the DSI panel's raw buffer; `touch.dis` turns it into pointer events | Pi |
| `#A` | `/dev` | `audio audioctl` — the 3.5 mm jack | Pi |
| `#p #e #s #M #\| #D` | `/prog /env /chan` … | processes, environment, served names, mounts, pipes, TLS records | both |

**`/dev/sdctl`** has one verb, `part <name> <startblock> <nblocks>`, which
names a range of the device so that it appears as `/dev/<name>`; reading
it lists them. The kernel parses no partition table — a partition table
is data on the card, and `osinit` reads the MBR and writes those lines.

**A USB disk** (a stick, a card reader, an external drive: mass storage,
bulk-only, SCSI) is driven by `diskusb`, a program like the other USB
class drivers, which serves the whole disk as one file, `/chan/usbdiskN`,
and mounts its FAT partition on `/n/usbN` — **for init and the network
console.** The console shell forked its namespace when it started, before
any USB driver ran, so from it (or the desktop) the disk is mounted with
one command on the block file, which is in every namespace:

    dossrv -f /chan/usbdisk0 -m /n/usb0

Only on a machine with an xHCI controller so far — QEMU's `virt`, and a
Pi 4's USB-A sockets once the board is here. On a Pi 3 the disk is
enumerated and named (`init: ep5.0 is a USB disk; diskusb is not started
on this machine`) and left alone: the driver has run only under
emulation, and a Pi 3 gets no new behaviour on that evidence. One logical
unit, disks up to 2 TB, no hot removal of the medium.

## 9. Testing

| | what it proves | where it runs |
|-|-|-|
| `tests/host/baremetal_test.sh`, bcm2837 half (≈260 checks; **CI**) | the Pi kernel against QEMU's `raspi3b`: boot, SMP, JIT, USB hot-plug, the SD controllers, dossrv on FAT16/32, DHCP/TCP over emulated USB Ethernet, framebuffer by screendump, keyboard and mouse by QMP, tryboot, the kernel installing itself | anywhere with QEMU 8.2 or later |
| …virt half (≈50 checks) | the same kernel above the drivers, on virtio: GIC, PSCI, preemption on every core, disk read *and written*, DHCP, the console on screen, typed keys, tablet scaling, both virtio transports, **the Lucifer desktop from a card** | anywhere with QEMU; **CI** |
| `tests/acceptance/*.py` | the *board*, as a peer to standard tools on a Linux tester: RFC 2544-style Ethernet, Bluetooth PTS cases, hostap-style Wi-Fi scenarios, a GPIO loopback jig. See its [README](../tests/acceptance/README.md). | a bench with a Pi on it |

What QEMU cannot show is a long list — caches, DMA coherence, real USB
timing, a watchdog that counts, a radio — and it is why there are three
rows and not one. A change that passes the first two has been proved
for software.

## 10. What an operator should know is not done

- **Every process is the host owner.** The desktop's namespace no longer
  holds the raw card, the pins or `/dev/sysctl`, but there is no
  unprivileged user yet.
- **`/n/dos` is read-write inside the desktop**, because Inferno has no
  read-only bind on this kernel: a desktop program can still overwrite
  the kernel it booted from, through the filesystem.
- **The network console's token is sent in clear**, and `rootpath net`
  mounts without authentication.
- **The Ethernet link is assumed up for ever** once bound: no link
  monitoring, no DHCP lease renewal.
- **Logon and secstore are exercised only on the board** — the QEMU
  desktop check uses `skiplogon`.
- **The tryboot firmware handshake and the watchdog's countdown** are
  things QEMU models neither of.
- Not started: USB storage, the Pi 4, an audio or HDMI acceptance battery.
- On virt only: no GICv3; KVM untried. USB there is xHCI on the PCI bus and optional (`-device qemu-xhci`).
