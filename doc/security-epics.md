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
**Status (2026-06-25): SUBSTANTIALLY COMPLETE — EPIC 1 closed.** Shipped & hardware-verified:
(a) UV-required login, (b) DK-encrypted save-back, (c) dual/backup key (`2fa addkey` + GUI),
recovery slot, (e) Settings GUI Security panel, (g) accreditation evidence
(`doc/compliance/SP800-63B-AAL3.md` + `tests/twofaslot_test.b`, 6/6 PASS). (f) passwordless
**declined** (defense-in-depth — keep an independent password factor; still AAL3 either way).
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

## EPIC 7 — Hardware-backed human authorization for agent actions (non-repudiable)
**Tier:** 1 · **Refs:** SP 800-53 **AU-10 (non-repudiation)**, AC-3/AC-5 (access enforcement / separation of duties), AC-6, IA-2; NIST AI RMF (human oversight / meaningful human control); FIDO2 assertion signatures; builds on EPIC 1 (`#F`/`twofa`) + EPIC 2 (audit log).
**Description:** Gate high-risk actions — especially those initiated by the on-device LLM agent (`lucibridge`/`agentlib`) — behind a YubiKey touch+UV that yields a **non-repudiable, action-bound signature** and a tamper-evident record of *who authorized what*. **Threat model: the adversary is the agent itself.** The design must hold when the code requesting approval is the thing being blocked — so enforcement is by namespace construction, never an in-process check the agent could patch.
**Enforcement (why a wily agent can't circumvent):**
- The gated capability exists ONLY behind a **guard 9P service** in a namespace the agent does not possess. The agent cannot *name* the raw action (no `/dev/exec`, no write to the real FS, no payment channel) — only the guarded path. Plan 9 enforcement by construction: remove the capability from the agent's namespace; the guard runs in a separate pgrp the agent can't bind into or escape.
- The YubiKey signs `H(canonical-action ‖ nonce ‖ time)` via a **UV FIDO2 assertion** — authorizing THIS action only. The nonce + the authenticator's monotonic **signature counter** defeat replay and detect cloning; the asymmetric signature gives true non-repudiation (verifiable later without any shared secret).
- The approval prompt is rendered by the **guard** from the canonical action bytes (not agent-supplied text) on a surface the agent has no draw access to — no bait-and-switch between "what the human saw" and "what runs".
- Every authorize/deny is appended to the **hash-chained audit log** (EPIC 2) with action, credential id, counter, UV flag, and time — offline-verifiable.
- **Default per-action** (no blanket "approve all"); scoped batch approvals only with explicit, signed scope.
**Acceptance:** a gated action cannot proceed without a fresh UV signature over its exact bytes; an adversarial test suite where the agent *tries* to bypass (forge, replay, namespace-escape, prompt-spoof, race another approval) all fail; the audit log verifies offline; non-repudiation holds (a third party can prove which key authorized which action).
**Stories:** (a) `#F` "assert/sign over an arbitrary challenge with UV" op + a verifier; (b) guard 9P service + the namespace policy that strips the raw capability from agent pgrps; (c) trusted approval UI (guard-drawn); (d) audit-log integration; (e) route gated agent tools (`write`/`exec`/`spawn`/`git`/`launch`/payments) through the guard; (f) adversarial "agent tries to escape" test suite.
