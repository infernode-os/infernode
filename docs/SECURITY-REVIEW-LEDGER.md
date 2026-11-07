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
| PR #1015: styxbrick commander, sdg, TLS pinning, D2 | Re-reviewed PR head `b66d0f2944ca98ecd141d21f483c021b4b64478d`; styxbrick `review-3` `93a90ba` | **blocked; do not promote or merge** | [PR-1015-SECURITY-REVIEW.md](PR-1015-SECURITY-REVIEW.md); low-order DH fixed, counter/TLS partial; credentials, D2 ordering, current-master conflict, framing, and test gates remain |
| PR #1069 fuzzing-derived kernel/JIT hardening | base `ae36deda20b72b603e3376e071c989e07f7108b1`, head `c17daccdaf6a2faea0e7741bfc5c1170b66e0ac3`, merge `c4bdd0f1f9608303ca8d9fd16d0b7a60a512273d` | reviewed; adjacent group-lifetime and durable-kill fixes implemented; three availability residuals and deterministic-fault gates remain | [FUZZ-HARDENING-SECURITY-REVIEW.md](FUZZ-HARDENING-SECURITY-REVIEW.md) and [REMOTE-KERNEL-SECURITY-REVIEW.md](REMOTE-KERNEL-SECURITY-REVIEW.md) |
| Native camera integration | source `16948f6ced372ed08eb2db9594f9551888208d33` / PR #1006 merge `80189fa777022abe7a3bda2995b9545d0a6fafa1` | test-pattern source reviewed; **hardening required before real imagery** | [CAMERA-SECURITY-REVIEW.md](CAMERA-SECURITY-REVIEW.md); retained-frame budget, non-ambient delegation, cancellable locking contract, and source validation remain |
| Post-report remote delta: Veltro git/Xenith, namespace cwd, keyring, Claude gate, mobile, formal evidence | InferNode `008e74363..c7d892104`; fix `dc2a35402` | reviewed; two containment defects fixed in release branch | [POST-REVIEW-DELTA-SECURITY-REVIEW.md](POST-REVIEW-DELTA-SECURITY-REVIEW.md) |
| Post-#1096 remote delta: sanitizer/stack, login, SDR, IP, CNSA, USB touch | InferNode `c7d892104..858fcb50d`; fixes on `security/0.9.0-patch` | reviewed; three defects fixed, focused gates pass | [POST-1096-SECURITY-DELTA.md](POST-1096-SECURITY-DELTA.md) |
| New GEFS work | Pi 5 integration `fb66e0893`; GEFS feature head `93a597f2d` | source pin identified; security review in progress before promotion | Review on-disk/input parsing, transaction and recovery invariants, length/offset arithmetic, permissions, namespace exposure, and fuzz regression quality |

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
