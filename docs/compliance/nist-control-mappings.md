# InferNode — NIST SP 800-53 / SP 800-171 Platform Control Mapping (self-produced)

**Standards:** NIST SP 800-53 Rev 5 (control catalogue) and NIST SP 800-171 Rev 2
(protection of Controlled Unclassified Information; CMMC Level 2 basis).
**Scope:** *platform-layer* mapping — what the InferNode runtime provides. Organizational
and process controls are marked as integrator responsibility.
**Date:** 2026-07-09.
**Companion:** [`common-criteria-security-target.md`](common-criteria-security-target.md)
(the CC SFR crosswalk column points into it).

---

## 0. Status and honesty statement (read first)

> **This is a self-assessment, not an accredited authorization.** It is **not** an ATO, **not**
> a 3PAO/CMMC assessment, and **not** a FedRAMP package. The cryptographic module is **not**
> FIPS 140-2/140-3 CMVP validated and its algorithms are **not** CAVP validated. Where a row
> says a control is satisfied **by construction**, that means the property is structural in the
> platform and evidenced by code/test/formal-verification — it does **not** mean an assessor
> has verified it. Controls that depend on deployment or organizational process are marked
> **configurable / integrator** and are *not* claimed as met by the product alone. Anything
> that could not be confirmed from the repository is marked **needs confirmation**.

This document adds **per-control** granularity for the platform-layer families and an explicit
**SP 800-171 Rev 2** requirement mapping. It is consistent with, and cites, the family-level
pass in [`SP800-53-171-mapping.md`](SP800-53-171-mapping.md)
and the four-family itemization in
[`SP800-53-controls.md`](SP800-53-controls.md).

### How to read the "Satisfaction basis" column

| Value | Meaning |
|-------|---------|
| **By construction** | Structural platform property; no bypass path. Evidenced by code + test + (often) formal verification. |
| **Configurable** | The platform provides the mechanism; the integrator must enable/deploy it (e.g. bind `auditfs`, enable CNSA mode). |
| **Partial** | Mechanism present but an honest gap remains (named in Notes). |
| **N/A** | Not applicable to a platform of this type, or no applicable artifact. |
| **Integrator** | Organizational/process control; platform gives supporting technical evidence only. |

---

## 1. Access Control (AC) — SP 800-53 / 800-171 §3.1

| Control | Requirement (paraphrase) | How InferNode satisfies it | Satisfaction basis | Evidence path | CC SFR crosswalk | Notes |
|---------|--------------------------|-----------------------------|--------------------|---------------|------------------|-------|
| **AC-3** / 3.1.1–3.1.2 | Enforce approved authorizations for access to resources | Per-process namespace **is** the capability set; a name not bound cannot be expressed. Single mediation path (`namec`). | By construction | `emu/port/chan.c`; `SP800-207-zero-trust.md` | FDP_ACC.2, FDP_ACF.1 | Enforcement is structural, not a checkpoint |
| **AC-4** / 3.1.3 | Control information flow between domains | Namespace boundaries mediate flow; cross-domain *guarded* transfer not yet built | Partial | `emu/port/pgrp.c`; `SP800-53-controls.md` (AC-4) | FDP_IFC.1, FDP_IFF.1 | CDS guard is roadmap (EPIC 5) — **non-compliance gap (F-7)** |
| **AC-5** / 3.1.4 | Separation of duties | Distinct capability sets + distinct factotum identities per subject | Partial | `SP800-53-controls.md` (AC-5) | FMT_SMR.1 | Enforcement partly operator process |
| **AC-6** / 3.1.5 | Least privilege | Capability attenuation (child ⊆ parent, structural); default-deny bind-replace; `NODEVS` device gate | By construction | `emu/port/pgrp.c` (`nodevs`); `tests/veltro_security_test.b` | FDP_ACF.1, FMT_MSA.3 | Attenuation covered by isolation proof |
| **AC-6(9)** / 3.1.7 | Audit use of privileged functions | Audit log records privileged credential ops (factotum keyadd/keydel, 2fa enroll/disable) | Configurable | `SP800-92-audit-log.md` | FAU_GEN.1 | Broader privileged-op coverage pending — **gap (F-4)** |
| **AC-25** | Reference monitor: tamper-proof, small, verifiable | 9P/Styx single mediation chokepoint; isolation **formally verified** (TLA+/SPIN/CBMC) | By construction (assurance-backed) | `formal-verification/` | FDP_IFF.1, FPT_SEP.1 (informative) | Residual: emu-host races (F-1) qualify "tamper-proof" |
| **AC-2** / 3.1.1 | Account management | Factotum + secstore accounts; lifecycle partly process | Partial / Integrator | `module/factotum.m` | FIA_UID.2 | Lifecycle is operator process |

