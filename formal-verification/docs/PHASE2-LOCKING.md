# Phase 2: Locking Protocol Verification

**Status**: Verified 2026-01-13 — see [../results/PHASE2-LOCKING-RESULTS.md](../results/PHASE2-LOCKING-RESULTS.md)
**Created**: 2026-01-13

## Overview

Phase 2 formally verifies the **deadlock freedom** and **lock ordering correctness** of the Inferno namespace locking protocol using SPIN model checker.

## Locking Architecture

### Lock Types

The Inferno namespace system uses two levels of reader-writer locks:

| Lock | Type | Purpose | Scope |
|------|------|---------|-------|
| `pg->ns` | RWlock | Protects mount table hash | Per process group |
| `m->lock` | RWlock | Protects individual mount head | Per mount point |

### RWlock Semantics

Reader-Writer locks allow:
- **Multiple readers** simultaneously (shared access)
- **Single writer** exclusively (no readers, no other writers)
- **Writer priority**: waiting writers block new readers

## Lock Ordering Invariant

**Critical Property**: `pg->ns` MUST be acquired before `m->lock`

This ensures a consistent lock hierarchy and prevents deadlock.

## Locking Patterns by Operation

### 1. `cmount()` - Mount Operation

**Source**: `emu/port/chan.c:506`

```c
wlock(&pg->ns);              // Acquire namespace write lock
// ... search mount table ...
wlock(&m->lock);             // Acquire mhead write lock
wunlock(&pg->ns);            // ← EARLY RELEASE (optimization)
// ... modify mount structure ...
wunlock(&m->lock);
```

**Key observation**: The namespace lock is released early while still holding the mhead lock. This is safe because:
1. The mhead is already found and locked
2. No further namespace traversal is needed
3. Other operations can proceed on different mount points

### 2. `cunmount()` - Unmount Operation

**Source**: `emu/port/chan.c:622`

```c
wlock(&pg->ns);              // Acquire namespace write lock
// ... find mount point ...
wlock(&m->lock);             // Acquire mhead write lock
// ... unmount operation ...
wunlock(&m->lock);           // Release in various orders
wunlock(&pg->ns);
```

**Lock release order**: Varies by code path but always releases both.

### 3. `pgrpcpy()` - Namespace Copy

**Source**: `emu/port/pgrp.c:75`

```c
wlock(&from->ns);            // Write lock source namespace
for (each mhead) {
    rlock(&f->lock);         // Read lock each mhead
    // ... copy mount entries ...
    runlock(&f->lock);
}
wunlock(&from->ns);
```

**Writer-reader pattern**: Holds write lock on namespace but only reads mount heads.

### 4. `findmount()` - Mount Lookup

**Source**: `emu/port/chan.c:731`

```c
rlock(&pg->ns);              // Read lock namespace
rlock(&m->lock);             // Read lock mhead
// ... search ...
runlock(&pg->ns);
runlock(&m->lock);
```

**Pure reader**: Only acquires read locks, allows concurrent lookups.

### 5. `closepgrp()` - Process Group Close

**Source**: `emu/port/pgrp.c:23`

```c
wlock(&p->ns);               // Write lock namespace
for (each mhead) {
    wlock(&f->lock);         // Write lock each mhead
    // ... free structures ...
    wunlock(&f->lock);
}
wunlock(&p->ns);
```

**Cleanup operation**: Exclusive access for teardown.

## Properties Verified

### 1. Deadlock Freedom

**Property**: No execution leads to a state where all processes are blocked waiting for locks.

**Method**: SPIN's built-in deadlock detection with safety checks.

**Test scenarios**:
- Concurrent `cmount` operations (writer-writer)
- Mixed `findmount` and `cmount` (reader-writer)
- `pgrpcpy` with `cmount` (write-read-write mix)
- Multiple `findmount` operations (reader-reader)

### 2. Lock Ordering Invariant

**Property (LTL)**:
```ltl
[] (holds_mhead_lock -> (holds_pg_ns_lock || previously_held_pg_ns_lock))
```

