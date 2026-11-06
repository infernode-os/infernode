# Remaining Verification Runs

This document describes verification runs that require a dedicated host
with sufficient memory and uninterrupted execution time.

## Status Summary

| Verification | Status | Where Run |
|-------------|--------|-----------|
| SPIN (5 models) | **DONE** | CI / any host |
| CBMC quick (3 kernel harnesses + PQC crypto harnesses) | **DONE** | CI / any host |
| TLA+ TLC small (11 invariants) | **DONE** (2026-11, 2 proc/2 pgrp/4 chan/1 path, MaxChanRef=2, about 5 h on 4 cores (checkpointed and resumed), 8 GB heap + 19 GB disk state) | any host. The 2026-03 run with MaxChannels=3 reached no copy and was vacuous |
| TLA+ TLC medium | **INCOMPLETE** (BFS depth 13, 2.56B queued) | Jetson Orin AGX (50GB heap, 10h50m) |
| TLA+ TLC large | **TODO** | Dedicated host (32GB+, ~hours) |
| CBMC full (pgrpcpy, MNTLOG=1) | **DONE** | AMD Ryzen 7 255 x86-64 (<1s, --slice-formula) |
| CBMC full (pgrpcpy, MNTLOG=2) | **DONE** | AMD Ryzen 7 255 x86-64 (<1s, --slice-formula) |
| CBMC full (pgrpcpy, MNTLOG=5) | **DONE** | AMD Ryzen 7 255 x86-64 (<1s, --slice-formula) |
| CBMC crypto (ML-KEM/ML-DSA) | **DONE** | 16/16 harnesses in `verify-all.sh` pass (the "5/9, 4 findings" of 2026-03 were against an earlier harness; the hard harnesses, NTT round trip, 10/11/12-bit encode, Montgomery correctness, are not in the script) |

## Prerequisites

```bash
# Java 11+ (for TLC)
java -version

# SPIN 6.5+
spin -V

# CBMC 5.x+
cbmc --version

# TLA+ tools
cd formal-verification
curl -L -o tla2tools.jar \
  "https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar"
```

## 1. TLC Medium Configuration

**Requirements**: 16GB+ RAM, 16+ cores recommended, ~30 minutes

The medium configuration (3 processes, 4 pgrps, 4 channels, 3 paths)
has tens of billions of distinct states at least. Previous attempts with 4GB
heap were OOM-killed at ~108M distinct states; 12GB reached 36M; 50GB plus
341GB of disk reached 3.17B at BFS depth 13 with the queue still growing.
Note that with 4 channels a copy consumes the last two, so post-copy mounts
in this configuration can only mount a slash or dot channel.

```bash
cd formal-verification

# Default: 16GB heap. Override with TLC_HEAP env var.
./run-verification.sh medium

# Or manually with custom heap:
TLC_HEAP=24g ./run-verification.sh medium
```

**Expected outcome**: All 11 invariants hold, 0 violations. The small
configuration passes completely (see results/). Medium exercises deeper
interleavings with more processes and paths, but has not been exhausted.

## 2. TLC Large Configuration

**Requirements**: 32GB+ RAM, 16+ cores, ~1-4 hours

The large configuration (4 processes, 5 pgrps, 5 channels, 3 paths) will
produce a very large state space. This may require disk-backed state storage
if RAM is insufficient.

```bash
TLC_HEAP=32g ./run-verification.sh large

# If RAM is limited, TLC can use disk-based state storage:
# Add -fpset flag to the java command in run-verification.sh
```

**Expected outcome**: Same 11 invariants verified. This is the most
thorough configuration and would be the strongest result for publication.

## 3. CBMC Full Mode — pgrpcpy Harnesses

**Requirements**: 12-16GB RAM per harness, ~15-60 minutes each

CBMC verifies the **actual C implementation** of `pgrpcpy()` from
`emu/port/pgrp.c` against property-annotated harnesses. The SAT solver
requires significant memory for the loop unrolling.

### MNTLOG=2 (MNTHASH=4, unwind=6)

Smaller configuration that still verifies the same code paths but with
fewer hash buckets. Good for validating the harness setup.

```bash
cd formal-verification/cbmc
CBMC_MNTLOG=2 ./verify-all.sh full
```

### MNTLOG=5 (MNTHASH=32, unwind=34) — Production Configuration

This is the production MNTHASH=32 configuration. Each harness requires
~10-15GB RAM and ~15 minutes.

