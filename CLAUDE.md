# Infernode - Development Guide for Claude

This guide ensures Claude Code works correctly with the Infernode (Inferno® OS) codebase.

## JIT Compiler Availability

**AMD64 (x86-64) and ARM64 have JIT compilers.** The ARM64 JIT (`libinterp/comp-arm64.c`) supports both macOS (Apple Silicon) and Linux (e.g. NVIDIA Jetson). Run with `emu -c1` to enable JIT compilation, `emu -c0` for interpreter only.

When compiling Limbo code:
- **Use the native `limbo` compiler** (`MacOSX/arm64/bin/limbo`) - produces portable Dis bytecode
- **Do NOT use the hosted limbo** (`dis/limbo.dis` inside emu) - it sets `MUSTCOMPILE` flag requiring JIT

If you see "compiler required" errors when running `.dis` files, you compiled with the wrong limbo. Recompile using the native compiler.

## Building Limbo Code

**Always use Inferno®'s native build tools from macOS**, not Plan 9 Port or commands inside Inferno. This ensures the build environment is compatible with the target Inferno® system - the same compiler and mk that ship with Inferno® are used to build code that runs on Inferno®.

### Bootstrap (first time after clone)

The native build tools (`mk`, `limbo`) are not checked into git. Bootstrap them:
```sh
./makemk.sh            # builds mk from source using cc (~30s)
```
Then build the rest (libraries, limbo compiler, emulator) using the platform build script or `mk install`.

### Environment Setup

From the project root, set these environment variables:
```sh
export ROOT=$PWD
export PATH=$PWD/MacOSX/arm64/bin:$PATH
```

