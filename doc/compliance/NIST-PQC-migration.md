# Compliance Evidence — NIST PQC Migration (Hybrid Classical + Post-Quantum)

**Standard:** NIST post-quantum migration guidance — deploy **hybrid** classical+PQC key
establishment during the transition (NIST IR 8547 / CNSA 2.0 transition posture;
`draft-ietf-tls-ecdhe-mlkem`).
**Roadmap row:** Cryptographic foundation — NIST PQC migration, Tier 1
("Hybrid classical+PQC, negotiated in factotum/`devssl`, transparent to apps").
**Tracking:** program epic [INFR-328].
**Artifact date:** 2026-06-22.
**Overall status:** **Met.** Hybrid key establishment is shipped on **both** transports
InferNode uses — outbound TLS 1.3 and the native 9P/Styx node-to-node handshake — is
negotiated transparently to applications, and falls back cleanly to classical when a peer
lacks PQ support. Tested end-to-end including negative cases.

> Distinct from [`CNSA-2.0.md`](CNSA-2.0.md): that artifact tracks whether the *parameter
> sets* meet CNSA 2.0's Category-5 mandate (open: ML-KEM-1024/ML-DSA-87). **This** standard
> asks only whether a *hybrid migration* is deployed and transparent — which it is.

## 1. Requirement → mechanism → evidence

| Requirement | Mechanism | Evidence | Status |
|-------------|-----------|----------|--------|
| Hybrid key exchange over TLS | X25519 **+** ML-KEM-768, `GROUP_X25519MLKEM768` (0x4588); combined secret → HKDF; classical fallback if peer lacks it | `appl/lib/crypt/tls.b:74`; `docs/CRYPTO-MODERNIZATION.md` §8 | ✅ |
| Hybrid on node-to-node transport | STS v2 handshake: classical DH **+** mutual ML-KEM-768, combined via SHA3-512, transcript-bound | `libinterp/keyring.c` (`Keyring_auth`, `mlkem768_keygen` at `:1847`); `docs/CRYPTO-MODERNIZATION.md` §10 | ✅ |
| Transparent to applications | Negotiated in the TLS/STS layer; apps speak unchanged 9P/Styx | `docs/CRYPTO-MODERNIZATION.md` §10 | ✅ |
| Defense-in-depth (safe unless *both* broken) | Combined classical‖PQ secret | [`CNSA-2.0.md`](CNSA-2.0.md) §4 | ✅ |
| Graceful fallback / no breakage | Hybrid group preferred but optional; classical path unchanged | `docs/CRYPTO-MODERNIZATION.md` §8 (Backward Compatibility) | ✅ |

## 2. Tests

| Test | Covers |
|------|--------|
| `tests/pqauth_test.b` | mutual hybrid handshake derives identical 64-byte secret; *HybridHandshakeMLDSA* (fully-PQ: PQ sig + PQ KEM); *DowngradeRejected* (classical-only peer refused); *TamperedEkRejected* (active KEM-substitution MITM fails — transcript binding holds); *MalformedEkRejected* |
| `tests/mlkem_test.b`, `mlkem_stress_test.b` | ML-KEM KATs + round-trip |
| `tests/tls_crypto_test.b` | TLS record/handshake crypto |

The negative cases (downgrade refused, tampered/malformed KEM rejected) are what make this
*Met* rather than merely *present*: the migration is safe against an active attacker, not
just a passive one.

## 3. Disposition

**Met.** Hybrid PQC migration is deployed on every transport, transparent to apps, fallback-
safe, and adversarially tested. The remaining PQC work is *parameter strictness* for CNSA 2.0
(ML-KEM-1024 / ML-DSA-87 — INFR-329/330), tracked under [`CNSA-2.0.md`](CNSA-2.0.md), not here.

## 4. References

- NIST IR 8547 (transition to PQC); `draft-ietf-tls-ecdhe-mlkem`; CNSA 2.0 transition guidance.
- `docs/CRYPTO-MODERNIZATION.md` §8, §10; `docs/QUANTUM-SAFE-CRYPTO-PLAN.md`; [`CNSA-2.0.md`](CNSA-2.0.md).
