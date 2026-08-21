# Repository Guidelines

## Project Structure & Module Organization

InferNode is a mixed C, Limbo, shell, and Go repository. Core runtime and kernel code lives in `libinterp/`, `emu/port/`, and `libsec/`. Limbo applications and libraries live under `appl/`, with notable areas in `appl/cmd/`, `appl/veltro/`, and `appl/xenith/`. Interface definitions belong in `module/*.m`. Tests are under `tests/`, with emulator tests named `*_test.b` and host-side shell tests in `tests/host/*_test.sh`. Supporting material lives in `docs/`, `formal-verification/`, and `tools/godis/`.

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
- `cd appl/cmd && mk install`: rebuild one Limbo subtree and install tracked runtime output into `dis/`.
- `cd tests && mk install && cd ..`: rebuild Limbo tests into the tracked runtime tree.
- `./run-tests.sh`: run host and emulator tests.
- `./run-tests.sh -h` or `./run-tests.sh -i -v`: run only host tests, or only emulator tests with verbose output.
- `./emu/<Platform>/o.emu -r. /tests/runner.dis -v`: run the native Limbo test runner directly when working inside the emulator workflow.

## Coding Style & Naming Conventions

Match the surrounding code closely. Limbo (`.b`) is close to Go in structure but should follow existing Inferno idioms, naming, and control-flow style. C uses Plan 9 / Inferno conventions and tabs, not generic modern C house styles. *Host-side* shell scripts (`tests/host/`, `tools/`, `build-*.sh`) stay POSIX `sh` compatible; scripts that run *inside Inferno* (`tests/inferno/`, `lib/sh/`, boot scripts) are rc-style — no `&&`/`||` — see the shell table in [docs/LIMBO-FOR-GO-PROGRAMMERS.md](docs/LIMBO-FOR-GO-PROGRAMMERS.md). Name new emulator tests `*_test.b`, host tests `*_test.sh`, and keep module interfaces in `module/` aligned with their implementation names.

Use Inferno `mk`, not GNU make, for subtree builds. In `mkfile`s, do not chain commands with `&&`; use separate rules or `;`.

## Testing Guidelines

Behavior changes should include tests. Prefer the repository’s Limbo test setup instead of ad hoc harnesses: build tests with `mk install`, then run them through `tests/runner.dis` or `./run-tests.sh`. Host integration checks belong in `tests/host/`. If a change regenerates runtime `.dis` files under `dis/`, make sure they result from `mk install` in the corresponding source directory rather than manual edits.

## Security Review Priorities

Model threats in this order unless a task says otherwise:

- adversarial or prompt-injected AI agents running inside InferNode via the Veltro harness
- sophisticated remote automated attackers attempting protocol or emulator compromise
- attacks on communication and cryptographic protocols

When proposing fixes, prefer namespace, mount, process-group, file-permission, and protocol-shape solutions over bolted-on policy code.

## Commit & Pull Request Guidelines

Recent history uses scoped, imperative subjects such as `fix(theme): ...`, `build: ...`, and `test: ...`. Keep the first line under 72 characters, explain why in the body when needed, and reference issue IDs like `INFR-28` when relevant. PRs should stay focused, describe the motivation, include test coverage, update docs for interface changes, and include screenshots for UI work in Lucia/Xenith.

Know what CI will check before you push: `verify-dis-paths` (every source's declared `.dis` exists and is fresh — the wrong-target trap), `verify-sh-exec` (Inferno-side test scripts committed mode 755), the ring-fence job (`tests/agent-harness/` material must never appear elsewhere), the advisory style gate (rc-violations, JSON inside `appl/`, new file interfaces with no linked proposal issue), plus builds, the test suites, CodeQL, and nsaudit fixture checks. The PR template's design-principles checklist is expected to be filled honestly.
