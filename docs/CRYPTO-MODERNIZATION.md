# Cryptographic Modernization Summary

**Status:** Complete (Phase 1-5 + ElGamal fix + Post-Quantum FIPS 203/204/205)

This document summarizes the cryptographic modernization work done on Inferno/infernode to support autonomous agent systems requiring identity verification and non-repudiation.

## Design Decision

**Clean break approach** - No backward compatibility with weak crypto. All deployments must regenerate keys after updating.

## Changes Implemented

### 1. Ed25519 Signatures (Phase 3)

Ed25519 is now the default signature algorithm for all new keys.

| Aspect | Before | After |
|--------|--------|-------|
| Default algorithm | ElGamal | **Ed25519** |
| Key size | 256+ bytes | 32 bytes |
| Signature size | Variable | 64 bytes |
| Performance | Slow keygen | Instant keygen |

**Files modified:**
- `libkeyring/ed25519alg.c` (new) - Ed25519 implementation
- `appl/cmd/auth/signer.b` - Uses Ed25519 by default
- `appl/cmd/auth/createsignerkey.b` - Ed25519 first in algorithm list

### 2. SHA-256 for Certificates (Phase 2)

All certificate hashing now uses SHA-256 instead of SHA-1.

| Aspect | Before | After |
|--------|--------|-------|
| Certificate hash | SHA-1 (broken) | **SHA-256** |
| Password hash | SHA-1 | **SHA-256** |
| Protocol digest | Mixed | **SHA-256** |

**Files modified:**
- `appl/cmd/auth/signer.b` - SHA-256 for signing
- `appl/cmd/auth/createsignerkey.b` - SHA-256 for certificates
- `appl/cmd/auth/logind.b` - SHA-256 for protocol
- `appl/cmd/auth/mkauthinfo.b` - SHA-256 for certificates
- `appl/cmd/auth/changelogin.b` - SHA-256 for passwords
- `appl/cmd/auth/keysrv.b` - SHA-256 for secret hashing
- `appl/lib/login.b` - SHA-256 for protocol

### 3. Key Size Defaults (Phase 1)

Minimum key sizes increased to 2048 bits.

| Component | Before | After |
|-----------|--------|-------|
| Signer PKmodlen | 512 bits | **2048 bits** |
| Signer DHmodlen | 512 bits | **2048 bits** |
| User PKmodlen | 1024 bits | **2048 bits** |
| User DHmodlen | 1024 bits | **2048 bits** |

**Files modified:**
- `appl/cmd/auth/signer.b` - 2048-bit defaults
- `appl/cmd/auth/createsignerkey.b` - 2048-bit defaults

### 4. ElGamal Performance Fix

ElGamal 2048-bit key generation improved from 8 minutes to 2 seconds (215x speedup).

| Metric | Before | After |
|--------|--------|-------|
| 2048-bit keygen | 486,000 ms | **2,258 ms** |
| Speedup | - | **215x** |

**Solution:** Pre-computed RFC 3526 MODP Group 14 parameters.

**Files modified:**
- `libsec/dhparams.c` (new) - RFC 3526 parameters
- `libsec/eggen.c` - Uses pre-computed params when available
- `include/libsec.h` - `getdhparams()` declaration
- `libsec/mkfile` - Build dhparams.c

## Security Properties

After these changes:

- **Signatures:** Ed25519 provides 128-bit security with deterministic signatures
- **Certificates:** SHA-256 hash prevents collision attacks
- **Key exchange:** 2048-bit DH provides ~112-bit security
- **Login EKE:** login(6) version 2: nothing a guessed password can be tested against (see "Login: version 2")
- **TLS:** 1.3 and 1.2 with AEAD suites only (the SSL 3.0 client and its suites are gone)
- **Revocation:** CRL-based certificate revocation checking
- **Transport:** WireGuard + Rosenpass handles (external to Inferno)

### 5. Login Protocol: RC4 → ChaCha20-Poly1305 (Phase 4)

The login EKE protocol's temporary encryption of the DH exchange now uses ChaCha20-Poly1305 AEAD instead of RC4-40.

| Aspect | Before | After |
|--------|--------|-------|
| Cipher | RC4-40 (40-bit key) | **ChaCha20-Poly1305 AEAD** |
| Key derivation | SHA-256 folded to 8 bytes | **SHA-256(SHA-256(pw) \|\| salt)** = 32 bytes |
| Authentication | None | **Poly1305 tag (16 bytes)** |
| IV/Nonce | 8-byte IV | **32 bytes (20 salt + 12 nonce)** |

**Files modified:**
- `appl/lib/login.b` - Client-side AEAD encryption
- `appl/cmd/auth/logind.b` - Server-side AEAD encryption

