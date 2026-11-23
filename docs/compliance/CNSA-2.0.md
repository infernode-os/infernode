# Compliance Evidence — CNSA 2.0 (NSA Commercial National Security Algorithm Suite 2.0)

**Standard:** NSA CNSA 2.0 (announced Sept 2022; quantum-resistant suite for National
Security Systems).
**Roadmap row:** Cryptographic foundation — CNSA 2.0, Tier 0→1.
**Tracking:** Program epic [INFR-328]; gaps [INFR-329] (G1), [INFR-330] (G2), [INFR-331] (G3). EPIC 3 — Complete CNSA 2.0 ([`history/security-epics.md`](../history/security-epics.md)).
**Artifact date:** 2026-06-22; revised 2026-11-23 (G4–G8: the password protocols' key establishment, auth(2)'s confirmation, the native transport's combiner, the signer's digest).
**Overall status:** **All in-scope CNSA 2.0 algorithm requirements Met under CNSA-strict mode**, with the stored-secret derivations of §3.7's known limits outstanding.
Every applicable CNSA 2.0 algorithm is implemented natively at the required security
category. The two parameter-selection gaps are closed under a fleet-wide **CNSA mode**
(the host `CNSAMODE` env var, reflected by the emu into Inferno `/env/cnsamode`, off by
default, for the native transport; the host `CNSATLS`, reflected into `/env/cnsatls`, for
TLS): **ML-KEM-1024** is negotiated end-to-end on both transports (G1 — native STS
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
[`history/QUANTUM-SAFE-CRYPTO-PLAN.md`](../history/QUANTUM-SAFE-CRYPTO-PLAN.md) and
[`../../docs/CRYPTO-MODERNIZATION.md`](../CRYPTO-MODERNIZATION.md) §8–10.

---

## 3. Algorithm inventory (the artifact accreditors ask for)

Each row is independently verifiable: the **Evidence** column points at the
implementation and the regression test.

### 3.1 Symmetric encryption — AES-256 ✅

| Item | Detail |
|------|--------|
| Requirement | AES with 256-bit keys |
| Implementation | `libsec/aes.c`, AES-GCM in `libsec/aesgcm.c` (`setupAESGCMstate` accepts `keylen`; 32 = AES-256) — decl `include/libsec.h:53` |
| In use | TLS offers `TLS_AES_256_GCM_SHA384` — `appl/lib/crypt/tls.b:209` (`defaultconfig`); CNSA-strict TLS (`/env/cnsatls`) restricts to it alone (`strictcnsaconfig`). The login exchange (login(6), version 3) in CNSA mode is suite 2 alone: AES-256 in counter mode for the masked value and the masked ML-KEM seed, HKDF and proofs under SHA-384, ML-KEM-1024, a 3072-bit group or larger, then `aes_256_gcm` records; outside the mode suite 1 (ChaCha20, SHA-256, ML-KEM-768, 2048 bits) is also taken — `appl/lib/login.b`, `appl/cmd/auth/logind.b`. secstore version 5 masks its ML-KEM seed with AES-256 in counter mode and seals its session with `aes_256_gcm` in every mode — `appl/lib/secstore.b` |
| Evidence | `tests/tls_crypto_test.b` (AES-GCM NIST vectors), `tests/secstore_crypto_test.b` (SGCM file encryption) |
| Status | **Met** — AES-256-GCM available and negotiated |

### 3.2 Hashing — SHA-384 / SHA-512 ✅

| Item | Detail |
|------|--------|
| Requirement | SHA-384 or SHA-512 |
| Implementation | `libsec/sha2.c` + `libsec/sha512block.c`; decls `include/libsec.h:306` (`sha384`), `:307` (`sha512`), HMAC at `:311`–`:312` |
| In use | TLS 1.3 `TLS_AES_256_GCM_SHA384`, transcript & signature hashing via SHA-384 — `appl/lib/crypt/tls.b:1441`, `:1755`. **Auth-certificate hashing** binds the digest to the signing key's strength: ML-DSA-87 / SLH-DSA certificates are hashed with **SHA-384**, classical (ed25519) certificates keep SHA-256 (`Keyring->sign`/`verify` now carry SHA-384/512 branches — `libinterp/keyring.c`; selection in `createsignerkey.b`, `signer.b`, `logind.b`, `mkauthinfo.b`, `factotum/proto/sign.b`; verifier side keys off `cert.ha` in `auditverify.b`, and Keyring's own `auth` reads it from the certificate) |
| Evidence | `tests/tls_crypto_test.b`; `tests/cnsa_nodepair_test.sh` (two CNSA nodes complete the STS handshake exchanging **SHA-384 ML-DSA-87 certificates** over TCP); `tests/auditsign_test.b` |
| Status | **Met** — SHA-384 now reaches the auth-certificate path, not just TLS. The hash name is stored in each certificate, so verifiers re-hash to match and pre-existing SHA-256 certificates still verify (backward compatible). |

