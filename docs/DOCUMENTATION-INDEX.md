# Documentation Index

**Purpose:** Navigate InferNode documentation

## Start Here

| Document | Description |
|----------|-------------|
| [DESIGN-PRINCIPLES.md](DESIGN-PRINCIPLES.md) | **The design philosophy** — namespace-as-capability, file interfaces, text protocols, mechanism over policy; read before designing anything |
| [LIMBO-FOR-GO-PROGRAMMERS.md](LIMBO-FOR-GO-PROGRAMMERS.md) | Limbo mapped from Go, plus the gotchas that bite |
| [INFERNO-SHELL.md](INFERNO-SHELL.md) | The rc-style shell dialect — POSIX→Inferno translation table, runtime gotchas, script conventions |
| [NAMESPACE-LAYOUT.md](NAMESPACE-LAYOUT.md) | `/mnt` vs `/n` placement convention and why it is security work |
| [compliance/](compliance/README.md) | Standards evidence register (CNSA 2.0, zero trust, SP 800-92 audit, SLSA, FIPS 140-3 readiness, AI governance) |

## For Users

| Document | Description |
|----------|-------------|
| [USER-MANUAL.md](USER-MANUAL.md) | **Comprehensive user guide** - namespaces, devices, host integration |
| [QUICKSTART.md](../QUICKSTART.md) | Get running in 3 commands |
| [RUN_TOUR.md](../RUN_TOUR.md) | Interactive Veltro feature tour |
| [XENITH.md](XENITH.md) | Xenith AI-native text environment |
| [NAMESPACE.md](NAMESPACE.md) | Namespace architecture and configuration |
| [FILESYSTEM-MOUNTING.md](FILESYSTEM-MOUNTING.md) | Filesystem mounting guide |
| [DIFFERENCES-FROM-STANDARD-INFERNO.md](DIFFERENCES-FROM-STANDARD-INFERNO.md) | How InferNode differs from standard Inferno |

## Architecture & Design

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture, layer diagram, and component overview |
| [decisions/0001-rooted-agent-capabilities.md](decisions/0001-rooted-agent-capabilities.md) | Proposed decision: rooted 9P filesystem capabilities and atomic agent delegation |
| [LUCIFER-EVALUATION.md](LUCIFER-EVALUATION.md) | Lucifer GUI production readiness evaluation (P0/P1/P2 issues) |
| [evaluations/fractal-app-evaluation.md](evaluations/fractal-app-evaluation.md) | Fractal app production readiness evaluation |
| [architecture-review-veltro-unification.md](architecture-review-veltro-unification.md) | Veltro architecture review |
| [matrix-architecture.md](matrix-architecture.md) | Matrix compositional module runtime — modules, compositions, the library, 9P control namespace, and the Lucifer GUI control surface |
| [9p-data-conventions.md](9p-data-conventions.md) | Data conventions for 9P file servers — text records, hierarchy as schema, ctl files, `/mnt` placement, the no-JSON argument |
| [RECOMMENDED-ADDITIONS.md](RECOMMENDED-ADDITIONS.md) | Recommended feature additions |

## For Developers

| Document | Description |
|----------|-------------|
| [CLAUDE.md](../CLAUDE.md) | Development guide for Claude Code (build, test, project structure) |
| [TUTORIAL-9P-SERVICE.md](TUTORIAL-9P-SERVICE.md) | **Worked tutorial** — design, build, test, and document a 9P service (`countfs`); every artifact ships in-tree |
| [TESTING.md](TESTING.md) | Testing guide (unit tests, integration tests, CI) |
| [PERFORMANCE-SPECS.md](PERFORMANCE-SPECS.md) | Performance specifications and benchmarks |
| [BENCHMARKS.md](BENCHMARKS.md) | Benchmark results (v1, v2, v3 suites) |
| [SDL3-GUI-PLAN.md](SDL3-GUI-PLAN.md) | SDL3 cross-platform GUI implementation plan |
| [SDL3-IMPLEMENTATION-STATUS.md](SDL3-IMPLEMENTATION-STATUS.md) | SDL3 implementation status |

