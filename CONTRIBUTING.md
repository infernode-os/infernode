# Contributing to InferNode

Thank you for your interest in InferNode. This is a modernized fork of
Inferno® OS with 64-bit support, JIT compilation, AI agents, and post-quantum
cryptography. Contributions of all kinds are welcome — from typo fixes to new
9P integrations to security audits.

## Where to Start

If you're new to the project:

1. Read the [Quick Start Guide](QUICKSTART.md) to build and run InferNode
2. Read the [Design Principles](docs/DESIGN-PRINCIPLES.md) — how design works here,
   and why (this is the one document that will save you the most time)
3. Browse [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a system overview
4. Try the [Interactive Tour](docs/TOUR.md) to explore features hands-on
5. Look at issues labeled **good first issue** for approachable tasks

## Open an Issue Before a Pull Request

**Every pull request starts with an issue.** Before you write code, open an
issue that says what you want to change and why, and wait for a maintainer
to agree that it is wanted. Then open the pull request and link the issue
in its description (`Closes #123` or `Refs #123`).

This is policy, not a suggestion. A pull request with no linked issue, or
whose issue a maintainer has not agreed to, will be closed with a pointer
to this section. That is not a judgment of the code: open the issue, and
once it is agreed, reopen the pull request or open a new one.

Why: a maintainer can answer "is this wanted, and is this the right
approach?" in minutes on an issue, before anyone has spent days on code.
It is the same reason new file interfaces start with a
[namespace sketch](#design-principles), and it protects your time as much
as ours. Some well-made contributions are still not what the project needs,
or not yet; it is far better to learn that before the work than after it.

The only exceptions are typo fixes, broken links, and similarly trivial
corrections, which may be sent as a pull request directly.

### Large contributions

New ports, new subsystems, new devices, and changes of more than a few
hundred lines need more than agreement in principle. In the issue:

- say what the whole piece of work is and where it ends;
- break it into steps, each one reviewable on its own;
- say what it will need from the project over time (CI, hardware, outside
  tools or projects it depends on, who will maintain it).

Then send **one step at a time**: keep no more than two pull requests open
at once unless a maintainer asks for more, and do not stack pull requests
on top of ones that have not been reviewed. Work arriving faster than it
can be reviewed is not merged faster; it waits, goes stale, and gets
closed.

## AI-Assisted Contributions

You may use AI tools to help write code, tests, or documentation. If you
do:

- **Say so** in the pull request, and say what for (for example, "code
  written with an AI assistant and reviewed by me; tests written by hand").
- **You are the author.** You must understand every line you submit, be
  able to explain and defend it in review, and be prepared to maintain it.
  "The model wrote it" is not an answer to a review question.
- **Check that it is real.** Run the tests yourself. Do not submit claims,
  test output, benchmarks, or references you have not verified.
- **Keep the volume reviewable.** AI tools make it cheap to write a great
  deal of code; reviewing it is not cheap. The issue-first rule and the
  limit on open pull requests above apply in full.
- **Respect licences.** Do not submit code an AI tool reproduced from
  another project unless that project's licence allows it and you say
  where it came from.

Bots and agents you run may not open pull requests, issues, or comments
here on their own; a person must be responsible for each one. (Tools the
project itself runs, such as Dependabot, are the maintainers'
responsibility.)

## Design Principles

InferNode follows the Plan 9 / Inferno design tradition, taken seriously:
every capability is a file server, the namespace is both the API schema and
the security mechanism, and data crossing a 9P interface is plain text.
Designs that are idiomatic elsewhere — REST endpoints, JSON configs, client
SDKs, policy middleware — do not compose with this system and will be asked
to change in review.

To make that painless rather than painful:

- **Read [docs/DESIGN-PRINCIPLES.md](docs/DESIGN-PRINCIPLES.md) before designing
  anything.** It explains the head-space with concrete wrong/right examples
  from this codebase, and lists the subsystems (audit, provenance,
  persistence, factotum, wallet) new work is expected to compose with.
- **Compose before you write.** Most new capabilities are a few mounts,
  binds and commands, not a program (for example, another machine's
  `/net` bound over yours routes your connections through it). Show what composition of existing name spaces,
  commands and modules you tried, and where it measurably fell short,
  before proposing new software ("Compose before you write" in
  [docs/DESIGN-PRINCIPLES.md](docs/DESIGN-PRINCIPLES.md)). New code runs in
  Limbo or a host service over 9P before the kernel or emulator.
- **Open an issue before adding a dependency.** A new third-party library,
  crate or package needs an issue first, with the alternatives tried and
  a risk assessment ("Dependencies are a decision"). Often a small tested
  rewrite is the better answer.
- **Propose a namespace sketch first.** For a new service or 9P tool, open
  an issue with the file tree you intend to serve, each file's read/write
  behavior, and an example shell session — before writing code. A sketch is
  reviewed in minutes; most design feedback happens there, where changing
  course is free. Use the "New service / tool proposal" issue template.
  This is policy, not a suggestion: PRs that introduce a non-trivial file
  interface without a linked proposal issue will be returned for the
  sketch first.
- **New to Limbo?** It's close to Go, by ancestry:
  [docs/LIMBO-FOR-GO-PROGRAMMERS.md](docs/LIMBO-FOR-GO-PROGRAMMERS.md)
  maps the concepts and lists the gotchas.

## What InferNode Needs

### Security Testing & Auditing *(high priority)*

InferNode runs a virtual machine, implements post-quantum cryptography, and
exposes a 9P network filesystem. Security is critical. We especially need:

- **Fuzz testing** of the Dis VM interpreter and JIT compilers (`libinterp/`)
- **9P protocol boundary testing** — the export filesystem
  (`emu/port/exportfs.c`) and mount driver (`emu/port/devmnt.c`) are
  network-facing attack surfaces
- **Cryptographic review** of our FIPS 203/204/205 implementations (ML-KEM,
  ML-DSA, SLH-DSA) in `libsec/`
- **Namespace escape analysis** — try to break out of the capability sandbox.
  See `formal-verification/` for existing proofs (3.17 billion states checked
  via TLA+, plus SPIN and CBMC verification)
- **Race condition analysis** — SPIN model checking found 3 real races in
  kernel code; more analysis and severity assessment is welcome
- **Static analysis improvements** — we run CodeQL, cppcheck, and flawfinder
  in CI; help us expand coverage or triage findings

If you find a vulnerability, please report it privately per our
[Security Policy](SECURITY.md). We coordinate fixes before public disclosure.

### 9P Tool Integrations

InferNode's architecture lets you connect *anything* as a filesystem using the
9P protocol. This is conceptually similar to the MCP server ecosystem, but
instead of JSON-RPC, everything is files — reading and writing files controls
tools, queries data, and connects systems.

The Veltro agent system already has **39 tool modules** exposed via `tools9p`.
Each tool is a Limbo module that serves a synthetic filesystem under `/tool/`.
An AI agent (or any program) interacts with external services by reading and
writing files — no new protocol to learn.

**And no required language.** An integration is either a Limbo tool module
in-tree, or an out-of-tree 9P server in whatever language you like — mature
9P libraries exist for Go, Python, Rust, C, and others. If it serves 9P,
InferNode mounts it at a canonical path and every program and agent uses it
as files; the speech helpers (C++) and the LLM backends behind `llmsrv` are
existing examples. Limbo is required only for the canonical in-tree core.
Either way, start with the namespace sketch (["New Service / Tool
Proposal"](docs/DESIGN-PRINCIPLES.md) issue template) — the file interface
is the design regardless of implementation language.

**Integrations we'd love to see:**

| Category | Examples |
|----------|---------|
| Communication | Matrix, Discord, IRC, XMPP, Slack |
| Productivity | CalDAV/CardDAV, Jira, Linear, Notion, Todoist |
| Data stores | PostgreSQL, Redis, SQLite, S3-compatible storage |
| Infrastructure | Docker, Kubernetes, cloud provider APIs |
| Monitoring | Prometheus, Grafana, system metrics |
| IoT / sensors | Hardware sensors, GPIO, MQTT |

**How to write one:** Look at `appl/veltro/tools9p.b` for how tools are served,
and individual tool modules in `appl/veltro/tools/` (e.g., `http.b`,
`git.b`, `mail.b`) for the pattern. Each tool has a corresponding documentation
file in `lib/veltro/tools/`. The `styxservers` library (`appl/lib/styxservers.b`)
provides high-level helpers for implementing 9P fileservers.

### Windows Experience

Windows support works (headless + SDL3 GUI) but needs polish:

- **Installer/packaging** — MSI, MSIX, or `winget` package instead of manual
  build from source
- **SDL3 GUI testing** — Xenith and Lucia run on Windows via SDL3/D3D12 but
  need more real-world testing
- **Developer experience** — better error messages, path handling, and docs for
  developers without Unix experience

See [docs/WINDOWS-BUILD.md](docs/WINDOWS-BUILD.md) and
`build-windows-amd64.ps1`.

### Platform Testing

We ship on Linux (x86-64, ARM64), macOS (ARM64, x86-64), and Windows (x86-64).
Testing and fixes on other platforms would be valuable:

- **FreeBSD, OpenBSD, NetBSD** — emulator code exists but is lightly tested
- **ARM64 single-board computers** — Raspberry Pi, NVIDIA Jetson, Pine64
- **Linux ARM64 GUI** — the SDL3/Vulkan backend is ~95% complete
- **RISC-V** — Linux RV64GC builds headless (`build-linux-riscv64.sh`) with a
  JIT, but is not a release target; testing on real boards is welcome

### Formal Verification

We have TLA+, SPIN, and CBMC proofs of critical security properties. Areas to
expand:

- Extended CBMC harnesses for `pgrpcpy` and reference counting
- New properties: memory safety bounds, channel protocol verification

See `formal-verification/README.md` and `formal-verification/METHODOLOGY.md`.

### Documentation

- Limbo language tutorials (it's like a cross between C and Go — few resources
  exist outside the Inferno community)
- 9P protocol guides with practical examples
- Architecture deep-dives on specific subsystems
- Troubleshooting guides (build issues, common runtime errors)

## Development Setup

### Prerequisites

| Platform | Requirements |
|----------|-------------|
| macOS (ARM64 or x86-64) | Xcode Command Line Tools |
| Linux x86-64 | GCC, make |
| Linux ARM64 | GCC, make |
| Windows x86-64 | Visual Studio 2022 Build Tools |

### Building

```bash
# Clone
git clone https://github.com/infernode-os/infernode.git
cd infernode

# Install the post-merge hook (prevents stale bytecode after pulls)
./hooks/install.sh

# Linux x86-64
./build-linux-amd64.sh

# Linux ARM64
./build-linux-arm64.sh

# macOS, Apple Silicon or Intel (bootstraps mk, then builds the toolchain)
./makemk.sh
./build-macos-sdl3.sh             # or ./build-macos-headless.sh

# Windows (from x64 Native Tools Command Prompt)
powershell -ExecutionPolicy Bypass -File build-windows-amd64.ps1
```

### Running the Emulator

```bash
# Linux
./emu/Linux/o.emu -r.

# macOS
./emu/MacOSX/o.emu -r.
```

```powershell
# Windows
.\emu\Nt\o.emu.exe -r .
```

### Running Tests

Tests run inside the Inferno emulator:

```bash
# Build tests (macOS example; use Linux paths on Linux)
export ROOT=$PWD
export PATH=$PWD/MacOSX/arm64/bin:$PATH
cd tests; mk install; cd ..

# Run all tests
./emu/MacOSX/o.emu -r. /tests/runner.dis -v

# Run a specific test
./emu/MacOSX/o.emu -r. /tests/crypto_test.dis
```

See [CLAUDE.md](CLAUDE.md) for the full testing API reference and build details.

## Making a Contribution

### Workflow

1. **Open an issue** and wait for a maintainer to agree to it (see
   [Open an Issue Before a Pull Request](#open-an-issue-before-a-pull-request))
2. **Fork** the repository on GitHub
3. **Clone** your fork and run `./hooks/install.sh`
4. **Create a branch** from `master` for your work
5. **Make your changes** and run the test suite
6. **Commit** with clear, descriptive messages
7. **Push** to your fork and open a **pull request** that links the issue

### Build System Notes

InferNode uses Plan 9's `mk` (not GNU make). Important points:

- Use InferNode's **native build tools** (`mk`, `limbo`), not Plan 9 Port
- Build from your host OS terminal, not inside the Inferno emulator
- `mkfile` in each directory defines build rules
- `mk install` compiles and copies output to `dis/`, which is a build product and is **not** tracked;
  rebuild with `for d in appl appl/mpeg appl/veltro tests; do (cd $d && mk install); done`
- Never commit `.dis` files. If a change adds or removes a module, update `tools/dis-manifest.txt` in the same commit
- `mk nuke` cleans build artifacts
- Don't use `&&` to chain commands in mkfiles — use `;` or separate rules

### Code Style

- **Limbo** (`.b` files): Follow the style of surrounding code. Tabs for
  indentation. Opening braces on the same line as the control structure.
- **C** (`libinterp/`, `emu/`, `lib*/`): K&R style, tabs for indentation.
  Match the existing Plan 9/Inferno conventions.
- **Shell scripts**: POSIX `/bin/sh` compatible. No bash-isms.

### Commit Messages

Write clear messages that explain *why*, not just *what*. Keep the first line
under 72 characters.

```
crypto: add test vectors for ML-KEM decapsulation

The existing tests only covered encapsulation. Add NIST ACVP test
vectors for decapsulation to verify round-trip correctness.
```

### What Not to Commit

- `.dis` files in `appl/` or `tests/` — build artifacts, `.gitignore`d
- `.dis` files in `dis/` — the runtime tree is a build product and is not
  tracked
- Secrets, API keys, or credentials of any kind

### Pull Request Guidelines

- **Link the agreed issue** — see
  [Open an Issue Before a Pull Request](#open-an-issue-before-a-pull-request)
- **Keep PRs focused** — one logical change per PR
- **Include tests** when changing behavior
- **Update docs** when changing interfaces or adding features
- **Run the test suite** before submitting
- **Describe the motivation** — what problem does this solve?
- **Follow the [Design Principles](docs/DESIGN-PRINCIPLES.md)** — file interfaces
  not APIs, text not JSON inside the namespace, namespace shape not policy
  code. Reviewers will point at specific sections of that document rather
  than re-arguing each case.

CI will automatically run:
- Build verification (Linux x86-64, macOS ARM64)
- CodeQL semantic analysis
- cppcheck and flawfinder static analysis
- Formal verification (if kernel or namespace code changed)
- OSSF Scorecard (supply chain security)

## Understanding the Codebase

### Key Directories

| Directory | Language | What's There |
|-----------|----------|-------------|
| `libinterp/` | C | Dis VM interpreter and JIT compilers |
| `emu/port/` | C | Kernel: namespaces, 9P, devices, memory |
| `libsec/` | C | Cryptography: AES-GCM, ChaCha20, ML-KEM, Ed25519 |
| `appl/veltro/` | Limbo | AI agent system, 9P tool servers |
| `appl/xenith/` | Limbo | Text environment (Acme-inspired, AI-native) |
| `appl/cmd/` | Limbo | Standard utilities (ls, cat, mount, etc.) |
| `appl/lib/` | Limbo | Libraries (styx, styxservers, JSON, TLS, etc.) |
| `module/` | Limbo | Interface definitions (like header files) |
| `formal-verification/` | TLA+/SPIN/CBMC | Security proofs |

### The Limbo Language

Limbo is InferNode's application language. If you know C and Go, you'll pick
it up quickly:

- C-like syntax with `:=` type-inferring declarations
- First-class channels and `spawn` (like Go's goroutines and channels)
- Module system with explicit `load` — no implicit linking
- Garbage collected, type-safe, compiles to portable Dis bytecode
- `alt` statement for selecting across multiple channels

The best way to learn is to read `appl/cmd/` for simple utilities and
`module/sys.m` for the system call interface. If you come from Go, start
with [docs/LIMBO-FOR-GO-PROGRAMMERS.md](docs/LIMBO-FOR-GO-PROGRAMMERS.md);
the original language paper is in-tree at `doc/limbo/limbo.ms`.

### The Inferno Shell

InferNode's shell (`sh`) is rc-style, **not** POSIX:

- No `&&` operator — use `;` or separate commands
- `for` loops: `for i in $list { commands }`
- Different quoting rules than bash/zsh

This matters when writing scripts that run inside the emulator. The
full dialect reference — the POSIX→Inferno translation table, the
runtime gotchas that have shipped as real bugs, and the script
conventions — is [docs/INFERNO-SHELL.md](docs/INFERNO-SHELL.md).

## Community

- **Issues**: [GitHub Issues](https://github.com/infernode-os/infernode/issues)
  for bugs, feature requests, and questions
- **Security**: Report vulnerabilities privately via our
  [Security Policy](SECURITY.md) — do **not** open public issues
- **Code of Conduct**: Please read our
  [Code of Conduct](CODE_OF_CONDUCT.md) before participating

## License

By contributing, you agree that your contributions will be licensed under the
same terms as the project. InferNode uses a dual-license scheme — see
[LICENSE](LICENSE) for details. The kernel and libraries are under permissive
terms (Lucent Public License / MIT-style); the VM library and applications are
LGPL/GPL.

---

Every contribution matters — whether it's a security audit, a new 9P tool
integration, a Windows installer, a Limbo tutorial, or a one-line bug fix.
Thank you for helping build InferNode.
