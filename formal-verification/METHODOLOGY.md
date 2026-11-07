# Formal Verification of Namespace Isolation in the Inferno Kernel

## Abstract

We present a multi-tool model-checking study of namespace isolation in the
Inferno operating system kernel. Using TLA+/TLC for an abstract
specification (429 million distinct states, exhaustive, small
configuration), SPIN for concurrent protocol models (130K states), and CBMC
for bounded checking of a copy of the `pgrpcpy()` C code, we check that the
specification's per-process mount tables stay independent after a copy, and
that the C copy allocates its own mount heads. The TLA+ invariants are
stated with history variables so that they are not syntactic tautologies;
they remain properties of the specification, whose state cannot express the
shared-structure bug the C could have. The SPIN race model confirms three
use-after-free races in the pre-fix emulator code, all since fixed. The
SPIN and CBMC suites run in minutes on commodity hardware; the TLC small
run takes about five hours on four cores. Section 10 lists the
limits; a 2026-11 review found the earlier small configuration vacuous (no
copy was reachable) and the medium run incomplete, and this document was
revised accordingly.

---

## 1. Introduction

### 1.1 Background

Inferno is a distributed operating system descended from Plan 9 from Bell
Labs, designed by the same team (Pike, Presotto, Dorward, Lucent
Technologies). Its defining feature is the *namespace*: each process has a
private, customizable view of the file system hierarchy. All resources —
files, devices, network connections, processes — appear as files in a
per-process namespace. Security boundaries are established by forking
namespaces: a child process can receive a copy of its parent's namespace
(`FORKNS`) or an empty one (`NEWNS`), after which modifications to either
side are independent.

The correctness of this isolation is a foundational security property. If
mounts in a parent namespace could "leak" to a child (or vice versa), the
entire resource access model would be compromised.

### 1.2 Contributions

1. **Multi-tool verification** at three abstraction levels: abstract
   specification (TLA+), concurrent protocol (SPIN), and C implementation
   (CBMC).

2. **Non-tautological isolation invariants** stated via history variables
   and checked over all reachable states of the specification. They are
   properties of the model: the model's mount tables are disjoint by
   construction, so they check the specification's bookkeeping, not the C.

3. **Confirmation of three real race conditions** in the kernel's host
   threading layer, suspected from reading the C and confirmed by model
   checking with LTL counterexamples (`-DUNFIXED`); all three are fixed.

4. **Reproducible pipeline**: SPIN quick and CBMC quick in CI; SPIN full
   and CBMC full by hand in minutes; TLC small by hand in about five hours
   on 4 cores with 8 GB of heap and 19 GB of disk.

### 1.3 Scope

The verification targets the Inferno kernel's namespace subsystem as
implemented in the `emu` (hosted) variant. The primary source files are:

| File | Lines | Role |
|------|-------|------|
| `emu/port/pgrp.c` | 264 | Process group / namespace copy (`pgrpcpy`) |
| `emu/port/chan.c` | 1,418 | Channel operations, mount/unmount (`cmount`, `namec`) |
| `emu/port/sysfile.c` | 1,089 | System call implementations (`kchdir`) |
| `emu/port/inferno.c` | 1,060 | Process control (`Sys_pctl` with `FORKNS`/`NEWNS`) |

Total kernel source under verification: **3,831 lines of C**.

---

## 2. System Under Verification

### 2.1 Data Structures

The central data structure is the **Pgrp** (process group), defined in
`emu/port/dat.h:284-296` (excerpt; the struct also has `nsh` and `pin`):

```c
struct Pgrp {
    Ref     r;                  // Reference count
    ulong   pgrpid;             // Unique process group ID
    RWlock  ns;                 // Namespace read-write lock
    Mhead*  mnthash[MNTHASH];   // Mount hash table (MNTHASH = 32)
    int     progmode;           // Default file creation mode
    Chan*   dot;                // Current working directory
    Chan*   slash;              // Root directory
    int     nodevs;             // Device restriction flag
};
```

Each `Pgrp` contains a hash table of **Mhead** (mount head) entries. Each
`Mhead` contains a linked list of **Mount** entries that map paths to
**Chan** (channel) objects. Channels are reference-counted file handles.

### 2.2 Critical Operations

**`pgrpcpy(to, from)`** (`pgrp.c:75-130`): The core namespace copy
operation. Creates a deep copy of the mount table from `from` to `to`.

