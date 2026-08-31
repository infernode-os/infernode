---
name: limbo-dev
description: Compile and build Limbo code correctly — the native toolchain, the wrong-target trap, stale bytecode, and when C libraries must be rebuilt. Use whenever compiling .b files, editing .m interfaces, or a fix mysteriously "isn't taking effect".
---

# Building Limbo code in InferNode

## Environment (once per shell, from the repo root)

```sh
export ROOT=$PWD
export PATH=$PWD/MacOSX/arm64/bin:$PATH   # Linux: $PWD/Linux/amd64|arm64/bin
```

If `mk`/`limbo` don't exist yet: `./makemk.sh`, then the platform build
script. Always use these native tools from the host — never Plan 9 Port's
mk, never the hosted `dis/limbo.dis` inside emu (it sets MUSTCOMPILE; the
resulting bytecode demands JIT and fails with "compiler required" under
`-c0`).

## The two rules that prevent lost debugging sessions

**1. Never run `limbo -o` by hand.** A module declares
`PATH: con "/dis/foo.dis"` and the runtime loads exactly that path. Compile
to anywhere else and emu silently keeps loading the old bytecode while your
fix lands in a file nothing reads. Instead:

```sh
tools/compile-limbo.sh appl/cmd/foo.b   # reads the PATH constant, emits there
# or
cd appl/cmd; mk install                 # installs to the canonical path
```

If a fix "isn't taking effect" — same bug after recompile, diagnostic
prints not appearing — you almost certainly compiled to a path nothing
loads. `dis/` is a build product and is not tracked; rebuild it properly:

    for d in appl appl/mpeg appl/veltro tests; do (cd $d && mk install); done

Never hand-roll `limbo -o <path>`; use `tools/compile-limbo.sh` or
`mk install`. `tools/verify-dis-build.sh` (run by CI) checks the build
against `tools/dis-manifest.txt`.

**2. A changed `.m` interface stales every dependent `.dis`.** The Dis VM
rejects stale modules at load time with `link typecheck` errors — blank
tabs, commands that won't load, everything looks broken while the source is
fine. Rebuild the directories that compile against the changed interface
(the post-merge hook does this automatically after `git pull`).

## What to rebuild, and how

- **A `.b` file changed:** recompile just that file with
  `tools/compile-limbo.sh`, or `mk install` in its directory. Do not
  recursively `mk install` source trees for one change.
- **The emulator (C code) changed:** use the platform scripts —
  `./build-macos-sdl3.sh`, `./build-macos-headless.sh`,
  `./build-linux-amd64.sh` etc. — not ad-hoc mk invocations.
- **C libraries changed (`libinterp/`, `libsec/`, keyring, JIT):** the
  build scripts only *relink* emu against installed archives. First:
  ```sh
  cd libsec && mk nuke && mk install     # likewise libinterp
  ```
  then the platform script. A stale archive looks exactly like a JIT bug.

## mkfile rules

Plan 9 `mk`, not GNU make. No `&&` in recipes — use `;` or separate rules.
`mk install` copies output into the tracked runtime tree `dis/`;
`mk nuke` cleans. Never commit `.dis` from `appl/` or `tests/` (gitignored);
`dis/` changes — including `dis/tests/`, which is tracked like the rest of
the runtime tree — must come from `mk install`, not manual copies.

## Before opening a PR

Verify every modified file's pre-image matches master tip (rebase, then
`git diff master...HEAD` and check the base blobs). A branch cut from — or
contaminated by — another unmerged branch can carry someone else's change
through a textually clean merge, silently. Then run
`tools/verify-dis-build.sh` and fill the PR template's design-principles
checklist honestly.

## Running what you built

```sh
# Headless, drops to the Inferno ';' shell
./emu/MacOSX/o.emu -c1 -r$PWD sh -l

# Full GUI
./emu/MacOSX/o.emu -c1 -pheap=1024m -pmain=1024m -pimage=1024m \
    -r$PWD sh -l /lib/lucifer/boot.sh
```

`-c1` enables JIT, `-c0` forces the interpreter (useful for isolating JIT
bugs). Inferno's shell is rc-style: no `&&`/`||`, `for i in $x { ... }` —
see [docs/INFERNO-SHELL.md](../../../docs/INFERNO-SHELL.md).
