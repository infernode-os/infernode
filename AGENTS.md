# Repository Guidelines

## Project Structure & Module Organization

InferNode is a mixed C, Limbo, and shell repository — where "shell" means two dialects: host-side POSIX `sh` and Inferno's rc-style `sh` (see Coding Style below; they are not interchangeable). The Limbo rule is scoped to the **canonical core**: in-tree application code (`appl/`, `module/`) is written in Limbo. Connectors and ancillary services are deliberately not so constrained — **anything that speaks 9P integrates, in any language**. Serve 9P from Go, Python, Rust, C++, whatever you like; it gets mounted at a canonical path (`docs/NAMESPACE-LAYOUT.md`) and every InferNode program and agent uses it as files. You do not need to learn Limbo to contribute an integration. Core runtime and kernel code lives in `libinterp/`, `emu/port/`, and `libsec/`. Limbo applications and libraries live under `appl/`, with notable areas in `appl/cmd/`, `appl/veltro/`, and `appl/xenith/`. Interface definitions belong in `module/*.m`. Tests are under `tests/`, with emulator tests named `*_test.b` and host-side shell tests in `tests/host/*_test.sh`. Supporting material lives in `docs/`, `formal-verification/`, and `tools/`.

## Design Principles

Prefer Inferno / Plan 9 style solutions. Keep interfaces simple, file-oriented, and composable; avoid unnecessary JSON, policy layers, or framework-heavy mediation. Namespace boundaries are the primary capability mechanism, so changes to Veltro, `tools9p`, mounts, and exported services should preserve truthful namespace restriction, attenuation, and direct text protocols.

Before designing any new service, tool, or interface, read [docs/DESIGN-PRINCIPLES.md](docs/DESIGN-PRINCIPLES.md) — the reasoning behind these principles, with a wrong/right catalogue drawn from real decisions in this tree. Its companions: [docs/TUTORIAL-9P-SERVICE.md](docs/TUTORIAL-9P-SERVICE.md) (the worked example — design, build, test, and document a real service, `countfs`, that ships in this tree), [docs/9p-data-conventions.md](docs/9p-data-conventions.md) (text data formats; no JSON inside the namespace), [docs/NAMESPACE-LAYOUT.md](docs/NAMESPACE-LAYOUT.md) (`/mnt` vs `/n` placement), [appl/veltro/SECURITY.md](appl/veltro/SECURITY.md) (the agent capability model), and [docs/LIMBO-FOR-GO-PROGRAMMERS.md](docs/LIMBO-FOR-GO-PROGRAMMERS.md) if Limbo is new to you.

A new service or tool starts with a namespace sketch — the file tree it serves, each file's read/write behavior, an example shell session — proposed in an issue *before* implementation ("Proposing a new service or tool" in DESIGN-PRINCIPLES.md). The file interface is the design; review happens there first.

Task-specific playbooks live in `.claude/skills/<name>/SKILL.md` — plain markdown, useful to any agent or human, not only Claude:

- `ninep-server` — authoring a 9P file server or Veltro tool the canonical way
- `limbo-dev` — the compile loop, the wrong-target trap, stale bytecode
- `limbo-test` — the three test tiers, skip conventions, what CI gates
- `gui-test` — headless GUI harnesses: `/mnt/ui` driving, Tk-to-PNG, `scap`
- `emu-dev` — emulator C: blocking rules, CONF wiring, driver layering

Everything else — architecture, subsystem guides, compliance evidence — is indexed in [docs/DOCUMENTATION-INDEX.md](docs/DOCUMENTATION-INDEX.md).

## Build, Test, and Development Commands

Use the platform scripts instead of inventing local build flows.

- `./build-linux-amd64.sh` or `./build-linux-arm64.sh`: standard Linux builds.
- `./build-linux-amd64.sh headless`: Linux build without SDL3.
- `./build-macos-sdl3.sh` or `./build-macos-headless.sh`: macOS builds.
- `powershell -ExecutionPolicy Bypass -File build-windows-amd64.ps1`: Windows build.
- `cd appl/cmd && mk install`: rebuild one Limbo subtree into `dis/`.
- `cd tests && mk install && cd ..`: rebuild the Limbo tests into `dis/tests/`.
- `./run-tests.sh`: run host and emulator tests.
- `./run-tests.sh -h` or `./run-tests.sh -i -v`: run only host tests, or only emulator tests with verbose output.
- `./emu/<Platform>/o.emu -r. /tests/runner.dis -v`: run the native Limbo test runner directly when working inside the emulator workflow.

