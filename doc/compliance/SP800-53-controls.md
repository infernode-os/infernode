# Compliance Evidence — SP 800-53 Rev 5 Per-Control Itemization (AC / IA / SC / AU)

**Standard:** NIST SP 800-53 Rev 5 (selected controls); maps to SP 800-171 / CMMC L2.
**Parent:** [`SP800-53-171-mapping.md`](SP800-53-171-mapping.md) (family-level). This file
drills the four technically load-bearing families to individual controls — the granularity
an SSP / CMMC L2 assessor works from.
**Tracking:** EPIC 4 / [INFR-340]; program epic [INFR-328].
**Artifact date:** 2026-06-22.
**Status convention:** Met · Substantially met · Partial · Planned · Operator (organizational).
Every "Met/Substantially" row points at code/test or an evidence artifact.

> Honesty notes carried forward: **SC-13** is *partial* because the algorithms are approved
> but the module is not yet FIPS-validated (Tier 2 — [`FIPS-140-3-readiness.md`](FIPS-140-3-readiness.md)).
> **AU** is largely *planned/partial* pending the audit-log service
> ([`SP800-92-audit-log-DESIGN.md`](SP800-92-audit-log-DESIGN.md)).

---

## AC — Access Control

| Control | Requirement (abridged) | Mechanism / evidence | Status |
|---------|------------------------|----------------------|--------|
| **AC-2** Account Management | Manage accounts/lifecycle | Factotum credential agent + secstore accounts; lifecycle is partly operator process | Partial |
| **AC-3** Access Enforcement | Enforce approved authorizations | **Per-process namespace = capability**: an unbound name cannot be expressed; enforcement is structural, not a checkpoint. [`SP800-207-zero-trust.md`](SP800-207-zero-trust.md) §2; `appl/veltro/nsconstruct.b` | **Met** |
| **AC-4** Information Flow Enforcement | Control information flows between domains | Namespace boundaries mediate flow today; cross-domain *guarded* transfer is the CDS guard (roadmap EPIC 5, planned) | Partial |
| **AC-5** Separation of Duties | Separate duties via access | Capability sets per agent; distinct factotum identities | Partial |
| **AC-6** Least Privilege | Grant least privilege | **Capability attenuation** (child caps ≤ parent, structural); default-deny bind-replace; `NODEVS` device gate. [`SP800-207-zero-trust.md`](SP800-207-zero-trust.md) §2; `tests/veltro_security_test.b` | **Met** |
| **AC-6(9)** Audit of Privileged Functions | Log privileged use | Ties to AU — `emitauditlog()` today; full coverage needs the audit-log service | Partial |
| **AC-25** Reference Monitor | Tamper-proof, small, verifiable mediator | 9P/Styx is the single mediation chokepoint; namespace isolation **formally verified** (TLA+ 3.17B states, SPIN, CBMC on real C). `formal-verification/` | **Met** (assurance-backed) |

## IA — Identification & Authentication

| Control | Requirement | Mechanism / evidence | Status |
|---------|-------------|----------------------|--------|
| **IA-2** Identify/Authenticate Org Users | Uniquely auth users | Factotum + secstore login; native STS mutual auth between nodes | **Met** |
| **IA-2(1)** MFA to Privileged Accounts | Multifactor | **FIDO2 hardware key + UV (PIN)** gating secstore unlock — AAL3. [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md) | **Met** |
| **IA-2(8)** Replay-Resistant Auth | Resist replay | Challenge-response (`hmac-secret`); STS handshake with transcript binding | **Met** |
| **IA-5** Authenticator Management | Manage authenticators | DK-wrapped secstore slots; recovery slot; never-brick enroll. Dual-key-by-default + DK save-back open (EPIC 1). [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md) §4 | Substantially met |
| **IA-5(2)** PKI-Based Auth | Validate certs incl. revocation | X.509 path validation + **CRL** (`appl/lib/crypt/x509.b:1896,1941`); PQ-capable certs | **Met** |
| **IA-7** Crypto Module Authentication | Use validated crypto for auth | Approved algorithms in use; module **not** FIPS-validated (see SC-13) | Partial |
| **IA-8** Identify/Authenticate Non-Org Users | — | Factotum protocols; largely deployment-specific | Partial |

