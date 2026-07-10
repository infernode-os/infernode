# Compliance Evidence — FIPS 140-3 Readiness (Cryptographic Module)

**Standard:** FIPS 140-3 (ISO/IEC 19790:2012) — Security Requirements for Cryptographic
Modules.
**Roadmap row:** Cryptographic foundation — FIPS 140-3, Tier 2 ("Consolidate all crypto
behind `libsec`/`keyring` as the single validated surface").
**Tracking:** EPIC 6 — FIPS 140-3 readiness ([`../security-epics.md`](../security-epics.md)); program epic [INFR-328].
**Artifact date:** 2026-06-22.
**Overall status:** **Readiness / gap analysis — not validated (Tier 2).** This is an honest
pre-validation assessment, not a compliance claim. FIPS 140-3 validation is an expensive,
lab-driven (CMVP/CAVP) process; this artifact records what already favors validation and the
concrete gaps a module would have to close first. It is the document an accreditor uses to
decide whether to fund a validation effort.

---

## 1. Why the architecture is favorable

FIPS 140-3 validates a **defined cryptographic module boundary**. InferNode already has the
hard part right: **all cryptographic primitives live in one place — `libsec`** (with
`libkeyring` SigAlgVec wrappers and the `libinterp/keyring.c` bridge). There is no scattered,
re-implemented crypto to corral. The roadmap's plan — "make `libsec`/`keyring` the single
validated surface" — is therefore a *consolidation-and-instrumentation* job, not a rewrite.

| FIPS 140-3 expectation | Current state | Evidence |
|------------------------|---------------|----------|
| Single, well-defined module boundary | All primitives in `libsec/`; one Keyring bridge | `libsec/`; `docs/CRYPTO-MODERNIZATION.md` §Architecture |
| Approved algorithms available | AES-256-GCM, SHA-2 (256/384/512), SHA-3/SHAKE, ML-KEM, ML-DSA, SLH-DSA, HMAC | [`CNSA-2.0.md`](CNSA-2.0.md) |
| Known-answer test material exists | NIST KAT vectors implemented as test suites | `tests/{mlkem,mldsa,slhdsa,sha3}_test.b`, `tests/tls_crypto_test.b` |
| Sensitive-data zeroization | `secureZero()` clears key material / intermediates | `libsec/mlkem.c:174,277,385,400,435-437` (and PQC primitives per `docs/QUANTUM-SAFE-CRYPTO-PLAN.md` §5) |
| Memory-safe callers | Dis VM applications cannot corrupt module memory | `doc/dis.ms`; [`SP800-53-171-mapping.md`](SP800-53-171-mapping.md) §5.SI |
| Small, analyzable TCB | Formal verification of adjacent kernel primitives | `formal-verification/` |

## 2. Gaps to validation (the honest list)

These are the items a CMVP submission would require that **do not exist today**. None is a
defect in the shipping crypto — they are *module-instrumentation* requirements of the
standard.

| # | FIPS 140-3 requirement | Gap | Notes / effort |
|---|------------------------|-----|----------------|
| **F1** | **Pre-operational (power-on) self-tests** — module runs KATs on its own approved algorithms before first use, and fails closed | KATs exist only as the Limbo *test suite* (run at test time), **not** as in-module self-tests executed at startup | New code in `libsec`/keyring init: run a fixed KAT per approved algorithm, refuse to operate on failure. *Bring design first (touches crypto init path).* |
| **F2** | **Conditional self-tests** — pairwise consistency on keygen (sign/verify, encaps/decaps); CRNG continuous health test | Not implemented as module self-tests | Add PCT on `gensk`/keygen paths; RNG health test (§F4). |
| **F3** | **Approved mode of operation** — module exposes/enforces an approved-only mode; non-approved algos (DES, RC4, MD5, SHA-1-for-signing) disabled or clearly outside the boundary | No `approved-mode` flag; legacy algos (3DES/IDEA in `ssl3.b`, DES in `keyring.c`) still reachable | Gate legacy algorithms behind a mode flag; document the boundary. (DES CodeQL dispositions already tracked: INFR-316.) |
| **F4** | **SP 800-90A/B DRBG + entropy** — approved DRBG with documented entropy source and health tests | RNG is `genrandom`/`prng` (`include/libsec.h:486-489`); not documented as an SP 800-90A DRBG with 90B entropy assessment | Document/￼align the DRBG; entropy-source analysis. See `docs/TLS-ENTROPY.md` for prior entropy work. |
| **F5** | **Module spec & security policy documents** — finite-state model, ports/interfaces, roles/services, SSP | Not authored | Documentation deliverables for the CMVP package. |
| **F6** | **CAVP algorithm certificates** — each approved algorithm independently CAVP-tested | Not obtained | Run the CAVP test harness against `libsec` and submit. The existing KAT suites are the starting material. |
| **F7** | **Operational environment / integrity test** — module integrity self-check (e.g. signature/HMAC over the module image) at load | Build-time integrity exists (cosign, SLSA, `verify-dis-paths`) but no *runtime* module-integrity self-test | Add an integrity check at module init. |

## 3. What is already met (do not re-do)

- **Algorithm coverage** at FIPS 203/204/205/202/197/180 — see [`CNSA-2.0.md`](CNSA-2.0.md).
- **Zeroization** of key material and sensitive intermediates (`secureZero` in the PQC
  primitives) — a real FIPS 140-3 SSP requirement, already honored in the new crypto.
- **KAT material** — NIST vectors already encoded; F1/F6 *reuse* these rather than author new ones.
- **Constant-time discipline** — SHA-3 and the NTT/poly operations are constant-time by
  construction (no secret-dependent branching/indexing), reducing side-channel findings.

## 4. Recommended sequencing (when validation is funded)

This is Tier 2 (expensive); pursue only when an accreditor requires a validated module. When
funded, the lowest-risk order:

1. **F3 approved-mode boundary** (documentation + a gate) — defines *what* gets validated.
2. **F1/F2/F7 self-tests** — the code work; *design-first, flagged for review* (touches the
   crypto init path; **no JSON, minimal, in keeping with `libsec` C style**). Tracked code item.
3. **F4 DRBG/entropy** documentation + alignment.
4. **F5 module spec + security policy** authoring.
5. **F6 CAVP** runs and submission, then CMVP.

## 5. Disposition

FIPS 140-3 is **not claimed**. The architecture is unusually favorable (single `libsec`
boundary, approved algorithms present, zeroization done, KATs available, memory-safe callers,
small TCB), so the path is *instrumentation*, not redesign. The seven gaps (F1–F7) are the
funded-effort backlog. **Recommendation:** keep at Tier 2 until an accreditor requires it;
the highest-leverage early step is the approved-mode boundary (F3) plus power-on self-tests
(F1), the latter brought as a design before any code lands.

## 6. References

- FIPS 140-3; ISO/IEC 19790:2012; NIST SP 800-140x (FIPS 140-3 IG); SP 800-90A/B (DRBG/entropy).
- NIST CMVP / CAVP programs.
- In-tree: `libsec/`, `libkeyring/`, `libinterp/keyring.c`, `tests/*_test.b`,
  `docs/CRYPTO-MODERNIZATION.md`, `docs/TLS-ENTROPY.md`, [`CNSA-2.0.md`](CNSA-2.0.md).
