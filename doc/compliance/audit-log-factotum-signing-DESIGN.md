# DESIGN (for review) — Factotum-held audit checkpoint signing (INFR-356)

> **STATUS: DESIGN — NOT IMPLEMENTED. Awaiting owner go/no-go before any code.**
> This adds a new factotum **signing protocol** (a TCB-adjacent auth proto) and
> rewires `auditfs` to use it. Brought as a design first per project policy. When
> approved: minimal, flagged for review, Plan 9/Inferno-idiomatic, no JSON.

**Goal:** the audit checkpoint-signing key must **never be plaintext on disk**, and
`auditfs` must **never hold the private key**. Factotum holds the (unlocked) key and
performs the signature; `auditfs` asks it to sign and receives only the certificate.
**Closes:** INFR-356 (residual gap recorded in [`SP800-92-audit-log.md`](SP800-92-audit-log.md) §3).
**Standard:** SP 800-53 **AU-10** non-repudiation; CNSA 2.0 (signature is **ML-DSA-87**).

---

## 1. Threat-model decision (settled with owner)

A host-permissions-protected `createsignerkey` keyfile on disk is **not acceptable**.
Therefore the key must be sealed at rest and unlocked into memory by a long-running
holder — and the canonical Inferno holder is **factotum**. A fire-when-needed signer
was rejected: with no human present at each autonomous checkpoint, "no plaintext on
disk" forces a holder, and that holder is factotum.

## 2. Why this shape

- **Canonical pattern.** Factotum holding a key and performing a private-key op for a
  client over its `rpc` *file* is the native Plan 9 mechanism — exactly what the
  existing (unbuilt, SSH-shaped) `proto/rsa.b` does. We reuse the *pattern*, not its
  crypto.
- **Not `rsa.b` as-is.** `rsa.b` is RSA-only, SSH-challenge-decrypt semantics, returns
  a raw bigint — **not** the keyring `Certificate` our `auditverify` checks, and
  **not quantum-safe**. Reusing it would force rewriting verification and lock us to
  classical RSA.
- **Quantum-safe for free.** The audit log already signs through the
  algorithm-agnostic `kr->sign → Certificate` path; the keyring already ships ML-DSA
  (`libkeyring/mldsaalg.c`) and `createsignerkey -a mldsa87` already mints it. A proto
  that calls `kr->sign` is PQC-capable with no crypto code of our own. (The SHA-256
  hash chain already gives quantum-resistant tamper-*evidence*; ML-DSA protects the
  *non-repudiation* — "provably signed by the audit authority a decade later".)
- **No factotum *core* change.** Protos are auto-discovered: `readprotos()` lists
  `/dis/auth/proto/*.dis` and `startproto()` loads `"/dis/auth/proto/"+p+".dis"`
  ([`factotum.b:525,602`](../../appl/cmd/auth/factotum/factotum.b)). A new
  `sign.dis` is picked up automatically. The key arrives via the existing secstore
  persistence path. **`factotum.b` itself is untouched.**

## 3. Architecture

```
provisioning (once, after login):           runtime (every checkpoint):
  createsignerkey -a mldsa87  -> SK,PK         auditfs writectl("checkpoint"):
  PK  -> /usr/inferno/audit/pub (public)         open /mnt/factotum/rpc
  SK  -> hex(sktostr(SK))                        start proto=sign service=audit role=client
       -> echo "key proto=sign service=audit \   write  <content bytes>
                !sk=<hex>" > /mnt/factotum/ctl    read   <- certtostr(cert)
       -> factotum persist thread seals it        append "head=.. seq=.. sig=hex(cert)"
          into secstore (encrypted at rest)
  (at boot, factotum loads it from secstore)
```

`content` is the existing signed string: `audit-checkpoint <hex(tiphash)> <seq>`
([`auditfs.b:291`](../../appl/cmd/auditfs.b)). The proto hashes it (SHA-256) and signs
with the ML-DSA-87 SK it holds; `auditfs` hex-encodes the returned `certtostr` into the
record exactly as today. **`auditverify` is unchanged** — same keyring `Certificate`.

## 4. Components & changes (each flagged for review)

