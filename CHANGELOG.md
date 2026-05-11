# Changelog

All notable changes to InferNode are documented in this file.

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