```bash
cd formal-verification/cbmc
CBMC_MNTLOG=5 ./verify-all.sh full

# Or run individual harnesses:
cbmc --function harness_basic_isolation harness_pgrpcpy.c \
  --bounds-check --pointer-check --signed-overflow-check \
  --unwind 34 --object-bits 11 -DMNTLOG=5

cbmc --function harness_modification_independence harness_pgrpcpy.c \
  --bounds-check --pointer-check --signed-overflow-check \
  --unwind 34 --object-bits 11 -DMNTLOG=5

cbmc --function harness_mnthash_bounds harness_pgrpcpy.c \
  --bounds-check --pointer-check --signed-overflow-check \
  --unwind 34 --object-bits 11 -DMNTLOG=5

cbmc --function harness harness_pgrpcpy_error.c \
  --bounds-check --pointer-check --signed-overflow-check \
  --unwind 34 --object-bits 11 -DMNTLOG=5
```

**4 harnesses verified**:
1. `harness_basic_isolation` — Copy produces independent mount tables
2. `harness_modification_independence` — Parent modification doesn't affect child
3. `harness_mnthash_bounds` — Hash index always in `[0, MNTHASH)`
4. `harness_pgrpcpy_error.c:harness` — waserror/nexterror cleanup correctness

**Expected outcome**: VERIFICATION SUCCESSFUL for all 4 harnesses.

## 4. Recording Results

After each run, save the output and update `results/PHASE4-VERIFICATION-RUN.md`
with the actual numbers. For TLC, the key metrics are:

- States generated / distinct states found
- Search depth reached
- States left on queue (0 = complete exhaustive search)
- Wall clock time
- Any invariant violations (should be none)

For CBMC, record:
- Number of properties checked per harness
- VERIFICATION SUCCESSFUL / FAILED
- Wall clock time and peak memory

## Empirical Resource Profile

### TLC Medium

- 4GB heap: OOM-killed at 108M distinct states (depth 11)
- 12GB heap: reached 36M distinct states (depth 11) in 6 min before
  external termination. Queue still growing (~31M states in queue).
- 50GB heap + disk-backed storage: reached 3.17B distinct states (depth 13)
  in 10h50m on Jetson Orin AGX. 341GB state files on NVMe SSD. Zero violations.
  Queue still growing at ~3.5M/min net (2.56B states remaining).
- **Actual total distinct states**: tens to hundreds of billions (not exhaustible
  on current hardware). The partial result at 3.17B shows no counterexample of
  depth 12 or less under those constants; it is not a result for the configuration.

### CBMC pgrpcpy (MNTLOG=2, MNTHASH=4, unwind=6)

- **Without --slice-formula** (2026-01-13): `harness_basic_isolation` ran for
  77+ minutes of continuous SAT solving at 93% CPU, 10.5GB RAM (51% of 21GB).
  Still in propositional reduction phase when terminated.
- **With --slice-formula** (2026-03-11): All 4 harnesses completed in <0.3s each
  on AMD Ryzen 7 255 (x86-64, 27GB RAM). The `--slice-formula` flag prunes
  irrelevant SAT clauses, reducing verification time by over 3 orders of magnitude.

### CBMC pgrpcpy (MNTLOG=5, MNTHASH=32, unwind=34)

- **Completed 2026-03-11** on AMD Ryzen 7 255 (x86-64, 27GB RAM, 16 cores).
- All 4 harnesses passed with `--unwinding-assertions` (sound verification).
- 3,310 properties verified, 0 failures, <0.3s per harness.
- Previous estimate of "32GB+ RAM, hours per harness" was based on the
  non-sliced formula. With `--slice-formula`, the production configuration
  is trivially fast.

### CBMC pgrpcpy (MNTLOG=1, MNTHASH=2, unwind=4)

- **Completed 2026-03-11** as a sanity check before scaling up.
- All 4 harnesses passed in <0.3s each. 3,310 properties, 0 failures.

### Key Lesson: --slice-formula

The `--slice-formula` flag is essential for CBMC verification of kernel code
with deep pointer chains. Without it, CBMC generates a monolithic SAT formula
that includes all possible pointer dereference chains and loop iterations,
even those irrelevant to the properties being checked. With slicing, CBMC
identifies which program variables and paths are relevant to each assertion
and prunes the rest, reducing the formula from billions of clauses to a
tractable size. This should be the default for all future CBMC harness runs.

### General Notes

- All verification code is committed and ready to run. No code changes needed.
- The quick suite (SPIN + CBMC quick) runs in under a minute and is what CI
  runs. TLC small (about 5 h on 4 cores) and SPIN/CBMC full (minutes) are run by hand.
- The extended runs (TLC medium/large) would explore larger state spaces of
  the same model; they do not change what the model can express.
- **The CBMC full pgrpcpy verification is now complete** at all three MNTLOG
  levels (1, 2, 5) with sound unwinding assertions on x86-64 hardware.