- Acquires `wlock(&from->ns)` for the duration (57 lines)
- Iterates over all MNTHASH=32 hash buckets
- For each `Mhead`, acquires `rlock(&f->lock)`, allocates new `Mhead` and
  `Mount` structures, increments channel reference counts
- Assigns mount IDs in the same sequence as the parent
- Clones `slash` and `dot` channels via `cclone()`
- Copies `nodevs` and `progmode` flags

**`cmount(new, old, flag, spec)`** (`chan.c:506-619`): Adds a mount to the
current process's namespace.

- Lock sequence: `wlock(&pg->ns)` → `wlock(&m->lock)` → `wunlock(&pg->ns)`
- The early release of `pg->ns` while holding `m->lock` is a critical
  optimization that allows concurrent operations on different mount points

**`Sys_pctl` with `FORKNS`** (`inferno.c:891-898`): Replaces a process's
namespace with a fresh copy.

```c
np.np = newpgrp();
pgrpcpy(np.np, o->pgrp);   // Copy namespace
opg = o->pgrp;
o->pgrp = np.np;            // Swap pointer (no lock!)
closepgrp(opg);
```

**`namec(aname, ...)`** (`chan.c:1221`): Name resolution. As verified, it
read `pg->slash` or `pg->dot` without any lock (line numbers as of the
finding). Since 89db5178 both reads take `rlock(&pg->ns)`
(`chan.c:1259-1262`, `1296-1299`):

```c
case '/':
    c = up->env->pgrp->slash;   // line 1022 — NO LOCK
    incref(&c->r);
case default:
    c = up->env->pgrp->dot;     // line 1057 — NO LOCK
    incref(&c->r);
```

**`kchdir(path)`** (`sysfile.c:143-160`): Changes working directory.
As verified, it performed `cclose(pg->dot); pg->dot = c;` without any lock.
Since 89db5178 it swaps `dot` under `wlock(&pg->ns)` and closes the old
channel afterwards (`sysfile.c:153-157`).

### 2.3 Locking Protocol

The namespace uses a two-level locking scheme:

1. **`pg->ns`** (RWlock): Protects the mount hash table structure
2. **`mh->lock`** (RWlock): Protects individual mount lists

The invariant is: `pg->ns` is always acquired before `mh->lock`. The
`cmount` function's optimization releases `pg->ns` while holding `mh->lock`,
which is safe because `mh->lock` only protects the mount list within a
single mount head.

---

## 3. Verification Approach

We employ three complementary verification tools at different abstraction
levels, following the principle that diverse verification techniques provide
stronger confidence than any single approach.

### 3.1 Tool Selection Rationale

| Tool | Level | Strength | Limitation |
|------|-------|----------|------------|
| TLA+/TLC | Abstract specification | Exhaustive state exploration, history variables | Does not verify C code directly |
| SPIN | Concurrent protocols | LTL model checking, race detection | Manual abstraction from C |
| CBMC | C implementation | Verifies actual source code | Bounded, sequential |

### 3.2 Verification Pipeline

```
┌─────────────┐    ┌──────────────┐    ┌──────────────┐
│   TLA+/TLC  │    │     SPIN     │    │     CBMC     │
│  Namespace  │    │   Promela    │    │  C Harnesses │
│  Isolation  │    │   Protocols  │    │  on pgrp.c   │
│  Theorem    │    │  + Races     │    │  + chan.c     │
│  (abstract) │    │ (concurrent) │    │ (impl-level) │
└──────┬──────┘    └──────┬───────┘    └──────┬───────┘
       │                  │                    │
       ▼                  ▼                    ▼
    369.4M            131,333              113+ props
    states             states              checked
```

---

## 4. TLA+ Specification and Verification

### 4.1 Specification Structure

The TLA+ specification comprises four modules totaling 1,199 lines:

| Module | Lines | Purpose |
|--------|-------|---------|
| `Namespace.tla` | 599 | State variables, operations, next-state relation |
| `NamespaceProperties.tla` | 261 | Safety invariants, isolation properties |
| `IsolationProof.tla` | 230 | Isolation theorem, inductive invariant, proof sketch |
| `MC_Namespace.tla` | 108 | Model checking configuration |

### 4.2 State Variables

The specification models 15 state variables organized into three categories:

**Implementation state** (10 variables):
- `processes`: Set of active process IDs
- `process_pgrp`: Process-to-pgrp mapping
- `pgrp_exists`, `pgrp_refcount`: Pgrp lifecycle
- `mount_table`: `PgrpId → [PathId → SUBSET ChannelId]`
- `pgrp_slash`, `pgrp_dot`, `pgrp_nodevs`: Per-pgrp state
- `chan_exists`, `chan_refcount`: Channel lifecycle
- `next_pgrp_id`, `next_chan_id`: Allocation counters

