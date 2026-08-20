# AI governance — agent provenance as the record-keeping mechanism

**Scope.** This document maps InferNode's agent-provenance capability (INFR-355;
[`audit-log-design.md`](audit-log-design.md) §8) onto the record-keeping and
traceability expectations of the emerging AI-governance frameworks. It is a
*mechanism-to-requirement* mapping: InferNode is a platform, and conformity of
any particular AI system is a property of the deployed system and its
organization, not of this codebase. What the platform contributes is the part
these frameworks find hardest to retrofit — a trustworthy technical record of
what an AI agent was given and what it did.

## 1. The mechanism (what exists, in one paragraph)

Every agent run on the veltro stack seals its full trajectory into the
tamper-evident audit log (`/mnt/audit`, [`auditfs(4)`](../../man/4/auditfs)):
system prompt, task, the namespace capability set it was granted, each model
exchange, each tool call and its complete result, each subagent spawn with the
child's granted capabilities, the namespace-restriction manifest, and the
completion — as hash-chained records with server-assigned sequence and time.
Bulky payloads are stored write-once in a content-addressed store
([`ventisrv(8)`](../../man/8/ventisrv)) and referenced as
`content=<score> sha256=<hex>` ([`auditprov(2)`](../../man/2/auditprov)); the
SHA-256 pin is sealed under the chain, and signed checkpoints (ML-DSA-87 held
in factotum) anchor the whole. Agents themselves hold only the append-only
`log` file — they can record their own trajectory but can never read or
rewrite history. The trail verifies **offline, by public key**
([`auditverify(1)`], `auditget(1)`): an auditor or regulator needs no trust in
the operator's running system to check it.

## 2. Mapping

| Framework | What it asks for | How the mechanism answers | Honest gap |
|-----------|-----------------|---------------------------|------------|
| **EU AI Act — Art. 12 (record-keeping)** | High-risk AI systems must technically allow automatic recording of events (logs) over the system's lifetime, sufficient for traceability of its functioning | Automatic, non-optional once auditing is enabled: the full agent trajectory is sealed as it happens, with forgery-resistant ordering (server-assigned seq/time) and tamper-evidence (chain + signed checkpoints). Logging is fail-closed for agent activity under the install marker (`Audit->ONFILE`) — an agent whose actions cannot be recorded does not run. | Retention duties on providers/deployers (Arts. 19, 26) are organizational policy; the platform's retention posture is the backing store + off-host anchoring (AU-11 residual, tracked). |
| **EU AI Act — Art. 13/14 (transparency, human oversight)** | Operation sufficiently transparent for deployers to interpret output; effective oversight | The trajectory is plain text over 9P — `cat`/`grep` are the review tools; every output is attributable to the exact prompt, capability grant, and tool results that produced it. Oversight controls themselves are separate work (security-epics: human-oversight epic). | Interpretation/UX tooling for non-technical overseers does not exist (AU-6/7 residual). |
| **NIST AI RMF 1.0 — "accountable & transparent" characteristic; MEASURE/MANAGE functions** | Traceability of AI system decisions and actions; evidence that risk controls operate | Cryptographically verifiable provenance for every agent action, third-party checkable offline; capability grants (`nscaps`, `subcaps`, `nsrestrict` records) document exactly what the agent *could* do, not just what it did. | RMF is an organizational process; the platform supplies evidence, not the program. |
| **ISO/IEC 42001 (AI management systems)** | Operational controls including event logging and traceability of AI system behaviour, feeding audit and improvement | Same mechanism; the chain is the operational log an AIMS audit would sample, and `auditverify -k` gives the auditor an integrity check independent of the auditee. | AIMS certification is organizational; no claim is made here. |
| **GDPR interplay (minimization)** | Records that support accountability without over-collecting | Payloads are separable from the trail by design: the broadly-reviewable chain carries hashes and metadata; sensitive content sits in the placement-protected store, deduplicated, disclosed only by handing over specific scores. | Erasure duties conflict with write-once storage generally; scoping personal data out of payloads is a deployment decision. |

## 3. Why this is hard to retrofit elsewhere

Most agent frameworks log trajectories as mutable application logs: the
process that writes them can rewrite them, timestamps are self-reported, and
"what could the agent do" is scattered across configuration. Here the three
properties come from the operating system, not the application:

1. **Append-only by namespace construction** — the writer holds a write-only
   file; there is no API whose misuse could edit history.
2. **Order and time assigned by the server** — an agent cannot backdate or
   reorder its own trail.
3. **Capability grants are first-class records** — the namespace *is* the
   capability set, so `nscaps`/`subcaps`/`nsrestrict` records document the
   agent's authority precisely, per run and per child.

## 4. Residuals (all tracked elsewhere, unchanged by this mapping)

- **Retention & rotation** (AU-11), **capacity/failure alerting** (AU-4/5),
  **review tooling** (AU-6/7), **trusted time source** (AU-8(1)) — see the
  residual table in [`SP800-92-audit-log.md`](SP800-92-audit-log.md).
- **Scope**: the record covers the veltro agent stack. Model *internals*
  (weights, sampling) are out of scope by design — the record captures the
  exact bytes exchanged with the model, which is what the frameworks' logging
  provisions ask of the system operator.
- **Certification**: nothing here claims conformity with any framework; this
  is the technical substrate an assessment would draw evidence from.

## 5. References

- [`audit-log-design.md`](audit-log-design.md) §8 (design + decisions),
  [`SP800-92-audit-log.md`](SP800-92-audit-log.md) (AU evidence),
  [`SP800-53-controls.md`](SP800-53-controls.md)
- `man/2/auditprov`, `man/8/ventisrv`, `man/1/auditget`, `man/4/auditfs`
- Verification: `tests/auditprov_test.b`, `tests/auditverify_test.b`