### 3.3 Key establishment — ML-KEM (FIPS 203) ✅ primitive / ⚠ parameter

| Item | Detail |
|------|--------|
| Requirement | ML-KEM-1024 (Category 5) |
| Implementation | `libsec/mlkem.c`, `libsec/mlkem_ntt.c`, `libsec/mlkem_poly.c`. **Both** ML-KEM-768 *and* ML-KEM-1024 keygen/encaps/decaps present (`mlkem1024_*`) — sizes per FIPS 203 (`docs/CRYPTO-MODERNIZATION.md` §8) |
| Keyring binding | `libinterp/keyring.c` builtins (`Keyring_mlkem768_keygen` at `:3944`, ML-KEM-1024 counterparts) |
| In use | **Native 9P/Styx STS handshake** — mutual ML-KEM (768 default, **1024 under CNSA mode**) hybridised with classical DH (`libinterp/keyring.c` `Keyring_auth`; the combiner is **SHA-512 under CNSA mode**, the ML-KEM-1024 secrets first, and SHA3-512 outside it). **login(6), version 3** — the password-authenticated exchange that issues every certificate: ML-KEM (768 for suite 1, **1024 for suite 2, the only suite in CNSA mode**) beside its Diffie-Hellman EKE, the client's encapsulation key's seed masked under the password and the DH secret, proofs and session by HKDF-SHA-384 over k ‖ z ‖ pw (`appl/lib/login.b`, `appl/cmd/auth/logind.b`, login(6)). **secstore version 5** — the PAK to the key store: **ML-KEM-1024** in every mode beside the PAK, the seed masked under the PAK's secret and the verifier, proofs and session by HKDF-SHA-384 (`appl/lib/secstore.b` PAK5, `appl/cmd/auth/secstored.b`). **TLS 1.3** — the **X25519MLKEM768** hybrid (`0x11EC`) first by default, with classical X25519/P-256/P-384 for servers without it; under CNSA-strict TLS (`/env/cnsatls`) the client offers the **SecP384r1MLKEM1024** hybrid alone (P-384 ECDH + ML-KEM-1024, `0x11ED`, `appl/lib/crypt/tls.b`). *(Until October 2026 the X25519MLKEM768 constant was `0x4588`, the decimal codepoint read as hex, and the share was never sent.)* |
| Evidence | `tests/mlkem_test.b` (KAT + round-trip), `tests/mlkem_stress_test.b`, `tests/pqauth_test.b` (hybrid handshake, downgrade-rejected, tamper-rejected), `tests/handshake_fuzz_test.b`, `tests/cnsa_nodepair_test.sh` (the SHA-512 combiner between two CNSA nodes); `tests/login_test.b` (both suites' ML-KEM lengths, a key that is none refused, a relay changing the key, its seed or the ciphertext refused, *Logarithms*: a signer given the client's exponent, as a quantum adversary would have it, finds the DH secret of every password it tries and matches none against the client's proof but its one guess) with `tests/host/login_test.sh` (key derivation against Python); `tests/secstored_test.b` *Version5* (version 4's exchange refused, bad keys refused, CNSA mode version 5 alone) and `tests/secstore_crypto_test.b` *Pak5Vectors* with `tests/host/secstore_pak5_test.sh` (against Python) |
| Status | **Met (CNSA-strict mode)** — both transports negotiate **ML-KEM-1024** under CNSA mode (`CNSAMODE` for the native transport, `CNSATLS` for TLS). *Native STS:* `Keyring_auth` uses `mlkem1024_*`; **multi-node verified** (`tests/cnsa_nodepair_test.sh`) — two CNSA nodes complete the 1024 handshake over TCP, a mixed 1024/768 pair is rejected (no silent downgrade); `tests/pqauth_test.b` passes 11/11 in both modes. *TLS 1.3:* the client offers **SecP384r1MLKEM1024** (P-384 ECDH + ML-KEM-1024, ECDH-first combiner) — **interop-verified against OpenSSL 3.6** (`tests/tls_cnsa_hybrid_test.sh`): the hybrid handshake + application data succeed, the classical path still works, and a CNSA client refuses an X25519-only server. Default deployments use ML-KEM-768 (native) and X25519MLKEM768 with classical fallback (TLS). The two settings are apart because public servers do not offer SecP384r1MLKEM1024: a node CNSA-strict to its peers keeps the web. |

