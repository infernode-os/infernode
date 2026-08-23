# Compliance Evidence Register — InferNode

**Status:** Living document — started 2026-06-22; roll-up last reviewed 2026-08-23
**Owner:** Security & Compliance program — Jira epic **INFR-328** (roadmap: [`../security-standards-roadmap.md`](../security-standards-roadmap.md))
**Audience:** CISO / accreditor / procurement (evidence), and engineering (backlog).

This directory holds **per-standard evidence artifacts**. Each artifact is written to
the bar an accreditor would accept: for every claim it states *requirement →
mechanism → evidence (file:line, test, commit) → residual gap → status*. Claims are
cited to source so they can be independently verified against the tree; nothing here is
asserted without a pointer.

The companion documents are:

- [`../security-standards-roadmap.md`](../security-standards-roadmap.md) — the
  aspirational standards list and the Inferno-native mechanism for each.
- [`../security-epics.md`](../security-epics.md) — the same, decomposed into Jira epics.

This register is the *evidence* side of those two; the roadmap is the *intent* side.

## How to read a status

| Status | Meaning |
|--------|---------|
| **Met** | Requirement satisfied today; evidence supplied; no open gap. |
| **Substantially met** | Core mechanism in place and evidenced; one or more bounded gaps tracked in Jira. |
| **Partial** | Some required elements present; material work remains. |
| **Planned** | On the backlog, not yet implemented. |
| **Mapping** | A mechanism-to-requirement mapping where conformity belongs to the deployed system and its organization, not to the platform. The artifact evidences what the platform contributes; it claims no status against the framework. |

A standard is only "closed" (cookie earned) when its artifact is **Met** *and* the
evidence has been reviewed.

## Scorecard (roll-up — as of 2026-08-23)

