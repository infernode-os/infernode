---
name: New Service / Tool Proposal
about: Propose a new 9P service, Veltro tool, or file interface — design review before code
title: 'proposal: '
labels: design
assignees: ''
---

<!--
The file interface IS the design. A sketch is reviewed in minutes;
code is not. See docs/DESIGN-PRINCIPLES.md ("Proposing a new service or
tool") for what good answers look like.
-->

## What it does

One paragraph: the capability this adds, and who consumes it (users,
other services, agents).

## Namespace sketch

The tree you intend to serve, each file's read/write behavior, and an
example shell session:

```
/mnt/example/
    ctl            # write: 'verb args...'
    status         # read: 'ok ...'
    ...

; cat /mnt/example/status
ok 3 items
; echo refresh > /mnt/example/ctl
```

## Placement

`/mnt/<app>` (we author the schema) or `/n/<source>` (foreign tree
imported intact) — and why. See docs/NAMESPACE-LAYOUT.md.

## Composition

- Which existing services it composes with (audit, factotum/secstore,
  venti, wallet, plumber, ...), and how.
- What it deliberately does NOT do (scope boundaries).

## Agent exposure

If agents will reach this service:

- Which files are grantable to an agent, and which are control-plane
  and must never be bound into an agent namespace.
- Does any grantable file pair a sensitive read with egress? (It must
  not — see the invariants in appl/veltro/SECURITY.md.)
- Effectful operations: where is the proposal/commit split?

## Data formats

Confirm reads/writes are text per docs/9p-data-conventions.md, or
state exactly where JSON crosses an external boundary and why.

## Test plan

- Limbo unit tests (logic)
- `tests/inferno/` sh test (namespace contract)
- `tests/host/` integration (only if the host boundary matters)
