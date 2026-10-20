# InferNode - Development Guide for Claude

This guide ensures Claude Code works correctly with the InferNode (Inferno® OS) codebase.

## Design Orientation (read before designing anything new)

The design philosophy — namespace-as-capability, file interfaces not APIs,
text not JSON, mechanism not policy — is in
[docs/DESIGN-PRINCIPLES.md](docs/DESIGN-PRINCIPLES.md), with wrong/right examples
from this tree. New services start with a namespace sketch in an issue, not
with code. Limbo is close to Go:
[docs/LIMBO-FOR-GO-PROGRAMMERS.md](docs/LIMBO-FOR-GO-PROGRAMMERS.md).
Task playbooks (compile loop, tests, headless GUI harness, authoring 9P
servers, emulator C) are project skills under `.claude/skills/`.

## JIT Compiler Availability

**AMD64 (x86-64), ARM64 and RISC-V (RV64GC) have JIT compilers.** The ARM64 JIT (`libinterp/comp-arm64.c`) supports both macOS (Apple Silicon) and Linux (e.g. NVIDIA Jetson). Run with `emu -c1` to enable JIT compilation, `emu -c0` for interpreter only.

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

### Dis Files: A Build Product

The `dis/` directory holds compiled Dis bytecode. **It is a build product and
is not tracked in git**, exactly like `emu/*/o.emu`. A fresh clone has no
runtime until you build one — and it has no emulator either, so you were
building regardless.

It used to be tracked, inherited from the 2006 upstream drop (`46439007c`,
still in this history). The cost was a tree free to drift from the source that
produced it: bytecode went stale (`dis/acme.dis` shipped font paths the source
had abandoned five months earlier), modules were compiled to paths the build
never installs to, sources were deleted with their binaries left behind, and 45
modules shipped that no mkfile ever compiled. Releases carried ~940 files that
nothing had built from the tagged source.

Releases still ship a runnable tree: the packaging job builds it before
staging, which is how `o.emu` has always worked.

**Rebuild after cloning, pulling, or editing any `.b` or `.m`:**

```sh
export ROOT=$PWD
export PATH="$ROOT/$SYSHOST/$OBJTYPE/bin:$PATH"
for d in appl appl/mpeg appl/veltro tests; do (cd $d && mk install); done
```

Takes about 20 seconds. `hooks/post-merge` does it for you after `git pull`
(`./hooks/install.sh` once). All four directories are needed: `appl/mpeg` and
`appl/veltro` are not in `appl/mkfile`'s `DIRS`.

**The set of modules the build must produce is tracked**, as
`tools/dis-manifest.txt`. `tools/verify-dis-build.sh` builds the tree and fails
if anything on that list is missing; CI and every release job run it. Add or
remove a module and you update the manifest in the same commit.

**The stale bytecode problem:** When a `.m` interface file changes (e.g. `module/widget.m`), every `.dis` compiled against the old interface becomes stale. The Dis VM rejects stale modules at load time with `link typecheck` errors — apps show blank tabs, commands fail to load, and everything looks broken even though the source is fine. This is the most common class of post-pull breakage.

**The solution:** A `post-merge` git hook automatically detects which `.m` and `.b` files changed after `git pull` and rebuilds the affected `.dis` directories. Install it once after cloning:

```sh
./hooks/install.sh
```

After that, every `git pull` triggers an automatic rebuild of stale bytecode. See `hooks/post-merge` for details.

**The wrong-target trap (READ THIS BEFORE COMPILING ANYTHING).** A module
declares `PATH: con "/dis/foo.dis";` so the runtime loads `dis/foo.dis`, and its
mkfile installs there. If you hand-compile with `limbo -o dis/cmd/foo.dis ...`
— any path that is not what the build installs to — `emu` keeps loading the old
`dis/foo.dis` while your "fix" lands in a directory it never reads from. This
burned multiple debug sessions, and `dis/cmd/` accumulated seven stale
duplicates that way before it was cleaned out.

