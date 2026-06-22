# Compliance Evidence Register — InferNode / NERVA

**Status:** Living document — started 2026-06-22
**Owner:** Security & Compliance program — Jira epic **INFR-328** (roadmap: [`../security-standards-roadmap.md`](../security-standards-roadmap.md))
**Audience:** CISO / accreditor / procurement (evidence), and engineering (backlog).

This directory holds **per-standard evidence artifacts**. Each artifact is written to
the bar an accreditor would accept: for every claim it states *requirement →
mechanism → evidence (file:line, test, commit) → residual gap → status*. Claims are
cited to source so they can be independently verified against the tree; nothing here is
asserted without a pointer.

The companion documents are:

- [`../security-standards-roadmap.md`](../security-standards-roadmap.md) — the
  aspirational standards list and the Inferno-native mechanism for each.
- [`../security-epics.md`](../security-epics.md) — the same, decomposed into Jira epics.

This register is the *evidence* side of those two; the roadmap is the *intent* side.

## How to read a status

| Status | Meaning |
|--------|---------|
| **Met** | Requirement satisfied today; evidence supplied; no open gap. |
| **Substantially met** | Core mechanism in place and evidenced; one or more bounded gaps tracked in Jira. |
| **Partial** | Some required elements present; material work remains. |
| **Planned** | On the backlog, not yet implemented. |

A standard is only "closed" (cookie earned) when its artifact is **Met** *and* the
evidence has been reviewed.

## Evidence index

| Standard | Artifact | Tier | Status |
|----------|----------|------|--------|
| **CNSA 2.0** (NSA quantum-resistant suite) | [`CNSA-2.0.md`](CNSA-2.0.md) | 1 | Substantially met — primitives complete; parameter-selection gaps tracked |
| NIST SP 800-63B AAL3 | *(planned — see `../second-factor-auth.md`, `../yubikey-2fa-operations.md`)* | 1 | Partial |
| NIST SP 800-92 tamper-evident audit log | *(planned)* | 1 | Planned |
| NIST SP 800-53 / 800-171 control mapping | *(planned — stub in roadmap)* | 1 | Partial |
| NIST SP 800-207 Zero Trust | *(planned)* | 0 | Substantially met (document-only) |
| FIPS 140-3 readiness | *(planned)* | 2 | Planned |

New artifacts are added a row at a time as each standard is worked. The index never
claims a status the artifact itself does not support.

## Evidence conventions

- **Cite to source.** Use `path:line` or `path` + symbol so a reviewer can `grep` it.
- **Cite the test, not just the code.** A control with a passing regression test is
  stronger evidence than code alone. Test files live under [`../../tests/`](../../tests).
- **Be honest about gaps.** A documented residual gap with a tracking ticket is
  acceptable to an accreditor; a silent overstatement is not. Every gap names its
  Jira key.
- **No new attack surface for evidence.** Evidence artifacts are documentation. Where a
  gap requires code, that work is scoped and tracked separately, reviewed on its own
  merits — consistent with the project's austerity (more code, more bugs).