## Compiled bytecode is not in the repository

`dis/` holds compiled Dis bytecode. **It is a build product and is not
tracked**, exactly like `emu/*/o.emu`. A fresh clone has no runtime until you
build one. Do not commit `.dis` files, and do not treat a missing one as a
bug in the tree.

**Standard procedure after cloning, pulling, or changing any `.b` or `.m`:**

```sh
export ROOT=$PWD
export PATH="$ROOT/$SYSHOST/$OBJTYPE/bin:$PATH"   # e.g. Linux/arm64/bin
for d in appl appl/mpeg appl/veltro tests; do (cd $d && mk install); done
```

`hooks/post-merge` does this automatically after `git pull` — install it once
with `./hooks/install.sh`. Rebuilding the whole tree takes about 20 seconds.

Those four directories are the complete set: `appl/mpeg` and `appl/veltro` are
**not** in `appl/mkfile`'s `DIRS`, so `cd appl && mk install` alone does not
reach them. This catches people out; use the loop.

**If a change makes the build produce a different set of modules**, update
`tools/dis-manifest.txt` in the same commit. It lists every module the build
must produce, and `tools/verify-dis-build.sh` (run by CI and by every release
job) fails when one goes missing. Adding a module means adding a target to an
mkfile `TARG` *and* a line to the manifest; removing one means deleting both.
A module that is not in any `TARG` is never compiled — 45 were in that state
and only appeared to work because their bytecode had been committed by hand.

**Never run `limbo -o <path>` by hand.** Use `tools/compile-limbo.sh` or
`mk install` from the source directory. Choosing an output path yourself is
how modules end up somewhere no build installs to and no runtime loads from.

## Coding Style & Naming Conventions

Match the surrounding code closely. Limbo (`.b`) is close to Go in structure but should follow existing Inferno idioms, naming, and control-flow style. C uses Plan 9 / Inferno conventions and tabs, not generic modern C house styles. *Host-side* shell scripts (`tests/host/`, `tools/`, `build-*.sh`) stay POSIX `sh` compatible; scripts that run *inside Inferno* (`tests/inferno/`, `lib/sh/`, boot scripts) are rc-style — no `&&`/`||` — see [docs/INFERNO-SHELL.md](docs/INFERNO-SHELL.md). Name new emulator tests `*_test.b`, host tests `*_test.sh`, and keep module interfaces in `module/` aligned with their implementation names.

Use Inferno `mk`, not GNU make, for subtree builds. In `mkfile`s, do not chain commands with `&&`; use separate rules or `;`.

### Inferno sh traps

Three that cost real debugging time, none of which announce themselves:

- **Quoting is single-quote only.** `"like this"` is not a quoted string and
  usually produces `syntax error`. `''` embeds a quote.
- **`=` is the assignment operator**, so *any* argument containing one must be
  quoted: `echo 'proto=wpapsk role=client'`, never `echo proto=wpapsk`. The
  unquoted form is a syntax error, which reads like a problem with the command
  rather than with the shell.
- **A failed output redirection is fatal to the shell.** `echo x > /nonexistent`
  does not just fail, it *exits sh*. Over a serial or network console this
  presents as the connection dropping for no reason. Check the path exists
  before redirecting to it, especially for `/prog/<pid>/ctl` when the process
  may already have gone.

`ls` of some synthetic directories (`/dev`, `/chan`) prints nothing even when
files are there and readable; use a direct `cat` to test presence rather than
concluding the directory is empty.

## Working on the bare-metal board

Notes from bringing wifi up on a Pi 3B+ running the native kernel
(`os/init/osinit.b`, `/osinit.dis`). None of this applies to hosted `emu`.

### What must not regress, and what gates it

The hard-won fixes on this board each have a test that fails if they go,
and a change in their area is not done until that test has run. In
order of how much they cost to find:

| what | where it is guarded | run it when |
|---|---|---|
| The scheduler fix for #622 (a preempted proc resumes on its own core; clang copies `m`) and the kernel's four error-stack detectors | `tests/host/baremetal_test.sh`, the **scheduler soak** at the end: 90 s of six `/tmp` loops under QEMU, any detector line is a FAIL (`SOAKSECS=0` skips, `SOAKSECS=600` for a real soak) | every kernel change; CI runs it |
| Every Plan 9 C guarantee clang/gcc do not give, with the fault each produced | `docs/PLAN9-C-UNDER-OTHER-COMPILERS.md` -- a new fault of that class is a new entry **before** its fix merges | a fault with no explanation in the source |
| `bt9p` behaviour: pairing, keys, SDP, RFCOMM, LE HID, #632 (a call the peer hangs up before a listen takes it) | `tests/inferno/bt_ns_test.sh` against the mock (CI); `tests/acceptance/bluetooth.py` against BlueZ on the board | any change under `appl/lib/{bthci,l2cap,sdp,rfcomm,att,smp,hid}.b`, `appl/cmd/bt9p.b` |
| Wi-Fi: `crypt off` clears the firmware's WPA state (open networks join, #638); the supplicant re-issues the join while unassociated (re-join after an AP outage) | `tests/acceptance/wifi.py` with `wifi-ap.sh` on the tester -- the only test there is, since the radio is hardware | any change to `os/bcm2837/ether4330.c` or `appl/cmd/ip/wpa.b` |
| Ethernet: RFC 2544 figures, TCP behaviour, and #633 when fixed | `tests/acceptance/ethernet.py` | any change under `os/ip/`, the LAN78xx driver, `etherusb` |
| GPIO as files, the console pins refusing | harness check at boot (QEMU); `tests/acceptance/gpio.py` with the jig | `devgpio.c` |

The acceptance batteries need the board and a Linux tester
(`tests/acceptance/README.md`); their PASS/FAIL lines go in the PR. A
battery that cannot be run for want of hardware is said so in the PR,
not skipped silently.

### Installing a kernel on the board: candidate first, always

**Never write a kernel over `infernode8.img`.** Twice on 2026-09-17 a
kernel that panicked before the console shell existed went on the card
that way, and each time the card had to come out and go into a reader
-- once for a double free in the JIT that no QEMU run had reached, once
for a module load that broke the loader. The A/B procedure in
`os/bcm2837/README.md` exists for exactly this and costs nothing:

    cp <kernel> /n/dos/tryboot.img          # the candidate, under its own name
    echo tryboot > /dev/sysctl              # one boot under the 90 s watchdog
    # it comes up saying CANDIDATE, or the watchdog boots infernode8.img again
    mv /n/dos/tryboot.img /n/dos/infernode8.img   # promote, from its own shell

A candidate that panics costs a reset. The serial loader (`recover.c`,
`~/pitools/serialboot.py` sprays ETX until it answers) is the fallback
for a card whose good kernel is also gone -- but note that a kernel fed
that way once died at once in `qproduce` with a nil queue (console input
arriving before the UART's queue existed), so it is not yet a substitute
for the candidate boot.

**Copying to the card over the network console: verify, never remove
first.** `mount -A tcp!...!6666 /tmp/jet` fails silently if `/tmp/jet`
does not exist in that session's namespace (each session is a fresh
fork), and an `rm` before the `cp` then deletes the only copy --
`/dis/ip/wpa.dis` was gone from the card for a minute that way. `cp`
over the file, `ls -l` the size, then trust it.

**Two ways in, and you want both.** A USB serial console at 115200
(`/dev/ttyUSB0` on the host) always works and needs no network. A network
console on `tcp!*!17010` is enabled only if `/n/dos/netconsole` exists on the
card; its contents are a token the caller must send as the first line, after
which it hands over a shell with a *forked* namespace (`osinit.b` `netshell`).
Because the namespace is forked, anything you `bind` or start there is invisible
to the console shell and dies with the session — convenient for experiments,
useless for making a change stick.

**Pace scripted writes to the serial line** on kernels before the console
moved to the mini-UART (2026-09-13): those polled the PL011's 16-byte FIFO
every 10ms, so a scripted `write()` of a whole command line arrived truncated
at exactly 16 characters and executed as garbage; about 8ms per character was
reliable. The interrupt-driven console has not been measured for this yet --
the first board session drove it through the network console -- so keep the
pacing until someone has.