| | Standard | Next step to advance |
|---|----------|----------------------|
| ✅ **Met** | SP 800-207 Zero Trust | — (formally verified) |
| ✅ **Met** | NIST PQC migration (hybrid) | — |
| ✅ **Met** | FIDO2 / CTAP2 (authenticator) | — |
| ✅ **Met** | SLSA Build L3 | SBOM done (CI-validated *and* release-attached, checksummed + cosign-signed); remaining: `attest-sbom` provenance link + hermetic/reproducible L4 (INFR-340) |
| ✅ **Met** | CNSA 2.0 (CNSA-strict mode) | — (ML-KEM-1024 + ML-DSA-87 under CNSA mode; default deployments classical by design) |
| ◐ **Substantially met** | X.509 / mTLS | client-cert over TLS (INFR-344) |
| ◐ **Partial** | SP 800-63B AAL3 | DK save-back + dual-key (EPIC 1) |
| ◐ **Partial** | SP 800-53 / 800-171 | itemize the families beyond AC/IA/SC/AU (INFR-340). Since the last roll-up: AC-7 lockout **Met** (#368), `nsaudit` runs as a per-PR gate (#391), and ~100 namespace-hardening fixes strengthen AC/SC |
| ○ **Readiness** | FIPS 140-3 | F1–F7 self-tests/approved-mode (INFR-342) — no movement since the last roll-up |
| ◐ **Substantially met** | SP 800-92 audit log (AU) | INFR-343 + INFR-356 **delivered** (strict verification, off-host anchoring, self-driving checkpoint cadence, factotum-held signing); AU-12 extended to agent provenance (INFR-355). Remaining: AU-4 capacity/alerting, AU-6/7 review tooling, AU-8(1) trusted time |
| ▣ **Mapping** | AI governance (EU AI Act Art. 12, NIST AI RMF, ISO/IEC 42001) | mechanism built (INFR-355); conformity is a property of the deployed system, so no platform status is claimed |

**Tally:** 5 Met · 2 Substantially met · 2 Partial · 1 Readiness · 1 mapping artifact.
**Evidence-only close-outs are exhausted** — every remaining advance needs code (tracked
under epic [INFR-328]) or an external assessor (Common Criteria evaluation; SOC 2 / CMMC
audits). Standards still purely on the roadmap (no artifact yet): MLS, CDS guard,
PCI-DSS, HSM/PKCS#11/KMIP, FIPS 201 PIV, measured boot/TPM-DICE, ISO 20022/SWIFT, SOC 2,
Common Criteria — all code- or assessor-gated.

## Evidence index

| Standard | Artifact | Tier | Status |
|----------|----------|------|--------|
| **CNSA 2.0** (NSA quantum-resistant suite) | [`CNSA-2.0.md`](CNSA-2.0.md) | 1 | **Met (CNSA-strict mode)** — ML-KEM-1024 + ML-DSA-87 negotiated/default under CNSA mode (G1/G2 closed); G3 Not Applicable. Default deployments classical by design |
| **NIST SP 800-207** Zero Trust | [`SP800-207-zero-trust.md`](SP800-207-zero-trust.md) | 0 | **Met** (architectural posture; formally verified) |
| **NIST SP 800-63B AAL3** | [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md) | 1 | Partial — AAL3 verifier shipped & hardware-verified; EPIC 1 remainder open |
| **NIST SP 800-92** tamper-evident audit log (AU) | [`SP800-92-audit-log.md`](SP800-92-audit-log.md) (evidence) · [design](audit-log-design.md) | 1 | **Substantially met** — AU-3/8/9/9(3)/10 core met; signing key held by factotum (INFR-356 closed); AU-12 covers the veltro agent trajectory (INFR-355). Residual: AU-4 capacity/alerting, AU-6/7 review, AU-8(1) time, bounded unsigned tail |
| **NIST SP 800-53 / 800-171** control mapping | [`SP800-53-171-mapping.md`](SP800-53-171-mapping.md) + [per-control AC/IA/SC/AU](SP800-53-controls.md) + [platform mapping](nist-control-mappings.md) | 1 | Partial — family map + AC/IA/SC/AU itemized; 6 families strong; CMMC L2 subset identified. AC-7 lockout Met (#368) |
| **FIPS 140-3** readiness | [`FIPS-140-3-readiness.md`](FIPS-140-3-readiness.md) | 2 | Readiness/gap analysis — favorable architecture; 7 gaps (F1–F7) backlogged; not validated |
| **Common Criteria** (ISO 15408) readiness | [`Common-Criteria-readiness.md`](Common-Criteria-readiness.md) + [security target](common-criteria-security-target.md) | 2 | Readiness/gap analysis + SFR crosswalk — small TCB + formally-verified isolation favor a Separation Kernel PP; not evaluated |
| **NIST PQC migration** (hybrid) | [`NIST-PQC-migration.md`](NIST-PQC-migration.md) | 1 | **Met** — hybrid on TLS + native transport, adversarially tested |
| **FIDO2 / CTAP2** | [`FIDO2-CTAP2.md`](FIDO2-CTAP2.md) | 0→1 | **Met** (authenticator; WebAuthn web-flow is a documented non-goal) |
| **SLSA** | [`SLSA.md`](SLSA.md) | 0→1 | **Met at Build L3**; SBOM shipped (CI + release-attached). `attest-sbom` + hermetic/reproducible L4 open (INFR-340) |
| **X.509 / mTLS** transport | [`X509-mTLS.md`](X509-mTLS.md) | 0 | Substantially met — server-auth TLS + CRL + native mutual auth; **mutual *TLS* client-cert open (INFR-344)** |
| **AI governance** (EU AI Act Art. 12/13/14, NIST AI RMF 1.0, ISO/IEC 42001) | [`ai-governance.md`](ai-governance.md) | 1 | Mechanism-to-requirement mapping — agent provenance (INFR-355) is the record-keeping substrate; no conformity claimed, since that is a property of the deployed system and its organization |

New artifacts are added a row at a time as each standard is worked. The index never
claims a status the artifact itself does not support.

## Evidence conventions

- **Cite to source.** Use `path:line` or `path` + symbol so a reviewer can `grep` it.
- **Cite the test, not just the code.** A control with a passing regression test is
  stronger evidence than code alone. Test files live under [`../../tests/`](../../tests).
- **Be honest about gaps.** A documented residual gap with a tracking ticket is
  acceptable to an accreditor; a silent overstatement is not. Every gap names its
  Jira key.
- **No new attack surface for evidence.** Evidence artifacts are documentation. Where a
  gap requires code, that work is scoped and tracked separately, reviewed on its own
  merits — consistent with the project's austerity (more code, more bugs).
