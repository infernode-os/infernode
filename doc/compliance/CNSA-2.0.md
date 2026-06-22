# Compliance Evidence — CNSA 2.0 (NSA Commercial National Security Algorithm Suite 2.0)

**Standard:** NSA CNSA 2.0 (announced Sept 2022; quantum-resistant suite for National
Security Systems).
**Roadmap row:** Cryptographic foundation — CNSA 2.0, Tier 0→1.
**Tracking epic:** EPIC 3 — Complete CNSA 2.0 ([`../security-epics.md`](../security-epics.md)).
**Artifact date:** 2026-06-22.
**Overall status:** **Substantially met.** Every CNSA 2.0 algorithm is implemented
natively at the required (or higher) security category, with passing regression tests.
Two parameter-selection items and one signing-scheme item remain for *strict-mode*
CNSA 2.0 and are tracked as gaps below.

---

## 1. What CNSA 2.0 requires

CNSA 2.0 mandates the following algorithms and parameters for National Security Systems.
(Classical ECDH/ECDSA P-384 and RSA-3072+ are permitted only during the transition
window and are being retired; SHA-384/512 and AES-256 carry forward.)

| Function | CNSA 2.0 algorithm | Required parameters | Authority |
|----------|--------------------|---------------------|-----------|
| Symmetric encryption | AES | **256-bit keys** | FIPS 197 |
| Hashing | SHA-2 | **SHA-384 or SHA-512** | FIPS 180 |
| Asymmetric key establishment | **ML-KEM** | **ML-KEM-1024** (Category 5) | FIPS 203 |
| Asymmetric signatures (general) | **ML-DSA** | **ML-DSA-87** (Category 5) | FIPS 204 |
| Software/firmware signing | **LMS or XMSS** | LMS SHA-256/192; XMSS | NIST SP 800-208 |

---

## 2. Inferno-native mechanism

Following the project's "all crypto primitives live in `libsec/`, protocol logic in
Limbo" precedent, every CNSA 2.0 primitive is a native C implementation in `libsec/`
with **no external dependency**, exposed to Limbo through the `Keyring` module
(`libinterp/keyring.c` ↔ `module/keyring.m`). The signature algorithms register through
the generic 8-slot `SigAlgVec` table; ML-KEM is a raw-byte-array builtin (it is a KEM,
not a signature scheme). This keeps the entire quantum-resistant surface inside the one
small, auditable `libsec`/`keyring` boundary that FIPS 140-3 work (EPIC 6) will later
validate.

Design rationale and full implementation history:
[`../../docs/QUANTUM-SAFE-CRYPTO-PLAN.md`](../../docs/QUANTUM-SAFE-CRYPTO-PLAN.md) and
[`../../docs/CRYPTO-MODERNIZATION.md`](../../docs/CRYPTO-MODERNIZATION.md) §8–10.

---

## 3. Algorithm inventory (the artifact accreditors ask for)

Each row is independently verifiable: the **Evidence** column points at the
implementation and the regression test.

### 3.1 Symmetric encryption — AES-256 ✅

| Item | Detail |
|------|--------|
| Requirement | AES with 256-bit keys |
| Implementation | `libsec/aes.c`, AES-GCM in `libsec/aesgcm.c` (`setupAESGCMstate` accepts `keylen`; 32 = AES-256) — decl `include/libsec.h:53` |
| In use | TLS offers `TLS_AES_256_GCM_SHA384` — `appl/lib/crypt/tls.b:197`, `:199`. Login/EKE channel uses ChaCha20-Poly1305 (256-bit) — `docs/CRYPTO-MODERNIZATION.md` §5 |
| Evidence | `tests/tls_crypto_test.b`, `tests/aesgcm`/crypto suite |
| Status | **Met** — AES-256-GCM available and negotiated |

### 3.2 Hashing — SHA-384 / SHA-512 ✅

| Item | Detail |
|------|--------|
| Requirement | SHA-384 or SHA-512 |
| Implementation | `libsec/sha2.c` + `libsec/sha512block.c`; decls `include/libsec.h:306` (`sha384`), `:307` (`sha512`), HMAC at `:311`–`:312` |
| In use | TLS 1.3 `TLS_AES_256_GCM_SHA384`, transcript & signature hashing via SHA-384 — `appl/lib/crypt/tls.b:1441`, `:1755` |
| Evidence | `tests/tls_crypto_test.b` |
| Status | **Met** |

