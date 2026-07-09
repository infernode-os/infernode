# DESIGN (historical) — Tamper-Evident Audit-Log Service

> **STATUS: APPROVED → BUILT.** This design was approved and implemented; it is
> retained as the design rationale of record. For the as-built evidence (per-control
> status, `file:line` citations, tests), see the companion evidence artifact
> [`SP800-92-audit-log.md`](SP800-92-audit-log.md). The service is a Limbo Styx server
> (no new C device), honors Plan 9/Inferno minimalism, uses 9P, and uses **no JSON**.

**Standard:** NIST SP 800-92 (Log Management) + SP 800-53 **AU** family (esp. AU-9
protection of audit information); underwrites **SOC 2** and **PCI-DSS Req 10**.
**Roadmap:** EPIC 2 — "the single highest-leverage control." Tier 1.
**Tracking:** program epic [INFR-328]; this design → a code Story when approved.
**Date:** 2026-06-22.

---

## 1. Problem

Auditing today is **per-subsystem and not integrity-protected**: `emitauditlog()`
(`appl/veltro/nsconstruct.b:708`) records namespace operations; the agent stack logs
subagent trajectories; login/factotum events are not centrally captured. There is no single,
append-only, **tamper-evident** record. AU-9 / SP 800-92 / PCI-10.5 require that audit data
be protected from modification and that tampering be *detectable*.

## 2. Goal (and non-goals)

**Goal:** one append-only, hash-chained log service that any subsystem writes to, whose
integrity an offline verifier can check, such that altering or deleting any past record is
detectable.

