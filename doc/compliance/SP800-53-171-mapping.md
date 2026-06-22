# Compliance Evidence — NIST SP 800-53 / SP 800-171 Control-Family Mapping

**Standards:** NIST SP 800-53 Rev 5 (control catalog, FISMA) and NIST SP 800-171 Rev 2
(CUI protection; the CMMC Level 2 basis).
**Roadmap row:** Federal / government — SP 800-53 / FISMA and SP 800-171 / CMMC, Tier 1.
**Tracking:** EPIC 4 — control mapping & evidence ([`../security-epics.md`](../security-epics.md)); program epic [INFR-328].
**Artifact date:** 2026-06-22.
**Overall status:** **Partial — first pass complete.** All SP 800-53 Rev 5 families are
mapped to an Inferno-native mechanism with an evidence pointer and an honest status. The
technically-load-bearing families (AC, IA, SC, AU, SI, CM, SR, CA) have dedicated evidence;
the organizational families are marked as operator responsibility with the technical
support InferNode provides. The **SP 800-171 / CMMC subset** is called out as the first
accreditation target (§3).

---

## 1. Purpose

This is the artifact procurement and accreditors ask for: control family → *what InferNode
does* → *where the evidence is* → *status*. It is deliberately a **family-level** first
pass; per-control (e.g. AC-3, AU-9) enumeration is added as each family is scheduled. It
does not overstate: where a control is organizational (policy, personnel, physical), it
says so and names only the technical support the product provides.

## 2. How to read a row

- **Technical control** — InferNode the runtime implements the control mechanism. Evidence
  is code + test + (often) formal verification.
- **Operator responsibility** — the control is satisfied by the *operating organization's*
  policy/process; InferNode provides technical support but cannot be "compliant" on its own.
  An accreditor expects this split; claiming a product satisfies, e.g., PS (Personnel
  Security) by itself is a red flag.

The thesis (`../security-standards-roadmap.md`): InferNode reduces most *technical* control
families to **namespace + 9P + factotum + a small, formally-verified TCB**, which is why the
AC/SC/IA/AU/SI evidence is unusually strong for a system this size.

## 3. First accreditation target: SP 800-171 / CMMC Level 2

SP 800-171 Rev 2 (110 requirements across 14 families: AC, AT, AU, CM, IA, IR, MA, MP, PE,
PS, RA, CA, SC, SI) is the achievable near-term target and the basis for **CMMC Level 2**
(defense-contractor CUI). It is a subset of 800-53. Of its 14 families, the ones InferNode
satisfies *technically and strongly* — **AC, AU, IA, SC, SI, CM** — are exactly where the
product, not the organization, carries the control. The remainder (AT, IR, MA, MP, PE, PS,
RA, CA) are largely operator responsibility for which InferNode supplies supporting
technical evidence. **Recommendation:** scope the CMMC L2 SSP around the six strong families
first; they are the controls a generic Linux/Windows host cannot evidence as cleanly.

---

## 4. SP 800-53 Rev 5 family mapping (all families)

