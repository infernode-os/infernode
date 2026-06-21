# Security & Compliance — Jira Epics (paste-ready)

Derived from `doc/security-standards-roadmap.md`. Each epic: Summary / Description /
Acceptance Criteria / candidate Stories. Tier per the roadmap. (Authored here because
the Atlassian MCP wasn't reachable in-session; bulk-create from this.)

---

## EPIC 0 — Security & Compliance Standards Program (umbrella)
**Tier:** — **Description:** Establish the program that takes InferNode/NERVA toward
government, banking, finance, and military accreditation, implemented the Inferno way
(namespace + 9P + factotum + small TCB). Tracks the roadmap and the SP 800-53 mapping.
**Acceptance:** roadmap doc maintained; control-mapping table kept current; each Tier-1
epic linked here.

## EPIC 1 — AAL3-harden YubiKey login (FIRST)
**Tier:** 1 · **Refs:** `doc/second-factor-auth.md`, NIST SP 800-63B AAL3, FIDO2 UV, PIV/CAC.
**Description:** Move the working 2FA login to a true AAL3 / PIV-CAC posture: hardware
user-verification, vault keyed to the key, no password-keyed blob ever on disk, no single
point of failure.
**Status (2026-06-21):** Story (a) ✅ **DONE & hardware-verified** — UV-required login shipped
(FIDO-PIN prompt in `logon`; PIN is load-bearing per the `t2uv` test: touch-only derive yields a
different secret). Recovery slot (part of d) wired. (b) DK save-back, (c) dual-key, (e) Settings
GUI, (f) passwordless, (g) accreditation test remain open.
**Acceptance Criteria:**
- ✅ hmac-secret credential **requires UV (FIDO2 PIN)**, not touch-only. *(shipped, hardware-verified)*
- Factotum **save-back uses the data key (DK)** for 2FA accounts — no password-keyed
  blob is ever written (closes the silent-downgrade gap).
- **Dual-key (primary + backup)** enrolled by default; **controlled recovery** secret.
- Optional **passwordless mode** (key + FIDO PIN, no OS password) selectable at enroll.
- Documented threat model incl. the USB-no-pinpad residual exposure.
**Stories:** (a) ✅ enforce UV on enroll credential; (b) DK-aware factotum secstore save-back;
(c) dual-key enroll + addkey flow; (d) recovery-secret model (passphrase → split/M-of-N);
(e) Settings GUI Security panel; (f) passwordless-mode toggle; (g) end-to-end accreditation test.

## EPIC 2 — Tamper-evident audit-log service
**Tier:** 1 · **Refs:** NIST SP 800-92, SP 800-53 AU, SOC 2, PCI-DSS Req 10.
**Description:** One hash-chained, append-only 9P log service (`#`-device / `/dev/audit`)
that every subsystem writes to; Merkle-verifiable; tamper-evident.
**Acceptance:** append-only chain; offline verifier; integrity break is detectable;
factotum/login/CDS events flow to it.
**Stories:** log device + chain format; verifier tool; subsystem wiring; retention policy.

## EPIC 3 — Complete CNSA 2.0 (quantum-resistant suite)
**Tier:** 1 · **Refs:** CNSA 2.0, FIPS 203 (ML-KEM).
**Description:** Add ML-KEM key-establishment (signer already has ML-DSA/SLH-DSA); hybrid
classical+PQC negotiated in factotum/devssl.
**Acceptance:** ML-KEM in libsec/keyring; hybrid handshake; algorithm inventory documented.
**Stories:** ML-KEM impl/binding; SSL/factotum negotiation; SHA-384/P-384 review.

## EPIC 4 — SP 800-53 / 800-171 control mapping & evidence
**Tier:** 1 · **Refs:** FISMA, NIST SP 800-53, SP 800-171 / CMMC.
**Description:** Complete the control-family → Inferno-mechanism → evidence table; the
artifact procurement/accreditors require.
**Acceptance:** all relevant families mapped with mechanism + evidence + status; CMMC subset
identified as the first accreditation target.
**Stories:** AC/IA/SC/AU first; remaining families; evidence-collection automation.

## EPIC 5 — Cross-Domain Solution (CDS) guard reference
**Tier:** 1→2 · **Refs:** NSA Raise-the-Bar, MLS, SP 800-53 AC/SC.
**Description:** Flagship demo — a guard process on a namespace boundary filtering 9P
messages between security domains. The differentiator no incumbent shows cleanly.
**Acceptance:** two-domain demo; guard enforces a documented policy; messages mediated at 9P.
**Stories:** namespace-labelled domains; guard process + policy; throughput/latency; threat model.

## EPIC 6 — FIPS 140-3 readiness (libsec module boundary)
**Tier:** 2 · **Refs:** FIPS 140-3.
**Description:** Consolidate crypto behind a single `libsec`/`keyring` boundary as the
validation surface; self-tests, approved-mode.
**Acceptance:** single boundary; power-on self-tests; approved algorithm enforcement; gap analysis.
**Stories:** crypto-call inventory/consolidation; self-tests; approved-mode flag; pre-validation gap report.
