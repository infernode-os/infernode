# Compliance Evidence — CNSA 2.0 (NSA Commercial National Security Algorithm Suite 2.0)

**Standard:** NSA CNSA 2.0 (announced Sept 2022; quantum-resistant suite for National
Security Systems).
**Roadmap row:** Cryptographic foundation — CNSA 2.0, Tier 0→1.
**Tracking:** Program epic [INFR-328]; gaps [INFR-329] (G1), [INFR-330] (G2), [INFR-331] (G3). EPIC 3 — Complete CNSA 2.0 ([`../security-epics.md`](../security-epics.md)).
**Artifact date:** 2026-06-22.
**Overall status:** **All in-scope CNSA 2.0 algorithm requirements Met under CNSA-strict mode.**
Every applicable CNSA 2.0 algorithm is implemented natively at the required security
category. The two parameter-selection gaps are closed under a fleet-wide **CNSA mode**
(the host `CNSAMODE` env var, reflected by the emu into Inferno `/env/cnsamode`, off by
default): **ML-KEM-1024** is negotiated end-to-end on both transports (G1 — native STS
multi-node-verified + TLS interop-verified vs OpenSSL) and **ML-DSA-87** is the signing
default (G2). The **LMS/XMSS firmware-signing** item (G3) is determined **Not Applicable**
— InferNode has no firmware and no in-system signed-image verification; distribution
releases are signed by a hardware YubiKey (with ML-DSA-87 available should a PQ release
signature be required). See §3.5.

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
| In use | **Native 9P/Styx STS handshake** — mutual ML-KEM (768 default, **1024 under CNSA mode**) hybridised with classical DH (`libinterp/keyring.c` `Keyring_auth`, SHA3-512 combiner). **TLS 1.3** — classical X25519 by default; under CNSA mode the client offers the **SecP384r1MLKEM1024** hybrid (P-384 ECDH + ML-KEM-1024, `0x11ED`, `appl/lib/crypt/tls.b`). *(Note: the older `GROUP_X25519MLKEM768 = 0x4588` constant existed but was never wired into the TLS key_share; the CNSA path supersedes it.)* |
| Evidence | `tests/mlkem_test.b` (KAT + round-trip), `tests/mlkem_stress_test.b`, `tests/pqauth_test.b` (hybrid handshake, downgrade-rejected, tamper-rejected), `tests/handshake_fuzz_test.b` |
| Status | **Met (CNSA-strict mode)** — both transports negotiate **ML-KEM-1024** under CNSA mode. *Native STS:* `Keyring_auth` uses `mlkem1024_*`; **multi-node verified** (`tests/cnsa_nodepair_test.sh`) — two CNSA nodes complete the 1024 handshake over TCP, a mixed 1024/768 pair is rejected (no silent downgrade); `tests/pqauth_test.b` passes 11/11 in both modes. *TLS 1.3:* the client offers **SecP384r1MLKEM1024** (P-384 ECDH + ML-KEM-1024, ECDH-first combiner) — **interop-verified against OpenSSL 3.6** (`tests/tls_cnsa_hybrid_test.sh`): the hybrid handshake + application data succeed, the classical path still works, and a CNSA client refuses an X25519-only server. Default deployments stay classical (ML-KEM-768 native / X25519 TLS). |

### 3.4 Signatures (general) — ML-DSA (FIPS 204) ✅

| Item | Detail |
|------|--------|
| Requirement | ML-DSA-87 (Category 5) |
| Implementation | `libsec/mldsa.c`, `mldsa_ntt.c`, `mldsa_poly.c`; **both** ML-DSA-65 and ML-DSA-87 present |
| Keyring binding | `libkeyring/mldsaalg.c` — registered as `SigAlgVec` slots `mldsa65`, `mldsa87` (`libinterp/keyring.c:2403`–`:2406`) |
| X.509 | OIDs `id-ML-DSA-65` 2.16.840.1.101.3.4.3.18, `id-ML-DSA-87` …3.19 (`appl/lib/crypt/pkcs.b`, `appl/lib/crypt/x509.b`) |
| Key generation | `auth/createsignerkey -a mldsa87 <name>`, or the **`-c` CNSA flag** (selects ML-DSA-87 in one option) (`appl/cmd/auth/createsignerkey.b`) |
| Evidence | `tests/mldsa_test.b` (KAT, sign/verify, wrong-key rejection, cert verify), `tests/mldsa_stress_test.b`, `tests/pqauth_test.b` *HybridHandshakeMLDSA* (fully-PQ handshake) |
| Status | **Met (CNSA-strict mode)** — with CNSA mode on (`/env/cnsamode`), `createsignerkey` defaults to **ML-DSA-87** (verified: the generated key matches the `-c` mldsa87 key size, ~20 KB, vs the 651 B ed25519 default); the `-c` flag and `-a` override are unchanged. Default deployments stay on ed25519. |