### 3.4 Signatures (general) — ML-DSA (FIPS 204) ✅

| Item | Detail |
|------|--------|
| Requirement | ML-DSA-87 (Category 5) |
| Implementation | `libsec/mldsa.c`, `mldsa_ntt.c`, `mldsa_poly.c`; **both** ML-DSA-65 and ML-DSA-87 present |
| Keyring binding | `libkeyring/mldsaalg.c` — registered as `SigAlgVec` slots `mldsa65`, `mldsa87` (`libinterp/keyring.c:2403`–`:2406`) |
| X.509 | OIDs `id-ML-DSA-65` 2.16.840.1.101.3.4.3.18, `id-ML-DSA-87` …3.19 (`appl/lib/crypt/pkcs.b`, `appl/lib/crypt/x509.b`) |
| Key generation | `auth/createsignerkey -a mldsa87 <name>`, or the **`-c` CNSA flag** (selects ML-DSA-87 in one option) (`appl/cmd/auth/createsignerkey.b`) |
| Evidence | `tests/mldsa_test.b` (KAT, sign/verify, wrong-key rejection, cert verify), `tests/mldsa_stress_test.b`, `tests/pqauth_test.b` *HybridHandshakeMLDSA* (fully-PQ handshake) |
| Cert hash | An ML-DSA-87 signer self-cert is hashed with **SHA-384** (FIPS 204 Cat-5 pairing), not SHA-256 — verified end-to-end: `createsignerkey -c` emits `cert.ha=sha384`, and two CNSA nodes mutually authenticate over TCP exchanging SHA-384 ML-DSA-87 certs (`tests/cnsa_nodepair_test.sh`, `both-cnsa-1024-mldsa87` PASS) |
| Status | **Met (CNSA-strict mode)** — CNSA mode (`/env/cnsamode`, or `createsignerkey -c`) is a **rule, not a default**: `createsignerkey` makes **ML-DSA-87** with a SHA-384 certificate and RFC 3526's 3072-bit Diffie-Hellman group, and **refuses** an `-a` naming any other algorithm and any `-b`, saying why (it used to accept `-a rsa -b 512` in the mode). The programs that take a key in the mode refuse one that is not CNSA's whole (ML-DSA-87 keys, certificate under SHA-384/512, modulus ≥ 3072 bits): `mkauthinfo` (the signing key), `logind` and `signer` (the signer's key, at each connection), the login client (the signer's key, modulus and certificate), factotum's `genkey` and `proto=sign`. The rule is stated once, in `appl/lib/login.b` (`cnsaalg`, `cnsahash`, `cnsakey`); `tests/cnsa_mode_test.b`, `tests/login_test.b`. Default deployments stay on ed25519. |

### 3.5 Software/firmware signing — LMS/XMSS — Not Applicable (no firmware in scope)

