# Security Standards Roadmap — InferNode / NERVA

**Status:** Living document — 2026-06-15
**Audience:** engineering (backlog), and procurement / compliance / accreditors (evidence).

InferNode and NERVA target **government, banking, finance, and military** computing.
This document is the deliberate list of standards we aspire to, and — the part that
matters — **the Inferno-native mechanism that satisfies each one more simply than the
incumbents.** Every row should answer: *what does the standard require, and what is the
smallest clean Plan 9 / Inferno construct that delivers it.*

---

## The thesis: a small TCB you can actually verify

Every standard below reduces to four jobs: **mediate access, prove identity, protect
data, produce evidence.** Inferno already has the primitives that make those simple,
and a system small enough (<30 MB) to *evaluate*:

| Primitive | Standards leverage |
|-----------|--------------------|
| **Per-process namespaces** | Least privilege & MAC *by construction* — a process cannot name what isn't bound. No ambient authority. (SP 800-53 AC, MLS, Zero Trust.) |
| **Everything-is-a-file over Styx/9P** | One chokepoint for access control, mediation, and audit → a tiny reference monitor. (Common Criteria, FISMA AU, PCI.) |
| **Factotum** | One capability/credential agent; PKI, PIV, FIDO2, KMIP, HSM all become factotum protocols. (IA, key management.) |
| **Dis VM (Limbo)** | Memory-safe, type-safe, sandboxed — deletes whole CWE classes; bytecode is amenable to formal analysis. (Assurance, SC.) |

**The differentiator:** "our TCB is small enough to formally verify" is a claim Linux
and Windows can never make. We implement standards *as composable file services and
namespace policy*, not as bolted-on subsystems.

## How to read this — tiers

- **Tier 0 — Have:** shipped or substantially present today.
- **Tier 1 — Near-term:** achievable, high-leverage; the active backlog.
- **Tier 2 — Aspirational:** expensive (formal validation/evaluation), but the
  architecture is favorable; the moonshots.

---

## Standards by domain

### Cryptographic foundation
| Standard | Requires | Inferno-native mechanism | Tier |
|----------|----------|--------------------------|------|
| **FIPS 140-3** | Validated crypto module boundary | Consolidate all crypto behind `libsec`/`keyring` as the single validated surface | 2 |
| **CNSA 2.0** (NSA QR suite) | AES-256, SHA-384/512, ML-KEM, ML-DSA, LMS/XMSS | Signer already has **ML-DSA-65/87, SLH-DSA** (FIPS 204/205); add **ML-KEM** (FIPS 203) for KEX | 0→1 |
| **NIST PQC migration** | Hybrid classical+PQC | Negotiated in factotum/`devssl`, transparent to apps | 1 |

### Identity & authentication
| Standard | Requires | Inferno-native mechanism | Tier |
|----------|----------|--------------------------|------|
| **NIST SP 800-63B AAL3** | Hardware authenticator + verifier-impersonation resistance | FIDO2 key + **UV (PIN)** + touch via factotum (the PIV/CAC model) | 1 |
| **FIDO2 / CTAP2 / WebAuthn** | Origin-bound, phishing-resistant | `#F`/`/dev/2fa` device + `twofa` (built); generalize to auth surfaces | 0→1 |
| **FIPS 201 PIV / SP 800-157 Derived PIV** | Smartcard identity; mobile derived creds | PIV applet via factotum; derived PIV on the NFC key + `/phone` bridge | 1 |
| **X.509 / mTLS** | Authenticated encrypted transport | `devssl` + 9P-over-TLS, uniform | 0 |

### Federal / government
| Standard | Requires | Inferno-native mechanism | Tier |
|----------|----------|--------------------------|------|
| **NIST SP 800-53 / FISMA** | Control catalog (AC/AU/IA/SC/…) | Map families to namespace + 9P + factotum + audit (see table below) | 1 |
| **NIST SP 800-171 / CMMC** | CUI protection (defense contractors) | Subset of 800-53; the achievable near-term accreditation target | 1 |
| **Common Criteria (ISO 15408)** | Evaluated Protection Profile | Small TCB → target a *Separation Kernel PP* | 2 |
| **NIST SP 800-207 Zero Trust** | No implicit trust | Default posture (no ambient authority) — mostly document it | 0 |

### Military / classified
| Standard | Requires | Inferno-native mechanism | Tier |
|----------|----------|--------------------------|------|
| **MLS (Bell-LaPadula / Biba)** | No read-up / no write-down | Labels on namespaces; policy at bind time, not a kernel retrofit | 2 |
| **Cross-Domain Solutions / Raise-the-Bar** | Guarded transfer between domains | A guard process on a namespace boundary filtering 9P — the cleanest CDS substrate there is (flagship demo) | 1→2 |
| **Secure / measured boot, anti-tamper (TPM/DICE)** | Attested launch | Measured launch of the Dis runtime; attest image hash | 2 |