## 2. Audit & Accountability (AU) — SP 800-53 / 800-171 §3.3

| Control | Requirement (paraphrase) | How InferNode satisfies it | Satisfaction basis | Evidence path | CC SFR crosswalk | Notes |
|---------|--------------------------|-----------------------------|--------------------|---------------|------------------|-------|
| **AU-2** / 3.3.1 | Log defined events | `auditfs` service + auth/identity/credential emitters | Configurable | `appl/cmd/auditfs.b`; `SP800-92-audit-log.md` §2 | FAU_GEN.1 | Must be bound into namespace to record |
| **AU-3** / 3.3.1 | Sufficient record content | Record `seq time source event hash msg`; server-assigned seq+time | By construction | `appl/cmd/auditfs.b` (`appendrec`) | FAU_GEN.1/.2 | |
| **AU-6** / 3.3.5 | Review/analysis/reporting | Offline verifier; correlation tooling limited | Partial | `appl/cmd/auditverify.b` | FAU_SAR.1 | AU-4/5/6/7 tooling open — **gap (F-4)** |
| **AU-8** / 3.3.7 | Trustworthy timestamps | Server assigns `daytime->now()` at seal; writer cannot backdate | By construction | `appl/cmd/auditfs.b` | FAU_GEN.1 | AU-8(1) authoritative time-source open |
| **AU-9** / 3.3.8 | Protect audit info from tampering | SHA-256 hash chain + namespace ACL + external anchor | By construction (cryptographic) | `appl/lib/auditchain.b`; `tests/auditchain_test.b` | FAU_STG.2 | Tamper/reorder/delete detectable |
| **AU-9(3)** | Cryptographic protection of audit info | Hash chain + signed checkpoints | By construction | `SP800-92-audit-log.md` | FAU_STG.2 | |
| **AU-10** / 3.3.x | Non-repudiation | Keyring-signed checkpoints; `auditverify -k pubkey` offline | Partial | `appl/cmd/auditverify.b` | FAU_STG.2, FAU_SAR.1 | Unsigned-tail window; factotum-held key — **gap (F-5)** (INFR-356) |
| **AU-12** / 3.3.1 | Record generation across components | Emitters at auth/identity/credential chokepoints | Partial | `appl/lib/audit.b` | FAU_GEN.1 | CDS/veltro emitters pending (INFR-355) |

## 3. Identification & Authentication (IA) — SP 800-53 / 800-171 §3.5

| Control | Requirement (paraphrase) | How InferNode satisfies it | Satisfaction basis | Evidence path | CC SFR crosswalk | Notes |
|---------|--------------------------|-----------------------------|--------------------|---------------|------------------|-------|
| **IA-2** / 3.5.1 | Uniquely identify & authenticate users | Factotum + secstore login; native STS mutual auth | Configurable | `module/factotum.m`; `SP800-63B-AAL3.md` | FIA_UID.2, FIA_UAU.2 | |
| **IA-2(1)** / 3.5.3 | MFA to privileged accounts | FIDO2 hardware key + user verification (PIN) gating secstore unlock — AAL3 | Configurable | `SP800-63B-AAL3.md`; `FIDO2-CTAP2.md` | FIA_UAU.5, FTP_TRP.1 | AAL3 verifier shipped |
| **IA-2(8)** / 3.5.4 | Replay-resistant authentication | Challenge-response (`hmac-secret`); STS transcript binding | Configurable | `tests/pqauth_test.b` | FIA_UAU.6 | |
| **IA-5** / 3.5.2 | Authenticator management | DK-wrapped secstore slots; recovery slot; never-brick enroll | Partial | `SP800-63B-AAL3.md` §4 | FIA_AFL.1 | Dual-key-by-default / DK save-back open (EPIC 1) |
| **IA-5(2)** | PKI-based auth incl. revocation | X.509 path validation + CRL; PQ-capable certs | Configurable | `appl/lib/crypt/x509.b`; `X509-mTLS.md` | FIA_UAU.1(PKI) | |
| **IA-7** / 3.5.x | Crypto module authentication | Approved algorithms in use; **module not FIPS-validated** | Partial | see SC-13 | FCS_COP.1(SIG) | **gap (F-2)** |
| **AC-7 / IA-5** lockout | Limit consecutive invalid logon attempts | **`secstored` throttles online guessing**: 10 consecutive wrong-password attempts → 60s per-account lock, rejected before any crypto, counter reset on success. FIDO2 UV/PIN factor is separately hardware-locked (8 lifetime tries). | By construction (threshold tunable) | `appl/cmd/auth/secstored.b` (`recordfail`/`lockremaining`/`notefail`); `tests/host/secstore_lockout_test.sh` | FIA_AFL.1 | Resolves former gap F-6 (INFR-372). Temporary cooldown, never bricks the boot store |