| Family | Theme | Type | Inferno-native mechanism | Evidence | Status |
|--------|-------|------|--------------------------|----------|--------|
| **AC** Access Control | Least privilege, separation, flow | Technical | Per-process namespaces = capability; default-deny bind-replace; `NODEVS` device gate; capability attenuation (child ≤ parent) | [`SP800-207-zero-trust.md`](SP800-207-zero-trust.md); `appl/veltro/SECURITY.md`; `formal-verification/` | **Strong** |
| **AU** Audit & Accountability | Logging, integrity, retention | Technical | Today: `emitauditlog()` (namespace ops), subagent trajectory logging. Planned: hash-chained append-only 9P audit-log service | `appl/veltro/SECURITY.md`; EPIC 2 (planned) | **Partial → planned** (see §5.AU) |
| **IA** Identification & Auth | MFA, PKI, AAL3 | Technical | Factotum credential agent; FIDO2 UV (AAL3) login; PQ-capable X.509 / mTLS | [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md); `docs/AUTHENTICATION.md`, `docs/DISTRIBUTED-AUTH.md` | **Strong** (AAL3 verifier shipped) |
| **SC** System & Comms Protection | Crypto, boundary, transport | Technical | `libsec` (AES-256-GCM, SHA-384/512, full PQC); hybrid TLS + hybrid native STS; namespace boundaries | [`CNSA-2.0.md`](CNSA-2.0.md); `docs/CRYPTO-MODERNIZATION.md` | **Strong** (CNSA-strict params tracked) |
| **SI** System & Information Integrity | Memory safety, malware, flaws | Technical | Dis VM: type-safe, memory-safe, sandboxed bytecode → eliminates whole CWE classes (no raw pointers, bounds-checked); CodeQL + fuzzing in CI | `doc/dis.ms`; `.github/workflows/security.yml` (CodeQL), `fuzz.yml`; `tests/handshake_fuzz_test.b` | **Strong** (see §5.SI) |
| **CM** Configuration Management | Baselines, integrity of components | Technical | Reproducible Plan 9 `mk` builds; `.dis` path-integrity verifier; SHA-pinned CI actions; tracked `dis/` runtime tree | `.github/workflows/verify-dis-paths.yml`; `tools/verify-dis-paths.sh`; `CLAUDE.md` (dis integrity) | **Strong** (see §5.CM) |
| **SR** Supply Chain Risk | Provenance, integrity of artifacts | Technical | SLSA build provenance attestations; cosign keyless (Sigstore) signing; SHA256SUMS; OpenSSF Scorecard | `.github/workflows/release.yml:1257-1288`; `scorecard.yml` | **Strong** (see §5.SR) |
| **CA** Assessment, Auth & Monitoring | Continuous assessment | Technical+Org | Formal verification in CI (TLA+/SPIN/CBMC); CodeQL/Scorecard/fuzz continuous scanning; ring-fence guard | `formal-verification/`; `.github/workflows/` (formal-verification, security, scorecard, fuzz); `CLAUDE.md` (ring-fence) | **Strong (technical)**; assessment process = operator |
| **RA** Risk Assessment | Vuln scanning, risk | Technical+Org | CodeQL, fuzzing, OpenSSF Scorecard, formal verification feed risk posture; threat models in security docs | `.github/workflows/{security,fuzz,scorecard}.yml`; `docs/NAMESPACE_SECURITY_REVIEW.md` §3 (threat model) | **Partial** (tooling ✅; org RA process = operator) |
| **SA** System & Services Acquisition | SDLC, dev security | Technical+Org | Memory-safe Limbo SDLC; formal-verification methodology; in-tree security review process | `formal-verification/METHODOLOGY.md`; `CONTRIBUTING.md`; `SECURITY.md` | **Partial** |
| **PT** PII Processing & Transparency | Privacy | Technical+Org | Data-minimizing namespace isolation (agents see only granted data); no telemetry by default | `appl/veltro/SECURITY.md` | **Partial** (privacy *policy* = operator) |
| **CP** Contingency Planning | Backup, recovery | Operator | Technical support: durable mailbox journal; secstore backup procedure; stateless re-clone of `dis/` tree | `doc/yubikey-2fa-operations.md` §8 (backup); INFR-302 (durable journal) | **Operator** (technical support noted) |
| **IR** Incident Response | Detection, handling | Operator | Technical support: audit-log evidence (EPIC 2), `nsaudit` config review, security-advisory process | `SECURITY.md`; EPIC 2 | **Operator** |
| **MA** Maintenance | Controlled maintenance | Operator | Technical support: signed updates (SR), reproducible builds (CM) | release.yml | **Operator** |
| **MP** Media Protection | Media handling, sanitization | Operator+Technical | Technical support: AES-256-GCM data-at-rest (secstore vault, DK-wrapped); zeroization of key material in `libsec` | `doc/yubikey-2fa-operations.md` §9; `docs/QUANTUM-SAFE-CRYPTO-PLAN.md` §5 (zeroization) | **Partial** |
| **PE** Physical & Environmental | Facility, hardware | Operator | Technical support: hardware authenticator (FIDO2) ties logical to physical possession | [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md) | **Operator** |
| **PL** Planning | SSP, rules of behavior | Operator | This evidence register + roadmap feed the SSP | `../security-standards-roadmap.md`; this dir | **Operator** |
| **PS** Personnel Security | Screening, access agreements | Operator | n/a (organizational) | — | **Operator** |
| **AT** Awareness & Training | Security training | Operator | n/a (organizational) | — | **Operator** |
| **PM** Program Management | Security program governance | Operator | Program epic + roadmap provide the governance artifacts | [INFR-328]; `../security-standards-roadmap.md` | **Operator** |

---

## 5. Deep-dive evidence (load-bearing families)

### 5.AC / IA / SC — covered by dedicated artifacts
See [`SP800-207-zero-trust.md`](SP800-207-zero-trust.md) (AC, least privilege, separation —
formally verified), [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md) (IA, AAL3 verifier), and
[`CNSA-2.0.md`](CNSA-2.0.md) (SC, crypto suite). Not repeated here.