### 3.5 Software/firmware signing — LMS/XMSS — Not Applicable (no firmware in scope)

| Item | Detail |
|------|--------|
| Requirement | LMS or XMSS stateful hash-based signatures (NIST SP 800-208) for **firmware/software image** signing — i.e. offline-signed boot/update images that a system verifies at load. |
| Applicability | **Not applicable to the current architecture.** InferNode ships **no firmware**, and the runtime performs **no in-system verification of signed firmware/software images** that would invoke a stateful hash-based scheme. (Signer keys sign *authentication certificates* for the 9P/Styx STS handshake — `appl/cmd/auth/`, `proto=infauth` — not code. In-system signed `.dis` modules are a *future* supply-chain roadmap item, `doc/security-standards-roadmap.md`, not a current mechanism.) The LMS/XMSS mandate targets the absent offline-image-signing role. |
| Actual control | Distribution **releases are signed out-of-band by a hardware YubiKey at release time** (human-gated, hardware-bound key — `yubikey/` git/PIV signing). This is a supply-chain authenticity control on the release artifact, not an in-system signing key. |
| PQ posture / forward path | The release signature is presently ECDSA (`ecdsa-sk`, P-256) — classical, transition-era. If a *quantum-resistant* software/release signature is later required (e.g. when "signed `.dis` modules" lands), the system already provides **ML-DSA-87** (FIPS 204, §3.4) via `createsignerkey` — usable with no new crypto. Implementing **LMS/XMSS is not warranted**: there is no offline image-signing use case for it, and its stateful one-time-key management would add catastrophic-reuse risk for no benefit. SLH-DSA (FIPS 205) also remains available (`libsec/slhdsa*.c`, `slhdsa192s`/`slhdsa256s`) as a *stateless* hash-based option. |
| Status | **Resolved — Not Applicable.** The LMS/XMSS firmware-signing mandate has no applicable artifact (no firmware / no in-system signed-image verification); the compensating control is hardware (YubiKey) release signing, with ML-DSA-87 available as the PQ option. *Accreditor to confirm the applicability determination.* (G3 closed.) |

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

## 5. Gap resolution (all closed)

| ID | CNSA 2.0 requirement | Resolution | Tracking |
|----|----------------------|------------|----------|
| **G1** | **ML-KEM-1024** (Cat 5) negotiated key exchange | **Closed.** Both transports select ML-KEM-1024 under CNSA mode (native STS `if(cnsa)` keygen/encaps/decaps, `libinterp/keyring.c:1765`–`2026`; TLS client offers `SecP384r1MLKEM1024`, `appl/lib/crypt/tls.b`). No silent downgrade. Multi-node (`tests/cnsa_nodepair_test.sh`) + OpenSSL-interop (`tests/tls_cnsa_hybrid_test.sh`) verified. | INFR-329 |
| **G2** | **ML-DSA-87** (Cat 5) across all signing surfaces | **Closed.** Under CNSA mode, `createsignerkey` and `auth/signer` (the auth-domain CA, first-run key) default to ML-DSA-87; the native STS / TLS / factotum / X.509 signers are algorithm-agnostic and honor the signer key's algorithm. `createsignerkey -c` selects it in one flag regardless of mode. | INFR-330 |
| **G3** | LMS/XMSS (SP 800-208) firmware signing | **Resolved — Not Applicable** (§3.5): no firmware / in-system signed-image use case; compensating control is hardware (YubiKey) release signing, with ML-DSA-87 / SLH-DSA available. Accreditor to confirm the determination. | INFR-331 |

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