The native tools are built to:
- `MacOSX/arm64/bin/mk` - Plan 9 mk (Inferno's build tool)
- `MacOSX/arm64/bin/limbo` - Limbo compiler

### Dis Files: What's Tracked and What's Not

The `dis/` directory (the Inferno runtime tree) **is tracked in git**. This is intentional — Inferno is a self-hosting OS, and `dis/` is its `/usr/bin`. Without pre-built `.dis` files, a fresh clone can't boot: no shell, no `cat`, no `ls`. Upstream Inferno OS tracks them for the same reason.

However, **build artifacts in source directories are not tracked**:
- `appl/**/*.dis` — intermediate build outputs (`.gitignore`d)
- `tests/**/*.dis` — compiled tests (`.gitignore`d)
- `dis/tests/*.dis` — test bytecode in the runtime tree (`.gitignore`d)

This means: the runtime tree ships pre-built, but you never commit `.dis` files from `appl/` or `tests/`.

**The stale bytecode problem:** When a `.m` interface file changes (e.g. `module/widget.m`), every `.dis` compiled against the old interface becomes stale. The Dis VM rejects stale modules at load time with `link typecheck` errors — apps show blank tabs, commands fail to load, and everything looks broken even though the source is fine. This is the most common class of post-pull breakage.

**The solution:** A `post-merge` git hook automatically detects which `.m` and `.b` files changed after `git pull` and rebuilds the affected `.dis` directories. Install it once after cloning:

```sh
./hooks/install.sh
```

After that, every `git pull` triggers an automatic rebuild of stale bytecode. See `hooks/post-merge` for details.

**The wrong-target trap (READ THIS BEFORE COMPILING ANYTHING).** A separate class of stale-bytecode bug: a module declares `PATH: con "/dis/foo.dis";` so the runtime loads `dis/foo.dis`. The mkfile installs to `dis/foo.dis`. But there is *also* an `appl/cmd/foo.dis` (intermediate) and there used to be a parallel `dis/cmd/foo.dis` tree. If you manually compile with `limbo -o dis/cmd/foo.dis ...` (or any path that is NOT what the module's PATH constant declares), `emu` cheerfully keeps loading the old `dis/foo.dis` while your "fix" silently lands in a directory it never reads from. This has burned multiple debug sessions. The defences:

- **Never run `limbo -o ...` directly.** Use one of:
  - `tools/compile-limbo.sh <source.b>` — reads the module's `PATH` constant and emits to that exact location. No `-o` to get wrong.
  - `mk install` from the appropriate `appl/<dir>/` — also installs to the canonical path (`DISBIN=$ROOT/dis`).
- **Pre-commit hook** (installed by `./hooks/install.sh`) runs `tools/verify-dis-paths.sh`, which refuses any commit where a source's `dis/<PATH>.dis` is missing or older than the source.
- **CI** (`.github/workflows/verify-dis-paths.yml`) runs the same verifier on every PR — universal backstop for contributors who didn't install the local hook.

If you see "my fix isn't taking effect" symptoms (the bug looks the same after recompile, diagnostic prints don't appear in logs), check `tools/verify-dis-paths.sh` immediately before chasing anything else.

### Build Commands

Build from macOS terminal (not inside Inferno):

```sh
# AFTER FRESH CLONE: Build all commands
cd appl/cmd
mk install

# Build tests
cd tests
mk install

# Clean and rebuild
mk nuke
mk install

# Build a specific directory
cd appl/lib
mk testing.dis
```

### Why Native Tools?

Using Inferno®'s native mk and limbo ensures:
1. **Compatibility** - Same toolchain that built Inferno® builds your code
2. **Correct SHELLTYPE** - mkconfig uses `SHELLTYPE=sh` for macOS /bin/sh
3. **No PATH conflicts** - Avoids mixing Plan 9 Port tools with Inferno® tools

Do NOT:
- Run `mk` inside Inferno (SHELLTYPE mismatch)
- Use Plan 9 Port's mk (may have subtle incompatibilities)
- Use bash-isms like `&&` to chain commands (use `;` or separate commands)

## Running for Development

The standard developer launch is `emu` invoked directly from a terminal — same shape on macOS, Linux, and Windows; only the binary path differs:

```sh
# GUI (lucifer) — same shape on every platform
./emu/MacOSX/o.emu -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r$PWD sh -l /lib/lucifer/boot.sh   # macOS
./emu/Linux/o.emu  -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r$PWD sh -l /lib/lucifer/boot.sh   # Linux
.\emu\Nt\o.emu.exe -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r%CD% sh -l /lib/lucifer/boot.sh  # Windows

# Headless (drops to Inferno ';' shell)
./emu/MacOSX/o.emu -c1 -r$PWD sh -l                                                                # macOS
./emu/Linux/o.emu  -c1 -r$PWD sh -l                                                                # Linux
.\emu\Nt\o.emu.exe -c1 -r%CD% sh -l                                                               # Windows
```

stdout/stderr stream to the terminal, Ctrl-C exits, no signing/Gatekeeper/Translocation in the loop. `/lib/lucifer/boot.sh` is the canonical boot orchestration and is the same script the production macOS `.app` launcher invokes. See [QUICKSTART.md](QUICKSTART.md#running-for-development) for the full table and flag reference.

The `.app` bundle path (`./build-dev-bundle.sh` then `open …`) is reserved for testing packaging itself, not for code iteration. `build-dev-bundle.sh` is currently untracked and authored ad-hoc — treat it as the local equivalent of `.github/workflows/release.yml` minus codesign/notarize/strip.

## Inferno® Shell Differences

The Inferno® shell is rc-style, not POSIX sh:
- No `&&` operator - use `;` or separate commands
- `for` loops: `for i in $list { commands }` not `for i in $list; do ... done`
- Different quoting rules

## Testing System

Infernode uses a custom testing framework (`module/testing.m`) for Limbo unit tests.

### Running Tests

Tests run inside the Inferno® emulator. From the project root:

```sh
# Set up environment first
export ROOT=$PWD
export PATH=$PWD/MacOSX/arm64/bin:$PATH

# Build all tests
cd tests
mk install

# Run all tests via the test runner (inside Inferno)
# The emu command launches Inferno and runs the test runner
./emu/MacOSX/o.emu -r. /tests/runner.dis

# Run a specific test file
./emu/MacOSX/o.emu -r. /tests/asyncio_test.dis

# Run with verbose output
./emu/MacOSX/o.emu -r. /tests/runner.dis -v
```

### Writing Tests

Test files follow this structure:

```limbo
implement MyTest;

include "sys.m";
    sys: Sys;

include "draw.m";

include "testing.m";
    testing: Testing;
    T: import testing;

MyTest: module
{
    init: fn(nil: ref Draw->Context, args: list of string);
};

# Source file path for clickable error addresses
SRCFILE: con "/tests/mytest.b";

# Global counters
passed := 0;
failed := 0;
skipped := 0;

# Test runner helper
run(name: string, testfn: ref fn(t: ref T))
{
    t := testing->newTsrc(name, SRCFILE);
    {
        testfn(t);
    } exception {
    "fail:fatal" =>
        ;
    "fail:skip" =>
        ;
    * =>
        t.failed = 1;
    }

    if(testing->done(t))
        passed++;
    else if(t.skipped)
        skipped++;
    else
        failed++;
}

# Example test function
testExample(t: ref T)
{
    t.assert(1 == 1, "basic math works");
    t.asserteq(2 + 2, 4, "addition");
    t.assertseq("hello", "hello", "string equality");

    # Log messages (shown in verbose mode)
    t.log("this is a log message");

    # Skip a test
    # t.skip("reason for skipping");

    # Fatal error (stops this test)
    # t.fatal("something went very wrong");
}

init(nil: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    testing = load Testing Testing->PATH;

    if(testing == nil) {
        sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
        raise "fail:cannot load testing";
    }

    testing->init();

    # Parse -v flag for verbose mode
    for(a := args; a != nil; a = tl a) {
        if(hd a == "-v")
            testing->verbose(1);
    }

    # Run tests
    run("Example", testExample);

    # Print summary and exit with failure if any tests failed
    if(testing->summary(passed, failed, skipped) > 0)
        raise "fail:tests failed";
}
```

### Testing API Reference

The `T` adt provides these methods:

| Method | Description |
|--------|-------------|
| `t.log(msg)` | Log a message (shown in verbose mode) |
| `t.error(msg)` | Report failure but continue test |
| `t.fatal(msg)` | Report failure and stop test |
| `t.skip(msg)` | Skip this test |
| `t.assert(cond, msg)` | Assert condition is true |
| `t.asserteq(got, want, msg)` | Assert integers are equal |
| `t.assertne(got, notexpect, msg)` | Assert integers are not equal |
| `t.assertseq(got, want, msg)` | Assert strings are equal |
| `t.assertsne(got, notexpect, msg)` | Assert strings are not equal |
| `t.assertnil(got, msg)` | Assert string is nil/empty |
| `t.assertnotnil(got, msg)` | Assert string is not nil/empty |

### Test File Naming

- Test files must end with `_test.b`
- Place tests in the `tests/` directory
- The test runner (`tests/runner.dis`) automatically discovers `*_test.dis` files

### Clickable Error Addresses

When a test fails, the output includes clickable addresses that work in Xenith:

```
FAIL: MyTest/Example
    /tests/mytest.b:/testExample/ assertion failed: something broke
```

To enable this, define `SRCFILE` and use `testing->newTsrc(name, SRCFILE)`.

### Testing Async/Concurrent Code

For testing spawned tasks and channels:

```limbo
testAsyncOperation(t: ref T)
{
    result := chan of string;

    # Spawn a task
    spawn worker(result);

    # Wait with timeout
    timeout := chan of int;
    spawn timeoutTask(timeout, 1000);  # 1 second

    alt {
        r := <-result =>
            t.assertseq(r, "expected", "worker result");
        <-timeout =>
            t.fatal("operation timed out");
    }
}

worker(result: chan of string)
{
    # Do work...
    result <-= "expected";
}

timeoutTask(ch: chan of int, ms: int)
{
    sys->sleep(ms);
    ch <-= 1;
}
```

### Test Categories

| Test File | Purpose |
|-----------|---------|
| `example_test.b` | Reference template for new tests |
| `asyncio_test.b` | Async I/O, channels, spawned tasks |
| `crypto_test.b` | Cryptographic operations |
| `spawn_test.b` | Process spawning |
| `spawn_exec_test.b` | Process exec after spawn |
| `tcp_test.b` | TCP networking |
| `9p_export_test.b` | 9P protocol export |
| `tempfile_test.b` | Temporary file operations |
| `stderr_test.b` | Standard error output |
| `hello_test.b` | Basic smoke test |
| `veltro_test.b` | Veltro agent system |
| `veltro_tools_test.b` | Veltro tool modules |
| `veltro_security_test.b` | Veltro namespace security |
| `veltro_concurrent_test.b` | Veltro concurrency |
| `agent_test.b` | Agent operations |
| `edit_test.b` | Edit operations |
| `xenith_concurrency_test.b` | Xenith concurrent operations |
| `xenith_exit_test.b` | Xenith exit handling |
| `sdl3_test.b` | SDL3 GUI backend |

Shell tests also exist in `tests/inferno/` (run inside Inferno) and `tests/host/` (run on the host OS).

## Project Structure

```
infernode/
├── MacOSX/arm64/bin/    # Native macOS build tools (built by makemk.sh + mk)
├── emu/                 # Emulator source and binaries
│   ├── MacOSX/          #   macOS emulator (o.emu binary)
│   ├── Linux/           #   Linux emulator (build with build-linux-*.sh)
│   └── port/            #   Platform-independent emulator source
├── appl/                # Limbo application source (~700 .b files)
│   ├── cmd/             #   Command-line utilities (incl. mail9p — IMAP/SMTP at /n/mail)
│   ├── lib/             #   Library modules
│   ├── veltro/          #   Veltro AI agent system
│   ├── xenith/          #   Xenith text environment (Acme fork)
│   ├── acme/            #   Acme text editor
│   ├── wm/              #   Window manager
│   └── svc/             #   Services (httpd, etc.)
├── module/              # Limbo module interfaces (.m files)
├── tests/               # Unit tests (Limbo + shell)
│   ├── host/            #   Host-side shell tests
│   ├── inferno/         #   Inferno-side shell tests
│   ├── testing/         #   Testing framework self-tests
│   └── agent-harness/   #   Ring-fenced eval-harness gateway (see Ring-fence rule)
├── dis/                 # Compiled Dis bytecode (~630 .dis files)
├── lib/                 # Runtime data (fonts, shell profile, etc.)
│   └── veltro/          #   Veltro tools, agents, reminders
├── libinterp/           # Dis VM interpreter and JIT compilers
├── docs/                # Technical documentation (100+ files)
├── formal-verification/ # CBMC, TLA+, SPIN verification
├── hooks/               # Git hooks (run ./hooks/install.sh after clone)
├── mkfiles/             # Shared mk build rules
├── mkconfig             # Build configuration (auto-detects platform)
├── .github/workflows/   # CI/CD (ci, security, scorecard)
└── build-*.sh           # Platform build scripts
```

## Ring-fence rule (tests/agent-harness/)

`tests/agent-harness/` holds the in-tree pieces of the external evaluation
harness — currently `serve-agent` (an Inferno rc profile that starts the
headless agent stack) and `serve-agent.sh` (its host launcher). These
files are **testing-only and must never ship in a release**:

- The release tarballs / .app bundle / DMG / .zip would each expose
  `/n/ui` over a 9P port if they included these files. That is not the
  posture a default install should ever land in.
- The harness configuration assumes localhost binding and a single
  trusted operator — fine for a private evaluation rig, wrong for any
  shipped artefact.

Two CI guards enforce this, and they are load-bearing:

1. **`.github/workflows/release.yml`** — after staging files for the
   release tarball/.app/.zip but before archiving, every job runs a
   `find` (bash) or `Get-ChildItem` (PowerShell) over the stage dir and
   fails the build if anything matches `serve-agent*` or `*agent-harness*`.
2. **`.github/workflows/ci.yml`** — a separate `ring-fence` job runs on
   every PR and fails if those patterns appear in the source tree
   outside `tests/agent-harness/`.

**Do not move serve-agent files into `lib/sh/` or any path that the
release copy loop touches** (currently `dis lib fonts module services
locale usr mnt`, in `release.yml`). If the harness ever genuinely
becomes a shippable feature, that decision needs explicit design work
and the CI guards updated together — never silently.

The subagent trajectory logging added in `appl/veltro/{spawn,subagent}.b`
is *not* ring-fenced: it's a general observability improvement to the
agent stack, useful outside the harness, and ships normally.

## Project tracking — Jira (Atlassian Cloud, free tier)

Work on this project is tracked in Jira at **https://nervsystems-team.atlassian.net**.

- **`INFR`** (this repo) — InferNode runtime, llmsrv, lucibridge, Veltro tools, headless serve-llm. Epic: `INFR-1` (LLM-as-tool routing + multi-model serving).
- **`IOL`** (sibling: `pdfinn/infernode-os-llm`) — LLM corpus, training, eval harness. Epic: `IOL-1` (v4 corpus + harness extensions).
- **`SCRUM`** — NERV Systems work, compliance.

A helper script lives in the sibling repo at `pdfinn/infernode-os-llm/tools/jira.py`. Auth: reads `ATL_EMAIL` + `ATL_TOKEN` from env, or `~/.atlassian/credentials` (mode 600). Never commit credentials.

When closing a code change that resolves a Jira ticket, **reference the key in the commit message** (e.g. `Refs: INFR-2`) — Jira links them automatically.

Notable open INFR tasks at time of this writing:
- `INFR-2` — implement `/tool/limbo/run` (LLM-as-tool routing pattern; see `docs/LLM-AS-TOOL.md` in the IOL repo for design)
- `INFR-3` — wire lucibridge per-capability routing (likely superseded by INFR-2)
- `INFR-4` — verify `/mnt/llm/$id/model` accepts writes (5-min spike; prerequisite for INFR-2)