**Breaking change:** Clients and servers must both be updated. Old clients cannot authenticate with new servers and vice versa.

**Superseded by login version 2** (below, "Login: version 2"). Sealing the
signer's Diffie-Hellman value with an AEAD gave anybody who asked for it a
tag to test passwords against; the value now goes under the cipher's
keystream with no tag.

### 6. SSL3 Weak Cipher Suite Rejection (Phase 5)

Weak cipher suites are now rejected during SSL3 negotiation before selection, rather than failing late during cipher activation.

**Blocked categories:**
- NULL ciphers (no encryption)
- RC4 (biased output, practical attacks)
- DES / DES-40 (56-bit or 40-bit keys, trivially brute-forced)
- Export-grade ciphers (intentionally weakened)
- Anonymous key exchange (no server authentication)
- FORTEZZA (unsupported)

**Remaining allowed suites:** 3DES-EDE-CBC and IDEA-CBC with RSA/DH/DHE key exchange and SHA-1 MAC.

**Files modified:**
- `appl/lib/crypt/ssl3.b` - Added `is_weak_suite()` filter in `find_cipher_suite()` (the module has since been removed: nothing in the tree speaks SSL 3.0; POP3 and webget's https use `tls(2)`)

### 7. Certificate Revocation Lists (Phase 5)

X.509 path validation (`X509->verify_certchain`, `verify_certchain_roots`) checks CRLs.

| Aspect | Before | After |
|--------|--------|-------|
| Revocation checking | None | **CRL-based** |
| CRL store | N/A | **`/lib/crls/*.der`** (DER-encoded CRLs), read again whenever a file there changes |
| A caller's CRLs | N/A | **`verify_certchain_roots(cs, roots, crls, now, usage)`**: each CRL signed by a root, or by a CA of the chain with the key the path verified (and cRLSign, if the CA has a keyUsage) |
| Check point | N/A | **As each certificate's issuer is found on the path**; an intermediate given as a trust anchor is checked against the roots' CRLs too |

A CRL past its `nextUpdate` is still applied (and said so on standard error when the store
is read): a stale list still names what it revoked. A CRL that cannot be used (not DER, a
critical extension that is not processed, a signature that is not its issuer's, an issuer
that is neither a root nor in the chain) fails every verification rather than being left
out. The store's own CRLs are not signature-checked: the directory is the administrator's.
Nothing fetches CRLs, and there is no OCSP.

**Files:**
- `appl/lib/crypt/x509.b` - `check_revoked`, `load_crl_store`
- `lib/crls/` - directory for CRL DER files (ships empty)

### 8. X.509 and TLS, as they stand (tranche-6 review)

The certificate code was reviewed against RFC 5280 and the TLS code against RFC 8446 and
RFC 5246; what follows replaces the earlier descriptions of both.

- **One reading of a certificate.** `asn1.b` decodes DER and nothing else (it took BER),
  and no longer encodes. A certificate's two signature algorithms are compared
  (RFC 5280 4.1.1.2); validity times are the two forms of 4.1.2.5; an EC key is a point of
  the curve its certificate names (P-256 or P-384, uncompressed); an ECDSA signature is DER;
  string types are decoded as what they are and a name has no NUL.
- **Keys and signatures taken.** RSA PKCS #1 v1.5 with a modulus of 2048 to 8192 bits and
  an odd exponent of 3 or more, and ECDSA P-256 and P-384, each with SHA-256, SHA-384 or
  SHA-512. Nothing else: no MD5 or SHA-1, no DSA, no RSA-PSS in certificates (TLS 1.3's
  CertificateVerify takes RSA-PSS), no post-quantum signature in a certificate.
- **Path validation.** Signatures, validity (the anchor's too), basicConstraints,
  pathLenConstraint, keyUsage, name constraints, critical extensions processed or refused,
  and a usage: every certificate below the anchor with an extendedKeyUsage must allow
  server (or client) authentication, CAs as well as the leaf.
- **What was removed.** `ssl3.b` and `sslsession.b`; from `pkcs.b` everything but the OID
  table, `RSAKey`, `decode_rsapubkey` and `rsa_encrypt` (PKCS #1 decryption and signing,
  DSS, PKCS #3 Diffie-Hellman, PKCS #5 password-based DES); from `x509.b` every encoder,
  `Signed.sign`, `verify_certpath` and the extension classes the path reads for itself;
  `asn1->encode`.
- **TLS after the handshake.** `Conn.read` is data, 0 for the peer's close_notify, or -1
  with the reason in the error string; record sizes are held to RFC 8446 5.1 and 5.2;
  KeyUpdate is handled both ways and sent before AES-GCM's limit of records under a key
  (5.5); renegotiation is refused. A TLS 1.2 client asked for a certificate sends an
  empty one (it has none to give under TLS 1.2).
- **The node-to-node exchange.** After `Keyring->auth`, the client's choice of ssl
  algorithm is confirmed by both ends with the shared secret and made part of ssl's keys
  (`appl/lib/auth.b`, version 2 of the exchange): it used to be one unauthenticated
  message. Both ends of a connection must be of this version.

See [`compliance/X509-mTLS.md`](compliance/X509-mTLS.md) for the evidence, test by test.

## What's Not Changed

### HMAC-SHA1

HMAC-SHA1 remains where a protocol still names it (HMAC-SHA1 is still considered secure; the attacks on SHA-1 are collision attacks, not applicable to HMAC). The SSL 3.0 client that used it is gone.

## Migration Guide

### For Existing Deployments

1. **Regenerate all keys:**
   ```sh
   # Generate new signer key with Ed25519
   auth/createsignerkey -a ed25519 signer_name
   # or, in CNSA mode (ML-DSA-87, SHA-384, a 3072-bit group; -a and -b
   # naming anything else are refused in the mode)
   auth/createsignerkey -c signer_name

   # Recreate user accounts
   auth/changelogin username
   ```
   A signer key made with `-c` before the mode was a rule has a 2048-bit
   Diffie-Hellman group and is refused by `logind` in CNSA mode: make it
   again. `createsignerkey -b` takes 2048 to 4096 bits (it took 32).

2. **Update client certificates:**
   - Old certificates will fail verification (SHA-1 vs SHA-256)
   - Clients must re-authenticate to get new certificates

3. **Update all clients and servers together:**
   - Login is version 2 of `login(6)` (incompatible with every exchange before it)
   - Both `login.b` (client) and `logind.b` (server) must be updated simultaneously

   What needs no action, because the programs do it:
   - `keyfs` converts a key file in the old format (AES-CBC under one SHA-1)
     to the current one (PBKDF2-HMAC-SHA-384, AES-256-GCM) when it starts,
     and says so; a backup made before is still in the old format.
   - A secstore account's verifier is moved to version 4 (made at the file
     key's cost) by its next login; the old verifier is removed after the
     first version 4 login (secstored(8)).

   What does need action:
   - A secstore file still in one of the two formats before SGCM2 is no
     longer read by a login: move it once with `auth/secstore m factotum`.
   - `svc/auth` no longer starts `auth/signer` and `auth/countersigner`
     (signer(8) says how to start them on purpose).
   - `p9any` and `p9sk1` are gone (their tickets are DES): nothing
     authenticates to a Plan 9 system, and `9export` serves one only
     with `-A`.

4. **Install CRLs (optional):**
   - Place DER-encoded CRL files in `/lib/crls/` for revocation checking
   - CRLs are matched by issuer name against certificate issuers; a file there that is not a usable CRL fails every verification until it is put right or removed

### For New Deployments

No action needed - Ed25519, SHA-256, and login version 2 are the defaults.

## Testing

### Ed25519

```sh
# Run Ed25519 test in Inferno
/tests/ed25519_test.dis
```

### ElGamal Performance

```sh
# Run keygen benchmark
/tests/keygen_benchmark.dis
```

## Related Documentation

- [QUANTUM-SAFE-CRYPTO-PLAN.md](history/QUANTUM-SAFE-CRYPTO-PLAN.md) - Full PQ crypto design document
- [CRYPTO-DEBUGGING-GUIDE.md](CRYPTO-DEBUGGING-GUIDE.md) - Debugging methodology
- [ELGAMAL-PERFORMANCE.md](history/ELGAMAL-PERFORMANCE.md) - Detailed performance analysis

## Commits

- `850e906a` - feat(crypto): Add Ed25519 signatures and modernize cryptography
- `172d7f7f` - Add RFC 3526 pre-computed DH params for fast ElGamal 2048-bit keygen

### 8. Post-Quantum Cryptography (FIPS 203/204)

Native implementations of NIST post-quantum standards, with no external dependencies.

#### ML-KEM (FIPS 203) — Key Encapsulation

| Parameter Set | Security Level | Public Key | Secret Key | Ciphertext | Shared Secret |
|---------------|---------------|------------|------------|------------|---------------|
| ML-KEM-768   | NIST Level 3  | 1184 bytes | 2400 bytes | 1088 bytes | 32 bytes      |
| ML-KEM-1024  | NIST Level 5  | 1568 bytes | 3168 bytes | 1568 bytes | 32 bytes      |

**Files created:**
- `libsec/sha3.c` — SHA-3/SHAKE (Keccak-f[1600], prerequisite for ML-KEM/ML-DSA)
- `libsec/mlkem_ntt.c` — NTT arithmetic (q=3329, Barrett/Montgomery reduction)
- `libsec/mlkem_poly.c` — Polynomial operations (CBD sampling, compress/decompress)
- `libsec/mlkem.c` — ML-KEM-768/1024 keygen/encaps/decaps (CPAPKE + FO transform)

**Keyring API:** `mlkem768_keygen/encaps/decaps`, `mlkem1024_keygen/encaps/decaps` (raw byte arrays)

#### ML-DSA (FIPS 204) — Digital Signatures

| Parameter Set | Security Level | Public Key | Secret Key | Signature  |
|---------------|---------------|------------|------------|------------|
| ML-DSA-65     | NIST Level 3  | 1952 bytes | 4032 bytes | 3309 bytes |
| ML-DSA-87     | NIST Level 5  | 2592 bytes | 4896 bytes | 4627 bytes |

**Files created:**
- `libsec/mldsa_ntt.c` — NTT arithmetic (q=8380417)
- `libsec/mldsa_poly.c` — Polynomial operations (sampling, packing, hint/decompose)
- `libsec/mldsa.c` — ML-DSA-65/87 keygen/sign/verify (rejection sampling)
- `libkeyring/mldsaalg.c` — SigAlgVec registration (mldsa65, mldsa87)

**Keyring API:** Registered as SigAlgVec (`genSK("mldsa65", ...)`, standard sign/verify)

#### Hybrid TLS 1.3 Key Exchange

X25519MLKEM768 (IANA group 0x11EC, 4588 decimal) hybrid key exchange per
draft-ietf-tls-ecdhe-mlkem. The client offers it first, with an X25519 share
beside it. P-256 and P-384 are offered in `supported_groups` without a share:
a server that takes only one of them asks for it by HelloRetryRequest
(RFC 8446 §4.1.4), and the client makes that share then. A share costs a
scalar multiplication, so a handshake no longer pays for two it rarely uses.

P-256 and P-384 themselves (`libsec/ecc.c`, under keyring's `p256_*` and
`p384_*`) are constant time with respect to secret scalars: Montgomery
arithmetic on 64-bit limbs (no libmp), complete projective formulas
(Renes–Costello–Batina 2016, a = -3), a fixed 4-bit window read by masked
scans, Fermat inversion. A key generation takes about 0.3 ms (P-256) and
0.9 ms (P-384), where the libmp version took 11 and 27.
`tests/host/ecc_test.sh` checks known answers from OpenSSL and, under
valgrind, that no branch or address depends on a secret.

secp256k1 (`libsec/secp256k1.c`, keyring's `secp256k1_*`: Ethereum keys and
transaction signatures) is built the same way for its p and n, with the
complete formulas for a = 0 (Algorithms 7 and 9) and the nonce inverted by
Fermat; a key generation or signature takes about 0.3 ms, a recovery 0.65,
where the libmp version took 11 and 23. `tests/host/secp256k1_test.sh`
checks signatures byte for byte against a reference checked against
OpenSSL, recovery's edges, and the same constant-time property.

Until October 2026 the constant was 0x4588, the decimal codepoint read as
hex, and the share was never sent: TLS was classical X25519 in practice.
`tests/tls_cnsa_hybrid_test.sh` now checks the group negotiated against
OpenSSL.

| Aspect | Classical | Hybrid |
|--------|-----------|--------|
| Client key share | 32 bytes (X25519) | 1216 bytes (ML-KEM pk + X25519) |
| Server response | 32 bytes | 1120 bytes (ML-KEM ct + X25519) |
| Shared secret | 32 bytes | 64 bytes (ML-KEM ss ‖ X25519 ss) |
| Fallback | — | X25519 if server doesn't support hybrid |

**Files modified:**
- `appl/lib/crypt/tls.b` — Hybrid key exchange in TLS 1.3 handshake
- `module/tls.m` — `X25519MLKEM768` constant

#### Certificates

ML-DSA signs the native (Keyring) certificates that the node-to-node exchange uses. It is
not an X.509 signature algorithm here: the X.509 verifier takes RSA and ECDSA only, and the
ML-DSA OID constants that `pkcs.m` once carried were looked up by nothing and have been
removed.

**Files modified:**
- `appl/cmd/auth/createsignerkey.b` — `mldsa65`/`mldsa87` algorithm options

#### Migration

```sh
# Generate ML-DSA-65 signer key
auth/createsignerkey -a mldsa65 signer_name

# Generate ML-DSA-87 signer key (higher security)
auth/createsignerkey -a mldsa87 signer_name
```

TLS hybrid key exchange is automatic — clients advertise X25519MLKEM768 first with X25519 fallback.
`/env/cnsatls` (the host `CNSATLS`) makes the client offer SecP384r1MLKEM1024
alone instead; see "CNSA 2.0 strict mode" below.

#### Testing

```sh
./emu/MacOSX/o.emu -r. /tests/sha3_test.dis
./emu/MacOSX/o.emu -r. /tests/mlkem_test.dis
./emu/MacOSX/o.emu -r. /tests/mldsa_test.dis
./emu/MacOSX/o.emu -r. /tests/tls_pq_test.dis
```

### 9. SLH-DSA (FIPS 205) — Stateless Hash-Based Signatures

Conservative backup for ML-DSA — no lattice assumptions, purely hash-based (WOTS+ + FORS + hypertree). Uses SHAKE-256 from `libsec/sha3.c`.

| Parameter Set | Security Level | Public Key | Secret Key | Signature |
|---------------|---------------|------------|------------|-----------|
| SLH-DSA-SHAKE-192s | NIST Level 3 | 48 bytes | 96 bytes | 16,224 bytes |
| SLH-DSA-SHAKE-256s | NIST Level 5 | 64 bytes | 128 bytes | 29,792 bytes |

**Architecture:** Five-layer construction:
- `slhdsa_hash.c` — ADRS address scheme, tweakable hash functions (F, H, T_l, PRF, H_msg)
- `slhdsa_wots.c` — WOTS+ one-time signatures (Winternitz w=16)
- `slhdsa_fors.c` — FORS few-time signatures (k=17/22 trees of height a=14)
- `slhdsa_tree.c` — XMSS tree and d-layer hypertree (sign/verify)
- `slhdsa.c` — Top-level keygen/sign/verify

**Files created:**
- `libsec/slhdsa.c` — SLH-DSA keygen/sign/verify
- `libsec/slhdsa_hash.c` — Tweakable hash functions, ADRS
- `libsec/slhdsa_wots.c` — WOTS+ one-time signatures
- `libsec/slhdsa_fors.c` — FORS few-time signatures
- `libsec/slhdsa_tree.c` — Merkle tree + hypertree
- `libkeyring/slhdsaalg.c` — SigAlgVec registration (slhdsa192s, slhdsa256s)

**Keyring API:** Registered as SigAlgVec (`genSK("slhdsa192s", ...)`, standard sign/verify). Uses slots 7-8 of the 8-slot `algs[]` array (all slots now filled).

**X.509:** none. The parameter sets' OIDs (id-slh-dsa-shake-192s is 2.16.840.1.101.3.4.3.28
and id-slh-dsa-shake-256s 2.16.840.1.101.3.4.3.30; this page once gave .22 and .26, which
are other sets) were constants in `pkcs.m` that nothing used, and are gone: the X.509
verifier takes no post-quantum signature.

**Files modified:**
- `include/libsec.h` — SLH-DSA declarations
- `libsec/mkfile` — Add 5 SLH-DSA source files
- `libkeyring/keys.h` — Bump Maxbuf to 49152, add init declarations
- `libkeyring/mkfile` — Add slhdsaalg.o
- `libinterp/keyring.c` — Register SLH-DSA algs + SHA-3 builtins
- `module/keyring.m` — SHA3-256/512 digest functions
- `appl/cmd/auth/createsignerkey.b` — SLH-DSA algorithm options

#### SHA-3 Keyring Builtins

SHA3-256 and SHA3-512 exposed to Limbo as one-shot digest functions:

```limbo
SHA3_256dlen: con 32;
SHA3_512dlen: con 64;
sha3_256: fn(buf: array of byte, n: int, digest: array of byte): int;
sha3_512: fn(buf: array of byte, n: int, digest: array of byte): int;
```

#### Migration

```sh
# Generate SLH-DSA-SHAKE-192s signer key (Level 3)
auth/createsignerkey -a slhdsa192s signer_name

# Generate SLH-DSA-SHAKE-256s signer key (Level 5)
auth/createsignerkey -a slhdsa256s signer_name
```

#### Testing

```sh
./emu/Linux/o.emu -r. /tests/slhdsa_test.dis
./emu/Linux/o.emu -r. /tests/sha3_test.dis
```

### 10. Native Transport Hybrid Key Agreement (9P / Styx)

The previous PQ work made the *TLS 1.3 client* (`appl/lib/crypt/tls.b`)
hybrid, but InferNode nodes do not talk to each other over that path — they
use the native Inferno authentication protocol (`Keyring->auth`, the
Station-to-Station handshake in `libinterp/keyring.c`) followed by the `ssl`
line-encryption device. That handshake derived its session key from
**classical Diffie-Hellman only**, so node-to-node 9P traffic was *not*
quantum-safe even with PQ certificates. This change closes that gap.

The STS handshake is now **protocol version 2** and performs a hybrid key
agreement. Because the protocol is symmetric (both peers run identical
code), it uses a **mutual ML-KEM-768 exchange**:

1. Each peer generates an ephemeral ML-KEM-768 keypair and sends its public
   key (`ek`, 1184 bytes) alongside the existing `alpha**r0`, certificate
   and public key.
2. Each peer encapsulates to the other's `ek` (sending a 1088-byte
   ciphertext) and decapsulates the ciphertext it receives.
3. Both `ek`s are bound into the signed STS transcript, so an active
   attacker cannot substitute ML-KEM keys without invalidating the
   signature. (The transcript signature hash was also upgraded SHA-1 →
   SHA-256.)
4. The session secret is

   ```
   SHA3-512("infernode-pq-sts-v2" || dh || kem_lo || kem_hi || ek_lo || ek_hi)
   ```

   where the two KEM secrets and `ek`s are ordered canonically by comparing
   the public keys, so both peers derive the identical 64-byte secret. That
   secret feeds the `ssl` device (since 0.10.1 split into a secret for each
   direction for AES-256-GCM; see section 11).

The result is safe unless **both** the Diffie-Hellman and the ML-KEM problem
are broken — directly addressing the harvest-now-decrypt-later threat on the
native transport.

| Aspect | v1 (classical) | v2 (hybrid) |
|--------|----------------|-------------|
| Key agreement | DH only | DH + mutual ML-KEM-768 |
| Session secret | raw `alpha**(r0*r1)` | `SHA3-512(dh ‖ kem ‖ eks)`, 64 bytes |
| Transcript signature hash | SHA-1 | SHA-256 |
| PQ ek/ct on the wire | — | 1184 B ek + 1088 B ct each way |
| Interop | — | **clean break**: v1 peers are rejected |

**Breaking change:** This is a clean break (consistent with the rest of this
document). A v2 node refuses to authenticate with a v1 (classical-only)
node; all nodes must be upgraded together.

**CNSA 2.0 strict mode.** When the host environment variable `CNSAMODE` is
set (any value other than empty, `0`, or one starting with `n`/`N`), the
handshake uses ML-KEM-1024 instead of ML-KEM-768 (`cnsamode()` in
`libinterp/keyring.c`). Every node in the fleet must agree: a 768/1024 pair
fails the public-key length check, with no fallback, and each side's error
says which of the two is in CNSA mode (`bad ml-kem public key length: the
peer is in CNSA mode (ML-KEM-1024), this node is not; set CNSAMODE alike`).
The policy is the environment of the process that started the emulator, so
set it where every way of starting one sees it: on macOS, both launchd
(`launchctl setenv`, which a LaunchAgent makes last) for the Dock and Finder,
and the shell's profile for a terminal. A bare-metal board has no host
environment: a file `cnsamode` on its card turns the mode on at boot
([BAREMETAL.md](BAREMETAL.md) section 5), through a kernel switch that
only turns on, and only before anything has authenticated, so no process
can make its own connections weaker than the machine's policy. Certificates follow the
signing key's strength (#304): `createsignerkey` and the other signer sites
choose SHA-384 for ML-DSA and SLH-DSA keys and SHA-256 for classical keys, and
record the choice in the certificate's `ha` field, which verifiers re-hash
from. `tests/cnsa_nodepair_test.sh` runs two CNSA-mode nodes through the
handshake with ML-DSA-87 certificates.

`CNSAMODE` does not touch TLS. CNSA-strict TLS (SecP384r1MLKEM1024 only,
TLS 1.3, `TLS_AES_256_GCM_SHA384`) is the host `CNSATLS`, reflected into
`/env/cnsatls`. Public servers do not offer that group, so it suits only a
network whose TLS servers are all its own; a node CNSA-strict to its peers
keeps the web, over X25519MLKEM768 where the server has it.

**Files modified:**
- `libinterp/keyring.c` — `Keyring_auth` hybrid handshake (ML-KEM exchange,
  transcript binding, SHA3-512 combiner, secret scrubbing)

**Files created:**
- `tests/pqauth_test.b` — covers the handshake end to end:
  - *HybridAuthHandshake* — both peers mutually authenticate and derive the
    **same** 64-byte hybrid secret (ed25519 signer).
  - *HybridHandshakeMLDSA* — same, with an ML-DSA-65 signer: a **fully
    post-quantum** handshake (PQ signatures + PQ KEM).
  - *HybridEncryptedChannel* / *HybridTcpChannel* — drives the real
    `Auth->client`/`Auth->server` + `ssl` path and round-trips a 9P-style
    payload over the encrypted channel (over a pipe, and over a real TCP
    socket; the TCP case skips where no IP stack is available).
  - *DowngradeRejected* — a v1 (classical-only) peer is refused.
  - *TamperedEkRejected* — flipping a byte in an ML-KEM public key fails the
    handshake (`bad certificate`), proving the transcript binding defends
    against an active KEM-substitution MITM.
  - *MalformedEkRejected* — a wrong-length ML-KEM key is rejected.

  The negative cases use a configurable man-in-the-middle relay between two
  real `auth()` endpoints.

```sh
./emu/Linux/o.emu -r. /tests/pqauth_test.dis -v
```

### 11. The line encryption: `ssl(3)` is AES-256-GCM (0.10.1)

The 64-byte secret from section 10 no longer feeds a choice of ciphers.
`ssl(3)` offers two algorithms and refuses the rest:

| Algorithm | What it is |
|-----------|------------|
| `aes_256_gcm` (default) | Each record sealed, its header authenticated; key and nonce from HKDF-SHA-384, record n's nonce n exclusive-ored in, so a record changed, cut, replayed, reordered or reflected is refused |
| `hmac_sha384` | Integrity alone |

`sha256` (SSL 2's hash, not an HMAC), `aes_128_cbc`, `aes_256_cbc` and the
padded record are gone. Each direction must have its own secret of at least
32 bytes, and the same secret both ways is refused; `ssl(2)`'s `secrets`
makes one shared secret into one for each way, which auth(2), login(2),
logind, secstore and secstored use. Every connection InferNode encrypts
(mount, listen, styxlisten, cpu, login, secstore, the grid registries, the
bare-metal cpu listener) takes it.

**Breaking change:** both ends must run 0.10.1 or later. `9cpu`, `import` and
`9export`, which speak to Plan 9 (p9sk1, a 56-bit key), refuse encryption
and run in the clear without `-e` (since then p9sk1 itself has gone, with
DES: see factotum(4)). `crypt(1)` uses AES-256-GCM with
PBKDF2-HMAC-SHA-384 and a salt per file.

Under it:

- **GHASH in constant time.** It indexed a table by nibbles of the running
  hash; it is now PMULL where the processor has it and table-free integer
  multiplication otherwise (after BearSSL). AES and SHA-256 use the ARMv8
  instructions where `ID_AA64ISAR0_EL1` says the core has them, in the
  emulator and the native kernels.
- **AES in constant time without the instructions.** Where the processor
  has no AES instructions (amd64 as the emulator is built, the Pi 3 and 4,
  RISC-V) `libsec/aes.c` was four tables indexed by the key exclusive-ored
  with the data, which a cache shared with an attacker shows. It is
  bitsliced now: eight 64-bit words hold one bit each of up to four
  blocks, SubBytes is Boyar and Peralta's 113-gate circuit, and nothing
  is indexed or branched on. It costs speed: AES-256-GCM about half what
  it was on amd64 (55 MB/s against 109), CBC decryption the same, CBC
  encryption a seventh (25 against 172), since a chained block cannot
  share the words with three others. `tests/host/armcrypto_test.sh`
  holds it to FIPS 197, SP 800-38A, OpenSSL's GCM answers and a plain
  reference, and runs it under valgrind with key and data secret.
- **Private keys and nonces away from the clock.** RSA's private
  operation is `libmp`'s `mpexpcrt`: both powers and Garner's
  recombination in Montgomery arithmetic at the primes' length, no
  division, on an input blinded with a fresh random number
  (`libsec/rsadecrypt.c`). A DSA, ElGamal or ECDSA nonce is RFC 6979's
  with 32 random bytes beside the key and the digest (its section 3.6),
  so a generator that repeats does not repeat a nonce; DSA inverts it as
  a power and makes s with `mpmuladdmod`; ElGamal, whose modulus p-1 is
  even, inverts it blinded and says in `libsec/egsign.c` what remains
  general arithmetic. `tests/host/rsa_edge_test.sh`,
  `tests/host/sign_nonce_test.sh` and `tests/host/ecc_test.sh` hold them
  to known answers (RFC 6979's own for P-256 and P-384) and to valgrind.
- **One generator, NIST's.** Every random number, in the emulator
  (`libsec/genrandom.c`) and the native kernels (`os/port/random.c`), comes
  from HMAC_DRBG with SHA-512 (SP 800-90A Rev. 1, `libsec/hmacdrbg.c`),
  checked against NIST's CAVP vectors before its first output. ChaCha20,
  which it replaced, is on no NIST or CNSA list. See
  [TLS-ENTROPY.md](TLS-ENTROPY.md).
- **Login in CNSA mode** hides its Diffie-Hellman value under AES-256-GCM's
  keystream with HKDF-SHA-384 rather than ChaCha20's with HKDF-SHA-256, in a
  group of 3072 bits or more; a signer in CNSA mode refuses the latter and
  says why. (See "Login: version 2".)

Tests: `tests/ssl_record_test.b`, `tests/ssl_transport_test.b`,
`tests/libsec_kat_test.b`, `tests/login_test.b`,
`tests/host/armcrypto_test.sh`, `tests/host/kernrandom_test.sh`,
`tests/host/emurandom_test.sh`.

## Login: version 2

`login(6)` is Bellovin and Merritt's encrypted key exchange with the signer's
Diffie-Hellman value alone encrypted. A review found that three of that
protocol's properties had been lost and one had never been there:

| What was wrong | What a peer could do | Now |
|----------------|----------------------|-----|
| The signer's value was sealed by an AEAD under the password's key, and sent to anybody who gave a name | Try passwords offline against one reply: the right one's tag verifies | The value is sent under the AEAD's keystream with no tag, with a random sign, in a group whose prime begins with 64 one bits: every password unmasks it to a number a signer could have sent |
| The key and nonce of that message came from the client's ivec alone | Have the signer encrypt new values under one keystream | The signer's own 32 random bytes are in the key derivation |
| The signer spoke next, under the session's keys, to a client that had proved nothing | Choose r1 and try passwords against that message | The client sends a proof made from the secret, the password and everything said; the signer checks it before it sends anything made from the secret, then proves itself |
| Neither end checked the other's Diffie-Hellman value | Send 0, 1 or p-1 and be issued a certificate for any account with no password | Both refuse a value outside 2..p-2 (SP 800-56A 5.6.2.3.1), and the exponents carry the cofactor 2 |
| The client took alpha and p from whoever answered, with no floor | A relay sent p = 2 and was taken for the signer | The groups are RFC 3526's 14, 15 and 16, held by both ends and named by number; 2048 bits at least, 3072 in CNSA mode |
| A name was used as a path and as the throttle's key as it came | `carol/.` logged in as carol with a count of its own; `../../tmp/x` took its password from a file | One rule for an account name (`Login->okname`), applied before a name is acknowledged, counted, looked up or signed |

The signer's key file still carries an `alpha` and `p`; they are not used by
the login exchange and reach the client under the session's keys, for
`auth(2)`.

**Breaking change:** both ends must speak version 2. Nothing is negotiated:
an old client is told `signer speaks login version 2`, and a new client
given the old signer's answer says the signer speaks the old exchange.
Password entries (`keyfs`) and certificates already issued are unchanged.

`auth/passwd` and `keysrv(4)` now speak one protocol, which they did not
(passwd proved the old secret one way and keysrv checked it another, so no
change ever worked). The server proves it is the signer: it runs with the
signer's key, whose name `logind` and `signer` certify for nobody else, and
passwd asks for nothing until it has seen that. The old password is proved
by answering a challenge of the server's, fresh for every write; the new one
is sent as its SHA-256, which is what `keyfs` holds, sealed under a key from
the old; wrong proofs are counted in `logind`'s throttle.

`signer(8)`, `countersigner`, `keysrv(4)` and `changelogin(8)` take a name by
the same rule as `logind`.

Tests: `tests/login_test.b`, `tests/host/login_test.sh`,
`tests/signer_test.b`, `tests/passwd_test.b`.

## Security Properties (Updated)

After all changes, the complete SigAlgVec registry:

| Slot | Algorithm | Type | Security |
|------|-----------|------|----------|
| 1 | ed25519 | Classical | 128-bit |
| 2 | elgamal | Classical | ~112-bit (2048-bit) |
| 3 | rsa | Classical | Variable |
| 4 | dsa | Classical | Variable |
| 5 | mldsa65 | Post-Quantum (lattice) | NIST Level 3 |
| 6 | mldsa87 | Post-Quantum (lattice) | NIST Level 5 |
| 7 | slhdsa192s | Post-Quantum (hash) | NIST Level 3 |
| 8 | slhdsa256s | Post-Quantum (hash) | NIST Level 5 |

## Future Work

Optional improvements not yet implemented:

1. **OCSP stapling** - Online certificate status checking (alternative to CRL)
2. **CRL auto-fetch** - Fetch CRLs from CRL Distribution Point URLs in certificates
3. **Client certificates under TLS 1.2** - the TLS 1.3 client and server have them; a TLS 1.2 client sends none