## 4. System & Communications Protection (SC) — SP 800-53 / 800-171 §3.13

| Control | Requirement (paraphrase) | How InferNode satisfies it | Satisfaction basis | Evidence path | CC SFR crosswalk | Notes |
|---------|--------------------------|-----------------------------|--------------------|---------------|------------------|-------|
| **SC-7** / 3.13.1 | Boundary protection | Namespace boundaries + 9P as the one mediated interface; `NODEVS` gate | By construction | `emu/port/chan.c`; `SP800-53-controls.md` (SC-7) | FDP_ACF.1, FTP_ITC.1 | |
| **SC-8** / 3.13.8 | Transmission confidentiality & integrity | TLS 1.2/1.3 (AES-256-GCM); native STS line encryption | Configurable | `appl/lib/crypt/tls.b`; `X509-mTLS.md` | FTP_ITC.1 | Client-cert mTLS open (INFR-344) |
| **SC-8(1)** | Cryptographic protection in transit | AEAD ciphers; hybrid PQC key exchange | Configurable | `appl/lib/crypt/tls.b` | FCS_COP.1(SYM), FCS_CKM.2 | |
| **SC-12** / 3.13.10 | Key establishment & management | Hybrid X25519+ML-KEM (TLS), DH+ML-KEM (native); SecP384r1MLKEM1024 under CNSA | Configurable | `appl/lib/crypt/tls.b` (`0x11ED`); `CNSA-2.0.md` | FCS_CKM.1/.2 | Default classical; CNSA mode off by default |
| **SC-13** / 3.13.11 | FIPS-validated cryptography | Approved algorithms present (AES-256, SHA-384/512, FIPS 203/204/205) — **module not FIPS-validated** | Partial | `CNSA-2.0.md`; `FIPS-140-3-readiness.md` | FCS_COP.1(*) | **gap (F-2)**: algorithms ✅ / validated module ☐ |
| **SC-13 (KAT/ACVP)** | Algorithm correctness validation | SHA-3: **NIST FIPS 202 KATs**. ML-KEM/ML-DSA/SLH-DSA: functional + constant-time CBMC harnesses only | Partial | `tests/sha3_test.b`; `formal-verification/cbmc/harness_mlkem_ct.c`, `harness_mldsa_ct.c` | FCS_COP.1(KEM/SIG) | **gap (F-3)**: no ACVP KAT for lattice/hash-DSA; **pending external cryptographic audit** |
| **SC-23** | Session authenticity | TLS/STS session keys; transcript binding rejects MITM | Configurable | `tests/pqauth_test.b` (*TamperedEkRejected*) | FTP_ITC.1 | |
| **SC-28** / 3.13.16 | Protection of information at rest | AES-256-GCM secstore vault, DK-wrapped, factor-gated | Configurable | `SP800-63B-AAL3.md` §1 | FDP_RIP.1 | |
| **SC-39** | Process isolation | Per-process namespaces; Dis VM memory/type safety | By construction | `emu/port/pgrp.c`; `libinterp/` | FPT_SEP.1 (informative) | Residual: emu-host races (F-1) |

## 5. System & Information Integrity (SI) — SP 800-53 / 800-171 §3.14