## SC — System & Communications Protection

| Control | Requirement | Mechanism / evidence | Status |
|---------|-------------|----------------------|--------|
| **SC-7** Boundary Protection | Monitor/control at boundaries | Namespace boundaries + 9P as the one mediated interface; `NODEVS` device gate | **Met** |
| **SC-8** Transmission Confidentiality & Integrity | Protect data in transit | TLS 1.2/1.3 (AES-256-GCM); native STS line encryption. [`X509-mTLS.md`](X509-mTLS.md) | **Met** (server-auth; client-cert mTLS open — INFR-344) |
| **SC-8(1)** Cryptographic Protection | Crypto in transit | AEAD ciphers; hybrid PQC key exchange | **Met** |
| **SC-12** Crypto Key Establishment & Management | Establish/manage keys | **Hybrid X25519+ML-KEM** (TLS) and DH+ML-KEM (native). [`NIST-PQC-migration.md`](NIST-PQC-migration.md) | **Met** |
| **SC-13** Cryptographic Protection (approved/validated) | FIPS-validated crypto | Approved algorithms present (AES-256, SHA-384/512, FIPS 203/204/205 PQC) — but the module is **not FIPS-140-validated** yet. [`CNSA-2.0.md`](CNSA-2.0.md); [`FIPS-140-3-readiness.md`](FIPS-140-3-readiness.md) | Partial (algorithms ✅; validated module ☐) |
| **SC-23** Session Authenticity | Protect session authenticity | TLS/STS session keys; transcript binding rejects active MITM (`tests/pqauth_test.b` *TamperedEkRejected*) | **Met** |
| **SC-28** Protection of Information at Rest | Encrypt data at rest | **AES-256-GCM** secstore vault, DK-wrapped, factor-gated. [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md) §1; `doc/yubikey-2fa-operations.md` §9 | **Met** |
| **SC-39** Process Isolation | Isolate processes | Per-process namespaces; Dis VM memory/type safety | **Met** |

## AU — Audit & Accountability

| Control | Requirement | Mechanism / evidence | Status |
|---------|-------------|----------------------|--------|
| **AU-2** Event Logging | Log defined events | Per-subsystem today (`emitauditlog()`, subagent trajectory logs); central event set pending the audit service | Partial |
| **AU-3** Content of Audit Records | Sufficient record content | Defined by the audit-log record format (seq/time/source/event). [`SP800-92-audit-log-DESIGN.md`](SP800-92-audit-log-DESIGN.md) §4 | Planned |
| **AU-9** Protection of Audit Information | Protect logs from tampering | **Designed**: hash-chained append-only 9P service, externally anchorable. [`SP800-92-audit-log-DESIGN.md`](SP800-92-audit-log-DESIGN.md) | Planned (design ready; INFR-343) |
| **AU-12** Audit Record Generation | Generate records across components | Subsystem wiring to the audit service (login/factotum/CDS/veltro) | Planned |

---

## Disposition

- **Strong, evidenced today:** AC-3, AC-6, AC-25, IA-2/2(1)/2(8)/5(2), SC-7, SC-8(1), SC-12,
  SC-23, SC-28, SC-39 — these are the hard-to-fake controls a generic OS cannot evidence as
  cleanly (namespace = capability; formally verified isolation; hybrid-PQC transport;
  AAL3 hardware auth; AES-256 at rest).
- **Honest partials:** SC-13 (validated module — Tier 2 FIPS work), IA-5 (dual-key/DK
  save-back — EPIC 1), SC-8 (client-cert mTLS — INFR-344), AC-4 (CDS guard — EPIC 5).
- **Planned cluster:** the AU family resolves together once the audit-log service lands
  (the single highest-leverage control — carries AU-2/3/9/12 + SOC 2 + PCI-10).
- **CMMC L2 framing:** an assessor can stand up the SSP on the "Met" rows immediately and
  schedule the partials/planned against the named tickets.

## References

- NIST SP 800-53 Rev 5; SP 800-171 Rev 2; CMMC 2.0 L2.
- Sibling artifacts in this directory (cited inline).
