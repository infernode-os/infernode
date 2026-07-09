# Compliance Evidence — FIDO2 / CTAP2 (Phishing-Resistant Authenticator)

**Standard:** FIDO2 — CTAP2 (Client to Authenticator Protocol) + the `hmac-secret`
extension. (WebAuthn — the W3C browser API layer — see scope note §3.)
**Roadmap row:** Identity & authentication — FIDO2 / CTAP2 / WebAuthn, Tier 0→1
("origin-bound, phishing-resistant").
**Tracking:** program epic [INFR-328]; related [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md).
**Artifact date:** 2026-06-22.
**Overall status:** **Met (as an authenticator).** InferNode uses a real FIDO2 hardware
authenticator over CTAP2 (via host libfido2) with the `hmac-secret` extension and
user-verification (PIN), proven on hardware. The browser-WebAuthn web-flow is an explicit,
documented non-goal (§3) — not a gap.

## 1. Requirement → mechanism → evidence

| FIDO2/CTAP2 property | Mechanism | Evidence | Status |
|----------------------|-----------|----------|--------|
| Hardware authenticator, secret non-exportable | YubiKey FIDO2; `hmac-secret` output `R` derived **on-key**, never leaves it | `docs/second-factor-auth.md` §1, §6; `docs/yubikey-2fa-operations.md` §9 | ✅ |
| CTAP2 transport | Host libfido2 bridge relays challenge→response; Inferno sees only files at `/mnt/2fa` | `emu/port/fido2bridge.*`, `emu/port/devtfa.c`; `module/twofa.m`, `appl/lib/twofa.b` | ✅ |
| Phishing / verifier-impersonation resistance | Challenge-response bound to credential; not a typed/replayable shared secret | `docs/second-factor-auth.md` §4–§6 | ✅ |
| User verification (UV) | FIDO2 **PIN** verified on-key; UV output cryptographically distinct from touch-only | `docs/yubikey-2fa-operations.md` §intro, §9, §11 (`t2uv`) | ✅ hardware-verified |
| Credential bound, deterministic per (cred, salt) | `hmac-secret` assertion mixed into the secstore file-key | `docs/second-factor-auth.md` §6 | ✅ |

## 2. The proof

The `t2uv` standalone hardware test enrolls a UV credential and shows: derive-with-PIN is
deterministic, derive-without-PIN returns a *different* secret. That demonstrates the CTAP2
`hmac-secret` + UV path works against real hardware and that UV is load-bearing
(`docs/yubikey-2fa-operations.md` §11). This is the same evidence that substantiates the
AAL3 verifier ([`SP800-63B-AAL3.md`](SP800-63B-AAL3.md)).

## 3. Scope note — WebAuthn web-flow is a deliberate non-goal

WebAuthn is the W3C *browser* Credential Management API. InferNode's browser (Charon) has no
JS engine, so the web flow is intentionally out of scope; InferNode uses **native CTAP2
challenge-response** instead (`docs/second-factor-auth.md` §2 "Non-goals"). The FIDO2/CTAP2
authenticator guarantees (hardware-bound, phishing-resistant, UV) are fully met without it.
An accreditor evaluating "phishing-resistant authenticator" gets that property; "WebAuthn in
a browser" is simply not a surface InferNode exposes.

## 4. Disposition

**Met** for the FIDO2/CTAP2 authenticator, hardware-verified. The roadmap's "0→1
generalize to auth surfaces" continuation (factotum `proto=2fa`, wallet gating — EPIC 1
stories e/f and second-factor-auth §9 Phase 4) is additive reach, tracked under EPIC 1; it
does not affect this close-out.

## 5. References

- FIDO Alliance CTAP2 spec; `hmac-secret` extension.
- `docs/second-factor-auth.md`, `docs/yubikey-2fa-operations.md`.