| Item | Detail |
|------|--------|
| Requirement | LMS or XMSS stateful hash-based signatures (NIST SP 800-208) for **firmware/software image** signing — i.e. offline-signed boot/update images that a system verifies at load. |
| Applicability | **Not applicable to the current architecture.** InferNode ships **no firmware**, and the runtime performs **no in-system verification of signed firmware/software images** that would invoke a stateful hash-based scheme. (Signer keys sign *authentication certificates* for the 9P/Styx STS handshake — `appl/cmd/auth/`, Keyring's `auth` — not code. In-system signed `.dis` modules are a *future* supply-chain roadmap item, `docs/security-standards-roadmap.md`, not a current mechanism.) The LMS/XMSS mandate targets the absent offline-image-signing role. |
| Actual control | Distribution **releases are signed out-of-band by a hardware YubiKey at release time** (human-gated, hardware-bound key — `yubikey/` git/PIV signing). This is a supply-chain authenticity control on the release artifact, not an in-system signing key. |
| PQ posture / forward path | The release signature is presently ECDSA (`ecdsa-sk`, P-256) — classical, transition-era. If a *quantum-resistant* software/release signature is later required (e.g. when "signed `.dis` modules" lands), the system already provides **ML-DSA-87** (FIPS 204, §3.4) via `createsignerkey` — usable with no new crypto. Implementing **LMS/XMSS is not warranted**: there is no offline image-signing use case for it, and its stateful one-time-key management would add catastrophic-reuse risk for no benefit. SLH-DSA (FIPS 205) also remains available (`libsec/slhdsa*.c`, `slhdsa192s`/`slhdsa256s`) as a *stateless* hash-based option. |
| Status | **Resolved — Not Applicable.** The LMS/XMSS firmware-signing mandate has no applicable artifact (no firmware / no in-system signed-image verification); the compensating control is hardware (YubiKey) release signing, with ML-DSA-87 available as the PQ option. *Accreditor to confirm the applicability determination.* (G3 closed.) |

### 3.6 Supporting primitive — SHA-3 / SHAKE (FIPS 202) ✅

Prerequisite for ML-KEM/ML-DSA/SLH-DSA. `libsec/sha3.c` (Keccak-f[1600], SHA3-256/512,
SHAKE-128/256); Keyring builtins `sha3_256`/`sha3_512` (`libinterp/keyring.c:1364`).
Evidence: `tests/sha3_test.b`. Constant-time by construction (no data-dependent
branches/table lookups). **Met.**

### 3.7 What the mode enforces in the authentication programs

CNSA mode (`/env/cnsamode`) was a set of defaults. It is a rule: every program
that makes or takes a signing key in the mode asks `appl/lib/login.b`
(`cnsaalg`, `cnsahash`, `cnsakey`), and what is not CNSA's is refused with the
reason.

| Program | In CNSA mode |
|---------|--------------|
| `auth/createsignerkey` (or `-c`) | Makes ML-DSA-87, certificate under SHA-384, RFC 3526's 3072-bit Diffie-Hellman group in the key file (it was the 2048-bit one). `-a` naming another algorithm and any `-b` are refused. |
| `auth/mkauthinfo` | Signs only with a key file that is CNSA's whole (keys, signer's key, certificate algorithm and hash, modulus ≥ 3072 bits). |
| `auth/logind` | Suite 2 of login(6) alone (AES-256, SHA-384, ML-KEM-1024, group ≥ 3072 bits), and a signer's key that is CNSA's whole, checked at each connection: with any other key every login is refused, "signer's key is not CNSA's". The key certified is of the signer's algorithm. A client of login version 2 (no ML-KEM) is refused in every mode. |
| login client (`login(2)`, `getauthinfo`) | Suite 2 alone (ML-KEM-1024); refuses a signer's key that is not ML-DSA-87, a signer's modulus under 3072 bits, a certificate not ML-DSA-87's under SHA-384/512, and a signer of login version 2. |
| `auth/signer` | As logind for its key; certifies only keys of its own algorithm; the digest the operator compares is SHA-384 for an ML-DSA or SLH-DSA signer. Not started by default (signer(8)). |
| `auth/secstored` | secstore version 5 alone (ML-KEM-1024 and SHA-384 beside the PAK); versions 1 and 3, kept outside the mode for accounts to move, are refused saying so. The version 4 exchange is refused in every mode. |
| secstore client (`secstore(2)`, `auth/secstore`, logon, factotum) | Version 5 alone; an account still at version 1 or 3 is not moved in the mode, and the client says to log in once outside it. |
| `auth/factotum` | `genkey` makes ML-DSA-87 alone; `proto=sign` signs with an ML-DSA-87 key alone. |
| `Keyring->auth` (every authenticated connection) | By the emulator's own switch (`CNSAMODE`): a key file that is not CNSA's whole is refused, each end told which part; the peer's key and certificate are held to the same; the exchange is signed over SHA-384 and a peer's signature over another hash is refused. (It took any key file and signed over SHA-256.) |
| `auth(2)` (`client`, `server`, `auth`) | By `/env/cnsamode`: a key file that is not CNSA's whole is refused before anything is sent, with `cnsakey`'s reason. The confirmation of the ssl algorithm (`infernode-auth 3`) is HMAC-SHA-384 in every mode (it was HMAC-SHA-256). |

