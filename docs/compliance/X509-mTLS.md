# Compliance Evidence — X.509 / mTLS (Authenticated Encrypted Transport)

**Standard:** X.509 PKI (RFC 5280) + TLS (RFC 8446, RFC 5246), with **mutual**
authentication (mTLS) for the strongest form.
**Roadmap row:** Identity & authentication — X.509 / mTLS, Tier 0 ("`devssl` + 9P-over-TLS,
uniform").
**Tracking:** program epic [INFR-328]; client certificates over TLS [INFR-344].
**Artifact date:** 2026-11-16 (rewritten after the tranche-6 review of `x509.b`, `asn1.b`,
`pkcs.b` and `tls.b`; the artifact of 2026-06-22 named functions and lines that no longer
exist and claimed post-quantum certificate signatures that were never verified).
**Overall status:** **Met for TLS 1.3; TLS 1.2 is server-authenticated only.** TLS 1.3
authenticates the server, and the client too when the server asks (both roles are
implemented and tested against OpenSSL). Under TLS 1.2 the client answers a
CertificateRequest with no certificate. Node-to-node 9P uses the native STS exchange,
which is mutual.

## 1. What is met

| Capability | Mechanism | Evidence |
|------------|-----------|----------|
| TLS 1.3 and 1.2 with AEAD only | `TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`; TLS 1.2 ECDHE and RSA key exchange with AES-GCM | `appl/lib/crypt/tls.b`; `tests/host/tls_matrix_test.sh` (OpenSSL `s_server`) |
| Post-quantum key exchange | Hybrid X25519MLKEM768 offered first; SecP384r1MLKEM1024 alone under `/env/cnsatls` | [`NIST-PQC-migration.md`](NIST-PQC-migration.md); `tests/tls_hrr_test.b` |
| Certificate path validation (RFC 5280 §6) | `X509->verify_certchain` (roots in `/lib/certs`) and `verify_certchain_roots` (a caller's roots): signatures, validity of every certificate and of the anchor, basicConstraints, pathLenConstraint, keyUsage, name constraints (dNSName, iPAddress, directoryName), critical extensions processed or refused, policyConstraints' requireExplicitPolicy | `appl/lib/crypt/x509.b`; `tests/host/x509_chain_test.sh` (205 chains made for the run), `tests/x509_total_test.b`, `tests/x509_path_test.b` |
| One reading of a certificate | DER only (lengths, INTEGERs, BOOLEANs, strings, OIDs: `asn1.b`); the two signature algorithms of a certificate compared (§4.1.1.2); times in §4.1.2.5's two forms; an EC key on the curve its certificate names; ECDSA signatures in DER; string types decoded as what they are, and no NUL in a name | `appl/lib/asn1.b`, `x509.b`; the same tests |
| Signature algorithms | RSA PKCS #1 v1.5 (2048 to 8192 bits, odd exponent of 3 or more) and ECDSA on P-256 and P-384, each with SHA-256, SHA-384 or SHA-512. Nothing else verifies: no MD5, SHA-1, DSA, RSA-PSS or post-quantum signature **in a certificate** | `x509.b` `sigverify`; `pkcs.b` `decode_rsapubkey` |
| What a chain is for | `usage` argument: every certificate below the anchor with an extendedKeyUsage must allow server (or client) authentication, CAs included (CA/B Forum BR 7.1.2.10.6); the TLS client also holds the leaf to its keyUsage | `x509.b` `check_path`; `tls.b` `leafusage` |
| Host name | subjectAltName dNSName and iPAddress; commonName only when there is no subjectAltName; wildcards in the left-most label | `tls.b` `verifyhostname` |
| Revocation | CRLs: `/lib/crls/*.der` for the store, or a caller's list. A caller's CRL must be signed by a root or by a CA of the chain (with cRLSign if that CA has a keyUsage); a stale CRL is still applied; one that cannot be used fails every verification. Nothing fetches CRLs, and there is no OCSP | `x509.b` `check_revoked`; `tests/host/x509_chain_test.sh` |
| Trust store | The Mozilla roots in `/lib/certs` (`lib/certs/SOURCE`), read again whenever a file there changes | `x509.b` `load_trust_store`; `x509_total_test.b` PublicRoots, StoreReload |
| Server key pinning | `Config.pinspki`: SHA-256 of the server's SubjectPublicKeyInfo, replacing chain and name checks | `tls.b` `verifyspkipin`; `tests/host/tls_clientauth_test.sh` |
| **Mutual TLS, TLS 1.3** | Client: `Config.clientcert`/`clientkey` (ECDSA P-256), sent with a CertificateVerify when the server asks. Server: `ServerConfig.clientroots`, `clientcrls`, `clientneed`; the client's chain is verified for client authentication | `tls.b`; `tests/tls_server_test.b`, `tests/host/tls_clientauth_test.sh`, `tests/host/httpd_auth_test.sh` |
| After the handshake | A read is data, the peer's close_notify, or an error with its reason; record sizes, alerts, KeyUpdate both ways, sequence-number and key limits (RFC 8446 §5, §4.6.3) | `tls.b` `Conn.read`, `Conn.write`; `tests/tls_record_test.b`, `tests/host/tls_keyupdate_test.sh` |
| **Mutual** auth, node to node | Native STS exchange (`Keyring->auth`): both peers exchange and verify certificates of a common signer; the ssl algorithm then chosen is confirmed with the shared secret | `libinterp/keyring.c`; `appl/lib/auth.b`; `tests/auth_bind_test.b` |

## 2. What is not

- **TLS 1.2 client certificates.** A TLS 1.2 server's CertificateRequest is answered with
  an empty Certificate. A server that requires one refuses the handshake.
- **Post-quantum signatures in certificates.** Keyring has ML-DSA and SLH-DSA for the
  native STS certificates; the X.509 verifier does not take them (no public CA issues such
  certificates). An earlier version of this artifact listed them as met on the strength of
  OID constants that nothing looked up; the constants are gone.
- **P-521.** One root in the store has a secp521r1 key; libsec has no P-521, so nothing
  that root signs verifies.
- **Certificate policies.** No policy is asked for; a path that requires an explicit
  policy is refused rather than evaluated.
- **Revocation freshness.** CRLs are installed by an administrator; a CRL past its
  nextUpdate is used and reported, not replaced.
- **The clock after 19 January 2038.** `Daytime->now` and the `now` given to
  `verify_certchain_roots` are ints: from that date every verification fails (closed).

## 3. Disposition

- *Authenticated encrypted transport* (the substance of the Tier-0 row): **Met** —
  server-authenticated TLS 1.2 and 1.3 with RFC 5280 path validation, and mutual
  authentication on TLS 1.3 and on the native transport.
- *Mutual TLS under TLS 1.2*: **not provided**; use TLS 1.3.

## 4. References

- RFC 8446 (TLS 1.3) §4.4.2–4.4.3, §4.6, §5; RFC 5246; RFC 5280; RFC 5480; RFC 3279;
  CA/Browser Forum Baseline Requirements §6.1.5, §7.1.2.10.
- `appl/lib/crypt/tls.b`, `appl/lib/crypt/x509.b`, `appl/lib/crypt/pkcs.b`,
  `appl/lib/asn1.b`, `module/tls.m`, `module/x509.m`; `docs/CRYPTO-MODERNIZATION.md` §7.
