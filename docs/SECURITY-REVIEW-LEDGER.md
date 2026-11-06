# Security review ledger

This is the durable index of security review work.  A row is complete only for
the exact source pin named by its linked report; later commits require a delta
review.  The ledger exists to prevent a clean checkout or a new reviewer from
repeating work whose evidence already lives in the repository.

| Scope | Source pin | Status | Record / next gate |
|---|---|---|---|
| Release 0.9.0 security hardening and report-pack assimilation | `security/0.9.0-patch` history | implemented and tested; release PR still follows its CI/review gate | Branch commits and the focused regressions; external report pack remains outside the product tree by design |
| Applicable 9front security fixes | 9front `f5df6bc0a4024b0e9764a49e4fd103e2ac31d42f` | complete at pinned baseline | [9FRONT-SECURITY-AUDIT.md](9FRONT-SECURITY-AUDIT.md); review later 9front deltas before advancing the pin |
| Major remote kernel assimilation | InferNode master `59dbf672cbf1` plus the CSPRNG follow-up recorded in the report | complete at pinned baseline | [REMOTE-KERNEL-SECURITY-REVIEW.md](REMOTE-KERNEL-SECURITY-REVIEW.md) |
| PR #1015: styxbrick commander, sdg, TLS pinning, D2 | PR head `08846129d207c1d535682e0ad37ca883a4e75c57`; styxbrick `review-3` `93a90ba` | **blocked; do not promote or merge** | [PR-1015-SECURITY-REVIEW.md](PR-1015-SECURITY-REVIEW.md); credentials, D2 ordering, sdg hardening, rebase, and test gates remain |
| Weekend fuzzing-derived fixes | not yet pinned in this ledger | queued after #1015 disposition | Inventory each finding, crashing input, root cause, fix, regression, and adjacent parser variants; do not infer correctness from “fuzzer no longer crashes” |
| New camera integration | not yet pinned in this ledger | queued | Review device/file authority, frame length/format arithmetic, lifetime/teardown, DMA or shared-buffer ownership, and agent namespace exposure |
| New gefs work | not yet pinned in this ledger | queued | Review on-disk/input parsing, transaction and recovery invariants, length/offset arithmetic, permissions, namespace exposure, and fuzz regression quality |

## Review record requirements

Every new row or linked report records:

1. exact repository commit(s), merge base, and relevant external dependency pin;
2. threat model and trust boundaries;
3. source locations and a reproducible construction for every finding;
4. whether evidence is static, model-free runtime, fuzz, formal, hardware, or
   live-model work;
5. fixes and regressions, including negative controls;
6. tests that could not be run and why; and
7. the precise exit criterion and current disposition.

Commit history shows what changed.  This ledger records what was actually
reviewed, at which pin, with what evidence, and what remains open.
