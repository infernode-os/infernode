# Compliance Evidence — Common Criteria (ISO/IEC 15408) Readiness

**Standard:** Common Criteria for Information Technology Security Evaluation (ISO/IEC 15408),
evaluated against a Protection Profile (PP) at an Evaluation Assurance Level (EAL 1–7).
**Roadmap row:** Federal / government — Common Criteria, Tier 2 ("Small TCB → target a
*Separation Kernel PP*").
**Tracking:** program epic [INFR-328].
**Artifact date:** 2026-06-22.
**Overall status:** **Readiness / gap analysis — not evaluated.** No CC certificate exists or
is claimed. CC evaluation is an external, accredited-lab (NIAP / CCRA scheme) engagement.
This artifact records why InferNode's architecture is unusually favorable for a high-assurance
evaluation, and the concrete assurance-evidence gaps a real evaluation would require.

---

## 1. Why the architecture is favorable (the differentiator)

CC assurance scales with the **evaluability of the TCB**. The higher EALs (EAL5–7) demand
*semiformal* or *formal* design and correspondence evidence — exactly where large monolithic
kernels (Linux, Windows) cannot go, and where InferNode is built to. Two structural facts:

1. **A small, well-defined TCB.** Security rests on two things: the per-process **namespace**
   (the access-control mechanism) and the **Dis VM** (type/memory-safe execution). Everything
   else is a file service composed on top. That is a *separation-kernel* shape — the cleanest
   target PP class for this architecture (U.S. Government Separation Kernel PP / SKPP lineage).

2. **The core isolation property is already formally verified.** The Namespace Isolation
   Theorem — that post-copy mounts do not leak across namespaces — is machine-checked at three
   levels (`formal-verification/METHODOLOGY.md`):
   - **TLA+/TLC:** 11 safety invariants, **369M states**, isolation theorem via history variables.
   - **SPIN:** concurrent protocol (131K states); also *found 3 real use-after-free races*.
   - **CBMC:** bounded model checking of the **actual C** (`pgrpcpy`, refcount, bounds).
   - Runs in CI in <10 min (`.github/workflows/formal-verification.yml`).

CC EAL5+ asks for a formal/semiformal security-policy model and correspondence to the
implementation. InferNode has *started that work for the load-bearing property already* —
which is the expensive, rare part. This is the "our TCB is small enough to formally verify"
claim the roadmap stakes out, and it is real and cited, not aspirational.

## 2. Toward a Target of Evaluation (TOE)

| CC element | InferNode candidate | State |
|------------|---------------------|-------|
| **TOE boundary** | The Dis VM + namespace kernel (`emu/port` + `libinterp`), excluding application file services | Needs formal definition |
| **Target PP** | Separation Kernel PP (isolation + information-flow control between partitions) | Identified; not formally instantiated |
| **Security Functional Requirements (SFRs)** | FDP_IFC/FDP_IFF (flow control), FDP_ACC/ACF (access control), FPT_SEP (domain separation) → map to namespace + Dis VM | To be written |
| **Security objectives / SPM** | Namespace isolation + Dis type-safety as the security-policy model | Isolation property **formally proved**; full SPM to author |

## 3. Assurance-class gaps (what a real evaluation requires)

These do not exist yet and are the funded-effort backlog. None is a defect in the system —
they are the *evaluation evidence* CC mandates.

| CC assurance class | Requirement | Gap |
|--------------------|-------------|-----|
| **ASE** Security Target | A complete ST (TOE description, SFRs, rationale) | Not authored |
| **ADV** Development | Functional spec, TOE design, and (EAL5+) a **formal/semiformal** security-policy model + correspondence | Isolation proof exists; full ADV_SPM / ADV_FSP / ADV_TDS to write |
| **AGD** Guidance | Operational user + prep guidance | Partial (QUICKSTART, ops docs); not CC-structured |
| **ALC** Life-cycle | CM, flaw remediation, delivery, dev security | Strong technical base (reproducible builds, SLSA L3, signed artifacts, `verify-dis-paths`, security.md) — needs CC-form documentation |
| **ATE** Tests | Functional test coverage + depth | Strong test base (in-emu suite, `veltro_security_test`, crypto KATs) — needs coverage-to-SFR mapping |
| **AVA** Vulnerability | Independent vuln assessment / pen-test | CodeQL + fuzzing + formal verification feed it; independent AVA is lab work |

## 4. What is already strong (do not re-do)

- **ADV (formal core):** the namespace isolation theorem and CBMC harnesses are exactly the
  kind of high-EAL evidence labs rarely see pre-engagement — `formal-verification/`.
- **ALC:** reproducible Inferno `mk` builds, SLSA L3 provenance + Sigstore signing, SBOM,
  `verify-dis-paths`, ring-fence guard — see [`SLSA.md`](SLSA.md), [`SP800-53-171-mapping.md`](SP800-53-171-mapping.md) §5.CM/SR.
- **ATE:** the in-emu regression suite and `tests/veltro_security_test.b` exercise the access
  mechanism directly.
- **Small TCB** keeps every above class tractable — the whole point.

## 5. Disposition

CC is **not claimed** and is correctly Tier 2 (expensive, external, scheme-driven). But the
*hard* part for a high-assurance separation-kernel evaluation — a small TCB with the core
isolation property already formally proved — is in hand. Recommended sequencing **when an
evaluation is funded**: (1) define the TOE boundary; (2) select/instantiate the Separation
Kernel PP; (3) author the ST + ADV_SPM building on the existing proofs; (4) engage an
accredited lab. Until then this artifact is the readiness baseline an accreditor uses to
scope the effort.

## 6. References

- ISO/IEC 15408 (CC) parts 1–3; CEM; NIAP / CCRA schemes; Separation Kernel Protection Profile.
- `formal-verification/METHODOLOGY.md`, `formal-verification/README.md`, `results/`.
- [`SP800-207-zero-trust.md`](SP800-207-zero-trust.md) (the isolation posture), [`SLSA.md`](SLSA.md) (ALC evidence).
