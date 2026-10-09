# Secstore Auth Suite Plan

## Purpose

This note fixes the design contract for InferNode secstore authentication
before more protocol changes land. It is intentionally short and engineering
driven.

InferNode currently has three relevant auth states:

- `secstore`: upstream-style legacy verifier and PAK path
- `secstore2`: InferNode SHA-256 verifier/transcript path on the inherited
  1024-bit PAK group
- `SGCM2`: the at-rest blob format for encrypted secstore files

`SGCM2` is not an auth protocol version and must stay separate from the PAK
suite.

## Decision

InferNode will treat the `PAK` file tag as an **auth suite identifier**, not
just a generation count.

An auth suite defines:

- password hash family
- PAK group parameters
- transcript hash
- session-key derivation

The current default suite is `secstore3`.

`secstore3` will use:

- the existing PAK protocol shape
- SHA-256-based verifier and transcript hashing
- a published 2048-bit MODP group with a 256-bit prime-order subgroup
- explicit `secstore3 <hexHi>` on-disk verifier format

The intended parameter source is RFC 5114's 2048/256 subgroup set. That keeps
the current Plan 9 / Inferno style PAK structure while removing the inherited
1024-bit group weakness.

## Compatibility Policy

InferNode has no deployed user base, so new account creation may move directly
to `secstore3`.

However, the code should keep compatibility paths for now:

- clients try `secstore3`, then `secstore2`, then legacy `secstore`
- servers accept all three verifier tags
- `auth/secstore-setup` defaults to `secstore3`, with explicit flags for older
  suites

This is for controlled migration, tests, imports, and rollback safety. It is
not a promise of permanent multi-suite support.

## Security Model

Keep the existing deployment posture:

- `secstored` stays loopback by default
- no silent remote exposure
- no silent account migration
- no hidden reinterpretation of old verifier tags

The user-visible model stays simple:

- `PAK` stores the auth verifier
- `factotum` stores encrypted key material
- the password remains the root secret
- namespace and file permissions remain the primary local trust boundary

## Non-Goals

- no switch to JSON or a different control plane
- no opportunistic rewrite of `PAK` files on login
- no attempt to make `secstore2` mean a new group
- no full PAKE redesign in this step

If InferNode later adopts a different PAKE such as SPAKE2, that should be a
new suite, not a reinterpretation of `secstore3`.

## Test Matrix

Before merging `secstore3`:

- new `secstore3` account authenticates and persists keys
- `secstore2` account still authenticates
- legacy `secstore` account still authenticates
- client fallback order is deterministic and tested
- `wm/logon`, `factotum`, and `secstore-setup` all create `secstore3` accounts
  by default
- `SGCM2` blob compatibility remains unchanged
- wrong-suite and wrong-password failures stay intelligible

## Implementation Order

1. Add shared suite selection in `appl/lib/secstore.b`.
2. Teach `secstored` to parse and serve `secstore3`.
3. Change account creation defaults in `secstore-setup`, `factotum`, and
   `wm/logon`.
4. Extend host and Limbo regression coverage.
5. Keep operator docs aligned as the compatibility policy evolves.

## Follow-Up

After `secstore3` lands and stabilizes, decide whether to:

- keep `secstore2` only for import/testing
- add explicit auth rate limiting for non-loopback deployments
- remove legacy suite support on a defined schedule