**Non-goals (explicitly):** not a SIEM; not log *analysis*; not access control on *reading*
(that is the namespace's job — bind the service only where it should be visible); not
distributed consensus. Minimal by intent.

## 3. Inferno-native shape

A log is a file. Writing an event is writing a line. Reading the record is reading a file.
This is the Plan 9 idiom and needs no new abstraction.

**Recommendation: a Limbo `styxserver`** (`module/styxservers.m`, as used by `tools9p` and
`vid9p`), mounted at **`/mnt/audit`** — *not* a new C `#`-device. Rationale: keeps new code
out of the C TCB (memory-safe Dis; "more code, more bugs" → put it in Limbo), reuses an
existing, well-worn server framework, and the tamper-evidence property lives in the
**hash chain**, not in the implementation language. (A C `#`-device remains an option only if
a future requirement needs kernel-level write mediation below the Dis VM; noted, not chosen.)

### 3.1 Namespace interface

```
/mnt/audit/
    log       # write-only, append-only: one event per write (see §4). Writes never seek.
    chain     # read-only: the full chain, record + per-record hash, oldest first
    head      # read-only: current tip hash (hex) + seq — for external anchoring
    verify    # read-only: "ok" or first broken seq — server-side self-check
```

The service is **placed by namespace**: bind `/mnt/audit/log` into the namespaces that may
*emit* (login, factotum, CDS guard, veltro), and keep `chain`/`head` where auditors read.
A restricted agent that has no `/mnt/audit` binding cannot even name the log — consistent
with the Zero-Trust posture ([`SP800-207-zero-trust.md`](SP800-207-zero-trust.md)).

## 4. Record format (line-oriented text — NO JSON)

One record per emit, newline-terminated, space-separated fields with a fixed prefix and a
free-form tail. Keeps with Inferno text conventions (cf. `ls -l`, `/prog/*/status`, ndb):

```
seq  unixnano  source  event  msg...
```

- `seq` — monotonic decimal, assigned by the server (caller cannot forge ordering).
- `unixnano` — server clock at append.
- `source` — short tag (`login`, `factotum`, `cds`, `veltro`, …).
- `event` — verb (`unlock`, `authfail`, `deny`, `spawn`, …).
- `msg` — remainder of the line (the server escapes any embedded newline).

The caller writes `source event msg`; the server prepends `seq` and `unixnano`. Callers
cannot set seq/time — append authority is the server's.

## 5. Hash chain (the tamper-evidence)

A linear hash chain over SHA-256 (already a Keyring builtin, `module/keyring.m:205`):

```
H[0]      = SHA-256("infernode-audit-v1")          # fixed genesis
H[n]      = SHA-256(H[n-1] || record_n_bytes)      # record_n includes seq+time+fields
```

- `chain` emits, per line: `record  <space>  H[n]` (hex).
- `head` emits `H[tip] seq` — publish/anchor this anywhere (printed at shutdown, mailed,
  committed) to pin the log at a point in time.
- **Property:** changing, reordering, or deleting any record_k changes H[k] and every
  H[>k]; unless an attacker can also rewrite every subsequent hash *and* forge any
  externally-anchored `head`, tampering is detectable. (Pre-image/2nd-pre-image resistance of
  SHA-256.)
- **Optional hardening (later):** periodically sign `head` with an ML-DSA signer key
  (factotum) → tamper-*evident* becomes tamper-*evident + attributable*. Not required for v1.

This is a hash chain, not a full Merkle tree; the roadmap says "Merkle-verifiable" — a linear
chain is the minimal construction that gives the required property. A Merkle tree only buys
efficient *inclusion proofs* for a subset, which the non-goal set doesn't need. Start linear.

## 6. Durability / append-only enforcement

- Backing store: a host file via the existing fs (e.g. `/usr/inferno/audit/log`), opened
  append-only; the server is the sole writer.
- The server holds `H[tip]` and `seq` in memory and reloads/recomputes them from the backing
  file on start (and runs `verify` at start — fail loud on a broken chain).
- No truncate, no random write across the 9P interface — `log` only appends. (A privileged
  host actor can still tamper with the raw file; that is *exactly* what the hash chain + the
  external `head` anchor make *detectable*. Documented residual, per SP 800-92.)

## 7. Offline verifier

A standalone command (`appl/cmd/auditverify.b`, ~tens of lines): read a `chain` dump,
recompute H from genesis, stop at the first mismatch, print `ok <count>` or
`broken at seq N`. Runs inside emu, no namespace manipulation, no network. This is the
artifact an auditor runs.

## 8. Subsystem wiring (after the service exists)

Smallest possible touch at each emit site — a single write to `/mnt/audit/log`:
- **login / 2FA** (`appl/wm/logon.b`, `2fa`): `login unlock|authfail|recovery user=…`.
- **factotum**: key add/remove, auth grant/deny.
- **CDS guard** (EPIC 5, when built): every mediated/blocked transfer — natural fit.
- **veltro**: route `emitauditlog()` here instead of its current local sink.

Each wiring is its own small, reviewed change.

## 9. Threat model (summary)

| Adversary | Mitigation |
|-----------|------------|
| In-namespace process alters past entries via 9P | Append-only interface; no seek/truncate |
| Process forges ordering/time | seq + time assigned by server, not caller |
| Privileged host edits the raw backing file | Hash chain + externally-anchored `head` make it detectable (not prevented) |
| Attacker rewrites whole chain to stay consistent | Must also forge every anchored `head`; optional ML-DSA signing of `head` raises this to key-forgery |
| Agent that shouldn't see logs | Not bound into its namespace → cannot name `/mnt/audit` |

## 10. Why this is minimal

- One Limbo styxserver, one small verifier command, a 4-file interface, a text record, a
  SHA-256 chain reusing an existing builtin. No new C, no new kernel device, no JSON, no new
  serialization format, no external dependency. It composes with the namespace (placement =
  access control) and with factotum (optional `head` signing).

## 11. Open questions for the owner (before any code)

1. **Placement:** `/mnt/audit` (this doc) vs the roadmap's `/dev/audit` `#`-device. Recommend
   `/mnt/audit` Limbo server for minimal TCB — confirm.
2. **`head` signing in v1?** Recommend *defer* (v1 = chain only; signing is additive later).
3. **Retention:** size/rotation policy — rotate with a chained "carry" record linking old→new
   segment, or single growing file with external archival? Recommend single file + documented
   archival for v1.
4. **Backing path** under `/usr/inferno/` and its host-side protection expectations.

## 12. References

- NIST SP 800-92; SP 800-53 AU-9 (Protection of Audit Information); PCI-DSS Req 10; SOC 2 CC7.
- In-tree idioms: `appl/lib/styxservers.b`, `module/styxservers.m`, `appl/veltro/nsconstruct.b`
  (`emitauditlog`), `module/keyring.m` (`sha256`).