Untracking `dis/` removes most of this: you can no longer commit bytecode, so a
wrongly-placed file is a local mess rather than something that ships. What
remains is that your own tree can lie to you for an afternoon. The defences:

- **Never run `limbo -o ...` directly.** Use one of:
  - `tools/compile-limbo.sh <source.b>` — reads the module's `PATH` constant and
    emits to that exact location. No `-o` to get wrong.
  - `mk install` from the appropriate source directory — installs to the
    canonical path the mkfile's `DISBIN` names.
- **`tools/verify-dis-build.sh`** builds the tree and checks it against
  `tools/dis-manifest.txt`. A module that no mkfile compiles shows up as
  missing. CI and every release job run it.

If you see "my fix isn't taking effect" symptoms — the bug looks identical after
a recompile, diagnostic prints never appear — you almost certainly compiled to a
path nothing loads. Rebuild properly with the loop above before chasing anything
else.

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

The `.app` bundle path (`./build-dev-bundle.sh` then `open …`) is reserved for testing packaging itself, not for code iteration. `build-dev-bundle.sh` (and `build-dev-bundle.ps1` on Windows) is the local equivalent of `.github/workflows/release.yml` minus codesign/notarize/strip.

To open a file in an editor for the user, run `plumb <file>` (opens it in their running Xenith, starting one if needed), falling back to `tools/xen <file>` (Xenith alone, full-window) if `plumb` fails; `tools/xen -s <file>` for sam. Both return at once; leaving the editor halts that instance. See [docs/XEN.md](docs/XEN.md).

## Inferno® Shell Differences

The Inferno® shell is rc-style, not POSIX sh:
- No `&&` operator - use `;` or separate commands
- `for` loops: `for i in $list { commands }` not `for i in $list; do ... done`
- Different quoting rules

Full dialect reference: [docs/INFERNO-SHELL.md](docs/INFERNO-SHELL.md).

## Testing System

