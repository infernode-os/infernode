# InferNode

[![Latest release](https://img.shields.io/github/v/release/infernode-os/infernode?display_name=tag&cacheSeconds=3600)](https://github.com/infernode-os/infernode/releases/latest)
[![Container image](https://img.shields.io/badge/ghcr.io-infernode--os%2Finfernode-blue?logo=docker)](https://github.com/infernode-os/infernode/pkgs/container/infernode)
[![CI](https://github.com/infernode-os/infernode/actions/workflows/ci.yml/badge.svg)](https://github.com/infernode-os/infernode/actions/workflows/ci.yml)
[![Security Analysis](https://github.com/infernode-os/infernode/actions/workflows/security.yml/badge.svg)](https://github.com/infernode-os/infernode/actions/workflows/security.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/infernode-os/infernode/badge)](https://scorecard.dev/viewer/?uri=github.com/infernode-os/infernode)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/12422/badge)](https://www.bestpractices.dev/projects/12422)
[![SLSA 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**64-bit Inferno® OS for embedded systems, servers, and AI agents.**

InferNode is a modern Inferno® distribution with JIT compilation on AMD64 (14×) and ARM64 (9×), namespace-isolated AI agents (Veltro), an optional SDL3 GUI (Lucia + Xenith), and a complete Plan 9-inspired environment — all in under 30 MB of RAM.

## Quick Start

### Install (recommended)

Every tagged release ships signed binaries for macOS, Linux, and Windows on the [latest release page](https://github.com/infernode-os/infernode/releases/latest). No toolchain, no build step — download and run.

- **macOS (Apple Silicon)** — `infernode-*-macos-arm64.dmg`: open, drag to Applications, launch.
- **Windows (x86_64)** — `infernode-*-windows-amd64-gui.zip`: extract, **double-click `setup-windows.bat`** (it clears the Mark-of-the-Web tag from the bundle and configures an LLM backend), then double-click `InferNode.exe`. (Until code-signing lands, the unsigned `InferNode.exe` would otherwise be silently blocked by SmartScreen after browser download — Windows propagates Mark-of-the-Web from the zip to every extracted file. `.bat` files are exempt from that gate, so `setup-windows.bat` runs anyway and its first job is to unblock the rest of the bundle.)
- **Linux x86_64 (GUI)** — `infernode-*-linux-amd64-gui.tar.gz`: SDL3 is bundled.
- **Linux ARM64 (GUI)** — `infernode-*-linux-arm64-gui.tar.gz`: for Jetson, Raspberry Pi, etc.
- **Linux (headless)** — `infernode-*-linux-amd64.tar.gz` or `infernode-*-linux-arm64.tar.gz`.
- **Container** — multi-arch (amd64 + arm64) headless image on GHCR:
  ```bash
  docker run -it ghcr.io/infernode-os/infernode:latest
  ```

```bash
tar xzf infernode-*-linux-*-gui.tar.gz
cd infernode-*-linux-*-gui
./infernode                   # or ./infernode-headless in the non-GUI tarballs
./setup-desktop.sh            # optional: app-menu/dock icon, or `infernode` on $PATH
```

> Pick the tarball that matches your CPU: `amd64` for Intel/AMD, `arm64` for Jetson / Raspberry Pi / Apple-Silicon Linux. The wrong arch fails with `ld-linux-aarch64.so.1: No such file` (or similar).

Every release asset is published with a cosign bundle (`.pem` + `.sig`) and a signed `SHA256SUMS.txt`; container images carry SLSA build provenance. See [Releases](https://github.com/infernode-os/infernode/releases) for the full history.

Code signing for Windows builds is provided by the [SignPath Foundation](https://signpath.org/) — a non-profit that signs open-source releases with certificates issued by SSL.com. Signed Windows binaries get verified Publisher metadata and Microsoft SmartScreen reputation; without signing, browser-downloaded zips carry a Mark-of-the-Web tag that Windows propagates to every extracted file and SmartScreen then silently blocks (handled in the meantime by `setup-windows.bat`, which clears the tag from the bundle on first run — see the Windows install bullet above).

### Build from source

Prefer a release unless you need bleeding-edge `master` or a platform without a prebuilt binary.

**Linux (x86_64 or ARM64):**
```bash
git clone https://github.com/infernode-os/infernode.git
cd infernode
./install-sdl3.sh              # one-time, GUI only
./build-linux-amd64.sh         # or ./build-linux-arm64.sh; add 'headless' to skip SDL3
# GUI:
./emu/Linux/o.emu -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r$PWD sh -l /lib/lucifer/boot.sh
# Headless (Inferno ';' shell):
./emu/Linux/o.emu -c1 -r$PWD sh -l
```

**macOS (Apple Silicon):**
```bash
git clone https://github.com/infernode-os/infernode.git
cd infernode
./makemk.sh                    # bootstrap mk (one-time)
brew install sdl3 sdl3_ttf     # GUI only
./build-macos-sdl3.sh          # or ./build-macos-headless.sh
# GUI:
./emu/MacOSX/o.emu -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r$PWD sh -l /lib/lucifer/boot.sh
# Headless:
./emu/MacOSX/o.emu -c1 -r$PWD sh -l
```

**Windows (x86_64)** — from an **x64 Native Tools Command Prompt**:
```powershell
powershell -ExecutionPolicy Bypass -File build-windows-amd64.ps1
# Headless (Inferno ';' shell):
.\emu\Nt\o.emu.exe -c1 -r%CD% sh -l
```
For the SDL3 GUI on Windows, see [docs/WINDOWS-BUILD.md](docs/WINDOWS-BUILD.md); the launch shape matches the macOS/Linux GUI lines above.

stdout/stderr stream to the terminal; Ctrl-C exits. `-c1` enables the JIT; `-r$PWD` tells the emulator to use the working tree as the Inferno® root, so `mk install` results show up on the next launch. See [QUICKSTART.md](QUICKSTART.md#running-for-development) and [docs/USER-MANUAL.md](docs/USER-MANUAL.md) for more.

## Highlights

- **Lightweight** — 15–30 MB RAM, 2-second startup, ~10 MB on disk.
- **JIT compiled** — native code generation on AMD64 and ARM64; interpreter fallback everywhere.
- **AI agents** — namespace-isolated [Veltro](appl/veltro/SECURITY.md) agents with 39 tool modules, LLM integration via 9P, and formally verified containment.
- **GUI (optional)** — three-zone tiling UI (Lucia) and an AI-native text environment ([Xenith](docs/XENITH.md)), rendered via SDL3 (Metal / Vulkan / D3D).
- **Matrix** — compositional module runtime: Limbo `.dis` modules loaded against mounted 9P namespaces, arranged from a [text composition file](docs/matrix-architecture.md), drivable by hand (clickable picker + right-click menu in Lucifer) or by agents through `/mnt/matrix/ctl`.
- **Payments** — native cryptocurrency wallet with [x402](docs/WALLET-AND-PAYMENTS.md) payment protocol, ERC-20 tokens, and budget-enforced agent spending with a trusted approval queue. Signing is cross-validated against go-ethereum; see the [security model](docs/WALLET-AND-PAYMENTS.md#status-and-security-model).
- **Formally verified** — namespace isolation proven in TLA+ (3.17B states), SPIN, and CBMC.
- **Quantum-safe crypto** — ML-KEM, ML-DSA, SLH-DSA (FIPS 203/204/205).
- **Complete** — 800+ Limbo source files, a full shell, TCP/IP, 9P, and 815 compiled utilities.

## Platforms

Run with `emu -c1` to enable the JIT (Dis bytecode → native code at module load).

| Platform | CPU | JIT speedup | Notes |
|----------|-----|-------------|-------|
| Linux AMD64 | AMD Ryzen 7 H 255 | **14.2×** | Servers, containers, workstations |
| macOS ARM64 | Apple M4 | **9.6×** | SDL3 GUI with Metal |
| Linux ARM64 | Cortex-A78AE (Jetson) | **8.3×** | Jetson AGX, Raspberry Pi 4/5 |
| Windows AMD64 | Intel / AMD x86_64 | **5.7×** | SDL3 GUI with D3D |
| Linux RISC-V 64 | RV64GC | not yet measured | Headless; cross-built and tested under qemu-user in CI. BeagleV-Fire, VisionFive 2 ([os/riscv64/README.md](os/riscv64/README.md)) |

Speedups are v1 suite (6 benchmarks, best-of-3). Full data: [docs/BENCHMARKS.md](docs/BENCHMARKS.md). Performance envelope: [docs/PERFORMANCE-SPECS.md](docs/PERFORMANCE-SPECS.md).

### Bare metal — InferNode as the kernel

InferNode also runs *native*, with nothing underneath it: the kernel boots the
board, brings up the hardware, starts the Dis VM, and runs the same bytecode the
hosted emulator runs — the same shell, the same Tk, the same Lucifer desktop. A
recovery root (shell, file utilities, `dossrv`, the USB and Ethernet drivers) is
compiled into the kernel image; the rest of userspace comes off the SD card at
boot. The machine decides how to boot by one question — is there a screen? With
one it goes on to the desktop; without one it boots headless to a shell on the
serial console, with the full namespace and the network up.

| Board | State |
|-------|-------|
| **Raspberry Pi 3B+** (`os/bcm2837`) | Runs on the real board, and on QEMU's `raspi3b`. Ethernet (LAN7515 over USB), Wi-Fi (CYW43455), Bluetooth, SD card, HDMI/DSI, USB keyboard and mouse, touch, GPIO, audio, A/B kernel update, boot watchdog. |
| **QEMU `virt`** (`os/virt`) | GICv2 and virtio (net, blk, keyboard, tablet, ramfb) — the kernel anywhere QEMU runs, which is what CI boots. |
| **Raspberry Pi 4B** (`os/bcm2711`) | Boots to the desktop under QEMU's `raspi4b`; has never run on a board. [os/bcm2711/README.md](os/bcm2711/README.md) says what that does and does not establish. |
| **QEMU RISC-V `virt`** (`os/riscvvirt`) | RV64GC under OpenSBI with the RISC-V Dis JIT: 4 harts, PLIC, virtio (net, blk, keyboard, tablet), ramfb to the graphical logon, and U-Boot `booti`/`boot.scr`. [os/riscv64/README.md](os/riscv64/README.md). |
| **PolarFire SoC: BeagleV-Fire, Icicle Kit** (`os/mpfs`) | Boots under QEMU's `microchip-icicle-kit`: SD card (Cadence SD4HC), Gigabit Ethernet (Cadence GEM, PHY over MDIO), the system controller's TRNG service, `/reserved-memory`. It has never run on a board. |

Building and booting it is one command — the test harness, which is the only
supported way to build the kernel (it needs `clang`, `ld.lld`, `llvm-objcopy`,
`python3`, `qemu-system-aarch64` and a built `dis/`):

```bash
BAREMETAL_BUILD_DIR=/tmp/bm ./tests/host/baremetal_test.sh
```

CI builds, boots and tests both machines on every pull request that touches the
kernel. Full manual — running it, the card image, the QEMU flags that fail
silently, what controls it: [docs/BAREMETAL.md](docs/BAREMETAL.md).

## Documentation

- [QUICKSTART.md](QUICKSTART.md) — running in under a minute
- [docs/USER-MANUAL.md](docs/USER-MANUAL.md) — namespaces, devices, host integration
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system architecture
- [docs/BAREMETAL.md](docs/BAREMETAL.md) — running InferNode as the operating system, on Raspberry Pi and QEMU
- [docs/XENITH.md](docs/XENITH.md) — AI-native text environment
- [docs/matrix-architecture.md](docs/matrix-architecture.md) — Matrix compositional module runtime
- [docs/WALLET-AND-PAYMENTS.md](docs/WALLET-AND-PAYMENTS.md) — wallet, x402, secstore, key management
- [appl/veltro/SECURITY.md](appl/veltro/SECURITY.md) — Veltro agent security model
- [docs/WINDOWS-BUILD.md](docs/WINDOWS-BUILD.md) — Windows build and SDL3 GUI
- [docs/DIFFERENCES-FROM-STANDARD-INFERNO.md](docs/DIFFERENCES-FROM-STANDARD-INFERNO.md) — how InferNode differs from upstream
- [formal-verification/README.md](formal-verification/README.md) — TLA+, SPIN, CBMC proofs
- [docs/DOCUMENTATION-INDEX.md](docs/DOCUMENTATION-INDEX.md) — full index (100+ documents)

## Contributing

Contributions welcome — security audits, 9P integrations, bug fixes, and documentation all help. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Sponsor

InferNode is MIT-licensed and free to use. [Sponsorship](https://github.com/sponsors/infernode-os) pays for the things that keep releases trustworthy and move the harder work forward: code signing and notarization, ARM64 and macOS CI hardware, external security review of the Veltro isolation boundary and the wallet signing path, bare-metal port work, compliance evidence (FIPS 140-3 and Common Criteria readiness, SP 800-53/171 mapping), and maintainer time.

## About

InferNode extends the MIT-licensed Inferno® OS with JIT compilers for AMD64 and ARM64, the Veltro AI agent system with formally verified namespace isolation, a cryptocurrency wallet with the x402 payment protocol, quantum-safe cryptography, a Go-to-Dis compiler, and an optional SDL3 GUI (Lucia + Xenith). It targets embedded systems, servers, and AI agent applications where a lightweight footprint and capability-based security matter.

## Acknowledgements

InferNode is a late arrival in a long lineage.

- **Dr Charles Forsyth and Vita Nuova** — the Limbo compiler, the Dis VM, and the JIT back ends are Forsyth's; some 800 commits in this history are his, and `libinterp/comp-arm64.c` is written against the shape he set in `comp-arm.c`. Vita Nuova carried Inferno for two decades, gave it work like Roger Peppé's shell ([doc/sh.ms](doc/sh.ms)), and relicensed it under MIT — without which InferNode could not exist. Through the long years when the industry had no use for any of it, they kept Inferno a living system rather than a paper about one. InferNode exists because that torch never went out.
- **Inferno's originators at Bell Labs** — Sean Dorward, Rob Pike, David Presotto, Dennis Ritchie, Howard Trickey, and Phil Winterbottom, for Inferno, Limbo, Dis, and Styx/9P. Their papers ship in this tree ([doc/bltj.ms](doc/bltj.ms), [doc/dis.ms](doc/dis.ms), [doc/limbo/limbo.ms](doc/limbo/limbo.ms)).
- **Caerwyn Jones** — [Acme SAC](https://github.com/caerwynj/acme-sac), Acme carried out of Plan 9 as a self-contained Inferno system rather than an app hosted on someone else's desktop. That framing is the major influence on [Xenith](docs/XENITH.md).
- **The Hellaphone crew** — John Floren, Joel Armstrong, and colleagues at Sandia National Laboratories, who ran Inferno on Android in place of the Java runtime and made a cellular radio a directory of text files. `emu/port/devphone.c` mirrors their `/phone` interface deliberately, their RIL bridge is still the reference for `emu/Android/phonebridge.c`, and the mobile target carries their name ([docs/HELLAPHONE.md](docs/HELLAPHONE.md), [Plan9-Archive/hellaphone](https://github.com/Plan9-Archive/hellaphone)).
- **The bare-metal Pi lineage** — **Richard Miller**, whose Plan 9 Raspberry Pi kernels nearly all Pi work in this world starts from (and, here, the Inferno RISC-V toolchain); **LynxLine Labs** of Kyiv, who did the [original native Inferno port to the Pi](https://lynxline.com/posts/labs-portintg-inferno-os-to-raspberry-pi/) in 2014 and documented it lab by lab ([github.com/yshurik](https://github.com/yshurik/inferno-rpi)); and **David Boddie**, who carries the native ports forward today ([Inferno Ports](https://dboddie.github.io/inferno-ports/)). And **the 9front project**, whose MIT-licensed `bcm` kernel this port reads from directly: `os/bcm/uartmini.c` is 9front's mini-UART, the console the machine boots on; `os/bcm/uartpl011.c` takes its structure from 9front's PL011, which is how the port speaks H4 to the Bluetooth radio; `os/bcm/sdhost.c` has its register semantics cross-checked against 9front's; and 9front's `egpset()` is the model for the firmware GPIO expander in `os/bcm/devgpio.c`.

Third-party components (FreeType, SDL3, the Bigelow & Holmes fonts, libmp/libsec under the Lucent Public Licence) are credited in [NOTICE](NOTICE).

## License

MIT, as with the original Inferno® OS. See [LICENSE](LICENSE).

---

<sub>Inferno® is a distributed operating system, originally developed at Bell Labs, and now maintained by trademark owner Vita Nuova®.</sub>
