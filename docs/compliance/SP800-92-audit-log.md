# Evidence — Tamper-Evident Audit Log (SP 800-92 / SP 800-53 AU family)

**Standard:** NIST SP 800-92 (Log Management) + SP 800-53 **AU** family
(esp. AU-9 protection of audit information); underwrites **SOC 2** (CC7.x logging
& monitoring) and **PCI-DSS Req 10** (track & monitor access).
**Tier:** 1. **Program epic:** [INFR-328]. **Implementation stories:** INFR-343.
**Date:** 2026-06-26. **Supersedes the design** in
[`SP800-92-audit-log-DESIGN.md`](SP800-92-audit-log-DESIGN.md) (approved → built).

**Overall family status: Substantially met.** The integrity and non-repudiation
core — the hard, high-leverage part of the family — is implemented, evidenced, and
regression-tested (AU-3, AU-8, AU-9, AU-9(3), AU-10). Operational tooling
(AU-4/5/6/7 storage-full handling, automated review, reduction) remains partial
and is tracked. No claim below is asserted without a `file:line`, test, or commit
pointer.

> **Deployment default (accreditor note).** Auditing is **off by default** in the
> general build — most installs do not need it, and the facility is loosely coupled
> (emitters are no-ops when `/mnt/audit` is unmounted). The boot profile
> (`lib/sh/profile`) mounts `auditfs` only when the opt-in marker
> `/usr/inferno/audit/on` exists. **A compliant deployment MUST enable it** — either
> `touch /usr/inferno/audit/on` (chain-only) or `sh /lib/sh/audit-setup` (enable +
> factotum-signed checkpoints). This is a deliberate general-vs-hardened split; an
> on-by-default hardened/compliance profile is tracked as **INFR-357**, not yet built.

---

## 1. What was built

A single append-only, **tamper-evident** log service, composed from existing
Inferno parts (a Styx file server + `keyring` + the namespace) rather than a new
subsystem. A log is a file; writing an event is writing a line; verifying integrity
is recomputing a hash chain. No new C device, no daemon, **no JSON**.

| Component | Source | Role |
|-----------|--------|------|
| Hash-chain core | [`appl/lib/auditchain.b`](../../appl/lib/auditchain.b), [`module/auditchain.m`](../../module/auditchain.m) | `H[0]=SHA-256(genesis)`, `H[n]=SHA-256(H[n-1]‖record)`; composes `keyring->sha256`, adds no new crypto |
| Log file server | [`appl/cmd/auditfs.b`](../../appl/cmd/auditfs.b) | Styx server at `/mnt/audit`; serves `log`/`chain`/`head`/`verify`/`pubkey`/`ctl` |
| Offline verifier | [`appl/cmd/auditverify.b`](../../appl/cmd/auditverify.b) | Standalone recompute + signature check; runs off-host against an exported chain |
| Client | [`appl/lib/audit.b`](../../appl/lib/audit.b), [`module/audit.m`](../../module/audit.m) | Thin, optional, fail-open emit sugar over a write to `/mnt/audit/log` |
| Boot integration | [`lib/sh/profile:86-99`](../../lib/sh/profile) | Mounts `auditfs` **before** the auth services so their events are captured |
| Man page | [`man/4/auditfs`](../../man/4/auditfs) | Operator reference |

Commits: `ef6447e` (server core), `ab2e907` (signed checkpoints + verifier + client),
`6ebb716` (secstore emitter), `67105ea` (boot), `9a69468` (2fa + factotum emitters).
Merged to `main` in **PR #292**.

## 2. Per-control evidence

