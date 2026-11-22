# Inferno Kernel Formal Verification

This directory contains formal specifications and verification scripts for the Inferno kernel's namespace isolation mechanism. Read [What this does and does not establish](#what-this-does-and-does-not-establish) before citing any number from it.

## Overview

The Inferno kernel provides **per-process namespaces** that isolate each process's view of the file system. This effort model-checks a specification of the namespace copy and bounded-checks parts of the C. The properties it targets are:

1. **Namespace Isolation**: After `pgrpcpy()` copies a namespace, modifications to the child namespace do NOT affect the parent, and vice versa.
2. **Reference Counting Correctness**: Reference counts are always non-negative and objects are properly freed.
3. **No Use-After-Free**: Freed resources are not accessed.
4. **Locking Protocol Safety**: Deadlock freedom and correct lock ordering.
5. **Race Condition Analysis**: Identifies potential data races in `Sys_pctl`, `kchdir`, and `namec`.
6. **Export Boundary Safety**: `exportfs` root boundary cannot be bypassed.
7. **Implementation Fidelity**: CBMC verifies actual C code, not models.

## Verification Status

| Phase | Tool | Focus | Status |
|-------|------|-------|--------|
| 1 | TLA+ | Abstract namespace isolation (history-variable invariants) | Small: exhaustive, 11 invariants hold (429,048,790 distinct states, 7,103,910,408 generated, depth 30, about 5 h on 4 cores (checkpointed and resumed), 8 GB heap + 19 GB disk state; a copy and a post-copy mount confirmed reachable first). Medium: **incomplete** (3.17B distinct states, BFS depth 13, 2.56B queued, 0 violations). The previous small configuration never reached a copy and its result was vacuous; see Known Limitations |
| 1 | SPIN | Namespace isolation with non-atomic operations | Pass (5/5). The isolation assertions cannot fail in these models (mount tables are disjoint by construction); they check the lock protocol of the model |
| 2 | SPIN | Multi-lock locking protocol (per-pgrp, per-mhead) | Deadlock-free on 8 fixed scenarios of 3 processes. The lock-ordering assertion is structural and cannot fail |
| 3 | CBMC | C code: pgrpcpy copy (full mode), model harnesses (quick) | Pass. Full: 4 harnesses on a copy of `pgrpcpy`, each one concrete mount, pointer- and bounds-checked, `--unwinding-assertions`. Quick (CI): 3 harnesses on re-typed snippets, not kernel code, plus 16 PQC checks |
| 4 | SPIN | Race conditions (pctl/kchdir/namec) | 3 real races confirmed and fixed (`kchdir`/`namec` in 89db5178, the `Sys_pctl` swap in INFR-373; the model is the fixed code, `-DUNFIXED` the code before). The LTL checks run in `verify-all.sh full` only; CI runs `quick`, which compiles the claims out |
| 5 | SPIN | exportfs root boundary | Models only the `..`-at-root check in `Exwalk`, as a definition. A bind of an ancestor inside the export, the escape that matters, is not expressible in it |
| CI | GH Actions | SPIN quick + CBMC quick on push | Active (no TLA+, no SPIN LTL) |

See [results/](results) for detailed verification reports.

## Files