**History variables** (3 variables, for verification only):
- `copy_snapshot[child]`: Records parent's mount table at copy time
- `pgrp_parent[child]`: Records which pgrp was copied from
- `post_copy_mounts[pg]`: Set of `<<path, cid>>` pairs mounted after creation

### 4.3 Operations Modeled

The specification covers 12 operations corresponding to kernel functions:

| Operation | Kernel Function | Key Behavior |
|-----------|----------------|--------------|
| `CreateProcess` | `kproc()` | New process with fresh pgrp |
| `ForkWithForkNS` | `Sys_pctl(FORKNS)` | Deep-copy namespace |
| `ForkWithNewNS` | `Sys_pctl(NEWNS)` | Empty namespace |
| `ForkWithSharedNS` | `rfork()` | Shared pgrp (incref) |
| `TerminateProcess` | `pexit()` | Decref pgrp, cleanup if zero |
| `Mount` | `cmount()` | Add channel to mount table |
| `Unmount` | `cunmount()` | Remove channel from mount table |
| `ChangeDir` | `kchdir()` | Update `pg->dot` |
| `AllocChannel` | `newchan()` | Allocate channel object |
| `IncRefChannel` | `incref(&c->r)` | Increment channel refcount |
| `DecRefChannel` | `cclose()` | Decrement channel refcount |
| `SetNoDevs` | `Sys_pctl(NODEVS)` | Restrict device access |

### 4.4 The Namespace Isolation Theorem

The central result is the **Namespace Isolation Theorem**
(`IsolationProof.tla`), stated as:

> For any parent-child pgrp pair created by `PgrpCopy`/`ForkWithForkNS`:
> if channel `cid` appears at path `path` in **both** the parent's and
> child's mount tables, then **either** (a) `cid` was present at copy
> time (in `copy_snapshot[child][path]`), **or** (b) both parent and
> child independently mounted `cid` at `path` (both recorded in their
> respective `post_copy_mounts`).

Formally:

```tla
NamespaceIsolationTheorem ==
    ∀ pg_child ∈ PgrpId :
        LET pg_parent == pgrp_parent[pg_child] IN
        (PgrpInUse(pg_child) ∧ pg_parent ≠ 0 ∧ PgrpInUse(pg_parent)) ⇒
            ∀ path ∈ PathId, cid ∈ ChannelId :
                (cid ∈ mount_table[pg_parent][path] ∧
                 cid ∈ mount_table[pg_child][path]) ⇒
                    (cid ∈ copy_snapshot[pg_child][path] ∨
                     (⟨path, cid⟩ ∈ post_copy_mounts[pg_parent] ∧
                      ⟨path, cid⟩ ∈ post_copy_mounts[pg_child]))
```

**What it can and cannot catch**: the property is not a syntactic
tautology. It would be violated if the specification's `Mount` modified more
than one pgrp's table, or if the history variables drifted from the state.
It cannot be violated by "pointer sharing instead of deep copy": the
specification has no pointers. `mount_table` is a function from pgrp id, so
two pgrps' tables are distinct values whatever `PgrpCopy` does. The C
failure this is meant to evoke, `pgrpcpy` leaving `to` and `from` sharing an
`Mhead` or `Mount`, is outside the model's vocabulary and is addressed only
by the CBMC harness (§6).

### 4.5 Supporting Invariants

Ten additional invariants support and strengthen the theorem:

1. **TypeOK**: All variables have correct types
2. **SafetyInvariant**: Combined type + refcount + no-UAF + bounds
3. **RefCountNonNegative**: `∀ pg: pgrp_refcount[pg] ≥ 0`
4. **NoUseAfterFree**: Freed pgrps not assigned to processes
5. **MountTableBounded**: Mount tables contain valid channel IDs
6. **NamespaceIsolation**: Post-copy mounts don't leak (accounting for
   pre-fork parent mounts via snapshot)
7. **UnilateralMountNonPropagation**: One-sided mount never appears in
   the other namespace
8. **CopyFidelity**: Immediately after copy, child's table equals snapshot
9. **PostCopyMountsSound**: Every mount is from snapshot or tracked
10. **NoIsolationViolation**: Negation of the violation predicate

### 4.6 Proof Sketch

The theorem is proved by induction over all possible state transitions:

- **Base case (Init)**: No pgrps exist; universal quantifier vacuously true.
- **Mount(pgid, path, cid)**: Only modifies `mount_table[pgid]` and
  `post_copy_mounts[pgid]`. If `cid` now appears in both parent and child,
  the induction hypothesis for the unchanged side applies.
- **Unmount**: Only removes entries; can only make the antecedent false.
- **PgrpCopy/ForkWithForkNS**: Sets `mount_table[child] = mount_table[parent]`
  and `copy_snapshot[child] = mount_table[parent]`, so any shared mount
  satisfies `cid ∈ copy_snapshot[child][path]`.
- **ForkWithNewNS**: Child has empty mount table; quantifier vacuously true.
- **Other operations**: Do not modify mount tables.

### 4.7 TLC Model Checking Results

| Configuration | MaxProc | MaxPgrp | MaxChan | MaxPath | MaxChanRef | States Gen. | Distinct | Depth | Time | Heap |
|---------------|---------|---------|---------|---------|------------|-------------|----------|-------|------|------|
| Small (2026-11, current) | 2 | 2 | 4 | 1 | 2 | 7,103,910,408 | 429,048,790 | 30 | about 5 h on 4 cores (checkpointed and resumed) | 8 GB heap + 19 GB disk state |
| Small (2026-03, **vacuous**) | 2 | 3 | 3 | 2 | 8 (implicit) | 369,414,154 | 19,307,332 | 39 | 7m 57s | 4 GB |
| Medium (**incomplete**) | 3 | 4 | 4 | 3 | 11 (implicit) | 26,515,255,632 | 3,168,821,335 | 12 (13 in progress) | 10h 50m | 50 GB + 341 GB disk |
| Large | 4 | 5 | 5 | 3 | 3 | not run | | | | |

In the current small configuration all 11 invariants hold in every reachable
state, the search is complete (0 states left on queue), and the vacuity
guard in `run-verification.sh` confirmed first that a copy, and a post-copy
mount while parent and child are both live, are reachable (their traces
are `results/tlc_vacuity_small_*.txt`). The run was done in two parts on a
16 GB host: two hours, a TLC checkpoint, then four hours resumed from it
(`RECOVER=`), so `results/tlc_output_small.txt` is the resumed part.
`MaxChanRef`
is new: the channel refcount bound used to be the implicit
`MaxProcesses + MaxPgrps + MaxChannels`, and because `IncRefChannel` and
`DecRefChannel` are free actions, every refcount value of every channel
multiplied the state space without bearing on isolation. Under the implicit
bound this same 2/2/4/1 configuration passed 250M distinct states at depth
16 (21 GB of state) on a 16 GB host without finishing, and the 2026-03
medium run on a 64 GB host did not finish either. The bound is now a
constant the configuration states.

The 2026-03 small configuration had `MaxChannels=3`. Each pgrp costs two
channels (slash and dot) and `ForkWithForkNS`/`ForkWithNewNS` are enabled
only while two channel ids remain, so after `CreateProcess` no copy could
ever fire. TLC over that configuration with the invariant
`\A pg : pgrp_parent[pg] = 0` completes with no violation over the same
19,307,332 states: every isolation invariant was vacuous in the run that
earlier versions of this document called an exhaustive proof.

The medium run is an incomplete breadth-first search: depth 12 finished,
depth 13 in progress, 2.56 billion states queued and growing when it was
stopped for disk. Under its constants a copy is reachable (TLC finds one at
depth 5) but it consumes the last two channels, so every post-copy mount is
of a slash or dot channel. Its state count is not a verification result for
the medium configuration. See `REMAINING-RUNS.md`.

---

## 5. SPIN Verification

### 5.1 Models

Five Promela models totaling 1,440 lines verify concurrent protocol
properties:

| Model | Lines | Procs | States | Property |
|-------|-------|-------|--------|----------|
| `namespace_isolation.pml` | 339 | 3 | 82,628 | Post-copy mount isolation |
| `namespace_isolation_extended.pml` | 211 | 3 | 5,724 | Nested fork (parent→child→grandchild) |
| `namespace_locks.pml` | 343 | 3 | 39,744 | Lock ordering (`pg->ns` before `mh->lock`) |
| `namespace_races.pml` | 475 | 4 | 2,013 | Use-after-free race detection |
| `exportfs_boundary.pml` | 177 | 1 | 106 | Walk("..") cannot escape exported root |

### 5.2 Modeling Decisions

**Lock atomicity**: OS mutexes are indivisible test-and-set operations. In
Promela, the guard (test) and flag set (acquire) must be wrapped in
`atomic{}` to prevent TOCTOU races that are model artifacts:

```promela
inline ns_wlock(pg) {
    atomic { (ns_writer[pg] == 0 && ns_readers[pg] == 0);
             ns_writer[pg] = 1; }
}
```

**Snapshot timing**: The copy's snapshot is taken from the child's mount
table *after* the copy completes (not from the parent *before*), because
`pgrpcpy` holds `wlock(&from->ns)` which serializes with concurrent
mounters.

**Lock ordering**: stated as inline assertions rather than LTL (SPIN's
parser cannot handle struct array indexing in LTL formulas):

```promela
/* Assert ns lock is held before acquiring mhead lock */
assert(proc[id].holds_ns_write[pg] || proc[id].holds_ns_read[pg]);
wlock_mh(pg, mh);
```

Each such assertion immediately follows the statement that sets the flag it
tests, so it cannot fail; the model establishes deadlock freedom on its
eight scenarios, not lock ordering. The real RWlock (`emu/port/lock.c`: two
QLocks and a reader count, writers preferred through `l->x`) is not what the
model implements.

**Isolation assertions**: `mount_table[MT_IDX(pg, path)]` are distinct
bytes and Promela assignments are atomic, so the cross-namespace assertions
in the two isolation models cannot fail either; what those models exercise
is the lock protocol between `pgrp_copy` and concurrent mounters.

### 5.3 Race Conditions Found

The `namespace_races.pml` model formally confirmed three use-after-free
races in the code as it was:

1. **kchdir dot race** (`sysfile.c`): `cclose(pg->dot)` followed
   by `pg->dot = c` without lock. Concurrent `namec()` reads freed pointer.
2. **FORKNS pgrp swap** (`inferno.c`, `Sys_pctl`): `o->pgrp = np.np` and
   `closepgrp` of the old group with the VM released, while devprog reads
   another Prog's `o->pgrp` holding the VM.
3. **namec slash/dot read** (`chan.c`): Unprotected reads of
   `pg->slash`/`pg->dot` concurrent with `kchdir`/`FORKNS`.

**Status: fixed** (89db5178 for 1 and 3; INFR-373 for 2). The model is
now the fixed code, in which the three LTL properties hold and no end
state deadlocks; `-DUNFIXED` models the code before, in which SPIN
still finds the dot and pgrp use-after-frees, so the model can see
them. `verify-all.sh full` checks both; CI runs `quick`, which compiles
the LTL claims out (`-DNOCLAIM`), so a green CI says nothing about the
races. In the fixed model the reader holds the VM lock for its whole
read, which matches devprog but not a Prog's own `namec`; the latter is
safe because only the owning Prog swaps its own `o->pgrp`, an argument the
model does not encode.

Exercising the fix on a running emu (`tests/pgrp_race_test.b`: one Prog
swapping its name space, fd group and dot while others read its
`/prog/n/ns`, `fd` and `status`) found three more of the same kind in
devprog and the Prog lifecycle, fixed with it: `/prog/n/ns` kept
pointers to the Prog's mounts across reads and walked mount lists
without the `Mhead` lock that `cmount` changes and frees them under
(a fault there leaked the `pg->ns` read lock and wedged the name
space); `Sys_pctl` swapped the fd group the same way as the pgrp; and
`delprog` closed an exiting Prog's groups with the VM released while
the Prog was still in the pid table.

These races were masked by Inferno's cooperative Dis VM scheduling (only
one Dis thread executes at a time) but were genuine hazards for the
multi-threaded emu host layer where I/O threads, timer threads, and
interpreter threads share the `Osenv`.

**Status:** races 1 and 3 were fixed in 89db5178 (2026-05-14): `kchdir`
and `namec` now take the `pg->ns` lock. That commit also re-acquired the VM
lock before the NEWNS/FORKNS swap; fa93471d removed that because it
deadlocked, on the reasoning that the `pg->ns` rwlock covers the race
(see the comment in `Sys_pctl` and
`docs/postmortems/2026-05-17-newns-vm-lock-deadlock.md`). INFR-373 then
fixed race 2 by holding the VM lock for the pointer swap alone.

**Reproduced on the runtime** (INFR-59): `tests/pgrp_race_test.b` has a
case for each.
- `SwapWhileRead` covers race 2: before INFR-373, 10 of 12 runs hung or
  faulted.
- `ChdirWhileResolve` covers races 1 and 3: Progs sharing a name space,
  one changing dot while the others resolve relative names. With
  `kchdir` and `namec` reverted to their unlocked form, 6 of 6 runs
  panicked emu (`cclose`: the freed dot closed again).