**Processes started from the network console outlive it.** The session's
shell dies; what it started does not, and it keeps whatever it held open. A
`bt9p` left behind keeps `/dev/eia0` open *and reading*, so the next session's
`bt9p` sends its Reset and the survivor eats the reply -- `eia0status`'s byte
counters advance, the new instance times out, and it reads as "the second
open never works". The mount it served died with its session, so nothing can
reach it either. `ps` lists survivors by module name (`Bt9p`, `Bthci`,
`Listen`); `kill Bt9p Bthci` before starting another. `listen(1)` does the
same with its connection.

**Bluetooth comes up from the card, not from a session.** `/n/dos/bt`
holds the `ctl` lines (`firmware`, `up`, `bdaddr`, `name`, `pairable`
...) and `osinit` mounts `bt9p` on `/net/bt` *before the shell starts*,
so the console, the network console and the desktop all inherit it;
`init: bt: <addr>` on the console says the radio is up. Change
`bt9p.dis` on the card and `echo reboot > '#c/sysctl'` rather than
restarting it by hand: a `bt9p` started from any session mounts into
that session's namespace only, and killing the boot one leaves every
other namespace's `/net/bt` pointing at a dead server, where the next
read blocks for ever. Keys live in `/n/dos/btkeys`; `cat
/tmp/factotum/ctl` lists whom the board is paired with. `listen -A
'bt!*!spp' cmd` and `dial("bt!addr!port")` are the application
interface; `bthid addr` puts an LE mouse on `/dev/pointer`.

**The C is Plan 9 C; the compilers are not.** gcc on Linux, clang on
macOS and for the bare-metal kernel, MSVC on Windows -- whatever the
host ships, by Inferno inheritance; Forsyth's `7c` is not in use. Every
guarantee the dialect takes from Plan 9 C that these compilers do not
give is recorded in `docs/PLAN9-C-UNDER-OTHER-COMPILERS.md` with the
fault it produced and the invariant that replaces it. When a fault has
no explanation in the source, read the compiler's output for the site
before theorising; the worst of these (#622, a stale copy of `m` across
a preempted migration) looked like a scheduler race for four days.