InferNode uses a custom testing framework (`module/testing.m`) for Limbo unit tests.

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
| `xenith_frame_test.b` | Xenith's frame (text layout and drawing) against a simulated screen: insert, delete, select, wrap, tabs, overflow, random edits; the suite is `xenith_framesuite.b` |
| `sdl3_test.b` | SDL3 GUI backend |
| `secp256k1_test.b` | secp256k1 curve, ECDSA, recovery |
| `tests/host/mldsa_decompose_test.sh` | ML-DSA Decompose against FIPS 204 Algorithm 36 on every input, and no divide instruction in it (it sees secret-derived values; cf. CVE-2026-22705) |
| `ethcrypto_test.b` | RLP, EIP-155 spec vector, address derivation, strict amounts |
| `ethrpc_conv_test.b` | Arbitrary-precision hex/decimal conversions |
| `x402_test.b` | x402 parsing, EIP-712 type hashes, authdigest |
| `llmclient_proxy_test.b` | llmclient's TLS connections through an HTTP proxy (INFR-307): CONNECT for the API's host and port, Basic credentials from the proxy URL, a ClientHello naming the host inside the tunnel, a refusal reported, `no_proxy` hosts and domains dialled directly; `tests/host/profile_proxy_test.sh` checks the login profile copies the host's `HTTPS_PROXY` and `no_proxy` |
| `publicnet_host_test.b` | Shared URL-host parsing + SSRF blocklist |
| `wallet_policy_test.b` | wallet9p budgets, approval queue, per-fid isolation |
| `wallet_capability_test.b` | Wallet agent-namespace narrowing |
| `wpa_test.b` | WPA2 key derivation (RFC 6070, 802.11i, RFC 3394) + the four-way handshake |
| `dhcp_test.b` | DHCP option encoding (RFC 2132) + a whole exchange against a synthetic server |
| `destructor_test.b` | Dropping the last reference frees the cell now (JIT MacFRP), not at the next collection; a chain deeper than destroy() recurses is freed whole |
| `fdclose_test.b` | Dropping the last reference to an fd closes it |
| `pgrp_race_test.b` | A Prog swapping its name space, fd group and dot (`pctl` FORKNS, NEWFD, `chdir`) and exiting while others read its `/prog/n/ns`, `fd` and `status`: no use-after-free, no wedged name space (INFR-373); Progs sharing a name space, one changing dot while the others resolve relative names (INFR-59) |
| `wstat_nulldir_test.b` | A wstat's "don't change" (~0) fields change nothing on 64-bit hosts; `tests/host/wstat_nulldir_test.sh` checks host files keep their mode and time across `mv` and `chmod` |
| `fractals_zoombox_test.b` | wm/fractals' own canvas bindings, driven by a synthetic button-1 drag: the zoom rubber-band grows from the press point and is painted |
| `jit_fault_test.b` | JIT faults: zero divide, bounds, nil, unwinding to the right handler; `tests/host/jit_fault_test.sh` runs it under `-c0` and `-c1` |
| `jit_ownhandler_test.b` | A hardware fault in compiled code caught in the faulting callee's own frame (the trap handler takes R.FP from the JIT's register); run by `tests/host/jit_fault_test.sh` too |
| `jit_bounds_test.b` | Negative and overlarge indices on arrays, strings and slices raise `array bounds error` from compiled code; `tests/host/jit_bounds_test.sh` runs it under `-c0` and `-c1` |
| `jit_big_test.b` | `big` `*`, `/`, `%` and `hd` of a list of `big` give from compiled code what the interpreter gives: signs, wrapping, zero divide, the most negative `big` over -1 (it wraps); `tests/host/jit_big_test.sh` runs it under `-c0` and `-c1` |
| `jit_real_test.b` | Real arithmetic, comparisons (a NaN, the signed zeros), conversions (half away from zero), negation and moves give from compiled code what the interpreter gives; `tests/host/jit_real_test.sh` runs it under `-c0` and `-c1` |
| `utf21_test.b` | Runes beyond U+FFFF (U+1F680, U+20000, to U+10FFFF): one rune each from four bytes of UTF-8 and back, `s[i] = r` and `%c`, `\U` literals, bad sequences and unencodable runes to U+FFFD, `utfbytes`/`byte2char`/`char2byte`, UTF-16 surrogate pairs through convcs; run under `-c0` and `-c1` |
| `refadt_zero_test.b` | `ref T` with no initializer zero-fills every scalar member; `tests/host/refadt_zero_test.sh` runs it under `-c0` and `-c1` |
| `limbo_inline_test.b` | Code the compiler inlines: an inlined call's temporary argument outlives the use of its element; `v = f(v)` reads the old `v` |
| `limbo_ldt_test.b` | A module taking a `ref fn` of its own functions loads another module through a module type equal to its own (INFR-310); the `ref fn` still calls through `$self` |
| `limbo_asgcall_test.b` | `a[i] = f()` and `p.x = f()` where `f` makes a new `a` or `p`: the call is made before the element's address is found, so its result lands in the new one, not in freed memory |
| `jit_unload_test.b` | A compiled module returning after its caller dropped the last reference (its code must not be unmapped under the return) |
| `jit_retslice_test.b` | A call between modules from compiled code does not end the thread's time slice, at any stack depth (a return punted to the VM after a call saw mcall's stale R.t) |
| `sam_test.b` | Native sam engine over its pipe: addresses, commands, undo, the terminal protocol |
| `hostplumb_test.b` | hostplumb(1) re-plumbing host messages under `/n/local`; the plumber refusing a message nothing can receive |
| `tests/host/agent_delegation_test.sh` | Activity 0 delegating to a task agent through lucibridge: the task agent uses its own tools, activity 0 keeps its tools and its own session afterwards, the completion reaches activity 0 as a turn (not the human's words), each reply shown once, a message longer than one 9P message arrives whole; a task's changes to two folders promoted together; changes staged in an earlier session set aside, offered back at start (Apply/Discard), never taken over by a new task |
| `tests/host/compaction_test.sh` | llmsrv compacting a long session (at a mark low enough to do it after every generation) does not break an agent's turn of tool calls: compaction waits for the end of a tool exchange, as a real API refuses results that answer calls no longer in the history; a chat's last exchange is kept as it was after the summary, not summarised |
| `tests/host/luciuisrv_closed_test.sh` | A closed activity refuses every write (status, messages, resources, artifacts, urgency) and luciuisrv keeps answering: a task closed while it worked used to crash the UI server or reopen itself |
| `tests/host/prompt_defaults_test.sh` | The agent prompts copied into `~/.infernode` follow the shipped defaults until the user edits them: every shipped version's hash is in `lib/veltro/prompt-defaults`, an unedited old copy is brought up to date at boot, an edited one is left |
| `tests/host/veltrosrv_test.sh` | The agent harness's file contract at `/mnt/veltro`: idle EOF, busy, cancel, ctl validation, and the agent's tools unable to see the mount |
| `tests/host/agentloop_characterization_test.sh` | What the agent loop does against a scripted model, through `lucibridge` (via `/mnt/ui`) and through `/mnt/veltro`, pinned as golden files |
| `tests/host/wiki9p_test.sh` | The LLM-maintained wiki (`/mnt/wikia`, wiki9p over wikifs) against a scripted model: a reply's pages all written and listed at once, a page updated with its history kept, a command's result read on its own fid (the read waits), status answering with nothing bound on `raw`, the agent's `wiki` tool through tools9p |
| `tests/host/xenith_agent_test.sh` | The `Agent` window in a headless Xenith: a message sent, the reply shown |
| `imgload_test.b` | The shared image loader (`module/imgload.m`): format detection from the data and the name, every format decoded from `tests/imgload/` fixtures with its pixels checked, the document registry not taking text that begins like an image for one |
| `docengine_test.b` | The document registry and engines (`module/docreg.m`, `module/docengine.m`): kinds by name and magic, no engine loaded until a document of its kind is opened (and Markdown never loading Charon), each engine's sheets, painting and text, a PDF sharp at scale 200, a PDF's words where they are drawn, a PDF's links (a URI, a page by destination and by name) where they are, a PDF's ToUnicode mapping a code to several characters (a ligature's `<00660066>`), a PDF whose page box is not at 0 0 (a cropped figure's) painted with its words and links where they are in it, Markdown's words and links, documents kept apart |
| `sheetview_test.b` | The document view (`module/sheetview.m`) on an image of its own: a PDF of three pages opened through the view's events, fitted, painted, paged, zoomed, searched, turned (points mapped back to the page), its place kept on a resize, the way it last moved; an HTML page painted into a band round the view (a scroll within it paints nothing, one past it keeps what it held, what is shown is the page) |
| `tests/host/wm_test.sh` | `wm/wm` driven by the pointer: New by a click or a hold, then swept (with no motion between, as a trackpad sends), a sweep cancelled or too small, the background, click to focus, the frame's move and reshape, Move, Resize, Hide and back, Delete; where each step leaves the windows; a theme switched, the frames (fractals' among them) and the menu checked by pixel |
| `tests/host/wm_theme_test.sh` | Every wm application under `wm/wm` through a live theme switch, by pixel: its frame takes the new windowborder and its window keeps almost none of the old theme's colours |
| `tests/host/wm_ghost_test.sh` | A `wm/wm` client that leaves, deleted from the menu and killed (INFR-433): wm stays up, and where its window was is wm's background again, by pixel |
| `tests/host/page_test.sh` | `wm/page` under `wm/wm`, driven by keys and the pointer, the page shown written as an image at each step: n, p, Home, End, go to, space, the wheel, a button-1 drag, the button-2 operations menu and button-3 pages menu, fit width and page, zoom, turning, two files as one, standard input, q, Markdown and HTML shown, a PDF's links followed (to a page; to a URI, through a plumber) |
| `tests/host/xenith_doc_test.sh` | A window's document through its files (`doc/`): a PDF shown as a document (read-only body, Put refused, zoom, fit, sheet, Render, Get, find), a window open on it as text shown, Markdown set by Render, Markdown and HTML shown beside their text (Zerox) set again on Put and `doc/ctl` refresh, and with `Live` (either window's tag, or `doc/ctl` `live`) a moment after each edit, at once if edited before; `Live` in a lone text window opening one live beside it, an image, a PDF's links (`doc/links`; button 3 on one to a page goes to it, on one to a URI browses it in Xenith); refresh after typing not yet committed (typed through `/dev/keyboard`); run with a plumber whose rules would take a web address, which a link clicked in Xenith must not reach |
| `tests/host/plumbrules_test.sh` | `lib/sh/plumbrules`: the user's plumbing rules read before the defaults (a user rule overrides, the defaults take the rest); `load` replaces them; a rules file that does not parse is refused at load and left out at start |
| `tests/host/charon_accept_test.sh` | What Charon's engine sends as Accept: an image fetch `image/webp` first, as browsers do, so image CDNs send WebP; a page or style sheet fetch none |
| `tests/host/js_dom_test.sh` | `tests/js/pages/dom.html`, the DOM a page's scripts see (`lib/js/dom.js`), checked from inside a page with its scripts on; among its checks, a page asking whether CSS animates is told no (nothing does; Microsoft's sign-in waited for an `animationend` when told yes) |
| `tests/host/js_formpost_test.sh` | A form a page's script submits by POST is posted (`form.submit()`, a submit button's `click()`), its entries url-encoded, the button named; it was only logged as unsupported, so Microsoft's sign-in went nowhere after the password |
| `tests/host/js_binary_test.sh` | A page's scripts get a response's bytes as they came (`arrayBuffer()`, `blob()`, an XHR's `arraybuffer`), every byte value, and an `ArrayBuffer` posted is sent as its bytes; a UTF-8 response's text and bytes unchanged. Bytes that are not UTF-8 came back mangled, so JSTOR's sign-in check could not decode its payload |
| `tests/host/charon_password_test.sh` | A password field's value is not in a page's files (`forms`, `dom/N/attrs`, `text`): they show `********` when it is filled, as anything with the window's files (an agent) could read them; the page's script and the form sent still have the value |
| `tests/host/presentation_fileopen_test.sh` | Lucifer's plumbed file-opens: by type into the presentation view, a web URL into Charon (a second one to the running Charon), the Tasks tab with and without a plumber |
| `tests/host/xenith_browse_test.sh` | Xenith browses: a URL looked at opens a browser window (the page over its text, Back Fwd Reload in the tag); Get goes to the URL in the tag; Back, Fwd and Render; a form typed into (injected click and keys); the page as files (posted where the window's `web` file says, a form submitted through `ctl` shown in the window, unposted when it closes); the same page over HTTP through webfs from a loopback server |
| `tests/host/xenith_image_test.sh` | Xenith opens every image format as an image through a look (B3) at its name; formats with no decoder are refused with a reason; text still opens as text |
| `tests/host/charon_forms_test.sh` | Charon's `forms` file after a page's scripts change the document: a control moved into a form made after it is in that form and sent with it; one removed, or made and never put in the document, is not listed (Microsoft's sign-in keeps three such copies of its inputs) |
| `tests/host/charon_formowner_test.sh` | A form's controls are the ones HTML puts in it, sent in the document's order, through Charon's files (`forms`, `submit`) and from the page's scripts (`.form`, `form.elements`, `form.submit()`): none from a template's content, a control's `form` attribute followed (to the form with that id, or to none), a field a script put first sent first |
| `tests/host/charon_shadowlabel_test.sh` | A web component's button is labelled in Charon's `forms` and `dom/N/text` with what the page put in the component (shown through a slot), a host's text is its shadow tree's without its style sheet, a plain button keeps its label (JSTOR's sign-in buttons had none) |
| `tests/host/charon_shadowcheck_test.sh` | A label clicked in a web component's shadow tree checks the checkbox its `for` names in that tree, not one with the same id in another component, and the component hears the change (JSTOR's terms checkbox could not be ticked) |
| `tests/host/editor_headless_test.sh` | A Tk application with no window manager waits rather than spins (INFR-365): `wm/editor`'s `/edit/1/body` written and read back, its idle CPU time measured |
| `tests/host/xen_boot_test.sh` | `lib/xen/boot.sh`, the standalone Xenith's entry point: plumber and model up, a plumbed file opened |
| `tests/host/tools9p_result_test.sh` | Two callers of one tool each read their own result (results are per fid, not per tool); arguments longer than one 9P message run the tool once, on all of them, including arguments ending exactly on a message boundary (INFR-521) |
| `tests/host/spawn_budget_test.sh` | A subagent spawned through tools9p loads the delegation budget's tools (named, and its default `plan`) and cannot load a tool outside it (INFR-486); `spawn_budget_test.b` is its Limbo half |
| `tests/host/profile_legacykey_test.sh` | The login profile imports a plaintext key left in `~/.infernode/lib/veltro-keys` into factotum, says which file to delete, and does not bind it into the name space (INFR-347) |
| `tests/host/veltro_cli_test.sh` | The `veltro` command: a task run, its session saved and resumed |
| `tests/host/pool_nomem_test.sh` | An allocation a pool refuses is reported with its size, the reason (beyond the pool's maxsize, over the 1GB block limit, a restricted Prog, the host), the caller as image+offset for addr2line, and the pool's state; the first ten, then every thousandth (INFR-472); `pool_nomem_helper.b` is its Limbo half |
| `tests/host/emu_root_test.sh` | A root (`-r`, `$ROOT`) of 300+ bytes is used; one longer than `rootdir` is refused, naming its length; a missing root, or one that is a file, stops emu saying so (not "`/dis` file does not exist") |

Shell tests also exist in `tests/inferno/` (run inside Inferno) and `tests/host/` (run on the host OS).

Xenith's 9P interface is tested inside a headless Xenith: `tests/host/xenith_inside.sh` runs a `tests/inferno/` script where it can see `/mnt/xenith` (`xenith_acme_files_test.sh`: the window files from canonical Acme; `xenith_edit_test.sh`: addresses, regular expressions and the sam command language, through `addr`, `xdata` and `edit`; `xenith_event_test.sh`: the event protocol, both ways; `xenith_image_test.sh`: images opened by a look; `xenith_blankname_test.sh`: a file name with a blank in it, quoted in the tag and Put to the right file; `xenith_browse_test.sh`: browsing, with `XENITH_INSIDE_NET=1` for the network). `XENITH_INSIDE_PLUMB=<rules>` starts a plumber with those rules first, as a session has one. They need the SDL GUI emulator and skip on a headless build.

## Project Structure

```
infernode/
├── MacOSX/arm64/bin/    # Native macOS build tools (built by makemk.sh + mk)
├── emu/                 # Emulator source and binaries
│   ├── MacOSX/          #   macOS emulator (o.emu binary)
│   ├── Linux/           #   Linux emulator (build with build-linux-*.sh)
│   ├── Nt/              #   Windows emulator (build-windows-amd64.ps1)
│   ├── Android/         #   Android platform glue (build-android-*.sh)
│   ├── iOS/             #   iOS platform glue (build-ios-*.sh)
│   └── port/            #   Platform-independent emulator source
├── appl/                # Limbo application source (~900 .b files)
│   ├── cmd/             #   Command-line utilities (incl. mail9p — IMAP/SMTP at /mnt/mail)
│   ├── lib/             #   Library modules
│   ├── veltro/          #   Veltro AI agent system
│   ├── xenith/          #   Xenith text environment (Acme fork)
│   ├── acme/            #   Acme text editor
│   ├── wm/              #   Window manager
│   └── svc/             #   Services (httpd, etc.)
├── module/              # Limbo module interfaces (.m files)
├── os/                  # NATIVE (bare-metal) kernel: os/arm64 shared AArch64,
│                        #   os/bcm2837 Raspberry Pi 3B+, os/port portable kernel,
│                        #   os/ip TCP/IP, os/init the Dis that boots it,
│                        #   os/bcm drivers the Pi SoCs share, os/bcm2711
│                        #   Raspberry Pi 4B, os/virt QEMU AArch64 virt,
│                        #   os/virtio virtio drivers, os/fb framebuffer console.
│                        #   Built and tested ONLY via tests/host/baremetal_test.sh;
│                        #   status and roadmap in os/bcm2837/README.md.
│                        #   RISC-V: os/riscv64 (arch), os/riscvvirt (QEMU virt),
│                        #   os/mpfs (PolarFire SoC: BeagleV-Fire, Icicle Kit),
│                        #   via tests/host/baremetal_riscv64_test.sh;
│                        #   see os/riscv64/README.md.
├── tests/               # Unit tests (Limbo + shell)
│   ├── host/            #   Host-side shell tests
│   ├── inferno/         #   Inferno-side shell tests
│   ├── testing/         #   Testing framework self-tests
├── dis/                 # Compiled Dis bytecode (build product, NOT tracked)
├── lib/                 # Runtime data (fonts, shell profile, etc.)
│   └── veltro/          #   Veltro tools, agents, reminders
├── libinterp/           # Dis VM interpreter and JIT compilers
├── docs/                # Technical documentation (100+ files)
├── formal-verification/ # CBMC, TLA+, SPIN verification
├── hooks/               # Git hooks (run ./hooks/install.sh after clone)
├── mkfiles/             # Shared mk build rules
├── mkconfig             # Build configuration (auto-detects platform)
├── .github/workflows/   # CI/CD (build, test, release, security and more)
└── build-*.sh           # Platform build scripts
```

## External harness ring-fence

Adversarial campaign infrastructure lives in
`infernode-os/infernode-escape-room`, with InferNode pinned as a dependency.
It is **testing-only and must never ship in an InferNode release**:

- The release tarballs / .app bundle / DMG / .zip would each expose
  `/mnt/ui` over a 9P port if they included these files. That is not the
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
   every PR and fails if those patterns appear anywhere in the source tree.

**Do not copy serve-agent files into this repository.** If the harness ever
genuinely becomes a shippable feature, that decision needs explicit design work
and the CI guards updated together — never silently.

The subagent trajectory logging added in `appl/veltro/tools/spawn.b` and `appl/veltro/subagent.b`
is *not* ring-fenced: it's a general observability improvement to the
agent stack, useful outside the harness, and ships normally.

## Project tracking — Jira (Atlassian Cloud, free tier)

Work on this project is tracked in Jira (project keys below).

- **`INFR`** (this repo) — InferNode runtime, llmsrv, lucibridge, Veltro tools, headless serve-llm. Epic: `INFR-1` (LLM-as-tool routing + multi-model serving).
- **`IOL`** (sibling: `pdfinn/infernode-os-llm`) — LLM corpus, training, eval harness. Epic: `IOL-1` (v4 corpus + harness extensions).
- **`SCRUM`** — organizational / compliance work.

A helper script lives in the sibling repo at `pdfinn/infernode-os-llm/tools/jira.py`. Auth: reads `ATL_EMAIL` + `ATL_TOKEN` from env, or `~/.atlassian/credentials` (mode 600). Never commit credentials.

When closing a code change that resolves a Jira ticket, **reference the key in the commit message** (e.g. `Refs: INFR-2`) — Jira links them automatically.

Notable open INFR tasks at time of this writing:
- `INFR-2` — implement `/tool/limbo/run` (LLM-as-tool routing pattern; see `docs/LLM-AS-TOOL.md` in the IOL repo for design)
- `INFR-3` — wire lucibridge per-capability routing (likely superseded by INFR-2)
- `INFR-4` — verify `/mnt/llm/$id/model` accepts writes (5-min spike; prerequisite for INFR-2)