On the fixed emu, 10 of 10 runs pass, under `-c0` and `-c1`. Any Dis
program can reach both: they need no privilege, only `spawn`, `chdir`,
`pctl` and reads of `/prog`. The demonstrated impact is a crash of the
whole emu, which is denial of service to every agent and service on
the node. A freed `Chan` or `Pgrp` that is reused before the stale
reference is followed could also resolve names in the wrong name space,
but this was not demonstrated. All three are fixed, so no follow-up is
open.

---

## 6. CBMC Bounded Model Checking

### 6.1 Approach

CBMC checks a **textual copy of C source code** from the kernel: the
`pgrpcpy()`, `newpgrp()`, `newmount()`, and `pgrpinsert()` bodies from
`pgrp.c` (differing only in `mallocz` → `malloc`+`memset` and the error
string; drift is not detected automatically), against property-annotated
harnesses with minimal stubs. The two isolation harnesses contain no
nondeterministic input: they are one concrete execution of one mount in
one hash bucket, instrumented for pointer and bounds safety, which is why
their property count is the same at every `MNTLOG` and they finish in
under a second. The bounds harness has a symbolic `qid`. `error()` and
`nexterror()` are no-ops in `stubs.h` and malloc is never allowed to fail,
so the kernel's allocation-failure path is not exercised;
`harness_pgrpcpy_error.c` checks a rewritten `pgrpcpy_safe` with return
codes instead. A mutation that makes the copy share the parent's `Mhead`
(`mh = f`) fails `harness_basic_isolation`, so the harness does see that
class of bug.

### 6.2 Stub Design

The stub header (`stubs.h`, 324 lines) provides:
- Simplified type definitions matching `dat.h` structures
- Configurable `MNTLOG`/`MNTHASH` (default 5/32, overridable via `-D`)
- Memory allocation wrappers (`cbmc_alloc_chan`, `cbmc_alloc_mhead`, etc.)
- Deterministic error injection (`_cbmc_error_at` counter) for waserror/poperror
- Lock operation stubs (no-ops for sequential verification)
- `cclone()` implementation that allocates fresh channel copies

### 6.3 Harnesses

**Quick mode** (CI) — the 3 kernel harnesses below, plus 16 PQC crypto checks from
`harness_mlkem_ct.c`, `harness_mldsa_ct.c` and `harness_mlkem_ntt.c`:

| Harness | File | Properties |
|---------|------|-----------|
| Array bounds (MOUNTH) | `harness_mnthash_bounds.c` | 58 |
| Integer overflow (fd) | `harness_overflow_simple.c` | 10 |
| Reference counting | `harness_refcount.c` | 45 |

**Full mode** (4 harnesses on real `pgrpcpy`, ~15 min each, 10GB RAM):

| Harness | Entry Function | Properties Verified |
|---------|---------------|-------------------|
| Basic isolation | `harness_basic_isolation` | Copy produces independent mount tables |
| Modification independence | `harness_modification_independence` | Parent modification doesn't affect child |
| MNTHASH bounds | `harness_mnthash_bounds` | Hash index always in `[0, MNTHASH)` |
| Error path safety | `harness_pgrpcpy_error.c:harness` | waserror/nexterror cleanup correctness |

Full mode uses `--unwind 34 --object-bits 11 -DMNTLOG=5` to verify
with `MNTHASH=32` (production configuration).

### 6.4 Key Properties Verified

For `harness_basic_isolation`:
- Child has mount at same hash bucket as parent
- Child's `Mhead` is a **different object** than parent's (deep copy)
- Child's mount points to **same channel** (shared, incref'd)
- Channel refcount incremented for copy
- Child has **cloned** (distinct) `slash` and `dot`
- `nodevs` and `progmode` flags copied correctly

For `harness_modification_independence`:
- After copy, adding mount to parent's mount list does **not** change child's
- Adding mount at different hash bucket in parent is invisible to child

---

## 7. Bugs Found and Fixed During Verification

### 7.1 Model Bugs (verification artifacts)

| Bug | Tool | Fix |
|-----|------|-----|
| Lock atomicity TOCTOU | SPIN | Wrap guard+set in `atomic{}` |
| Snapshot timing (false positive) | SPIN | Take snapshot from child after copy |
| LTL formula too complex | SPIN | Replace with structural assertions |
| Promela reserved word `chan` | SPIN | Rename to `ch` |
| IncRefChannel unbounded | TLA+ | Add bound guard on refcount |
| NamespaceIsolation property too strict | TLA+ | Account for pre-fork parent mounts via snapshot |
| `((PASS++))` with `set -e` | Bash | Use `PASS=$((PASS + 1))` |
| MC_Namespace duplicate constants | TLA+ | Use Namespace.tla constants directly |
| Pipe exit code via `tee` | Bash | Use `pipefail` in subshell |

