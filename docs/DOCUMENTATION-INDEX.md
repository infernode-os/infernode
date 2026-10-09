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
| [TOUR.md](TOUR.md) | Interactive Veltro feature tour |
| [LUCIA.md](LUCIA.md) | User and operator guide for Lucia, the three-zone desktop UI |
| [VELTRO.md](VELTRO.md) | User and operator guide for Veltro, the AI agent system |
| [PERSISTENCE.md](PERSISTENCE.md) | What survives updates and why: all of `/usr` is durable, snapshots add history |
| [REMOTE-DESKTOP.md](REMOTE-DESKTOP.md) | Using a headless InferNode from another one's screen |
| [VOICE.md](VOICE.md) | Voice calls over 9P: each device exports `/dev/audio`, `mount` is the call |
| [XENITH.md](XENITH.md) | Xenith AI-native text environment |
| [XEN.md](XEN.md) | `xen`: open host files in a standalone Xenith or sam, from a shell or an agent |
| [NAMESPACE.md](NAMESPACE.md) | Namespace architecture and configuration |
| [FILESYSTEM-MOUNTING.md](FILESYSTEM-MOUNTING.md) | Filesystem mounting guide |
| [DIFFERENCES-FROM-STANDARD-INFERNO.md](DIFFERENCES-FROM-STANDARD-INFERNO.md) | How InferNode differs from standard Inferno |

## Architecture & Design

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture, layer diagram, and component overview |
| [decisions/0001-rooted-agent-capabilities.md](decisions/0001-rooted-agent-capabilities.md) | Proposed decision: rooted 9P filesystem capabilities and atomic agent delegation |
| [architecture-review-veltro-unification.md](architecture-review-veltro-unification.md) | Veltro architecture review |
| [matrix-architecture.md](matrix-architecture.md) | Matrix compositional module runtime — modules, compositions, the library, 9P control namespace, and the Lucia GUI control surface |
| [9p-data-conventions.md](9p-data-conventions.md) | Data conventions for 9P file servers — text records, hierarchy as schema, ctl files, `/mnt` placement, the no-JSON argument |
| [OPERATIONAL-OVERVIEW.md](OPERATIONAL-OVERVIEW.md) | Operational overview of the platform and the AI stack |
| [MESSAGE-INTEGRATION.md](MESSAGE-INTEGRATION.md) | The contract every messaging, sensor and integration feature follows |
| [PATH-MANAGEMENT.md](PATH-MANAGEMENT.md) | Path management between the Lucia GUI and the agent's separate namespace |
| [DIALOGUE-TILES.md](DIALOGUE-TILES.md) | Dialogue tiles: inline status and Allow/Deny tiles in the Lucia conversation |
| [CHARON-ENGINE.md](CHARON-ENGINE.md) | Design of Charon's new web engine |
| [draw-geometry.md](draw-geometry.md) | Anti-aliased geometry in the draw device |
| [scene-design.md](scene-design.md) | Scene: a general 2-D situation display (`lib/scene`, `scenefs`, `wm/scene`) |
| [H264-9P-BRIDGE.md](H264-9P-BRIDGE.md) | H.264-over-9P video bridge (`vid9p`) |
| [ML-VISION-9P.md](ML-VISION-9P.md) | Design exploration: ML vision inference as composable 9P services |
| [INFR-119-design.md](INFR-119-design.md) | Design proposal: split the mobile zones into wm windows and a generic pager |

## For Developers

