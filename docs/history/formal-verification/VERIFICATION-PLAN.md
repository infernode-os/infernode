# Inferno Kernel Formal Verification Plan

## Executive Summary

This document outlines a formal verification strategy for the Inferno kernel's namespace isolation mechanism. The primary objective is to provide machine-checked proofs that **process-specific namespaces behave as expected**, ensuring that namespace operations maintain isolation guarantees.

## Prior Art Assessment

**Finding: No existing formal verification of Inferno OS exists.**

A comprehensive search (January 2026) found:
- No formal verification of Inferno OS, Limbo language, or Dis VM
- No formal specification of the 9P protocol
- No academic papers on Plan 9 namespace formal verification

This makes our verification effort **novel and valuable**.

### Related Work

The closest comparable effort is the [seL4 microkernel verification](https://sel4.systems/Research/pdfs/comprehensive-formal-verification-os-microkernel.pdf), which provides:
- Refinement proofs from abstract specification to C implementation
- capDL specification for capability-based access control
- Information flow proofs for isolation guarantees

We adopt similar methodology adapted for the Inferno namespace model.

## Target System Overview

### Architecture

The "Inferno kernel" is the **Dis VM emulator** (`emu/port/`), approximately 31,600 lines of C code running as a hosted system on Linux/macOS/Windows.

### Namespace Isolation Components

| Component | Source File | Description |
|-----------|-------------|-------------|
| `Pgrp` | `emu/port/pgrp.c` | Process group containing namespace (mount table hash) |
| `Fgrp` | `emu/port/pgrp.c` | File descriptor group |
| `Egrp` | `emu/port/pgrp.c` | Environment variable group |
| `Chan` | `emu/port/chan.c` | Channel abstraction (file handles) |
| `Mount` | `emu/port/chan.c` | Mount point structure |
| `Mhead` | `emu/port/chan.c` | Mount head (hash bucket entry) |

### Key Data Structures

```c
struct Pgrp {
    Ref     r;                      // Reference count with lock
    ulong   pgrpid;                 // Unique process group ID
    RWlock  ns;                     // Read/write lock for namespace
    QLock   nsh;                    // Queue lock for namespace
    Mhead*  mnthash[MNTHASH];       // Mount table hash (32 buckets)
    int     progmode;               // Program mode flags
    Chan*   dot;                    // Current working directory
    Chan*   slash;                  // Root directory
    int     nodevs;                 // Device access restrictions
    int     pin;                    // Pin status
};

struct Mount {
    ulong   mountid;                // Unique mount ID
    Mount*  next;                   // Next mount in chain
    Mhead*  head;                   // Back pointer to mount head
    Mount*  copy;                   // Copy for namespace duplication
    Mount*  order;                  // Order in union
    Chan*   to;                     // Channel being mounted (target)
    int     mflag;                  // Mount flags (MREPL, MBEFORE, MAFTER, MCREATE)
    char*   spec;                   // Mount specification
};
```

### Critical Operations

1. **`newpgrp()`** - Create a new empty process group
2. **`pgrpcpy()`** - Copy a process group (deep copy of namespace)
3. **`closepgrp()`** - Close and potentially free a process group
4. **`cmount()`** - Mount a channel onto another channel
5. **`cunmount()`** - Unmount a channel
6. **`namec()`** - Resolve a path to a channel through namespace

## Security Properties to Verify

### Primary: Namespace Isolation

**Property NS-ISO-1**: After `pgrpcpy()`, modifications to the child namespace do not affect the parent namespace.

```
forall p_parent, p_child, path:
    pgrpcpy(p_parent) = p_child =>
    cmount(p_child, path, chan) =>
    lookup(p_parent, path) = lookup_before(p_parent, path)
```

**Property NS-ISO-2**: Two processes with different `pgrpid` have independent namespaces.

```
forall p1, p2:
    p1.pgrpid != p2.pgrpid =>
    !shares_mount_structure(p1.pgrp, p2.pgrp)
```

### Secondary: Reference Counting

**Property REF-1**: Reference count is always non-negative.

```
forall ref: ref.ref >= 0
```

**Property REF-2**: Object is freed iff reference count reaches zero.

```
forall obj:
    freed(obj) <=> (obj.ref.ref = 0 AND was_positive(obj.ref.ref))
```

**Property REF-3**: No use-after-free.

```
forall obj, op:
    freed(obj) => !accessed(obj, op)
```

### Tertiary: Locking Correctness

**Property LOCK-1**: No deadlock in namespace operations.

```
forall execution:
    !exists cycle in lock_wait_graph(execution)
```

**Property LOCK-2**: Data race freedom on shared structures.

```
forall chan, pgrp:
    concurrent_access(chan) => protected_by_lock(chan)
```

## Verification Methodology

### Phase 1: TLA+ Abstract Specification (Current Phase)

**Objective**: Create a formal model of namespace semantics and verify isolation properties using the TLC model checker.

**Deliverables**:
1. `Namespace.tla` - Core data structure definitions
2. `NamespaceOps.tla` - Operation specifications
3. `NamespaceProperties.tla` - Safety invariants
4. `NamespaceModel.cfg` - TLC configuration

**Properties Verified**:
- Namespace isolation after copy
- Reference counting bounds
- Mount table consistency

**Tools**: TLA+ Toolbox, TLC Model Checker

### Phase 2: SPIN Locking Protocol Verification

**Objective**: Verify deadlock freedom and correct lock ordering in concurrent namespace operations.

**Deliverables**:
1. `namespace_locks.pml` - Promela model of locking protocol
2. LTL properties for deadlock freedom

**Properties Verified**:
- No deadlock in `wlock(&pg->ns)` / `rlock(&pg->ns)` sequences
- Correct lock ordering across `cmount`, `cunmount`, `walk`

**Tools**: SPIN Model Checker

### Phase 3: CBMC Bounded Model Checking

**Objective**: Verify C implementation against bounded scenarios.

**Deliverables**:
1. Annotated source files with CBMC assertions
2. Harness functions for bounded verification

**Properties Verified**:
- Buffer bounds in `mnthash` access
- Reference count non-negativity
- Null pointer safety

**Tools**: CBMC

### Phase 4: ACSL Annotations (Optional)

**Objective**: Add machine-checkable contracts to C functions.

**Deliverables**:
1. ACSL-annotated header files
2. Frama-C verification reports

**Tools**: Frama-C with WP plugin

## Phase 1 Detailed Design

### TLA+ Module Structure

```
formal-verification/
├── tla+/
│   ├── Namespace.tla           # Core definitions
│   ├── NamespaceOps.tla        # Operations
│   ├── NamespaceProperties.tla # Invariants and properties
│   ├── RefCount.tla            # Reference counting model
│   ├── MC_Namespace.tla        # Model checking configuration
│   └── MC_Namespace.cfg        # TLC config file
└── docs/
    ├── VERIFICATION-PLAN.md    # This document
    └── RESULTS.md              # Verification results
```

### Abstract Model

We model the system at a level of abstraction that captures namespace semantics while remaining tractable for model checking:

1. **Processes**: Finite set of process IDs
2. **Pgrps**: Mapping from PgrpId to namespace state
3. **Namespaces**: Mapping from Path to MountEntry
4. **Channels**: Abstract channel identifiers
5. **References**: Mapping from object to reference count

### State Variables

```tla
VARIABLES
    processes,      \* Set of active process IDs
    pgrps,          \* PgrpId -> Pgrp state
    process_pgrp,   \* ProcessId -> PgrpId mapping
    mounts,         \* PgrpId -> (Path -> Set of Channels)
    refcounts,      \* ObjectId -> Nat
    freed           \* Set of freed object IDs
```

### Invariants to Check

```tla
NamespaceIsolation ==
    \A p1, p2 \in processes :
        process_pgrp[p1] # process_pgrp[p2] =>
        \A path \in DOMAIN mounts[process_pgrp[p1]] :
            mounts[process_pgrp[p1]][path] \cap
            mounts[process_pgrp[p2]][path] = {}
            \/ InheritedFrom(process_pgrp[p1], process_pgrp[p2])

RefCountNonNegative ==
    \A obj \in DOMAIN refcounts : refcounts[obj] >= 0

NoUseAfterFree ==
    \A obj \in freed : obj \notin ActiveObjects
```

## Success Criteria

### Phase 1 Complete When:
- [ ] TLA+ specification compiles without errors
- [ ] TLC model checker runs to completion
- [ ] All defined invariants hold for bounded state space
- [ ] Namespace isolation property verified
- [ ] Reference counting properties verified

### Overall Verification Complete When:
- [ ] All four phases complete
- [ ] No property violations found
- [ ] Results documented with reproducible verification scripts

## Assumptions and Limitations

### Assumptions
1. Hardware executes instructions correctly
2. C compiler (GCC/Clang) is correct
3. Host OS provides correct threading primitives
4. Memory allocator behaves correctly

### Limitations
1. **Bounded verification**: TLC explores finite state spaces
2. **Abstraction gap**: TLA+ model may not capture all C semantics
3. **Concurrency model**: Assumes sequentially consistent memory

### Out of Scope (for now)
1. Limbo type system verification
2. Dis VM bytecode verification
3. 9P protocol correctness
4. Network security properties

## Timeline and Resources

**Note**: No time estimates provided per project guidelines. Work proceeds in phases with clear deliverables.

### Phase Dependencies
```
Phase 1 (TLA+) ─┬─> Phase 2 (SPIN)
                └─> Phase 3 (CBMC) ─> Phase 4 (ACSL)
```

Phases 2 and 3 can proceed in parallel after Phase 1.

## References

1. [seL4: Formal Verification of an OS Kernel](https://sel4.systems/Research/pdfs/comprehensive-formal-verification-os-microkernel.pdf)
2. [TLA+ Proof System](https://lamport.azurewebsites.net/pubs/keappa08-web.pdf)
3. [Inferno OS Documentation](https://github.com/inferno-os/inferno-os)
4. [awesome-formal-verification](https://github.com/ElNiak/awesome-formal-verification)
5. Inferno source: `emu/port/pgrp.c`, `emu/port/chan.c`

---

*Document Version: 1.0*
*Created: 2026-01-13*
*Branch: claude/formal-verification-namespace-e4zPW*