Known limits, stated rather than hidden:

- **The masked-seed construction** in login(6) version 3 and secstore version 5
  (ML-KEM beside the password exchange, the encapsulation key's seed masked
  under the password and the Diffie-Hellman secret) is this project's own. Its
  key establishment is ML-KEM-1024 and SHA-384 as CNSA 2.0 asks; the claim that
  a quantum adversary gets one password guess per login it takes part in rests
  on the reasoning in login(6) and on `tests/login_test.b` *Logarithms*, not on a
  published proof, and wants a cryptographer's review.
- **Stored secrets.** keyfs(4)'s key file is PBKDF2-HMAC-SHA-384 and AES-256-GCM
  in every mode. An account's stored secret is the SHA-256 of its password
  (keys(6), changelogin(8)) in every mode: it enters login(6)'s suite 2 only as
  key material to HKDF-SHA-384 and is never a signature's hash. secstore's file
  key and PAK verifier are HMAC-SHA-256 and SHA-256 (`appl/lib/secstore.b`), with
  AES-256-GCM for the files and the session: outside the mode's signature and
  key-establishment rules, and not SHA-384. Moving them to SHA-384 needs each
  account's password (they are derived from it), so it is a migration at the
  next password change and is not yet made. **Open.**

---

## 4. Defense-in-depth note (hybrid posture)

All deployed PQ key exchange is **hybrid** (classical + PQ), so a session is safe unless
*both* the classical and the post-quantum problem are broken — directly addressing the
"harvest-now-decrypt-later" threat:

- TLS 1.3: X25519 **+** ML-KEM-768, combined secret fed to HKDF, where the server offers
  it; classical otherwise (`appl/lib/crypt/tls.b`, `docs/CRYPTO-MODERNIZATION.md` §8).
- Native 9P/Styx transport: classical DH **+** mutual ML-KEM-768, combined via SHA3-512,
  transcript-bound against active substitution (`docs/CRYPTO-MODERNIZATION.md` §10;
  proven by `tests/pqauth_test.b` *TamperedEkRejected* / *DowngradeRejected*); in CNSA
  mode ML-KEM-1024, combined via SHA-512.
- login(6) version 3: the Diffie-Hellman EKE **+** ML-KEM (768, or 1024 in CNSA mode),
  both secrets and the password in the HKDF-SHA-384 key material.
- secstore version 5: the PAK **+** ML-KEM-1024, both secrets and the verifier in the
  HKDF-SHA-384 key material.

This exceeds the CNSA 2.0 baseline (which permits PQ-only); the hybrid construction is a
stricter, transition-safe posture.

---

## 5. Gap resolution