```
formal-verification/
├── README.md                                  # This file
├── METHODOLOGY.md                             # Methodology and threats to validity
├── REMAINING-RUNS.md                          # Verification runs not yet done
├── run-verification.sh                        # TLC model checker script
├── tla+/
│   ├── Namespace.tla                         # Core spec (history vars, namec, kchdir)
│   ├── NamespaceProperties.tla               # Non-trivial isolation invariants
│   ├── IsolationProof.tla                    # Isolation theorem (non-tautological)
│   ├── MC_Namespace.tla                      # Model checking configuration
│   └── MC_Namespace.cfg                      # TLC configuration (medium defaults)
├── spin/
│   ├── namespace_isolation.pml               # Non-atomic isolation model
│   ├── namespace_isolation_extended.pml      # Extended model (nested fork)
│   ├── namespace_locks.pml                   # Multi-lock protocol model
│   ├── namespace_races.pml                   # Race conditions (pctl/kchdir/namec)
│   ├── exportfs_boundary.pml                 # Export root escape verification
│   ├── verify-locks.sh                       # Legacy locking verification
│   └── verify-all.sh                         # Run all SPIN models
├── cbmc/
│   ├── stubs.h                               # CBMC stubs for kernel types
│   ├── os.h, libsec.h, crypto_stubs.h        # Stub headers for the crypto harnesses
│   ├── harness_pgrpcpy.c                     # pgrpcpy isolation (real code)
│   ├── harness_pgrpcpy_error.c               # pgrpcpy error path safety
│   ├── harness_mnthash_bounds.c              # Array bounds harness
│   ├── harness_overflow_simple.c             # Integer overflow harness
│   ├── harness_integer_overflow.c            # Integer overflow (not run by verify-all.sh)
│   ├── harness_refcount.c                    # Reference counting harness
│   ├── harness_mlkem_ct.c                    # ML-KEM constant-time helpers, FO transform
│   ├── harness_mldsa_ct.c                    # ML-DSA reduction and polynomial arithmetic
│   ├── harness_mlkem_ntt.c                   # ML-KEM encode/decode, polynomial identities
│   └── verify-all.sh                         # CBMC verification script
├── docs/
│   └── PHASE2-LOCKING.md                     # Phase 2 locking model design
└── results/
    ├── VERIFICATION-RESULTS.md               # Phase 1 results
    ├── PHASE2-LOCKING-RESULTS.md             # Phase 2 results
    ├── PHASE3-CBMC-RESULTS.md                # Phase 3 results
    └── PHASE4-VERIFICATION-RUN.md            # Phase 4 run (races)
```

The original work plan and the race-condition list are in
[`docs/history/formal-verification/`](../docs/history/formal-verification/)
(`PLAN-namespace-security-verification.md`, `TODO-RACE-CONDITIONS.md`).

## Quick Start

### Run All SPIN Verification

```bash
# Install SPIN
apt-get install -y spin   # Linux
brew install spin         # macOS

# Quick verification (for CI)
cd formal-verification/spin
./verify-all.sh quick

# Full verification with LTL properties
./verify-all.sh full
```

### Run All CBMC Verification

```bash
# Install CBMC
apt-get install -y cbmc   # Linux
brew install cbmc         # macOS

cd formal-verification/cbmc
./verify-all.sh
```

### Run TLA+ Verification

```bash
# Requires Java 11+ and tla2tools.jar
cd formal-verification
./run-verification.sh small    # ~minutes
./run-verification.sh medium   # ~hours
./run-verification.sh large    # ~days
```

## Key Properties Verified

### Namespace Isolation (Non-Trivial)

The core isolation property uses **history variables** to track post-copy mutations:

```
NamespaceIsolation ==
  ∀ pg_child ∈ PgrpId :
    let pg_parent = pgrp_parent[pg_child] in
    (active(pg_child) ∧ active(pg_parent)) ⟹
      ∀ path, cid :
        (⟨path, cid⟩ ∈ post_copy_mounts[pg_parent] ∧
         cid ∈ mount_table[pg_parent][path]) ⟹
          (cid ∈ mount_table[pg_child][path] ⟹
            ⟨path, cid⟩ ∈ post_copy_mounts[pg_child])
```

This says: if a channel was mounted in the parent AFTER the copy, it does NOT appear in the child's mount table UNLESS the child independently mounted it. This is NOT tautologically true — it depends on the correctness of `Mount`, `PgrpCopy`, and the separation of mount table data structures.

### Additional Properties

| Property | Description | Tool |
|----------|-------------|------|
| `NamespaceIsolation` | Post-copy mounts don't leak across namespaces | TLA+/SPIN |
| `UnilateralMountNonPropagation` | Unilateral mount never appears in other namespace | TLA+ |
| `CopyFidelity` | Copy produces exact duplicate of source | TLA+/CBMC |
| `PostCopyMountsSound` | History tracking is accurate | TLA+ |
| `MountLocalityProperty` | Each step modifies at most one pgrp | TLA+ (defined; not checked by run-verification.sh, which passes no PROPERTY) |
| `RefCountNonNegative` | Refcounts ≥ 0 | TLA+/CBMC |
| `NoUseAfterFree` | Freed pgrps not assigned to a process (channels not covered) | TLA+/SPIN |
| `DeadlockFreedom` | No deadlocks in concurrent ns operations | SPIN |
| `LockOrdering` | pg->ns always acquired before m->lock | SPIN (assertion placed after the flag it tests is set; cannot fail) |
| `ArrayBounds` | MOUNTH macro always produces valid index | CBMC |
| `IntegerOverflow` | fd allocation arithmetic is safe | CBMC |
| `ExportBoundary` | walk("..") at the export root stays there | SPIN (the model defines the check, then asserts it) |