## Wallet & Payments

| Document | Description |
|----------|-------------|
| [WALLET-AND-PAYMENTS.md](WALLET-AND-PAYMENTS.md) | **Comprehensive guide** - wallet9p, x402 protocol, secstore, factotum, key persistence, login screen |

## Authentication

| Document | Description |
|----------|-------------|
| [AUTHENTICATION.md](AUTHENTICATION.md) | **Canonical reference** — secstore + factotum protocol, PAK exchange, on-disk format, boot orchestration, threat model |
| [DISTRIBUTED-AUTH.md](DISTRIBUTED-AUTH.md) | Multi-host deployment topologies — standalone, dedicated server, p2p, hybrid; includes diagrams and a comparison matrix |

## Security

| Document | Description |
|----------|-------------|
| [SECURITY.md](../SECURITY.md) | Security vulnerability reporting policy |
| [SECURITY.md (Veltro)](../appl/veltro/SECURITY.md) | Veltro agent namespace security model (v3) |
| [InferNode Escape Room](https://github.com/infernode-os/infernode-escape-room) | External live adversarial-model protocol and campaign harness for testing namespace containment |
| [NAMESPACE_SECURITY_REVIEW.md](NAMESPACE_SECURITY_REVIEW.md) | Namespace security deep analysis |
| [VELTRO_NAMESPACE_SECURITY.md](VELTRO_NAMESPACE_SECURITY.md) | Veltro namespace security details |

## Cryptography

| Document | Description |
|----------|-------------|
| [CRYPTO-MODERNIZATION.md](CRYPTO-MODERNIZATION.md) | Ed25519 signatures, SHA-256, key sizes |
| [QUANTUM-SAFE-CRYPTO-PLAN.md](QUANTUM-SAFE-CRYPTO-PLAN.md) | ML-KEM, ML-DSA, SLH-DSA (FIPS 203/204/205) |
| [CRYPTO-DEBUGGING-GUIDE.md](CRYPTO-DEBUGGING-GUIDE.md) | Debugging cryptographic code |
| [ELGAMAL-PERFORMANCE.md](ELGAMAL-PERFORMANCE.md) | ElGamal optimization |
| [TLS-ENTROPY.md](TLS-ENTROPY.md) | TLS entropy configuration |

## Porting Guide

| Document | Description |
|----------|-------------|
| [WINDOWS-BUILD.md](WINDOWS-BUILD.md) | Building and running on Windows (prerequisites, SDL3 GUI, troubleshooting) |
| [LESSONS-LEARNED.md](LESSONS-LEARNED.md) | **Start here** - Critical fixes and pitfalls for porters |
| [PORTING-ARM64.md](PORTING-ARM64.md) | ARM64 technical implementation details |
| [COMPILATION-LOG.md](COMPILATION-LOG.md) | Build process walkthrough |
| [JETSON-PORT-PLAN.md](JETSON-PORT-PLAN.md) | NVIDIA Jetson porting plan |
| [JETSON-PORT-ESTIMATE.md](JETSON-PORT-ESTIMATE.md) | Jetson port effort estimate |
| [COMPLETE-PORT-SUMMARY.md](COMPLETE-PORT-SUMMARY.md) | Port completion summary |
| [BAREMETAL.md](BAREMETAL.md) | **Bare metal, start here** - the manual: build, run under QEMU (`virt`, `raspi3b`), put it on a Pi 3B+, the card's control files, the command line, `/dev/sysctl`, debug keys, devices, boot sequence, testing |
| [BAREMETAL-BOARD-INTERFACE.md](BAREMETAL-BOARD-INTERFACE.md) | The contract between the shared native kernel and a board directory: files, hooks in call order, what the shared drivers call downward |
| [BAREMETAL-PORTING-LESSONS.md](BAREMETAL-PORTING-LESSONS.md) | What a port to other hardware should take from the first one |
| [../os/bcm2837/README.md](../os/bcm2837/README.md) | Bare-metal Raspberry Pi 3B+ kernel: the engineering journal -- status, decisions, measurements, board runbook |
| [../os/bcm2711/README.md](../os/bcm2711/README.md) | Bare-metal Raspberry Pi 4B: boots to the desktop under QEMU `raspi4b`, never on a board; what the emulator lacks and the nine things only hardware will show |
| [../os/bcm/README.md](../os/bcm/README.md) | The drivers the Raspberry Pi SoCs share, and the rule for what may live there |
| [../os/virt/README.md](../os/virt/README.md) | Bare-metal QEMU `virt`: what the second machine is for, what it found (a GIC end-of-interrupt bug), and the QEMU flags that fail silently |
| [BLUETOOTH.md](BLUETOOTH.md) | Bluetooth design: `#t` serial, mini-UART console, `bt9p` at `/net/bt`; classic pairing, SDP/RFCOMM, LE HID -- on the Pi 3B+ |
| [PLAN9-C-UNDER-OTHER-COMPILERS.md](PLAN9-C-UNDER-OTHER-COMPILERS.md) | Every guarantee Plan 9 C gives that gcc/clang do not, the fault each produced (#622: `m` copied across a migration), the invariant that replaces it, and the detectors kept in the kernel |

## ARM64 JIT Compiler

Detailed JIT documentation is in `docs/arm64-jit/` (27 files covering implementation, debugging, benchmarks across all platforms).

## Additional Guides

| Document | Description |
|----------|-------------|
| [PDF.md](PDF.md) | PDF support documentation |
| [SPEECH-ARCHITECTURE.md](SPEECH-ARCHITECTURE.md) | **speech9p architecture** — file tree, three engines (cmd / api / local), TTS/STT data flow, devcmd bridge, Veltro + lucibridge integration, threat surface |
| [SPEECH-REMOTE-AUDIO.md](SPEECH-REMOTE-AUDIO.md) | Cross-host speech via 9P namespace composition |
| [RUNNING-ACME.md](RUNNING-ACME.md) | Running the Acme editor |
| [SONARQUBE_WORK.md](SONARQUBE_WORK.md) | SonarQube static analysis work |

## Debugging Reference

| Document | Description |
|----------|-------------|
| [OUTPUT-ISSUE.md](OUTPUT-ISSUE.md) | Console output debugging |
| [SHELL-ISSUE.md](SHELL-ISSUE.md) | Shell execution investigation |
| [HEADLESS-STATUS.md](HEADLESS-STATUS.md) | Headless build details |
| [TEMPFILE-EXHAUSTION.md](TEMPFILE-EXHAUSTION.md) | Temp file slot exhaustion |
| [64-bit-alt-structure-fix.md](64-bit-alt-structure-fix.md) | 64-bit alt structure fix |
| [FONT-RENDERING-DEBUG.md](FONT-RENDERING-DEBUG.md) | Font rendering debugging |

## Formal Verification

See [formal-verification/README.md](../formal-verification/README.md) for TLA+, SPIN, and CBMC verification of namespace isolation (3 tools, 11 properties, 3.17B+ states explored).

## The Key 64-bit Fix

Pool quanta must be 127 for 64-bit (not 31 as for 32-bit). This single change in `emu/port/alloc.c` was the critical breakthrough that made the entire port work. See [LESSONS-LEARNED.md](LESSONS-LEARNED.md) for the full story.

## External References

- [inferno-os](https://github.com/inferno-os/inferno-os) - Upstream Inferno OS
- [inferno64](https://github.com/caerwynj/inferno64) - Reference 64-bit port
- [Inferno Shell paper](https://www.vitanuova.com/inferno/papers/sh.html)
- [EMU manual](https://vitanuova.com/inferno/man/1/emu.html)