| ID | CNSA 2.0 requirement | Resolution | Tracking |
|----|----------------------|------------|----------|
| **G1** | **ML-KEM-1024** (Cat 5) negotiated key exchange | **Closed.** Both transports select ML-KEM-1024 under CNSA mode (native STS `if(cnsa)` keygen/encaps/decaps, `libinterp/keyring.c:1891`–`2177`; TLS client offers `SecP384r1MLKEM1024`, `appl/lib/crypt/tls.b`). No silent downgrade. Multi-node (`tests/cnsa_nodepair_test.sh`) + OpenSSL-interop (`tests/tls_cnsa_hybrid_test.sh`) verified. | INFR-329 |
| **G2** | **ML-DSA-87** (Cat 5) across all signing surfaces | **Closed, and enforced.** Under CNSA mode `createsignerkey` makes ML-DSA-87 and refuses anything else asked for; `logind`, `signer`, `mkauthinfo`, factotum's `genkey` and `proto=sign`, and the login client each refuse a key that is not ML-DSA-87 (§3.7). `auth/signer` no longer makes a key of its own when it finds none: `createsignerkey` is the one maker. `createsignerkey -c` is the mode for that command regardless of the environment. | INFR-330 |
| **G3** | LMS/XMSS (SP 800-208) firmware signing | **Resolved — Not Applicable** (§3.5): no firmware / in-system signed-image use case; compensating control is hardware (YubiKey) release signing, with ML-DSA-87 / SLH-DSA available. Accreditor to confirm the determination. | INFR-331 |
| **G4** | ML-KEM-1024 in **login(6)**, which issues every certificate | **Closed.** Version 2 was a classical Diffie-Hellman EKE alone: a party with a quantum computer and a recording of a login whose signer's part it took could test every password. Version 3 runs ML-KEM beside it (1024 in CNSA mode, the mode's only suite), the seed masked under the password and the DH secret, proofs and session from both by HKDF-SHA-384; version 2 is refused at both ends (`appl/lib/login.b`, `appl/cmd/auth/logind.b`, login(6); `tests/login_test.b`, `tests/host/login_test.sh`). | — |
| **G5** | ML-KEM-1024 and SHA-384 in **secstore's PAK** | **Closed.** Version 4 was a PAK over a 2048-bit group with SHA-256 proofs: a recorded login was a password to search for. Version 5 keeps the account's verifier and adds ML-KEM-1024 and SHA-384 (`appl/lib/secstore.b` PAK5, `appl/cmd/auth/secstored.b`); the version 4 exchange is refused, and in CNSA mode both ends speak version 5 alone. The PAK's group stays the account's (2048 bits, below CNSA 1.0's 3072): the verifier is bound to it, so it is the hybrid's T and ML-KEM-1024 its Z (SP 800-56C rev. 2), the key establishment CNSA 2.0 counts (`tests/secstored_test.b` *Version5*, `tests/secstore_crypto_test.b` *Pak5Vectors*, `tests/host/secstore_pak5_test.sh`). | — |
| **G6** | SHA-384 for **auth(2)'s confirmation** of the ssl algorithm | **Closed.** It was HMAC-SHA-256; `infernode-auth 3` is HMAC-SHA-384 (`appl/lib/auth.b`; `tests/auth_algs_test.b`, `tests/auth_bind_test.b`). | — |
| **G7** | SHA-2 for the **native transport's hybrid combiner** | **Closed.** It was SHA3-512, which CNSA 2.0 has only inside ML-KEM and ML-DSA; under CNSA mode it is SHA-512 with the ML-KEM-1024 secrets first (`libinterp/keyring.c` `Keyring_auth`; `tests/cnsa_nodepair_test.sh`, `tests/pqauth_test.b`). | — |
| **G8** | SHA-384 for **signer(8)'s operator digest** | **Closed** for ML-DSA and SLH-DSA signers (`appl/cmd/auth/signer.b`, signer(8)). | — |
| **G9** | SHA-384 for the **stored secrets** (an account's password hash, secstore's verifier and file key) | **Open** (§3.7, known limits): derived from passwords, so moved at the next password change; not yet made. | — |

None of G1–G3 require architectural change; G1/G2 are selection of already-implemented
Category-5 parameters. Per project policy these are scoped and reviewed as their own
changes rather than bundled here. **No code is altered by this evidence artifact.**

### 5.1 Why G4–G8, and what they break

G4–G8 were made to meet CNSA 2.0, not because each one answered a
present threat. The table says which did both, so that an accreditor
and an operator can each weigh them. CNSA 2.0 asks for quantum-resistant
public-key algorithms in all key establishment within a National
Security System, on NSA's transition timeline. It names no
password-authenticated exchange, and it does not exempt a protocol for
being confined to one host. An accreditor may still scope loopback
traffic as inside the boundary. A classical Diffie-Hellman exchange of
3072 bits is CNSA 1.0's transition algorithm, not CNSA 2.0's end state.

| Gap | Exposure in a deployment | Threat it answers | Driven by |
|-----|--------------------------|-------------------|-----------|
| G4 login(6) | logind listens on every interface where the auth service runs (`tcp!*!inflogin`: `appl/svc/auth.sh`, `lib/sh/srv`) | A recording of a login, kept until a quantum computer exists, gives the password by offline guessing (the session carries nothing else secret: keys and certificate are public, and the user's secret key never leaves the client). An active attacker with a quantum computer at login time, taking the signer's part, got every password; now it gets one guess | **Threat and compliance** |
| G5 secstore | secstored listens on `127.0.0.1` by default (`secstored.b`, `lib/sh/profile`); on the network only with `-a` | On loopback, nothing an observer does not already have by holding the machine. With `-a`, a recording plus a future quantum computer gives the password, and with it every file in the store (factotum's keys among them) | **Compliance** by default; **threat and compliance** with `-a` |
| G6 auth(2) confirmation | Every authenticated 9P connection | None: HMAC-SHA-256 is not weakened by a quantum computer | **Compliance** (CNSA 2.0's hash is SHA-384/512) |
| G7 transport combiner | Every authenticated 9P connection in CNSA mode | None: SHA3-512 is a sound combiner | **Compliance** (CNSA 2.0 has SHA-3 only inside ML-KEM and ML-DSA) |
| G8 signer digest | The operator's comparison, out of band | None of note: 16 bytes are shown either way | **Compliance** |

**Breaking changes, made on purpose.** Each of these protocols was
changed in every mode, not only in CNSA mode, and none negotiates down:

- login(6) version 3: a signer and its clients must be updated together.
- secstore version 5: secstored refuses the version 4 exchange, so an
  old client cannot reach a new server.
- auth(2) `infernode-auth 3`: an authenticated 9P connection between an
  updated node and an older one is refused, whatever the mode.

Accounts, verifiers, keys and certificates are unchanged; only the
exchanges are. Each refusal tells the other end which version is spoken.
The project accepts these breaks now, while deployment is limited: one
exchange per protocol, with nothing to negotiate down to, gives an
attacker nothing to downgrade, leaves less to accredit, and is cheaper
to establish before there are fleets that depend on compatibility than
after. The changelog's Security section names each break.

## 6. Disposition

- CNSA 2.0 **algorithm primitives: complete** at Category 5 (FIPS 203/204/205/202; AES-256;
  SHA-384/512) — closes EPIC 3 acceptance item *"algorithm inventory documented."*
- CNSA 2.0 **strict-mode parameter compliance:** Met under CNSA-strict mode — G1, G2 and
  G4–G8 Closed, G3 Resolved as Not Applicable, G9 (the stored secrets' hash) Open (§5).
- Remaining: G9; the accreditor to confirm the G3 applicability determination (LMS/XMSS
  vs. SLH-DSA waiver); a cryptographer's review of the masked-seed construction (§3.7).

## 7. References

- NSA, *Announcing the Commercial National Security Algorithm Suite 2.0* (CNSA 2.0).
- NIST FIPS 203 (ML-KEM), 204 (ML-DSA), 205 (SLH-DSA), 202 (SHA-3), 197 (AES), 180 (SHA-2).
- NIST SP 800-208 (Stateful Hash-Based Signatures: LMS/XMSS).
- Implementation history: [`history/QUANTUM-SAFE-CRYPTO-PLAN.md`](../history/QUANTUM-SAFE-CRYPTO-PLAN.md),
  [`../../docs/CRYPTO-MODERNIZATION.md`](../CRYPTO-MODERNIZATION.md).