### 3.3 Key establishment — ML-KEM (FIPS 203) ✅ primitive / ⚠ parameter

| Item | Detail |
|------|--------|
| Requirement | ML-KEM-1024 (Category 5) |
| Implementation | `libsec/mlkem.c`, `libsec/mlkem_ntt.c`, `libsec/mlkem_poly.c`. **Both** ML-KEM-768 *and* ML-KEM-1024 keygen/encaps/decaps present (`mlkem1024_*`) — sizes per FIPS 203 (`docs/CRYPTO-MODERNIZATION.md` §8) |
| Keyring binding | `libinterp/keyring.c` builtins (`Keyring_mlkem768_keygen` at `:3944`, ML-KEM-1024 counterparts) |
| In use | Hybrid X25519+ML-KEM-768 in TLS 1.3 (`GROUP_X25519MLKEM768 = 0x4588`, `appl/lib/crypt/tls.b:74`); mutual ML-KEM-768 in the native 9P/Styx STS handshake (`libinterp/keyring.c` `Keyring_auth`, `mlkem768_keygen` at `:1847`, SHA3-512 combiner) |
| Evidence | `tests/mlkem_test.b` (KAT + round-trip), `tests/mlkem_stress_test.b`, `tests/pqauth_test.b` (hybrid handshake, downgrade-rejected, tamper-rejected), `tests/handshake_fuzz_test.b` |
| Status | **Substantially met** — Category-5 primitive (ML-KEM-1024) implemented and tested; **negotiated key exchange uses ML-KEM-768 (Category 3)**. See Gap G1. |

### 3.4 Signatures (general) — ML-DSA (FIPS 204) ✅ primitive / ⚠ default

| Item | Detail |
|------|--------|
| Requirement | ML-DSA-87 (Category 5) |
| Implementation | `libsec/mldsa.c`, `mldsa_ntt.c`, `mldsa_poly.c`; **both** ML-DSA-65 and ML-DSA-87 present |
| Keyring binding | `libkeyring/mldsaalg.c` — registered as `SigAlgVec` slots `mldsa65`, `mldsa87` (`libinterp/keyring.c:2403`–`:2406`) |
| X.509 | OIDs `id-ML-DSA-65` 2.16.840.1.101.3.4.3.18, `id-ML-DSA-87` …3.19 (`appl/lib/crypt/pkcs.b`, `appl/lib/crypt/x509.b`) |
| Key generation | `auth/createsignerkey -a mldsa87 <name>` (`appl/cmd/auth/createsignerkey.b`) |
| Evidence | `tests/mldsa_test.b` (KAT, sign/verify, wrong-key rejection, cert verify), `tests/mldsa_stress_test.b`, `tests/pqauth_test.b` *HybridHandshakeMLDSA* (fully-PQ handshake) |
| Status | **Substantially met** — ML-DSA-87 implemented, tested, and selectable; the *recommended/default* signer parameter is ML-DSA-65 (Category 3). See Gap G2. |

### 3.5 Software/firmware signing — LMS/XMSS ⚠ substitute present

| Item | Detail |
|------|--------|
| Requirement | LMS or XMSS stateful hash-based signatures (NIST SP 800-208) for software/firmware signing |
| Present instead | **SLH-DSA** (FIPS 205, *stateless* hash-based): `libsec/slhdsa*.c` (WOTS+ / FORS / hypertree), registered `slhdsa192s`/`slhdsa256s` (`libinterp/keyring.c:2407`–`:2410`); X.509 OIDs …3.22 / …3.26 |
| Evidence | `tests/slhdsa_test.b`, `tests/mldsa_stress_test.b` (SLH-DSA stress) |
| Status | **Gap.** SLH-DSA is a conservative, hash-based, FIPS-approved signature scheme and a strong substitute, but it is **not** the LMS/XMSS that CNSA 2.0 names for the software/firmware-signing role. See Gap G3. |

