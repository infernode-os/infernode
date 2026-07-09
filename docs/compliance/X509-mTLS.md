# Compliance Evidence — X.509 / mTLS (Authenticated Encrypted Transport)

**Standard:** X.509 PKI + TLS, with **mutual** authentication (mTLS) for the strongest form.
**Roadmap row:** Identity & authentication — X.509 / mTLS, Tier 0 ("`devssl` + 9P-over-TLS,
uniform").
**Tracking:** program epic [INFR-328]; client-cert gap → [INFR-344].
**Artifact date:** 2026-06-22.
**Overall status:** **Substantially met — with one honest gap.** Server-authenticated TLS
1.2/1.3 with full X.509 path validation and CRL revocation is shipped and PQ-capable.
**Mutual authentication** is provided on the **native 9P/Styx transport** (STS handshake),
but **mutual *TLS* (client-certificate presentation) is not yet implemented** — the TLS
client treats a server `CertificateRequest` as a stub. This artifact states that plainly
rather than claim a clean "Met."

> **Correction of record:** an earlier index entry marked X.509/mTLS "Met". That was an
> overstatement for the TLS path; this artifact is the corrected, evidence-backed position.

## 1. What is met

| Capability | Mechanism | Evidence | Status |
|------------|-----------|----------|--------|
| TLS 1.2 / 1.3 with AEAD | `TLS_AES_256_GCM_SHA384`, ChaCha20-Poly1305 | `appl/lib/crypt/tls.b:195-200` | ✅ |
| X.509 parsing + path validation | `verify_certpath()` | `appl/lib/crypt/x509.b:1896` | ✅ |
| **CRL revocation checking** | CRLs from `/lib/crls/*.der`; `check_revoked()` in path validation | `appl/lib/crypt/x509.b:240,277,1941` | ✅ |
| PQ-capable transport | Hybrid X25519+ML-KEM-768 key exchange | [`NIST-PQC-migration.md`](NIST-PQC-migration.md) | ✅ |
| **Mutual** auth (node-to-node) | Native STS handshake: both peers exchange + verify certificates (`Keyring->auth`) | `libinterp/keyring.c` (`Keyring_auth`); `docs/CRYPTO-MODERNIZATION.md` §10 | ✅ (native transport) |
| PQ X.509 signatures | ML-DSA / SLH-DSA OIDs in cert verification | [`CNSA-2.0.md`](CNSA-2.0.md) | ✅ |

So *authenticated encrypted transport* — the underlying control — **is** satisfied: outbound
TLS authenticates the server and validates its chain (incl. revocation), and the
node-to-node path is **mutually** authenticated.

## 2. The gap (honest)

Mutual **TLS** specifically — the TLS *client* presenting its own X.509 certificate when a
server sends `CertificateRequest` — is **not implemented**:

- `appl/lib/crypt/tls.b:696-697` — on `HT_CERTIFICATE_REQUEST` (TLS 1.2): *"Client cert
  requested - we don't support this yet."*
- `appl/lib/crypt/tls.b:926-987` (TLS 1.3) — sends an **empty** Certificate message and
  (per RFC 8446 §4.4.3) omits CertificateVerify; i.e. the client cannot authenticate with a
  cert over TLS.

Impact: deployments that require client-certificate auth **over TLS** (as opposed to the
native STS transport) are not yet covered. For InferNode↔InferNode, the native mutually-
authenticated STS path already provides the equivalent property; the gap matters for mTLS to
**external** TLS services that demand a client cert.

## 3. Disposition

- *Authenticated encrypted transport* (the substance of the Tier-0 row): **Met** — server-
  auth TLS + validation + CRL, plus mutual auth on the native transport.
- *Strict mutual **TLS** (client-cert over TLS)*: **open — needs code** (client Certificate +
  CertificateVerify in `tls.b`). Tracked as [INFR-344]; small, well-bounded, will be flagged
  for review and kept in the existing `tls.b` style. Does **not** touch the namespace boundary.

Marked **Substantially met** in the register rather than Met, until INFR-344 lands.

## 4. References

- RFC 8446 (TLS 1.3) §4.4.2–4.4.3; RFC 5280 (X.509/CRL).
- `appl/lib/crypt/tls.b`, `appl/lib/crypt/x509.b`; `docs/CRYPTO-MODERNIZATION.md` §7, §10.