**Userspace dead, kernel alive, no panic: the Dis kproc died.** The
presentation is exact -- the board pings, `tcp!*!17010` accepts and
then resets, the serial line echoes keystrokes and nothing answers --
and it means `vmachine`, the kproc that owns the interpreter, unwound
out through an `error()` with no handler left (#622). The capture line
is `linkproc: error() underflow in N:dis`. Root cause found and fixed
2026-09-17 (#622, `docs/PLAN9-C-UNDER-OTHER-COMPILERS.md` 1): a stale
copy of `m` across a preempted migration pushed one kproc's error label
on another's stack; `runproc` now resumes a preempted proc only on its
own core. `vmachine` still audits its error stack after every Prog
quantum and prints `vmachine: error stack N, expected M, after prog P
<module> ...; re-armed` if it ever recurs, and `waserror()` prints
`waserror: up is X but the stack is Y's` naming the site. Either line is
a new instance of the class in that document. A *panic* reboots the
board by itself; the dead-Dis state did not, and needed the power pulled.

**On the host, `brltty` steals CH340 adapters.** The generic `1a86:7523`
USB-serial ID is also a Baum braille display, so a running `brltty` claims the
interface over usbfs and the `ttyUSB0` node disappears a second or two after
appearing. `udev` rules do not help, because the daemon is already running:
`systemctl stop brltty-udev.service brltty.service && systemctl mask` both.

**The card is a union, and FAT truncates names.** `rootbind` unions
`/n/dos/{dis,lib,fonts,icons}` *behind* the read-only kernel root, so writes to
`/lib/...` land on the card and appear in the union, but a name longer than 8.3
comes back under a different name than you created — a file written as
`.wtest` is `.wte` afterwards, which reads as "the write silently failed" when
it did not. `/usr` is `MREPL` and writable. `/dis/lib/wpakey.dis` and friends
resolve to the *card*, not the image, so replacing bytecode there does take
effect; `/lib/sh/profile` resolves to the read-only image copy, so it cannot be
the hook for boot-time changes. `/lib/lucifer/boot-baremetal.sh` comes from the
card and can.

**factotum runs unlocked, and that is deliberate.** `osinit.b` starts it with no
arguments, so neither persistence backend is configured, `allkeys` starts empty
and nothing prompts — which is the only arrangement that works on a headless
board. Keys are injected at boot by writing to `/mnt/factotum/ctl`, one key per
write (**multiline writes are refused** so a bad key can be identified). The
mount point needs `/tmp` bound over `/mnt` first, since the root is read-only.
`cat /mnt/factotum/ctl` lists what is loaded with secrets elided, so "what keys
does this machine hold" is answerable as a file. A second factotum cannot start:
it binds the same global srv entry `#sfactotum` and its `file2chan` creates fail
with *file already exists*. Reuse the running one.

**The radio latches its essid, and a failed join does not clear it.**
`ether4330.c`'s `CMauth` re-joins using `ctl->essid`, so `ip/wpa -s <new>`
writes the RSN element first (`wpa.b`), the driver immediately tries to join the
*old* network, and `wpa` dies with `the firmware did not report an association`
before it ever sets the new name. Every retry repeats it. Write `essid default`
to a conversation ctl to clear the name before switching networks.

**A wedged radio looks like a dead one.** Symptoms are `join failed` or an
association that never completes DHCP, with the interface's own `in`/`out`
counters frozen and `link: 0`. A *soft* reboot does clear it on current kernels
(probe takes `WL_REG_ON` low for 20ms, then high); only kernels predating that
need the operator to pull the power, which is what the INFR-467 comments
describe. `echo reboot > '#c/sysctl'` reboots; watch it come up on serial.

**Two interfaces on one subnet give asymmetric paths, not redundancy.** The
wifi address does answer: ARP is answered per-interface (`ethermedium.c`,
`iplocalonifc`) and the access point bridges the request to the station, so it
resolves to the radio's MAC. But the route for the shared prefix picks one
interface for everything outbound, so the replies leave by the cable. Measured
with five pings to the wifi address: the radio's `in` rose by 35 and its `out`
by **0**, while ether0's `pktout` rose by 11. The radio carries inbound only,
and its transmit path is not exercised at all — so a board that pings fine this
way has proved nothing about its radio. Test wifi with the cable out.

If a wifi address does not answer ARP at all, suspect the radio rather than the
stack: check `link:` in `#l1/ether1/stats` first. A deassociated radio produces
exactly the same symptom and is the more likely cause.

## Testing Guidelines

Behavior changes should include tests. Prefer the repository’s Limbo test setup instead of ad hoc harnesses: build tests with `mk install`, then run them through `tests/runner.dis` or `./run-tests.sh`. Host integration checks belong in `tests/host/`. `.dis` files are never committed; if a change adds or removes a module, update `tools/dis-manifest.txt` to match (see above).

## Security Review Priorities

Model threats in this order unless a task says otherwise:

- adversarial or prompt-injected AI agents running inside InferNode via the Veltro harness
- sophisticated remote automated attackers attempting protocol or emulator compromise
- attacks on communication and cryptographic protocols

When proposing fixes, prefer namespace, mount, process-group, file-permission, and protocol-shape solutions over bolted-on policy code.

## Commit & Pull Request Guidelines

Recent history uses scoped, imperative subjects such as `fix(theme): ...`, `build: ...`, and `test: ...`. Keep the first line under 72 characters, explain why in the body when needed, and reference issue IDs like `INFR-28` when relevant. PRs should stay focused, describe the motivation, include test coverage, update docs for interface changes, and include screenshots for UI work in Lucia/Xenith.

Know what CI will check before you push: `verify-dis-build` (the tree builds and produces every module `tools/dis-manifest.txt` lists), `verify-sh-exec` (Inferno-side test scripts committed mode 755), the ring-fence job (external escape-room harness material must not appear in the product tree), the advisory style gate (rc-violations, JSON inside `appl/`, new file interfaces with no linked proposal issue), plus builds, the test suites, CodeQL, and nsaudit fixture checks. The PR template's design-principles checklist is expected to be filled honestly.