### Banking / finance
| Standard | Requires | Inferno-native mechanism | Tier |
|----------|----------|--------------------------|------|
| **PCI-DSS / PCI-PIN / P2PE** | Isolate + protect cardholder data | CHD in an isolated namespace behind one mediated 9P service; tokenize at the boundary | 1→2 |
| **HSM / PKCS#11 / KMIP / X9.24 (DUKPT)** | Managed key lifecycle | Factotum-backed; the YubiKey work generalizes to HSMs | 1 |
| **ISO 20022 / 8583, SWIFT CSP** | Message schemas + secure transport | Schema libs + a guarded transport service | 2 |
| **SOC 2** | Trust-services controls + evidence | Falls out of the audit-log service | 1 |

### Supply chain & integrity
| Standard | Requires | Inferno-native mechanism | Tier |
|----------|----------|--------------------------|------|
| **SLSA** | Build provenance | At **SLSA 3** today; push to L4 (hermetic/reproducible) | 0→1 |
| **SBOM (SPDX/CycloneDX), in-toto, Sigstore** | Signed artifacts + bill of materials | Sign Dis modules (git-signing work feeds this); LMS/XMSS firmware signing | 1 |

### Audit & assurance
| Standard | Requires | Inferno-native mechanism | Tier |
|----------|----------|--------------------------|------|
| **NIST SP 800-92 + tamper-evident logs** | Complete, integrity-protected audit | One hash-chained append-only 9P log service (`#`-device); Merkle-verifiable. Underwrites SOC 2, FISMA AU, PCI-10 at once | 1 |

---

## SP 800-53 control-family mapping (stub — Tier 1, highest leverage)

The artifact procurement and accreditors actually ask for. Fill the *Mechanism* and
*Evidence* columns as each lands.

| Family | Control theme | Inferno-native mechanism | Evidence | Status |
|--------|---------------|--------------------------|----------|--------|
| **AC** Access Control | Least privilege, separation | Per-process namespaces; capability (no ambient authority) | [`compliance/SP800-207-zero-trust.md`](compliance/SP800-207-zero-trust.md) — namespace mechanism, `verifyns`, formally verified isolation | strong — Zero Trust posture **Met**; AC family mapping to be itemized |
| **IA** Identification & Auth | MFA, PKI, AAL3 | Factotum + FIDO2/PIV; **UV/AAL3 verifier shipped & hardware-verified** (FIDO PIN load-bearing) | [`compliance/SP800-63B-AAL3.md`](compliance/SP800-63B-AAL3.md) — enrollment records, factotum protos, `t2uv` UV test | partial — AAL3 verifier ✅; DK save-back + dual-key open |
| **SC** System & Comms Protection | Crypto, boundary, TLS | `libsec` (AES-256-GCM, PQC), `devssl`, namespace boundaries | [`compliance/CNSA-2.0.md`](compliance/CNSA-2.0.md) — algorithm inventory (source-cited) | partial — PQC suite complete; CNSA-strict params (G1/G2) tracked |
| **AU** Audit & Accountability | Logging, integrity, retention | Hash-chained 9P audit-log service | log chain + verifier | planned |
| **SI** System & Information Integrity | Memory safety, malware | Dis VM type/memory safety; signed modules | CWE class elimination, signatures | partial |
| **CM** Configuration Management | Baselines, integrity | Reproducible builds, SLSA 3, signed `.dis` | provenance attestations | partial |
| **SR** Supply Chain | Provenance, SBOM | SLSA, in-toto, SBOM | attestations, SBOM | partial |

*(Remaining families — AT, CP, IR, MA, MP, PE, PL, PS, RA, CA — to be added as scoped.)*

---

## Near-term priorities (Tier 1, ordered)

1. **AAL3-harden the YubiKey login** — ✅ **UV-required (FIDO PIN) shipped & hardware-verified**
   (login FIDO-PIN prompt + key-derived vault + recovery slot); ☐ DK-only keyring save-back,
   ☐ dual-key default. See `doc/second-factor-auth.md`, `doc/yubikey-2fa-operations.md`. *First.*
2. **Tamper-evident audit-log service** — single highest-leverage control (AU + SOC 2 + PCI-10).
3. **CNSA 2.0 strict params** — ML-KEM/ML-DSA primitives done; negotiate ML-KEM-1024 (INFR-329) + ML-DSA-87 default (INFR-330). See [`compliance/CNSA-2.0.md`](compliance/CNSA-2.0.md).
4. **SP 800-53 / 800-171 control-mapping** — unlocks federal & finance conversations.
5. **CDS-guard reference demo** — the differentiator nobody else can show cleanly.