### 3.6 Supporting primitive — SHA-3 / SHAKE (FIPS 202) ✅

Prerequisite for ML-KEM/ML-DSA/SLH-DSA. `libsec/sha3.c` (Keccak-f[1600], SHA3-256/512,
SHAKE-128/256); Keyring builtins `sha3_256`/`sha3_512` (`libinterp/keyring.c:1364`).
Evidence: `tests/sha3_test.b`. Constant-time by construction (no data-dependent
branches/table lookups). **Met.**

---

## 4. Defense-in-depth note (hybrid posture)

All deployed PQ key exchange is **hybrid** (classical + PQ), so a session is safe unless
*both* the classical and the post-quantum problem are broken — directly addressing the
"harvest-now-decrypt-later" threat:

- TLS 1.3: X25519 **+** ML-KEM-768, combined secret fed to HKDF
  (`appl/lib/crypt/tls.b`, `docs/CRYPTO-MODERNIZATION.md` §8).
- Native 9P/Styx transport: classical DH **+** mutual ML-KEM-768, combined via SHA3-512,
  transcript-bound against active substitution (`docs/CRYPTO-MODERNIZATION.md` §10;
  proven by `tests/pqauth_test.b` *TamperedEkRejected* / *DowngradeRejected*).

This exceeds the CNSA 2.0 baseline (which permits PQ-only); the hybrid construction is a
stricter, transition-safe posture.

---

## 5. Residual gaps (tracked)

| ID | Gap | CNSA 2.0 requirement | Effort | Tracking |
|----|-----|----------------------|--------|----------|
| **G1** | Negotiated key exchange uses ML-KEM-768 (Cat 3); CNSA 2.0 mandates **ML-KEM-1024** (Cat 5). The -1024 primitive already exists — this is a parameter/negotiation selection, not new crypto. | ML-KEM-1024 | Small (wire a hybrid group / native-STS option using the existing `mlkem1024_*` calls) | INFR — *CNSA-strict ML-KEM-1024* |
| **G2** | Default/recommended signer is ML-DSA-65 (Cat 3); CNSA 2.0 mandates **ML-DSA-87** (Cat 5). The -87 algorithm is implemented and selectable. | ML-DSA-87 default in CNSA mode | Small (default selection / "CNSA mode" flag) | INFR — *CNSA-strict ML-DSA-87 default* |
| **G3** | No LMS/XMSS (SP 800-208) for software/firmware signing. SLH-DSA is present as a hash-based substitute. | LMS or XMSS | Medium (new primitive) — or a documented accreditor waiver accepting SLH-DSA | INFR — *LMS/XMSS firmware signing (or SLH-DSA waiver)* |

None of G1–G3 require architectural change; G1/G2 are selection of already-implemented
Category-5 parameters. Per project policy these are scoped and reviewed as their own
changes rather than bundled here. **No code is altered by this evidence artifact.**

## 6. Disposition

- CNSA 2.0 **algorithm primitives: complete** at Category 5 (FIPS 203/204/205/202; AES-256;
  SHA-384/512) — closes EPIC 3 acceptance item *"algorithm inventory documented."*
- CNSA 2.0 **strict-mode parameter compliance:** open via G1–G3.
- Recommended next step for full close-out: schedule G1 + G2 (both small, both use existing
  Category-5 code paths), then revisit G3 with the accreditor (LMS/XMSS vs. SLH-DSA waiver).

## 7. References

- NSA, *Announcing the Commercial National Security Algorithm Suite 2.0* (CNSA 2.0).
- NIST FIPS 203 (ML-KEM), 204 (ML-DSA), 205 (SLH-DSA), 202 (SHA-3), 197 (AES), 180 (SHA-2).
- NIST SP 800-208 (Stateful Hash-Based Signatures: LMS/XMSS).
- Implementation history: [`../../docs/QUANTUM-SAFE-CRYPTO-PLAN.md`](../../docs/QUANTUM-SAFE-CRYPTO-PLAN.md),
  [`../../docs/CRYPTO-MODERNIZATION.md`](../../docs/CRYPTO-MODERNIZATION.md).
