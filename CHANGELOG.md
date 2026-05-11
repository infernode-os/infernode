# Changelog

All notable changes to InferNode are documented in this file.

## [0.2] - 2026-04-14

### Windows AMD64 Release

- **Windows JIT compiler** — AMD64 JIT with 5.7x speedup (181/181 correctness tests pass)
- **Host filesystem mounting** — Drive letters mounted at `/n/C`, `/n/D` etc. via `#U` device; `~/.infernode` overlay for persistent user state
- **Secstore and factotum** — Encrypted key persistence works on Windows with PAK authentication
- **SDL3 GUI** — Xenith, Lucifer, and window manager with D3D acceleration
- **Build system** — Complete MSVC build via `build-windows-amd64.ps1` and `build-windows-sdl3.ps1`; crypto libraries (secp256k1, keccak256, securezero) fully linked
- **CSPRNG** — Secure random via `BCryptGenRandom` (replaces `/dev/urandom`)
- **CI/CD** — Windows build and test verification in GitHub Actions
- **Packaging** — Portable zip and MSIX packaging scripts

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