| Control | Requirement (paraphrase) | How InferNode satisfies it | Satisfaction basis | Evidence path | CC SFR crosswalk | Notes |
|---------|--------------------------|-----------------------------|--------------------|---------------|------------------|-------|
| **SI-2** / 3.14.1 | Flaw remediation | CodeQL + fuzzing in CI; formal verification; security-advisory process | Configurable / Integrator | `.github/workflows/security.yml`, `fuzz.yml`; `SECURITY.md` | FPT_TST | Remediation SLA is operator process |
| **SI-3** / 3.14.2 | Malicious-code protection | Application layer is type-/memory-safe Dis bytecode; modules type-checked at load | By construction | `libinterp/`; `CLAUDE.md` (link typecheck) | FPT_TDC.1 | Eliminates whole CWE classes for ~700 Limbo apps |
| **SI-7** / 3.14.x | Software/firmware/information integrity | `.dis` path-integrity verifier; tracked `dis/` tree; hash-chained audit | By construction | `.github/workflows/verify-dis-paths.yml`; `tools/verify-dis-paths.sh` | FPT_TST | |
| **SI-16** | Memory protection | No raw pointers; bounds-checked arrays in Dis VM | By construction | `libinterp/` | FPT_TDC.1 | C TCB (emu/libsec) is *not* memory-safe — covered by CodeQL/fuzz/formal only |
| **SI (TCB race residual)** | Integrity of the TSF itself | Namespace primitives formally verified; **3 emu-host UAF races open** | Partial | `formal-verification/TODO-RACE-CONDITIONS.md` | FPT_SEP.1 | **gap (F-1)** — formally confirmed defects |

## 6. Configuration Management (CM) — SP 800-53 / 800-171 §3.4

| Control | Requirement (paraphrase) | How InferNode satisfies it | Satisfaction basis | Evidence path | CC SFR crosswalk | Notes |
|---------|--------------------------|-----------------------------|--------------------|---------------|------------------|-------|
| **CM-2** / 3.4.1 | Baseline configuration | Reproducible Inferno-`mk` builds; tracked `dis/` runtime tree | By construction | `CLAUDE.md` ("Why Native Tools") | ALC (Part 3) | |
| **CM-5** | Access restrictions for change | Pre-commit + CI verifiers gate commits/PRs | Configurable | `hooks/`, `.github/workflows/verify-dis-paths.yml` | ALC | |
| **CM-6** / 3.4.2 | Configuration settings | CNSA mode (`/env/cnsamode`), `NODEVS`, export scope are explicit settings | Configurable | `appl/lib/crypt/tls.b` (`cnsamode`); `CNSA-2.0.md` | FMT_SMF.1 | Secure settings are opt-in — integrator must set |
| **CM-7** / 3.4.6–3.4.7 | Least functionality | Small TCB; `NODEVS`; compose only needed file services; ring-fence guard keeps test-only harness out of releases | By construction | `CLAUDE.md` (Ring-fence rule); `.github/workflows/ci.yml`, `release.yml` | FMT_MSA.3 | |
| **CM-14 / SR** | Signed components / provenance | SHA-pinned CI actions; Sigstore cosign; SLSA provenance; SBOM | By construction | `.github/workflows/release.yml`, `scorecard.yml`, `sbom.yml` | ALC / (SR family) | See §7 |

## 7. Supply Chain (SR) & Assessment (CA) — supporting the platform posture

| Control | Requirement (paraphrase) | How InferNode satisfies it | Satisfaction basis | Evidence path | CC SFR crosswalk | Notes |
|---------|--------------------------|-----------------------------|--------------------|---------------|------------------|-------|
| **SR-3/4** | Supply-chain controls; provenance | SHA-256 sums, Sigstore cosign keyless signatures, SLSA build-provenance attestations, SPDX SBOM, OpenSSF Scorecard + Best-Practices badge | By construction | `.github/workflows/release.yml` (cosign, attest-build-provenance, sbom); `scorecard.yml`; `README.md` badges | ALC_DEL/CMC | SLSA-3 evidenced by provenance attestations |
| **SR-11** | Component authenticity | Cosign `verify-blob` against build OIDC identity | Configurable | `release.yml` (verification instructions) | ALC_DEL | Verification is operator step |
| **CA-2/7** | Assessment & continuous monitoring | Formal verification + CodeQL + Scorecard + fuzz run continuously in CI | By construction (technical) / Integrator | `.github/workflows/{formal-verification,security,scorecard,fuzz}.yml` | AVA/ATE (Part 3) | Assessment *process* is operator |

---

## 8. SP 800-171 Rev 2 — platform-layer support summary

SP 800-171 Rev 2 has 110 requirements across 14 families. InferNode carries the **technical**
weight of six families strongly; the remainder are integrator responsibility with platform
support noted. This mirrors and refines
[`SP800-53-171-mapping.md`](SP800-53-171-mapping.md) §3.