## Correspondence to C Code

| Operation | C Function | Source File | Verified By |
|-----------|------------|-------------|-------------|
| `NewPgrp` | `newpgrp()` | `emu/port/pgrp.c:9` | TLA+ (defined, not in `Next`; CreateProcess/Fork* allocate instead), CBMC |
| `PgrpCopy` / `ForkWithForkNS` | `pgrpcpy()` | `emu/port/pgrp.c:75` | TLA+, SPIN, CBMC |
| `ClosePgrp` | `closepgrp()` | `emu/port/pgrp.c:23` | TLA+ (defined, not in `Next`; TerminateProcess covers it), SPIN |
| `Mount` | `cmount()` | `emu/port/chan.c:506` | TLA+, SPIN |
| `Unmount` | `cunmount()` | `emu/port/chan.c:622` | TLA+, SPIN |
| `NameResolve` | `namec()` | `emu/port/chan.c:1221` | TLA+ (defined, not in `Next`), SPIN (race) |
| `ChangeDir` | `kchdir()` | `emu/port/sysfile.c:143` | TLA+, SPIN (race) |
| `ForkWithNewNS` | `Sys_pctl(NEWNS)` | `emu/port/inferno.c:870` | TLA+, SPIN (race) |
| `ForkWithForkNS` | `Sys_pctl(FORKNS)` | `emu/port/inferno.c:891` | TLA+, SPIN (race) |
| `findmount` | `findmount()` | `emu/port/chan.c:731` | SPIN |
| `walk` | `walk()` | `emu/port/chan.c:856` | SPIN (export; `..` at root only) |

## Trusted Computing Base (TCB)

The verification trusts:
1. Hardware executes correctly
2. C compiler is correct (gcc)
3. Host OS provides correct threading primitives
4. Memory allocator returns valid memory or nil
5. SPIN, CBMC, and TLC tools are correct
6. The stubs in `cbmc/stubs.h` faithfully model kernel primitives

## Known Limitations

1. **Bounded verification**: TLA+/TLC and CBMC explore finite state spaces. For unbounded proofs, interactive theorem proving (Isabelle/HOL) would be needed.
2. **Abstraction gap**: SPIN models abstract lock semantics; the real RWlock implementation is not verified at the assembly level.
3. **Race condition findings**: The `namespace_races.pml` model may report races that are benign under Inferno's cooperative threading model (one Dis thread at a time), but are real at the C/emu level with multiple host threads. All three found are fixed: `kchdir` and `namec` in 89db5178 (both now take the `pg->ns` lock), and the `Sys_pctl` NEWNS/FORKNS swap in INFR-373, which holds the VM lock for the pointer store alone. 89db5178's VM-lock re-acquire around the whole NEWNS/FORKNS branch was removed in fa93471d because the copy inside it waits on Limbo file servers and deadlocked; see `docs/postmortems/2026-05-17-newns-vm-lock-deadlock.md`.
4. **`nodevs` exception consistency**: Verified via manual audit — both `namec()` and `devindir.c` use identical exception string `"|esDa"`.
5. **Model expressiveness**: In TLA+ `mount_table` is a function from pgrp id, and in Promela the tables are disjoint bytes. Shared `Mhead`/`Mount` structure, the way `pgrpcpy` could actually fail to isolate, has no representation. The isolation invariants therefore check the specification's bookkeeping against the specification's own `Mount`; they cannot fail on the C bug they describe. Only the CBMC `pgrpcpy` harness sees pointers, and a mutation that makes the copy share the parent's `Mhead` is caught there.
6. **Vacuity**: every pgrp costs two channels (slash, dot), and a copy is enabled only while two channel ids remain. The small configuration used until 2026-11 (2 processes, 3 pgrps, 3 channels) had `MaxChannels=3`, so after the first process no copy was ever enabled, `pgrp_parent` was 0 in all 19.3M states, and all six isolation invariants held vacuously. The small configuration is now 2 processes, 2 pgrps, 4 channels, 1 path: one copy per behaviour, after which the four channels are the two pgrps' slash and dot, so post-copy mounts are of those (the spec treats channels uniformly, so the invariants are exercised the same way). Leaving a fifth channel to allocate after the copy, or a second path, did not fit a 16 GB host: 60M+ distinct states at depth 12 with the queue still growing. The channel refcount bound is now an explicit constant (`MaxChanRef`, 2 at the small level): `IncRefChannel`/`DecRefChannel` are free actions unrelated to the isolation invariants, and under the old implicit bound of `MaxProcesses + MaxPgrps + MaxChannels` even the 4-channel configuration passed 250M distinct states without finishing. `run-verification.sh` now refuses to run unless TLC can reach a copy and a post-copy mount (`CopyNeverHappened`, `LivePostCopyMountNeverHappened` in `MC_Namespace.tla` must be violated). Under the medium constants a copy is reachable but consumes the last two channels, so post-copy mounts can only mount a slash or dot channel.
7. **CBMC harness shape**: `harness_basic_isolation` and `harness_modification_independence` have no nondeterministic input; they are one concrete execution of one mount in one bucket, run with pointer and bounds instrumentation. `error()` and `nexterror()` are no-ops in `stubs.h` and malloc is never allowed to fail, so the real allocation-failure path of `pgrpcpy` is not exercised; `harness_pgrpcpy_error.c` checks a rewritten `pgrpcpy_safe`, not the kernel function. The quick-mode harnesses verify re-typed snippets and a locally written `incref_checked`, not `emu/port/lock.c`.
8. **Crypto harnesses**: CBMC checks functional properties. Nothing here establishes constant-time execution; that is a compiler and ISA property these runs do not address.
9. **Medium run**: incomplete breadth-first search (depth 12 done, 13 in progress, 2.56B states queued and growing). A state count from an unfinished run is not a verification result for that configuration.