| Document | Description |
|----------|-------------|
| [CLAUDE.md](../CLAUDE.md) | Development guide for Claude Code (build, test, project structure) |
| [TUTORIAL-9P-SERVICE.md](TUTORIAL-9P-SERVICE.md) | **Worked tutorial** — design, build, test, and document a 9P service (`countfs`); every artifact ships in-tree |
| [TESTING.md](TESTING.md) | Testing guide (unit tests, integration tests, CI) |
| [PERFORMANCE-SPECS.md](PERFORMANCE-SPECS.md) | Performance specifications and benchmarks |
| [BENCHMARKS.md](BENCHMARKS.md) | Benchmark results (v1, v2, v3 suites) |
| [DEVELOPER-GUIDE.md](DEVELOPER-GUIDE.md) | Running, debugging and resetting InferNode from the command line |
| [SETTINGS-CONVENTIONS.md](SETTINGS-CONVENTIONS.md) | Adding a control to the Settings app: Settings reads and writes files |
| [TK-MIGRATION.md](TK-MIGRATION.md) | Moving GUI apps off the native widget toolkit onto Tk |
| [THEME-RESEARCH.md](THEME-RESEARCH.md) | The research behind Xenith's colours and type |
| [xenith-window-manipulation.md](xenith-window-manipulation.md) | Xenith window manipulation API at `/mnt/xenith` |
| [xenith-tempfiles.md](xenith-tempfiles.md) | How Xenith and Acme manage their temporary buffer files |
| [NODE-INTEROP-TESTING.md](NODE-INTEROP-TESTING.md) | Node-to-node interoperability testing: cert auth and post-quantum transport |
| [veltro-llm-bridge-bug-taxonomy.md](veltro-llm-bridge-bug-taxonomy.md) | Catalogue of defect classes in the Anthropic/OpenAI LLM bridge |

## Wallet & Payments

| Document | Description |
|----------|-------------|
| [WALLET-AND-PAYMENTS.md](WALLET-AND-PAYMENTS.md) | **Comprehensive guide** - wallet9p, x402 protocol, secstore, factotum, key persistence, login screen |

## Authentication

| Document | Description |
|----------|-------------|
| [AUTHENTICATION.md](AUTHENTICATION.md) | **Canonical reference** — secstore + factotum protocol, PAK exchange, on-disk format, boot orchestration, threat model |
| [DISTRIBUTED-AUTH.md](DISTRIBUTED-AUTH.md) | Multi-host deployment topologies — standalone, dedicated server, p2p, hybrid; includes diagrams and a comparison matrix |
| [second-factor-auth.md](second-factor-auth.md) | Second-factor (YubiKey) authentication: design and threat model |
| [yubikey-2fa-operations.md](yubikey-2fa-operations.md) | Hands-on guide to the YubiKey-gated secstore login |

## Security