| Control | Requirement | Mechanism & evidence | Status |
|---------|-------------|----------------------|--------|
| **AU-2** Event Logging | Log an agreed set of security events | Authentication: `secstored` emits `authfail`/`authok` ([`appl/cmd/auth/secstored.b:192,197`](../../appl/cmd/auth/secstored.b)). Identity lifecycle: `2fa` emits `enroll`/`disable` ([`appl/cmd/2fa.b:117,166`](../../appl/cmd/2fa.b)). Credential lifecycle: `factotum` emits `keyadd`/`keydel` ([`appl/cmd/auth/factotum/factotum.b:270,286`](../../appl/cmd/auth/factotum/factotum.b)). | **Substantially met** — auth + credential/identity events covered; broader subsystem coverage (CDS, veltro) tracked under AU-12. |
| **AU-3** Content of Audit Records | Records carry enough to reconstruct the event | Each sealed record is `seq time source event hash msg` — server-assigned sequence and time, originating subsystem, event type, chain hash, and message ([`appl/cmd/auditfs.b:303-321` `appendrec`](../../appl/cmd/auditfs.b)). Canonical form in [`auditchain.b:56` `canon`](../../appl/lib/auditchain.b). | **Met** |
| **AU-8** Time Stamps | Records use trustworthy timestamps a writer cannot forge | The **server** assigns the timestamp via `daytime->now()` at seal time ([`auditfs.b:309`](../../appl/cmd/auditfs.b)); the writer supplies only `source event msg` and so cannot backdate or reorder. | **Met** for record-time integrity. *Residual:* authoritative/synchronized time source (AU-8(1), NTP/host-clock attestation) not addressed — gap noted in §3. |
| **AU-9** Protection of Audit Information | Protect audit data from unauthorized modification/deletion; make tampering detectable | (a) **Integrity:** linear SHA-256 hash chain — editing, reordering, or deleting any record changes its hash and every later one; `replay` recomputes and reports the first break ([`auditfs.b:323-343` `replay`](../../appl/cmd/auditfs.b)). (b) **Access control by namespace placement:** `log` is write-only `8r222`; `chain`/`head`/`verify`/`pubkey` read-only `8r444` ([`auditfs.b:156-161`](../../appl/cmd/auditfs.b)). Bind only `log` into a subject's name space and it can append but cannot read or rewrite history — an agent cannot cover its tracks. (c) **External anchor:** `head` (`hash seq`) is shippable off-host, so even a full rewrite of the backing file is detectable. | **Met** — this is the headline control. |
| **AU-9(3)** Cryptographic Protection | Use cryptography to protect audit integrity | SHA-256 hash chain (above) plus signed checkpoints (below). | **Met** |
| **AU-10** Non-Repudiation | Bind records to an origin such that the binding is verifiable and cannot be repudiated | `ctl`←`checkpoint` signs the current chain tip with a `keyring`/`createsignerkey` key and exposes the public key at `pubkey` ([`auditfs.b:289-300` `signhead`](../../appl/cmd/auditfs.b)); `auditverify -k pubkey` verifies every checkpoint signature offline ([`auditverify.b:87,123`](../../appl/cmd/auditverify.b)). The verifier holds **no secret** — verification is by public key. | **Substantially met** — *residual:* records since the last checkpoint are chain-protected but not yet signature-covered (unsigned-tail window); the signing key is held by `auditfs` itself. Both tracked (§3, INFR-356). |
| **AU-12** Audit Record Generation | Generate records across system components | Emitters wired at the auth/identity/credential chokepoints (AU-2 row); any subsystem can emit with one optional `load Audit` + `audit->log()`. | **Substantially met** — auth stack wired; CDS guard / veltro provenance pending (INFR-355). |
| **AU-4 / AU-5** Storage Capacity / Response to Failure | Provision audit storage; alert/act on audit failure | The client is intentionally **fail-open** ([`audit.b:25-35`](../../appl/lib/audit.b)) — absence returns `-1` and the caller chooses fail-closed for high-value events. No storage-full quota or automated alerting yet. | **Partial** — operational gap (§3). |
| **AU-6 / AU-7** Review, Analysis, Reporting / Reduction | Review and report on audit records | `chain` is plain text — `cat`, `grep`, and `auditverify` are the review tools; deliberately **not** a SIEM (non-goal). No automated correlation/reporting. | **Partial / by-design-minimal** (§3). |
| **AU-11** Record Retention | Retain records for a defined period | Retention follows the backing file and the platform dump/snapshot story; no in-service retention policy. | **Partial** (§3). |

## 3. Residual gaps (all tracked)

| Gap | Why bounded | Tracking |
|-----|-------------|----------|
| **Unsigned-tail window** — records after the last signed checkpoint are chain-protected but not signature-covered | Hash chain still makes tampering *detectable*; checkpoint frequently to bound the window. Documented in [`man/4/auditfs` BUGS](../../man/4/auditfs). | INFR-343 (checkpoint cadence policy) |
| **`auditfs` holds the signing key** — hardening would move it into `factotum` so the server never holds the private key | Today's posture (server-held key, localhost) is acceptable for a single trusted operator; non-repudiation still holds against external parties. | **INFR-356** |
| **AU-8(1) authoritative time source** — record time is the host clock, not an attested/synchronized source | Within-log ordering and anti-backdating are guaranteed by server-assigned monotone `seq`; only wall-clock authority is open. | (new) INFR backlog |
| **AU-4/5 storage-full + failure alerting** | Fail-open is a deliberate default; high-value callers fail-closed. | (new) INFR backlog |
| **AU-6/7 automated review/reporting** | Explicit non-goal (not a SIEM); off-host tooling consumes the plain-text `chain`. | roadmap, not a defect |
| **Agent-provenance high-volume payloads** — content-addressed store layer | Out of scope for the security-log compliance goal; needs customer validation. | **INFR-355** |

## 4. Verification

- **Chain core:** [`tests/auditchain_test.b`](../../tests/auditchain_test.b) — 6/6 pass:
  `GenesisDeterministic`, `ExtendChains`, `TamperDetected`, `ReorderDetected`,
  `DeletionDetected`, `HexFormat`. The three negative tests directly exercise AU-9
  (tamper/reorder/deletion are all detected).
- **End-to-end:** `auditfs` mounted at boot, `secstored`/`2fa`/`factotum` emit on the
  live auth path; `cat /mnt/audit/chain | auditverify -k pubkey` confirms the chain and
  every checkpoint signature off-host (see [`man/4/auditfs` EXAMPLE](../../man/4/auditfs)).
- **CI:** the Linux/macOS/ARM build-and-test jobs (PR #292, all green) build the service
  and run the test suite on every change.

## 5. Why this shape (CISO FAQ)

The full design rationale — why Plan 9/Inferno deliberately have no logging *daemon*,
why a hash chain over a forward-secure MAC, why namespace placement instead of mode
bits for read-protection — is in
[`SP800-92-audit-log-DESIGN.md`](SP800-92-audit-log-DESIGN.md),
[`plan9-logging-rationale.md`](plan9-logging-rationale.md), and
[`audit-log-prior-art.md`](audit-log-prior-art.md). The one-line CISO answer: *audit
integrity is a property we can prove (recompute the chain; verify the signature with a
public key), access control is the same namespace boundary that bounds everything else,
and the whole facility tears out by simply not mounting it.*

[INFR-328]: https://tracker.internal/browse/INFR-328