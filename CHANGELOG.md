# Changelog

All notable changes to InferNode are documented in this file.

## [0.3.1] - 2026-06-29

Security-hardening point release, with cross-platform YubiKey/FIDO2 second-factor
authentication.

### Second-factor auth (`/dev/2fa`)

- **Cross-platform FIDO2** — the `#F` (`/dev/2fa`) device, previously macOS-only,
  is now built into the Linux and Windows emulators, and into headless Linux
  builds (#305, #307).
- **YubiKey 2FA fixes** — namespace ACL enforcement, Dis-parser hardening,
  Windows Hello (winhello) integration, and clearer error surfacing (#309).
- **Enrollment persistence** — `~/.infernode` overlays are persisted so a
  YubiKey 2FA enrollment survives an emulator restart (#311).

### Cryptography & Dis VM hardening

- **SHA-384 auth-cert hashing** for ML-DSA-87 signing (CNSA 2.0) (#304).
- **Dis parser hardening** — guard the Dis bytecode parser against malformed
  modules and pointer corruption (#306), with additional module-parse
  hardening in `libinterp` (#302).

### Security

- **Pre-authentication bounds** — pre-auth handshake work is time- and
  concurrency-bounded (#312).
- **Transport** — remove weak transport algorithms and close devfs races (#301).
- **Memory safety** — resolve CodeQL memory-safety findings (#300).
- **Internal configuration audit** added (#310).

### Release engineering

- Fix FIDO2 packaging in the release pipeline: the Windows `vcpkg` port is
  `libfido2` (not `fido2`) and that install step is now genuinely best-effort;
  the macOS GUI/headless emulators link `libfido2` and `opus` reliably even when
  `pkg-config` cannot resolve Homebrew's keg-only `openssl@3`.

## [0.3.0] - 2026-06-28

### Breaking & behavior changes

- **Namespace move `/n/*` → `/mnt/*`** — `mail9p` (`/mnt/mail`), `calendar9p`
  (`/mnt/cal`), and `msg9p` (`/mnt/msg`). Scripts, shell profiles, or configs
  referencing the old `/n/` paths must be updated.
- **CNSA 2.0 strict mode** (opt-in via `/env/cnsamode`, off by default) —
  ML-KEM-768 → ML-KEM-1024 and ed25519 → ML-DSA-87 for the native STS
  handshake, TLS, and the auth-domain CA. No silent downgrade; enabling it
  requires upgrading all nodes in a fleet together.
- **2FA accounts** (opt-in) — a YubiKey-enrolled account cannot be unlocked by
  a password alone; it requires the hardware key (touch, and a FIDO PIN at
  AAL3) or the recovery passphrase. Legacy password-only accounts are unchanged.

### Highlights

- **YubiKey-gated secstore login** with UV/AAL3, backup key, and a Settings GUI
  Security panel.
- **Hybrid TLS** — `SecP384r1MLKEM1024` CNSA hybrid key exchange, with P-384
  (secp384r1) ECDH primitives and Keyring builtins.
- **Tamper-evident audit log** (`/mnt/audit`) with factotum-held ML-DSA-87
  signing and a compliance evidence program.
- **Pre-auth hardening** — time-bounded handshakes with a per-listener
  concurrent-auth cap; weak/malformed v2 DH shares are rejected
  (INFR-321/322/323).
- **Veltro agent** — research agent and launchable personas, deterministic
  intent classifier for persona routing, agent-loop read-cache, and per-session
  model override (`veltro -m <model>`).
- **SBOM** — CI-verifiable SPDX SBOM generated and shipped with releases.

## [0.2] - 2026-05-11

### Windows AMD64 release

First official Windows AMD64 distribution. Feature parity with macOS and Linux
modulo the items called out under "Known limitations" below.

- **Windows JIT compiler** — AMD64 JIT with 5.7× speedup (181/181 correctness tests pass).
- **Host filesystem mounting** — Drive letters mounted at `/n/C`, `/n/D`, etc. via the `#U` device; `~/.infernode` overlay for persistent user state.
- **Secstore + factotum** — Encrypted key persistence with PAK authentication; Lucifer login screen unlocks it interactively.
- **SDL3 GUI** — Lucia, Xenith, and the window manager render with D3D acceleration.
- **Bundled-app UX** — `InferNode.exe` is a Windows-subsystem launcher that double-clicks to a full-screen Lucifer session (uses screen-resolution sizing on launch).
- **CSPRNG** — Secure random via `BCryptGenRandom` (replaces the POSIX `/dev/urandom` path).
- **Build system** — Complete MSVC build via `build-windows-amd64.ps1` (libs + headless emu), `build-windows-sdl3.ps1` (GUI emu), and `emu/Nt/build-launcher.ps1`. Crypto libraries (secp256k1, keccak256, securezero) fully linked.
- **Cross-platform unification** — Windows launcher invokes the same `/lib/lucifer/boot.sh` as macOS and Linux; legacy `dis/lucifer-start.sh` and `Lucia.bat` removed.
- **Dev bundle** — `build-dev-bundle.ps1` mirrors the macOS `build-dev-bundle.sh` for local packaging tests without going through CI.
- **CI/CD** — Windows AMD64 build and test job runs alongside macOS/Linux on every PR; release job produces a signed bundle on tag push.

### Known limitations on Windows

- **JIT GUI race** (latent) — Some long-running JIT GUI sessions can crash with `STATUS_BAD_FUNCTION_TABLE` because the JIT does not yet register Windows SEH unwind data for its executable pages. Mitigation in place; proper fix tracked in INFR-46.
- **MSIX packaging** — Deferred to a follow-up release (INFR-48). For 0.2 the artefact is a portable zip.
- **Stdio-redirected boot** — `o.emu.exe` started with `Start-Process -RedirectStandardOutput` crashes in the secstore PAK dial step. Interactive double-click is unaffected. Tracked in INFR-50; matters mainly for headless smoke tests.

### Platforms

| Platform | Architecture | GUI | JIT |
|----------|-------------|-----|-----|
| macOS | ARM64 (Apple Silicon) | SDL3 | 9.6x |
| Linux | AMD64 | Headless / SDL3 | 14.2x |
| Linux | ARM64 | Headless / SDL3 | 8.3x |
| Windows | AMD64 | SDL3 | 5.7x |

## [0.1] - 2026-04-09

First public release of InferNode, a 64-bit fork of Inferno OS for AI agents.

### Highlights

- **Veltro AI Agent** — built-in conversational agent with tool use, delegation,
  and namespace-isolated sub-agents
- **Capability-based namespace isolation** — each agent sees only explicitly
  granted resources; formally verified with TLA+, SPIN, and CBMC
- **Post-quantum cryptography** — preliminary ML-KEM (FIPS 203) and ML-DSA
  (FIPS 204) implementations
- **ARM64 JIT compiler** — native JIT for Apple Silicon and Linux ARM64
  (e.g. NVIDIA Jetson)
- **Xenith text environment** — Acme-inspired editor with markdown, PDF,
  image, and Mermaid rendering
- **Lucifer GUI** — presentation zone with app hosting, tab management, and
  context/namespace browser
- **Secstore persistence** — encrypted key storage with PAK authentication
- **Ollama/OpenAI-compatible backend** — local LLM support alongside
  Anthropic API
- **9P everywhere** — LLM, speech, tools, wallet, and UI all exposed as
  9P filesystems

### Platforms

| Platform | Architecture | GUI |
|----------|-------------|-----|
| macOS | ARM64 (Apple Silicon) | SDL3 |
| Linux | AMD64 | Headless (SDL3 optional via build script) |
| Linux | ARM64 | Headless (SDL3 optional via build script) |

### Known Issues

- Secstore key loading can intermittently fail on cold boot due to trfs
  cache timing; a warmup workaround is in place
- Models that do not support tool use (e.g. llama2) return empty responses;
  use a tool-capable model (llama3.2, qwen2.5, mistral, etc.)
- The presentation rendering architecture is tightly coupled to the lucipres
  window; a refactor to a separate wmclient app is planned (see
  docs/TODO-LUCIPRES-ARCHITECTURE.md)