| Document | Description |
|----------|-------------|
| [SECURITY.md](../SECURITY.md) | Security vulnerability reporting policy |
| [SECURITY.md (Veltro)](../appl/veltro/SECURITY.md) | Veltro agent namespace security model (v3) |
| [InferNode Escape Room](https://github.com/infernode-os/infernode-escape-room) | External live adversarial-model protocol and campaign harness for testing namespace containment |
| [VELTRO-ESCAPE-ROOM.md](VELTRO-ESCAPE-ROOM.md) | Where the escape-room harness lives and what InferNode still owns |
| [security-standards-roadmap.md](security-standards-roadmap.md) | The standards InferNode aims at and the mechanism that meets each |

## Cryptography

| Document | Description |
|----------|-------------|
| [CRYPTO-MODERNIZATION.md](CRYPTO-MODERNIZATION.md) | Ed25519 signatures, SHA-256, key sizes |
| [CRYPTO-DEBUGGING-GUIDE.md](CRYPTO-DEBUGGING-GUIDE.md) | Debugging cryptographic code |
| [TLS-ENTROPY.md](TLS-ENTROPY.md) | TLS entropy configuration |

## Porting Guide

| Document | Description |
|----------|-------------|
| [WINDOWS-BUILD.md](WINDOWS-BUILD.md) | Building and running on Windows (prerequisites, SDL3 GUI, troubleshooting) |
| [HELLAPHONE.md](HELLAPHONE.md) | InferNode on a phone: Android (Termux) |
| [IOS.md](IOS.md) | InferNode on iOS: design plan and build spec |
| [IOS-ONDEVICE-LLM.md](IOS-ONDEVICE-LLM.md) | On-device LLM inference on iOS behind `/mnt/llm` |
| [BAREMETAL.md](BAREMETAL.md) | **Bare metal, start here** - the manual: build, run under QEMU (`virt`, `raspi3b`), put it on a Pi 3B+, the card's control files, the command line, `/dev/sysctl`, debug keys, devices, boot sequence, testing |
| [BAREMETAL-BOARD-INTERFACE.md](BAREMETAL-BOARD-INTERFACE.md) | The contract between the shared native kernel and a board directory: files, hooks in call order, what the shared drivers call downward |
| [BAREMETAL-PORTING-LESSONS.md](BAREMETAL-PORTING-LESSONS.md) | What a port to other hardware should take from the first one |
| [../os/bcm2837/README.md](../os/bcm2837/README.md) | Bare-metal Raspberry Pi 3B+ kernel: the engineering journal -- status, decisions, measurements, board runbook |
| [../os/bcm2711/README.md](../os/bcm2711/README.md) | Bare-metal Raspberry Pi 4B: boots to the desktop under QEMU `raspi4b`, never on a board; what the emulator lacks and the nine things only hardware will show |
| [../os/bcm/README.md](../os/bcm/README.md) | The drivers the Raspberry Pi SoCs share, and the rule for what may live there |
| [../os/virt/README.md](../os/virt/README.md) | Bare-metal QEMU `virt`: what the second machine is for, what it found (a GIC end-of-interrupt bug), and the QEMU flags that fail silently |
| [BLUETOOTH.md](BLUETOOTH.md) | Bluetooth design: `#t` serial, mini-UART console, `bt9p` at `/net/bt`; classic pairing, SDP/RFCOMM, LE HID -- on the Pi 3B+ |
| [PLAN9-C-UNDER-OTHER-COMPILERS.md](PLAN9-C-UNDER-OTHER-COMPILERS.md) | Every guarantee Plan 9 C gives that gcc/clang do not, the fault each produced (#622: `m` copied across a migration), the invariant that replaces it, and the detectors kept in the kernel |
| [WIFI-WPA2.md](WIFI-WPA2.md) | Joining a WPA2 network from the bare-metal Pi 3B+ |

## JIT Compiler

[JIT.md](JIT.md) is the reference. Per-platform benchmark results are in [arm64-jit/](arm64-jit); the session logs and Dis opcode analysis are in [history/arm64-jit/](history/arm64-jit).

## Additional Guides

| Document | Description |
|----------|-------------|
| [PDF.md](PDF.md) | PDF support documentation |
| [SPEECH-ARCHITECTURE.md](SPEECH-ARCHITECTURE.md) | **speech9p architecture** — file tree, three engines (cmd / api / local), TTS/STT data flow, devcmd bridge, Veltro + lucibridge integration, threat surface |
| [SPEECH-REMOTE-AUDIO.md](SPEECH-REMOTE-AUDIO.md) | Cross-host speech via 9P namespace composition |
| [llm-mount.md](llm-mount.md) | Using the `llmsrv` LLM filesystem at `/mnt/llm` |
| [HEADLESS-LLM-DAEMON.md](HEADLESS-LLM-DAEMON.md) | Tutorial: serve a local LLM over 9P from a headless server and mount it elsewhere |
| [CLAUDE-GATE.md](CLAUDE-GATE.md) | claude-gate: Anthropic models through the Claude Code CLI |
| [CODEX-GATE.md](CODEX-GATE.md) | codex-gate: OpenAI models through the Codex CLI |
| [MODEL-INTEGRATION-NOTES.md](MODEL-INTEGRATION-NOTES.md) | Local LLM models tested through the harness: what works and what does not |

## Debugging Reference

| Document | Description |
|----------|-------------|
| [FONT-RENDERING-DEBUG.md](FONT-RENDERING-DEBUG.md) | Font rendering debugging |

## History

Status reports and debugging logs from the 64-bit port, the SDL3 GUI and early CI bring-up are kept in [history/](history/README.md). They record how things were at the time and are not maintained.

## Formal Verification

See [formal-verification/README.md](../formal-verification/README.md) for TLA+, SPIN, and CBMC verification of namespace isolation (3 tools, 11 properties, 3.17B+ states explored).

## The Key 64-bit Fix

Pool quanta must be 127 for 64-bit (not 31 as for 32-bit). This single change in `emu/port/alloc.c` was the critical breakthrough that made the entire port work. See [LESSONS-LEARNED.md](history/LESSONS-LEARNED.md) for the full story.

## External References

- [inferno-os](https://github.com/inferno-os/inferno-os) - Upstream Inferno OS
- [inferno64](https://github.com/caerwynj/inferno64) - Reference 64-bit port
- [Inferno Shell paper](https://www.vitanuova.com/inferno/papers/sh.html)
- [EMU manual](https://vitanuova.com/inferno/man/1/emu.html)