### 7.2 Real Kernel Bugs (confirmed by formal methods)

Three use-after-free race conditions documented in
`docs/history/formal-verification/TODO-RACE-CONDITIONS.md`:

1. **kchdir dot race** — `cclose(pg->dot); pg->dot = c;` without lock
   (`sysfile.c:153-154`)
2. **FORKNS pgrp swap** — `o->pgrp = np.np` without lock
   (`inferno.c:873`)
3. **namec slash/dot read** — `pg->slash`/`pg->dot` read without lock
   (`chan.c:1022,1057`)

**Mitigation**: Inferno's cooperative Dis VM scheduling means only one
Dis thread executes at a time. However, the emu host layer uses multiple
OS threads for I/O, timers, and the interpreter, and the `Osenv`
structure (containing the `Pgrp` pointer) is accessible from all threads.

**Fix**: applied in 89db5178 — `pg->ns` read lock around the `slash`/`dot`
reads in `namec()` and write lock around the reassign in `kchdir()`; and
for INFR-373 the FORKNS/NEWNS (and NEWFD/FORKFD) swap holds the VM lock
for the pointer store alone, not the copy that can wait on Limbo file
servers (see `docs/postmortems/2026-05-17-newns-vm-lock-deadlock.md` for
why the copy must not). See §5.3.

---

## 8. Verification Infrastructure

### 8.1 CI/CD Integration

The verification suite is integrated into GitHub Actions
(`.github/workflows/formal-verification.yml`):

```yaml
- SPIN: ./verify-all.sh quick  # 5 models, assertions + deadlock only (no LTL)
- CBMC: ./verify-all.sh quick  # 3 model harnesses + PQC crypto harnesses (no pgrpcpy)
```

TLA+ (`./run-verification.sh small`), SPIN `full` (the race LTL properties
and `-DUNFIXED` checks) and CBMC `full` (the `pgrpcpy` harnesses) are run
by hand; the workflow has no job for them.

### 8.2 Reproducibility

All verification artifacts are committed to the repository under
`formal-verification/`:

```
formal-verification/
├── spin/                    # 5 Promela models + verify-all.sh
├── tla+/                    # 4 TLA+ modules + configs
├── cbmc/                    # 10 C harnesses + stub headers + verify-all.sh
├── docs/                    # Phase 2 locking model design
├── results/                 # Phase reports, TLC output logs, generated configs
└── run-verification.sh      # TLC runner (small/medium/large)
```

The race-condition list is now at
`docs/history/formal-verification/TODO-RACE-CONDITIONS.md`.

Total verification code: **4,929 lines** (1,440 Promela + 1,198 TLA+ +
2,291 C/headers).

---

## 9. Related Work

- **seL4** (Klein et al., 2009): Full functional correctness proof of a
  microkernel in Isabelle/HOL. Our work uses model checking rather than
  theorem proving, trading completeness for automation.

- **CertiKOS** (Gu et al., 2016): Certified concurrent OS kernel with
  compositional verification in Coq. Our approach is lighter-weight but
  targets a specific subsystem.

- **SLAM/SDV** (Ball & Rajamani, 2001): Microsoft's Static Driver
  Verifier uses predicate abstraction and model checking on C code.
  Our CBMC approach similarly verifies C implementation but with bounded
  model checking.

- **Hyperkernel** (Nelson et al., 2017): Verified using Z3 with
  push-button automation. Our multi-tool approach provides complementary
  coverage at different abstraction levels.

- **Plan 9 namespace verification**: To our knowledge, no prior formal
  verification of Plan 9/Inferno namespace isolation exists in the
  literature.

---

## 10. Threats to Validity

1. **Model fidelity**: The TLA+ and SPIN models are abstractions of the
   C implementation. Properties verified at the abstract level may not
   hold if the abstraction is unfaithful. We mitigate this with CBMC
   verification on actual C code.

2. **Bounded verification (CBMC)**: CBMC checks properties up to a
   bounded depth. Bugs beyond the unwind bound would not be found.
   We use `MNTHASH=32` (production value) with `--unwind 34`.