## What this does and does not establish

Established, and reproducible from this directory:

- A TLA+ specification of Inferno's namespace copy, with history variables,
  whose 11 invariants hold in every reachable state of the small
  configuration (exhaustive), with a guard that the copy is actually reached.
- Bounded, pointer-checked execution of a copy of `pgrpcpy()`,
  `newmount()`, `pgrpinsert()`, `newpgrp()` on one mount at `MNTHASH=32`,
  showing the child gets its own `Mhead`, shares and increfs the channel,
  and clones slash and dot. A mutation that aliases the parent's `Mhead`
  fails the harness.
- SPIN confirmation of three use-after-free races in the pre-fix code
  (`-DUNFIXED`) and their absence in a model of the fixed code; both fixes
  are in the tree and `tests/pgrp_race_test.b` exercises them on the emulator.
- Functional properties of the ML-KEM polynomial code, linked from the real
  `libsec` sources, and of inlined copies of the reduction routines.

Not established:

- That the C implementation isolates namespaces. The abstract models cannot
  express the failure, and the CBMC harness covers one concrete shape.
- Anything about the medium or large configurations (incomplete / not run).
- Lock ordering (the assertion cannot fail), exportfs escape in general
  (ancestor binds are not modelled), constant-time execution, channel
  use-after-free, error paths in `pgrpcpy`, or any of `restrictdir`,
  `bind` semantics, union mounts, the `nodevs` device gate, tools9p, the
  Dis VM or the JIT.

Cite it as: a model-checked specification of the namespace copy, a
bounded unit-level check of `pgrpcpy`'s deep copy, and SPIN confirmation of
three fixed races. Not as a proof of isolation.

## CI/CD Integration

Formal verification runs automatically on push/PR via `.github/workflows/formal-verification.yml`:
- SPIN: Quick mode (assertions and deadlock) on every push. The race model's
  LTL properties and the `-DUNFIXED` expected-violation checks run only in
  `./verify-all.sh full`, which CI does not run.
- CBMC: Quick mode (model harnesses and PQC crypto harnesses) on every push.
  The `pgrpcpy` harnesses run only in `./verify-all.sh full`.
- TLA+: not in CI; `./run-verification.sh small` is run by hand.

## References

1. Klein et al., "seL4: Formal Verification of an OS Kernel", SOSP 2009
2. Nelson et al., "Hyperkernel: Push-Button Verification of an OS Kernel", SOSP 2017
3. Ferraiuolo et al., "Komodo: Using Verification to Disentangle Secure-Enclave Hardware from Software", SOSP 2017
4. Lamport, "Specifying Systems: The TLA+ Language and Tools for Hardware and Software Engineers"
5. Holzmann, "The SPIN Model Checker: Primer and Reference Manual"
6. Clarke et al., "Bounded Model Checking Using Satisfiability Solving"

---

*Last updated: 2026-11-06 (review: small-config vacuity, claims narrowed)*