### 5.SI — System & Information Integrity
The integrity story is **architectural**: application code runs as **Dis bytecode in a
type-safe, memory-safe VM** (`doc/dis.ms`). There are no raw pointers, array accesses are
bounds-checked, and modules are type-checked at load (the `link typecheck` rejection noted
in `CLAUDE.md`). This **eliminates entire CWE classes** (buffer overflows, use-after-free,
type confusion) for the ~700 Limbo applications — the SI-2/SI-16 memory-protection controls
are met by construction for the application layer.

For the C TCB (emu/libsec/libinterp), integrity is evidenced by:
- **CodeQL** semantic analysis on every push (`.github/workflows/security.yml`).
- **Fuzzing** (`.github/workflows/fuzz.yml`; `tests/handshake_fuzz_test.b`).
- **Formal verification** of the namespace primitives on real C
  (`formal-verification/`, §3 of the Zero Trust artifact).

*Residual:* C-layer CodeQL findings are triaged (e.g. INFR-315/316 — DES weak-crypto
dispositions, noreturn FPs); tracked, not silent.

### 5.CM — Configuration Management
- **Reproducible builds** via Inferno-native `mk` (same toolchain builds the system and the
  apps; `CLAUDE.md` "Why Native Tools").
- **Bytecode integrity:** `tools/verify-dis-paths.sh` + the `verify-dis-paths` CI workflow
  refuse any commit where a compiled `.dis` is missing or older than its source — preventing
  the "stale/ wrong-target bytecode" class. Pre-commit hook enforces locally; CI is the
  universal backstop.
- **Pinned dependencies:** CI actions are pinned to commit SHAs (see `release.yml`), not
  floating tags — a CM-2/CM-7 supply-integrity property.
- **Ring-fence guard:** CI fails the build if testing-only harness files (`serve-agent*`,
  `*agent-harness*`) leak into a release artifact (`CLAUDE.md` "Ring-fence rule";
  `release.yml`, `ci.yml`). A configuration-baseline control enforced in CI.

### 5.SR — Supply Chain Risk Management
The release pipeline (`.github/workflows/release.yml`) produces, for every artifact:
- **SHA-256 checksums** (`SHA256SUMS.txt`, `:1257-1261`).
- **Cosign keyless signatures** via Sigstore (`.sigstore` bundles, `:1263-1278`) — verifiable
  against the OIDC identity of the build, no long-lived signing key to steal.
- **SLSA build provenance attestations** (`actions/attest-build-provenance`, `:1280-1288`)
  for the tarball, DMG, and zip — the SLSA-3 provenance the roadmap claims.
- **OpenSSF Scorecard** (`scorecard.yml`) continuous supply-chain posture scoring.

*Residual / next:* SBOM (SPDX/CycloneDX) generation and in-toto attestation are the
documented push to SLSA L4 (roadmap "Supply chain & integrity"). Tracked under EPIC 4/SR.

### 5.AU — Audit & Accountability (the gap)
Today auditing is **per-subsystem**: `emitauditlog()` records namespace operations and the
agent stack logs subagent trajectories. There is **no single, tamper-evident, hash-chained
audit service yet** — that is EPIC 2 (planned), the single highest-leverage control (it
underwrites AU-9 integrity-of-audit, SOC 2, and PCI-10 simultaneously). Honest status:
**partial today, with the high-value piece planned.**

---

## 6. Disposition & next steps

- **First pass complete:** every 800-53 family mapped with mechanism + evidence + honest
  type/status; six families (AC, IA, SC, SI, CM, SR) are technically strong and CA is strong
  on the technical side.
- **CMMC L2 framing:** scope the SSP around the six strong families; they are the
  hard-to-fake controls.
- **Biggest single lever:** the AU hash-chained audit service (EPIC 2) — turns AU from
  partial to strong and carries SOC 2 / PCI-10 with it.
- **Recommended tickets:** (a) per-control itemization for AC/IA/SC/AU under [INFR-328];
  (b) SBOM generation for SR (SLSA L4 push); (c) the AU audit-log service design (EPIC 2,
  *new code — bring design first*).

## 7. References

- NIST SP 800-53 Rev 5; NIST SP 800-171 Rev 2; CMMC 2.0 Level 2.
- Sibling evidence: [`CNSA-2.0.md`](CNSA-2.0.md), [`SP800-207-zero-trust.md`](SP800-207-zero-trust.md),
  [`SP800-63B-AAL3.md`](SP800-63B-AAL3.md).
- In-tree: `appl/veltro/SECURITY.md`, `formal-verification/`, `.github/workflows/`,
  `docs/AUTHENTICATION.md`, `docs/DISTRIBUTED-AUTH.md`, `doc/dis.ms`.