3. **Cooperative scheduling assumption**: The race conditions we found
   are mitigated by Dis VM cooperative scheduling. Our models assume
   arbitrary interleaving, which is conservative (finds more bugs) but
   may overreport issues for the Dis scheduler context.

4. **History variable correctness**: The isolation theorem depends on
   history variables accurately tracking post-copy mounts. We verify
   `PostCopyMountsSound` as a separate invariant to confirm tracking
   completeness.

5. **Scope limitation**: We model the namespace copy only, not the
   entire kernel. Cross-subsystem interactions (e.g., device drivers
   modifying mount tables) are out of scope.

6. **Model expressiveness (the main threat)**: neither the TLA+ nor the
   Promela state can represent two pgrps sharing an `Mhead` or `Mount`.
   The isolation invariants therefore cannot fail on the implementation
   bug they describe; they check the specification against itself. The
   CBMC harness is the only artefact that sees pointers, and it covers one
   concrete shape.

7. **Vacuity**: the 2026-03 small run reached no copy at all (§4.7).
   `run-verification.sh` now checks reachability of a copy and of a live
   post-copy mount before the main run. The medium constants allow one copy
   per behaviour and no fresh channel after it.

8. **Incomplete runs**: the medium run is a partial BFS (depth 13). It
   is evidence that no shallow counterexample exists under those constants,
   nothing more.

9. **What is not modelled at all**: channel use-after-free (channels are
   never freed in the TLA+ model and `DecRefChannel` can reach 0 while
   mounted), `cmount`'s union-mount copying, `cunmount`, the `nodevs`
   device gate, `restrictdir`/`restrictns`, binds of an ancestor inside an
   exported tree (the exportfs model's `walk_down` always descends), the
   cname stack that now governs `..`, the Dis VM and JIT.

10. **Constant time**: CBMC checks functional properties of the crypto
    code. Nothing here establishes constant-time execution.

11. **Provenance**: the fix commits cited (89db5178, fa93471d) are not in
    the current repository history; the code as it stands matches their
    description and `tests/pgrp_race_test.b` exercises the fixes.

---

## 11. Conclusion

We have model-checked a TLA+ specification of Inferno's namespace copy,
exhaustively at small scale with a guard that the copy is reached, and
found its 11 invariants hold. We have bounded-checked a copy of the
`pgrpcpy()` C code on one concrete mount and shown it allocates its own
mount heads, shares and increfs channels, and clones slash and dot; an
aliasing mutation is caught. We have confirmed three use-after-free races
in the pre-fix emulator with SPIN and shown a model of the fixed code free
of them.

What this is not is a proof that the C implementation isolates
namespaces. The abstract models cannot express the shared-structure
failure, the C check covers one shape, and the only run large enough to be
interesting is incomplete. The right citation is: a model-checked
specification of the namespace copy, a bounded unit-level check of
`pgrpcpy`'s deep copy, and SPIN confirmation of three fixed races.

---

## Appendix A: Tool Versions

| Tool | Version |
|------|---------|
| TLC (TLA+ model checker) | 2026.03.02.213938 |
| SPIN | 6.5+ |
| CBMC | 5.95.1 (CI pin; 6.7.1 used for the 2026-01 results) |
| Java (for TLC) | OpenJDK 21 |

## Appendix B: Reproduction Instructions

```bash
# Prerequisites: Java 11+, SPIN, CBMC

# Clone repository
git clone <repo-url> infernode
cd infernode/formal-verification

# Download TLA+ tools
curl -L -o tla2tools.jar \
  "https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar"

# Run all verification
./spin/verify-all.sh full      # SPIN models incl. race LTL + -DUNFIXED (~1m)
./cbmc/verify-all.sh quick     # CBMC quick mode (~15s)
CBMC_MNTLOG=5 ./cbmc/verify-all.sh full   # + pgrpcpy harnesses (~20s)
./run-verification.sh small    # TLA+ small, with vacuity guard (~5 h on 4 cores, 8 GB heap, ~19 GB disk)

# Full verification (dedicated host, see REMAINING-RUNS.md)
CBMC_MNTLOG=2 ./cbmc/verify-all.sh full    # CBMC pgrpcpy, MNTHASH=4 (~20m, 12GB)
CBMC_MNTLOG=5 ./cbmc/verify-all.sh full    # CBMC pgrpcpy, MNTHASH=32 (~60m, 16GB)
./run-verification.sh medium               # TLA+ medium (~30m, 16GB heap)
TLC_HEAP=32g ./run-verification.sh large   # TLA+ large (~hours, 32GB heap)
```
