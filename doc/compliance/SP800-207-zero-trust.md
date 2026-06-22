# Compliance Evidence — NIST SP 800-207 (Zero Trust Architecture)

**Standard:** NIST SP 800-207, *Zero Trust Architecture* (Aug 2020).
**Roadmap row:** Federal / government — Zero Trust, Tier 0 ("Default posture — no
ambient authority — mostly document it").
**Tracking epic:** [INFR-328].
**Artifact date:** 2026-06-22.
**Overall status:** **Met (architectural posture).** Zero Trust is not a feature InferNode
adds; it is the **default and only** posture of the runtime. A process can act only on
what is bound into its per-process namespace — there is no ambient authority to fall back
on. This artifact documents the mechanism and the evidence, as the roadmap directs.

---

## 1. What SP 800-207 requires (tenets, §2.1) and how InferNode meets each

SP 800-207 frames Zero Trust as seven tenets. InferNode satisfies them *by construction*,
because the access primitive is the per-process namespace rather than an ambient
user/host identity.

| # | SP 800-207 tenet (abridged) | InferNode mechanism | Evidence |
|---|------------------------------|---------------------|----------|
| 1 | All data sources & compute are resources | Everything is a file served over Styx/9P | `doc/styx.ms`; `docs/NAMESPACE.md` |
| 2 | All communication secured regardless of network location | 9P-over-TLS + native STS transport, **hybrid PQ** (X25519+ML-KEM, DH+ML-KEM) | `doc/compliance/CNSA-2.0.md` §4; `docs/CRYPTO-MODERNIZATION.md` §10 |
| 3 | Access granted **per-session** | Each agent/process forks its own namespace and is restricted at start of session | `appl/veltro/SECURITY.md` (3 entry points: tools9p/repl/spawn) |
| 4 | Access by **dynamic policy**, least privilege | Capability set → `restrictns(caps)` bind-replace allowlist; child caps ≤ parent caps | `appl/veltro/nsconstruct.b`; `docs/NAMESPACE_SECURITY_REVIEW.md` §11 |
| 5 | Integrity/posture of assets monitored | `verifyns()` post-restriction audit (positive + negative assertions); formal verification of the kernel primitive | `appl/veltro/SECURITY.md` §Verification; `formal-verification/` |
| 6 | **Authn/authz strictly enforced before access** | Resource simply **does not exist** in the namespace if not granted — enforcement is structural, not a checkpoint that can be skipped | `docs/NAMESPACE_SECURITY_REVIEW.md` §3.1–3.2 |
| 7 | Collect state to improve posture | `emitauditlog()` records namespace operations; subagent trajectory logging | `appl/veltro/SECURITY.md` (Security Properties: "Auditable") |

---

## 2. The core claim: no ambient authority

On conventional OSes a process inherits the full authority of its UID; "zero trust" is
then bolted on as policy that code must remember to consult. **Inferno inverts this.** A
process's authority *is* its namespace. If a name is not bound, the process cannot
express it — there is no `/etc/passwd` to deny access to, because it is not in the name
space at all.

- **Default-deny by replacement.** `restrictdir(target, allowed)` builds a shadow
  directory of only the allowed items and bind-replaces (`MREPL`) the target. Everything
  not on the allowlist becomes *invisible*, not *forbidden*. (`appl/veltro/nsconstruct.b`;
  model in `docs/NAMESPACE_SECURITY_REVIEW.md` §11.1.)
- **Capability attenuation.** A child forks an already-restricted namespace and can only
  narrow it further — the invariant *child caps ≤ parent caps* holds structurally, not by
  check (`docs/NAMESPACE_SECURITY_REVIEW.md` §1.2; `appl/veltro/SECURITY.md` §Two-Level
  Restriction).
- **Device-attach gate.** Even kernel `#x` device naming is closed off:
  `pctl(NODEVS)` blocks `sys->bind("#U", …)` / `#sfactotum` / `#p`. The kernel gate is at
  `emu/port/chan.c:1046-1053` (the `"|esDa"` exception allowlist). Applied unconditionally
  in spawned children (`appl/veltro/tools/spawn.b`).
- **Truthful environment.** Because denial is by absence, an agent never sees an "access
  denied" on a path it can name — eliminating the probing oracle. (`appl/veltro/SECURITY.md`
  Security Properties: "Truthful namespace".)

