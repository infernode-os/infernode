# Compliance Evidence Register — InferNode / NERVA

**Status:** Living document — started 2026-06-22
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

A standard is only "closed" (cookie earned) when its artifact is **Met** *and* the
evidence has been reviewed.

## Scorecard (roll-up — as of 2026-06-26)

| | Standard | Next step to advance |
|---|----------|----------------------|
| ✅ **Met** | SP 800-207 Zero Trust | — (formally verified) |
| ✅ **Met** | NIST PQC migration (hybrid) | — |
| ✅ **Met** | FIDO2 / CTAP2 (authenticator) | — |
| ✅ **Met** | SLSA Build L3 | SBOM now generated+validated in CI; release-attached SBOM + L4 (INFR-340) |
| ✅ **Met** | CNSA 2.0 (CNSA-strict mode) | — (ML-KEM-1024 + ML-DSA-87 under CNSA mode; default deployments classical by design) |
| ◐ **Substantially met** | X.509 / mTLS | client-cert over TLS (INFR-344) |
| ◐ **Partial** | SP 800-63B AAL3 | DK save-back + dual-key (EPIC 1) |
| ◐ **Partial** | SP 800-53 / 800-171 | per-control itemization (INFR-340); AU core now built |
| ○ **Readiness** | FIPS 140-3 | F1–F7 self-tests/approved-mode (INFR-342) |
| ◐ **Substantially met** | SP 800-92 audit log (AU) | built + evidenced; AU-4/5/6/7 + unsigned-tail (INFR-343/356) |

**Tally:** 5 Met · 2 Substantially met · 2 Partial · 1 Readiness.
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
| **NIST SP 800-92** tamper-evident audit log (AU) | [`SP800-92-audit-log.md`](SP800-92-audit-log.md) (evidence) · [design](SP800-92-audit-log-DESIGN.md) | 1 | **Substantially met** — built & evidenced; AU-3/8/9/9(3)/10 core met; AU-4/5/6/7 + unsigned-tail tracked |
| **NIST SP 800-53 / 800-171** control mapping | [`SP800-53-171-mapping.md`](SP800-53-171-mapping.md) + [per-control AC/IA/SC/AU](SP800-53-controls.md) | 1 | Partial — family map + AC/IA/SC/AU itemized; 6 families strong; CMMC L2 subset identified |
| **FIPS 140-3** readiness | [`FIPS-140-3-readiness.md`](FIPS-140-3-readiness.md) | 2 | Readiness/gap analysis — favorable architecture; 7 gaps (F1–F7) backlogged; not validated |
| **Common Criteria** (ISO 15408) readiness | [`Common-Criteria-readiness.md`](Common-Criteria-readiness.md) | 2 | Readiness/gap analysis — small TCB + formally-verified isolation favor a Separation Kernel PP; not evaluated |
| **NIST PQC migration** (hybrid) | [`NIST-PQC-migration.md`](NIST-PQC-migration.md) | 1 | **Met** — hybrid on TLS + native transport, adversarially tested |
| **FIDO2 / CTAP2** | [`FIDO2-CTAP2.md`](FIDO2-CTAP2.md) | 0→1 | **Met** (authenticator; WebAuthn web-flow is a documented non-goal) |
| **SLSA** | [`SLSA.md`](SLSA.md) | 0→1 | **Met at Build L3**; L4 + SBOM open (INFR-340) |
| **X.509 / mTLS** transport | [`X509-mTLS.md`](X509-mTLS.md) | 0 | Substantially met — server-auth TLS + CRL + native mutual auth; **mutual *TLS* client-cert open (INFR-344)** |

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