| # | File | Change | New code? |
|---|------|--------|-----------|
| 1 | **`appl/cmd/auth/factotum/proto/sign.b`** (new) | New `Authproto`. Modeled on `rsa.b` structure. `interaction()`: `io.findkeys(proto=sign …)`, reconstruct SK via `kr->strtosk(unhex(lookattrval(k.secrets,"!sk")))`, `io.read()` the content, `state=kr->sha256(...)`, `cert=kr->sign(sk,0,state,"sha256")`, `io.write(certtostr(cert))`, `io.done(nil)`. ~80 lines. | yes (proto, ~80 ln) |
| 2 | **`appl/cmd/auth/factotum/proto/mkfile`** | Add `sign.dis` to `TARG`. | 1 line |
| 3 | **`appl/cmd/auditfs.b`** | Replace in-process `signhead()`/`signsk` with a factotum driver: `Factotum->open()` + `rpc(start/write/read)`. Drop `-k` key loading; keep `-k` only as an optional *fallback* for offline/no-factotum installs (or remove — owner choice, see §7). Serve `Qpubkey` by reading `/usr/inferno/audit/pub`. | moderate edit |
| 4 | **`appl/cmd/auth/audit-setup.b`** (new) or fold into `secstore-setup.b` | Provisioning: `createsignerkey -a mldsa87`, write PK to `/usr/inferno/audit/pub`, write the `key proto=sign …` line to `/mnt/factotum/ctl`. ~50 lines. | yes (~50 ln) |
| 5 | **`lib/sh/profile`** | `auditfs` already mounts before auth services; ensure it can reach `/mnt/factotum` (it runs in the boot namespace, which has it). No new mount. Possibly reorder so factotum is up before the first checkpoint. | small |
| 6 | **`man/4/auditfs`** + **`module`/mkfiles** | Update man page (signing now via factotum); wire any new module. | docs/build |
| 7 | **`tests/`** | (a) keyring-level test: `mldsa87` `sktostr→hex→unhex→strtosk` roundtrip then `sign`/`verify` — proves crypto + serialization. (b) integration checklist for the full factotum path (full e2e in CI is hard — see §8). | yes (tests) |

**Namespace note (flag):** the `sign` proto means "anyone who can open `/mnt/factotum/rpc`
can ask factotum to sign with the audit key." That is gated by namespace placement —
the same boundary that gates all of factotum. `auditfs` is in the boot namespace and has
it; a restricted subagent (only `/mnt/audit/log` bound) does **not**. No boundary is
widened, but this is a new capability behind that boundary and is called out explicitly.

## 5. Key serialization (the one real wrinkle)

ML-DSA/SLH-DSA keys are not a handful of named bigints (unlike RSA's `n,!dk,!p,…`), so
the `rsa.b` decomposed-attr approach **cannot** represent them. `sktostr(SK)` *does*
roundtrip any algorithm (`libinterp/keyring.c:463/491`), but its output is **multi-line**
(`sigalg\nowner\nbytes`) and factotum rejects multi-line key writes
([`factotum.b:231`](../../appl/cmd/auth/factotum/factotum.b)). So we store the SK as a
**single-line hex** secret attr — `!sk=<hex(sktostr(SK))>` — and the proto does
`strtosk(unhex(...))`. This is the only non-obvious mechanic; it is purely our proto +
provisioning, no keyring change.

## 6. Graceful degradation (unchanged contract)

If factotum is unreachable or holds no `proto=sign service=audit` key, the `checkpoint`
write falls back to an **unsigned** chain marker — exactly today's behavior when no `-k`
is given ([`auditfs.b:276-281`](../../appl/cmd/auditfs.b)). Tamper-*evidence* (the hash
chain) never depends on signing. Signing failures must never break the log or boot.

## 7. Owner decisions for go/no-go

1. **Keep `-k` as an offline fallback, or remove it entirely?** Keeping it preserves a
   path for air-gapped/no-secstore installs (key still sealed by host perms there);
   removing it is purist ("factotum or nothing"). *Recommend: keep `-k` as a documented
   fallback, default path is factotum.*
2. **New `auth/audit-setup` command vs. folding into `secstore-setup.b`?**
   *Recommend: a small dedicated `audit-setup` — single responsibility, easy to ring-off.*
3. **Algorithm: `mldsa87` (CNSA 2.0 Cat 5) confirmed?** *Recommend yes.*

## 8. Honest risks / unknowns

- **Full e2e in the emu is hard.** Driving a live factotum proto inside CI needs
  secstore + factotum up; my earlier headless factotum smoke runs hung on environment
  setup. Mitigation: unit-test the crypto+serialization deterministically (§4.7a); gate
  the integration test behind the boot harness; document a manual verification recipe.
- **`auditfs` serveloop blocks during signing.** The checkpoint write drives factotum
  synchronously (as `kr->sign` does today). Infrequent + local, so acceptable; note it.
- **Proto framework is heavier than a one-shot sign.** The `Authproto` client/server
  model is built for handshakes; our use is a degenerate one-round exchange. Acceptable
  (it's the sanctioned extension point and avoids touching factotum core), but it is
  more machinery than the operation strictly needs.

## 9. Scope boundary

This change does **only** the factotum-held signing for audit checkpoints. It does not
touch the hash chain, the record format, the verifier's crypto, or any other factotum
key type. Agent-provenance (INFR-355) and AU-4/5/6/7 operational tooling remain separate.