This is the property the roadmap calls out: *"a process cannot name what isn't bound."*

## 3. Assurance — the posture is formally verified, not merely asserted

The namespace isolation that Zero Trust rests on is **machine-checked**, which is the
differentiator a Linux/Windows ZTA cannot offer (see `doc/security-standards-roadmap.md`,
"the thesis"):

| Property | Tool | Result | Source |
|----------|------|--------|--------|
| Post-copy mounts don't leak across namespaces (`NamespaceIsolation`) | TLA+ | small: exhaustive; medium: **3.17B states, 0 violations** | `formal-verification/results/VERIFICATION-RESULTS.md` |
| Isolation under non-atomic operations | SPIN | 5/5 models pass | `formal-verification/spin/` |
| `pgrpcpy()` copy fidelity / refcount / bounds on **real C code** | CBMC | pass | `formal-verification/cbmc/`, `results/PHASE3-CBMC-RESULTS.md` |
| `exportfs` root boundary cannot be escaped by `walk("..")` | SPIN | verified | `formal-verification/spin/exportfs_boundary.pml` |
| Lock ordering / deadlock freedom | SPIN | verified | `results/PHASE2-LOCKING-RESULTS.md` |

These run in CI on every push (`.github/workflows/formal-verification.yml`). The C
functions verified map directly to the namespace syscalls (`pgrpcpy`, `cmount`,
`cunmount`, `namec`, `Sys_pctl(NEWNS/FORKNS)`) — see the correspondence table in
`formal-verification/README.md`.

## 4. Tests

| Test | Covers |
|------|--------|
| `tests/veltro_security_test.b` | allowlist visibility, exclusion of non-granted items, `restrictns()` full policy, `verifyns()` violation detection, audit logging, negative assertions on `/.env`/`/.git`/`/CLAUDE.md`/`/n/local` |
| `tests/veltro_concurrent_test.b` | concurrent init / restrictdir / restrictns (race safety) |

## 5. Residual notes (observability / future hardening)

- **`NODEVS` device-attach gate — applied.** `pctl(NODEVS)` is set at every agent
  FORKNS site: the spawned child (`spawn.b:1071`) and all three top-level entry points
  (`veltro.b:169`, `repl.b:170`, `tools9p.b:798`), each right after `FORKNS`. The kernel
  gate (`emu/port/chan.c:1046-1053`) then blocks any `#x` attach outside the `|esDa`
  allowlist, so device-attach cannot bypass path restriction. Locked in by
  `testNodevsBlocksDeviceAttach` in `tests/veltro_security_test.b` (asserts `#p` /
  `#sfactotum` bind fails after `NODEVS`). The only un-gated `FORKNS` is the throwaway
  manifest fork in `tools9p.b`'s `emitmanifestnow()`, whose namespace is discarded and
  which runs no agent code — not a sandbox. (INFR-341 — verified already implemented.)
- **`nsaudit`** (config-time authority linter) is in progress (`appl/cmd/nsaudit.b`) — a
  *pre-flight* check that a shipped capability set grants only intended authority. It
  strengthens tenet 7 evidence; the namespace remains the enforcer regardless.

## 6. Disposition

SP 800-207's tenets are satisfied by the default runtime posture, the mechanism is
documented and tested, and the underlying kernel isolation is formally verified. **Met**
for the architectural posture. The `NODEVS` device-attach gate is applied at all agent
sites and test-locked; `nsaudit` (pre-flight config linter) is the remaining
observability enhancement, not a posture defect.

## 7. References

- NIST SP 800-207, *Zero Trust Architecture*.
- `docs/NAMESPACE.md`, `docs/NAMESPACE-LAYOUT.md`, `docs/NAMESPACE_SECURITY_REVIEW.md`.
- `appl/veltro/SECURITY.md` (v3 namespace security model).
- `formal-verification/README.md` and `formal-verification/results/`.
- Pike et al., *The Use of Name Spaces in Plan 9*.
