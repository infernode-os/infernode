# InferNode GPL / Copyleft License Audit

**Date:** 2026-05-29
**Scope:** Entire InferNode working tree (excluding `.git/`).
**Question:** InferNode bills itself as GPL-free. It was forked from Inferno,
which Vita Nuova relicensed to MIT in 2021. Does the InferNode tree, *as it
stands today*, actually contain any GPL- or LGPL-licensed code?

## TL;DR

**Yes. As it stands, InferNode is *not* GPL-free.** The tree was forked from a
**pre-2021 (dual-license era) Inferno snapshot**, not from the current
MIT-relicensed upstream. It still carries the old Inferno copyleft apparatus:

- The **entire `appl/` application tree is declared GPLv2-or-later** by
  `appl/NOTICE`. That is **964 `.b`/`.m` source files** — including *all of
  InferNode's own original work* (Veltro, Xenith, lucifer, llmsrv, lucibridge,
  the mail9p stack, etc.), because they live under `appl/`.
- Five library/runtime trees are declared **LGPL**: `module/`, `libinterp/`,
  `appl/lib/`, `include/`, `libkeyring/`.
- The full **GPL and LGPL license texts ship in `lib/legal/`** (`GPL`, `LGPL`),
  and the top-level `LICENCE`/`LICENSE`/`NOTICE` describe the old Vita Nuova
  "dual-licence" mixture (GPL + LGPL + Lucent Public + MIT-template).

**Mitigating structural fact:** *No source file carries an inline GPL/LGPL
header.* Every copyleft obligation is asserted purely through ~9
directory-level `NOTICE` files. Relicensing is therefore a paperwork operation
(swap the NOTICE/LICENCE files for the upstream MIT ones), **not** a
thousand-file header rewrite.

## How the tree is licensed today (per-directory NOTICE classification)

| Path / tree | License asserted by its NOTICE | Copyleft? |
|---|---|---|
| `appl/` (whole app tree) | **GPLv2 or later** (`appl/NOTICE`) | **YES — GPL** |
| `appl/lib/` (Limbo libraries) | **LGPL** (`appl/lib/NOTICE`, overrides appl GPL) | **YES — LGPL** |
| `module/` (Limbo `.m` interfaces) | **LGPL** | **YES — LGPL** |
| `libinterp/` (Dis VM + JIT) | **LGPL** | **YES — LGPL** |
| `include/` | **LGPL** | **YES — LGPL** |
| `libkeyring/` | **LGPL** | **YES — LGPL** |
| `emu/` (emulator kernel) | MIT / "free-for-all" | no |
| `lib9/`, `libdraw/`, `libmath/`, `libmemdraw/`, `libmemlayer/`, `locale/`, `appl/lib/ida/` | MIT / "free-for-all" | no |
| `libmp/`, `libsec/` | Lucent Public Licence | no (permissive) |
| `LICENCE`, `LICENSE`, `NOTICE` (top level) | Meta: describes the GPL/LGPL/Lucent/MIT mixture | references GPL |
| `lib/legal/{GPL,LGPL,NOTICE.gpl,NOTICE.lgpl}` | Full GPL & LGPL texts + templates | the license texts themselves |

The top-level `LICENCE` states this explicitly:

> "…the native and hosted kernels are 'free for all', as are most of the
> supporting libraries, but the virtual machine library and Limbo library
> modules are LGPL, **and the applications, including the Limbo compiler, are
> GPL**."

## Detailed findings

### 1. The `appl/` tree is GPL (the big one)
`appl/NOTICE` reads, verbatim:

> "This program is free software; you can redistribute it and/or modify it
> under the terms of the GNU General Public License as published by the Free
> Software Foundation; either version 2 of the License, or (at your option) any
> later version."

This NOTICE governs **all of `appl/`** "unless another copyright notice appears
in a given file or subdirectory." It therefore covers every application —
crucially **including InferNode's own additions** (Veltro, Xenith, lucifer,
etc.), since none of them carry an overriding permissive NOTICE.
**Count: 964 `.b`/`.m` files** under `appl/` (plus shell/data files).

### 2. LGPL trees
`module/` (173 `.m`), `libinterp/` (60 `.c`/`.h`), `appl/lib/` (207 `.b`/`.m`),
`include/` (22 files), `libkeyring/` (11 files) each carry an LGPL `NOTICE`.

### 3. No inline GPL/LGPL file headers anywhere
A full-tree scan for "General Public License" inside source files
(`.b .m .c .h .y .sh`) found **zero** matches. The only files containing GPL/LGPL
text are the directory `NOTICE` files and the license texts in `lib/legal/`.
This is the standard Inferno arrangement and is the single most important fact
for remediation cost.

### 4. The current upstream is MIT — the relicense exists and is usable
`inferno-os/inferno-os` (current `master`) ships a single top-level `NOTICE`:

> "The bulk of the tree is covered by the permissive MIT licence reproduced
> below."

with copyright "Lucent Technologies / Vita Nuova" and full MIT terms. Vita Nuova
held the rights and relicensed the whole distribution. The *same source files*
InferNode carries are available from upstream under MIT today — so the legal
right to relicense InferNode's inherited Inferno code to MIT already exists; the
fork simply never picked up the new NOTICE files.

## What this means for "GPL-free"

InferNode cannot currently claim to be GPL-free. The claim becomes true once the
inherited Inferno code is brought onto the upstream MIT terms. Because all
copyleft is asserted via directory NOTICEs (not file headers), the remediation
is bounded and mechanical.

### Suggested remediation (for discussion — not yet performed)
1. **Sync license files to current upstream MIT.** Replace the top-level
   `LICENCE`/`LICENSE`/`NOTICE` and the per-directory copyleft `NOTICE` files
   (`appl/NOTICE`, `appl/lib/NOTICE`, `module/NOTICE`, `libinterp/NOTICE`,
   `include/NOTICE`, `libkeyring/NOTICE`) with the upstream MIT `NOTICE`.
2. **Retire the copyleft texts in `lib/legal/`** (`GPL`, `LGPL`, `NOTICE.gpl`,
   `NOTICE.lgpl`) once nothing references them; keep `lucent`/`ffal` as needed.
3. **InferNode's own original `appl/` work:** confirm NERV Systems intends those
   files under MIT (they are first-party, so this is a self-relicense — just
   needs an explicit decision + the new NOTICE).
4. **Verify no genuinely third-party GPL code was added** post-fork (the scan
   found none; re-run on each release).
5. **Watch legacy per-file headers** such as the 1997 Lucent restrictive notice
   in `appl/examples/minitel/swkeyb.b` (superseded by the MIT relicense, but the
   text should be cleaned up when that code lands).

## Method / reproducibility
```sh
# All license/notice files
find . -path ./.git -prune -o -type f \
  \( -iname 'NOTICE*' -o -iname 'LICEN*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' \) -print

# Classify a NOTICE: grep for "Lesser General Public" / "GNU General Public"
#   / "Permission is hereby granted" / "Lucent Public"

# Inline headers (returns nothing -> no tainted source files):
grep -rlI "General Public License" . | grep -vE '\.git|lib/legal/|^\./(LICENCE|LICENSE|NOTICE)$' \
  | grep -E '\.(b|m|c|h|y)$'
```