For every process, if it holds an mhead lock, it either:
1. Currently holds the corresponding pg_ns lock, OR
2. Previously held the pg_ns lock (released early in cmount case)

**Method**: LTL model checking with explicit lock state tracking.

### 3. RWlock Correctness

**Properties**:
- **Mutual exclusion**: Writer excludes all readers and writers
- **Reader concurrency**: Multiple readers can hold lock simultaneously
- **Progress**: Waiting lock requests eventually succeed (no starvation)

**Method**: Assertions in rwlock implementation.

## SPIN Model Details

### File: `formal-verification/spin/namespace_locks.pml`

**Model structure**:
1. **RWlock implementation** (lines 12-75)
   - Reader/writer state tracking
   - Atomic lock acquisition primitives
   - Deadlock-safe blocking on lock contention

2. **Process state tracking** (lines 77-88)
   - Which locks each process holds
   - Current operation being performed

3. **Operation models** (lines 90-260)
   - `cmount`, `cunmount`, `pgrpcpy`, `findmount`, `closepgrp`
   - Faithful representation of C code locking patterns

4. **LTL property** (lines 262-280)
   - Lock ordering invariant

5. **Test scenarios** (lines 282-305)
   - Non-deterministic choice of concurrent operations

### Abstraction Choices

| Aspect | Abstraction | Rationale |
|--------|-------------|-----------|
| Mount table | Omitted | Not relevant to locking protocol |
| Channel data | Omitted | Not relevant to locking protocol |
| Loop iterations | Single iteration | Representative of multi-iteration behavior |
| Error handling | Simplified | Focus on lock acquisition/release |
| Process count | 3 processes | Balance between coverage and state space |

## Running Verification

### Prerequisites

```bash
# macOS
brew install spin

# Linux (Debian/Ubuntu)
apt-get install spin
```

### Quick Verification

```bash
cd formal-verification/spin
./verify-locks.sh basic
```

**Expected output**:
```
State-vector X bytes, depth reached Y, errors: 0
Z states explored
```

### Full Verification

```bash
./verify-locks.sh full
```

Explores larger state space with collision checking.

### LTL Property Verification

```bash
./verify-locks.sh ltl
```

Verifies lock ordering invariant explicitly.

## Expected Results

✅ **No deadlocks** - All concurrent scenarios complete without blocking
✅ **Lock ordering maintained** - LTL property holds in all states
✅ **RWlock semantics correct** - Mutual exclusion and reader concurrency work
✅ **No assertion violations** - All assertions in model pass

## Correspondence to Code

| Model | C Code | Source File:Line |
|-------|--------|------------------|
| `cmount()` | `cmount()` | `emu/port/chan.c:506` |
| `cunmount()` | `cunmount()` | `emu/port/chan.c:622` |
| `pgrpcpy()` | `pgrpcpy()` | `emu/port/pgrp.c:75` |
| `findmount()` | `findmount()` | `emu/port/chan.c:731` |
| `closepgrp()` | `closepgrp()` | `emu/port/pgrp.c:23` |

## Limitations

1. **Abstraction gap**: Model simplifies data structures and error paths
2. **Finite processes**: Models 3 processes; real system has variable process count
3. **Single namespace**: Models operations on shared locks; doesn't model multiple independent namespaces
4. **No host OS**: Assumes rwlock implementation is correct

These limitations are acceptable because:
- Locking protocols are compositional (3 processes is representative)
- Multiple namespaces use independent locks (no interaction)
- We verify the protocol, not the lock primitive implementation

## Potential Issues Found

*To be filled in after verification runs*

## Future Enhancements

- [ ] Model `mountid` spinlock interactions
- [ ] Add timing constraints for lock hold times
- [ ] Model Fgrp locking alongside Pgrp
- [ ] Verify interrupt handler interactions (if any)

## References

1. [SPIN Model Checker](https://spinroot.com/)
2. [The SPIN Model Checker: Primer and Reference Manual](https://spinroot.com/spin/Doc/Book_extras/)
3. Inferno source: `emu/port/pgrp.c`, `emu/port/chan.c`

---

*Document Version: 1.0*
*Created: 2026-01-13*
*Branch: master*
