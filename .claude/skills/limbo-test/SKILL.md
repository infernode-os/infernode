---
name: limbo-test
description: Write and run InferNode tests at the right tier — Limbo unit tests (testing.m), Inferno-side sh tests, and host-side sh tests — including the skip conventions, the emu-never-exits pattern, and what CI actually gates. Use when adding or debugging any test.
---

# Testing in InferNode

Three tiers. Pick the lowest one that can observe the behavior:

| Tier | Location | Use for |
|---|---|---|
| Limbo unit | `tests/*_test.b` | Pure logic: parsers, crypto, protocol state machines, tool modules |
| Inferno sh | `tests/inferno/*.sh` | Namespace contracts: "service X publishes files Y with contents Z" |
| Host sh | `tests/host/*_test.sh` | Anything crossing the emu boundary: real processes, host fs/network, multiple services, restart semantics |

GUI verification has its own harnesses — see the `gui-test` skill.

## Running

```sh
export ROOT=$PWD; export PATH=$PWD/MacOSX/arm64/bin:$PATH
cd tests; mk install; cd ..

./run-tests.sh              # host + emulator suites
./run-tests.sh -h           # host only
./run-tests.sh -i -v        # emulator only, verbose
./emu/MacOSX/o.emu -r. /tests/runner.dis -v      # in-emu runner directly
./emu/MacOSX/o.emu -r. /tests/foo_test.dis       # one module
```

## Limbo unit tests (`module/testing.m`)

Copy `tests/example_test.b` — the required shape (SRCFILE constant,
`run()` wrapper catching `fail:fatal`/`fail:skip`, `testing->summary` at
the end) is in CLAUDE.md's Testing System section. Then **add the target to
`TARG=` in `tests/mkfile`**.

Conventions the docs used to omit:
- **Suite skip:** if the environment a whole module needs is absent, `raise
  "skip:<reason>"` from `init()` — the runner counts it SKIP. A bare
  `raise "fail:..."` counts as FAIL.
- `mk install` places `.dis` both in `tests/` (where `runner.dis` scans)
  and `dis/tests/` (what `run-tests.sh` invokes). Compiling manually to
  only one location makes the test invisible to the other entry point.
- **CI compiles tests per-file with plain `limbo -I$ROOT/module -o ...`,
  not via `tests/mkfile`** — a test that needs extra include paths (a
  special mkfile rule) will compile locally and fail CI's compile gate.
  Keep includes standard, or update the CI loop in the same PR.

## Inferno-side sh tests (`tests/inferno/`)

```sh
#!/dis/sh.dis
load std
myservice &                                  # background 9P servers, always
sleep 2
if {! ftest -d /mnt/myservice} { raise 'skip:/mnt/myservice not available' }
echo 'do thing' > /mnt/myservice/ctl
echo PASS
```

Rules, all load-bearing:
- Inferno sh is rc-style: **no `&&`, no `||`**; `if {cmd} { ... }`.
- `raise 'skip:reason'` → SKIP, `raise 'fail:reason'` → FAIL.
- **The file must be committed executable (mode 100755)** —
  `sh->system()` execs the path; a 644 script fails as "file does not
  exist" and looks like a missing backend. `tools/verify-sh-exec.sh` gates
  this in CI.
- The runner executes **every** `.sh` in `tests/inferno/`, not just
  `*_test.sh` — helper scripts must be PASS-silent or live elsewhere.

## Host-side sh tests (`tests/host/`)

Start from this contract:

```sh
#!/bin/sh
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"      # sets EMU, BINDIR, LIMBO; exit 77 if unsupported
```

Exit 0 = PASS, **exit 77 = SKIP**, anything else = FAIL. Only
`tests/host/*_test.sh` are auto-run.

The standard long-test pattern (because **emu never self-exits while a 9P
server is backgrounded**): write the in-emu script into `$ROOT/tmp/` (so
it's reachable as `/tmp/...`), start emu in the background redirected to a
log, poll the log for a sentinel line (`=== SCRIPT DONE ===`) with a hard
timeout, then `kill` the emu. Reference implementation:
`tests/host/wallet9p_test.sh`.

Note: several `tests/host/*_test.sh` are static source-greps (regression
pins on C/Limbo source patterns), not runtime tests — read the test before
assuming it exercises behavior.

## What CI actually does

- Compile failures in the test tree **do** fail the build.
- The Limbo suite result is currently **non-gating** (transitional):
  failures surface as warnings. A green check does not by itself mean the
  suite passed — read the job log when it matters.
- Gating: nsaudit fixture checks, wallet/secstore integration, the
  presentation file-open GUI regression, JIT correctness and boot smoke,
  `verify-dis-paths`, `verify-sh-exec`, and the ring-fence job.
- Benchmarks (`tests/bench/`), stress (`tests/stress/`), and interop
  (`tests/interop/`) are deliberately outside the auto-run suite.