| 800-171 family | Platform contribution | Basis | Residual for integrator |
|----------------|-----------------------|-------|--------------------------|
| **3.1 Access Control** | Namespace = capability; least privilege by construction | By construction | Account lifecycle, SoD policy, CDS (F-7) |
| **3.3 Audit & Accountability** | Tamper-evident hash-chained `auditfs` | Configurable + by construction | Bind service; AU-4/5/6/7 tooling (F-4); non-repudiation hardening (F-5) |
| **3.4 Configuration Management** | Reproducible builds, `.dis` integrity, pinned actions, ring-fence | By construction | Org CM policy; enable secure settings |
| **3.5 Identification & Authentication** | Factotum; FIDO2 AAL3; PKI+CRL; **failed-attempt lockout** (`secstored`) | Configurable | Deploy MFA |
| **3.13 System & Comms Protection** | Namespace boundary; approved + hybrid-PQC crypto; AES-256 at rest | Configurable + by construction | Enable CNSA mode; **FIPS validation (F-2)**; ACVP (F-3); mTLS |
| **3.14 System & Information Integrity** | Type-/memory-safe Dis VM; CI scanning; formal verification | By construction | Flaw-remediation SLA; TCB race fix (F-1) |
| 3.2 Awareness/Training, 3.6 Incident Response, 3.7 Maintenance, 3.8 Media Protection, 3.9 Personnel, 3.10 Physical, 3.11 Risk, 3.12 Assessment | Supporting evidence only (signed updates, audit evidence, hardware auth) | Integrator | Organizational controls |

---

## 9. Consolidated non-compliance / open-gap register

The rows above flag every honest gap. Consolidated for tracking (see the companion ticketing
action). **None of these is presented as met.**

| ID | Gap | Affected controls | Type | Existing tracking |
|----|-----|-------------------|------|-------------------|
| **F-1** | Three formally-confirmed use-after-free races in the `emu` host-threading layer (`kchdir`, FORKNS swap, `namec`) | AC-25, SC-39, SI (TSF integrity) | Defect (TSF) | `formal-verification/TODO-RACE-CONDITIONS.md` — **no Jira ticket found** |
| **F-2** | Cryptographic module not FIPS 140-2/140-3 CMVP validated | SC-13, IA-7 | Validation | `FIPS-140-3-readiness.md` (readiness only) |
| **F-3** | No NIST ACVP/CAVP known-answer validation for ML-KEM/ML-DSA/SLH-DSA (round-trip + CBMC only); pending external cryptographic audit | SC-13 (KAT/ACVP) | Validation / assurance | **no dedicated ticket found** |
| **F-4** | AU-4/5/6/7 operational tooling and broad privileged-op coverage incomplete | AU-6, AC-6(9), AU-12 | Coverage | INFR-343 (partial) |
| **F-5** | Audit non-repudiation: unsigned-tail window + factotum-held signing key | AU-10 | Hardening | INFR-356 |
| **F-6** ✅ | ~~Authentication lockout thresholds unconfirmed~~ → **Resolved**: `secstored` enforces a 10-attempt / 60s per-account lockout on the password verifier | AC-7, IA-5, FIA_AFL.1 | **Resolved** | INFR-372 — `appl/cmd/auth/secstored.b`; `tests/host/secstore_lockout_test.sh` |
| **F-7** | No cross-domain guarded transfer (information-flow guard) | AC-4 | Feature gap | EPIC 5 (planned) |

---

## 10. References

- NIST SP 800-53 Rev 5; NIST SP 800-171 Rev 2; CMMC 2.0 Level 2.
- Sibling artifacts: [`SP800-53-171-mapping.md`](SP800-53-171-mapping.md),
  [`SP800-53-controls.md`](SP800-53-controls.md),
  [`CNSA-2.0.md`](CNSA-2.0.md),
  [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md),
  [`SP800-92-audit-log.md`](SP800-92-audit-log.md),
  [`FIPS-140-3-readiness.md`](FIPS-140-3-readiness.md).
- In-tree evidence cited inline (`emu/port/`, `libsec/`, `libinterp/`, `appl/`, `tests/`,
  `formal-verification/`, `.github/workflows/`).
- Companion: [`common-criteria-security-target.md`](common-criteria-security-target.md).
