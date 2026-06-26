# DESIGN (for review) — Factotum-held audit checkpoint signing (INFR-356)

> **STATUS: APPROVED — implementation in progress.** Owner go/no-go received with
> these decisions locked in (see §7): **(1)** no `-k` keyfile fallback — secstore is
> the sole at-rest backing, degrade to unsigned markers if absent; **(2)** provisioning
> is a **shell script** (Plan 9 idiom) plus a tiny compiled SK-export filter, and the
> strong property **P2** ("the signing service never holds the key; only factotum sees
> the unlock secret") is required, so we build the factotum sign proto; **(3)** algorithm
> is **`mldsa87`**. Each code change is flagged for review; no JSON; factotum core untouched.

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
| 3 | **`appl/cmd/auditfs.b`** | Replace in-process `signhead()`/`signsk` with a factotum driver: `Factotum->open()` + `genproxy` with channels that feed the head string and accumulate the chunked cert. **Remove `-k` entirely** (no keyfile fallback). Serve `Qpubkey` by reading `/usr/inferno/audit/pub`. | moderate edit |
| 4a | **`lib/sh/audit-setup`** (new shell script) | Provisioning, Plan 9 idiom: run `createsignerkey -a mldsa87`, write PK to `/usr/inferno/audit/pub`, emit the `key proto=sign service=audit !sk=<hex>` line to `/mnt/factotum/ctl`, shred the temp keyfile. | shell (~25 ln) |
| 4b | **`appl/cmd/auth/sk2line.b`** (new, tiny) | The one bit shell can't do: read a `createsignerkey` keyfile and print `hex(sktostr(mysk))` (no existing tool exports an SK as a string, by design). ~15 lines. | yes (~15 ln) |
| 5 | **`lib/sh/profile`** | `auditfs` already mounts before auth services; ensure it can reach `/mnt/factotum` (it runs in the boot namespace, which has it). No new mount. Possibly reorder so factotum is up before the first checkpoint. | small |
| 6 | **`man/4/auditfs`** + **`module`/mkfiles** | Update man page (signing now via factotum); wire any new module. | docs/build |
| 7 | **`tests/`** | (a) keyring-level test: `mldsa87` `sktostr→hex→unhex→strtosk` roundtrip then `sign`/`verify` — proves crypto + serialization. (b) integration checklist for the full factotum path (full e2e in CI is hard — see §8). | yes (tests) |

**Namespace note (flag):** the `sign` proto means "anyone who can open `/mnt/factotum/rpc`
can ask factotum to sign with the audit key." That is gated by namespace placement —
the same boundary that gates all of factotum. `auditfs` is in the boot namespace and has
it; a restricted subagent (only `/mnt/audit/log` bound) does **not**. No boundary is
widened, but this is a new capability behind that boundary and is called out explicitly.

## 5. Two implementation wrinkles (both confined to our proto)

**(a) Key serialization.** ML-DSA/SLH-DSA keys are not a handful of named bigints
(unlike RSA's `n,!dk,!p,…`), so the `rsa.b` decomposed-attr approach **cannot**
represent them. `sktostr(SK)` *does* roundtrip any algorithm
(`libinterp/keyring.c:463/491`), but its output is **multi-line** (`sigalg\nowner\nbytes`)
and factotum rejects multi-line key writes
([`factotum.b:231`](../../appl/cmd/auth/factotum/factotum.b)). So we store the SK as a
**single-line hex** secret attr — `!sk=<hex(sktostr(SK))>` — and the proto does
`strtosk(unhex(...))`. Purely our proto + provisioning, no keyring change.

**(b) Certificate chunking.** An ML-DSA-87 certificate is ~6 KB, but factotum's
`AuthRpcMax` is 4096, and `IO.write` requires the client's read buffer to hold a message
in **one** frame ([`factotum.b:1105-1116`](../../appl/cmd/auth/factotum/factotum.b)). So
the proto must **fragment** the cert into ≤4093-byte chunks via successive `io.write()`
calls; the stock `genproxy` client loop reassembles them (each chunk arrives as an `"ok"`
frame, accumulated until `"done"`). `auditfs` concatenates the chunks. A few lines in the
proto; **no `AuthRpcMax` / factotum-core change.**

## 6. Graceful degradation (unchanged contract)

If factotum is unreachable or holds no `proto=sign service=audit` key, the `checkpoint`
write falls back to an **unsigned** chain marker — exactly today's behavior when no `-k`
is given ([`auditfs.b:276-281`](../../appl/cmd/auditfs.b)). Tamper-*evidence* (the hash
chain) never depends on signing. Signing failures must never break the log or boot.

## 7. Owner decisions — RESOLVED

1. **`-k` keyfile fallback → REMOVED.** secstore is the sole at-rest backing; a plaintext
   keyfile would reintroduce the very problem. No factotum/secstore ⇒ unsigned markers.
2. **Provisioning → shell script** (`lib/sh/audit-setup`) plus a tiny compiled SK-export
   filter (`sk2line`), honoring the Inferno idiom of lightweight tools as scripts. The
   strong property **P2** is required, so the factotum sign proto is built (not the
   simpler "auditfs loads the key into its own RAM from secstore", which would spread the
   secstore unlock secret to a second service).
3. **Algorithm → `mldsa87`** (ML-DSA, CNSA 2.0 Category 5).

## 7a. BLOCKER found in implementation — key-injection size (awaiting decision)

Empirically (build + emu): an **ML-DSA-87 key line is ~10 KB**, because `sktostr`
serializes the secret key **and** the public key (4896 + 2592 = 7488 bytes → ~10 KB
base64; the encoding is already single-pass, not the earlier hex double-encoding). But
the emu mount iounit is **8192 bytes** (`emu/port/devmnt.c` `MAXRPC = IOHDRSZ+8192`), so
writing that line to `/mnt/factotum/ctl` is split into two Twrites, and factotum's ctl
handler treats each write independently — the oversized injection **hangs/corrupts**.
The deterministic crypto + encode/decode path is proven (`tests/auditsign_test.b`, 3/3);
only the *provisioning injection* is blocked.

Resolutions (all but #4 settle the same way the rest of the design did — minimal, P2):

1. **Factotum self-generates the key** via a new ctl verb (e.g. `genkey proto=sign
   service=audit alg=mldsa87`). The SK is born inside factotum and never crosses the
   mount or any other process — the **strongest** P2. Tiny ctl write. Cost: a small,
   contained `factotum.b` *core* change (and a way to publish the public key). Makes
   `mkauditkey` unnecessary. **Recommended.**
2. **Provision into secstore directly**; factotum loads it at startup (no 9P framing on
   the startup blob). No factotum core change, but needs the secstore filekey and is
   more moving parts; SK still transits provisioning memory.
3. **Raise the emu mount `MAXRPC`** (exportfs already allows 64 KB). One emu C change but
   affects *all* mounts — broad blast radius.
4. **Downgrade to `mldsa65`** (~8 KB line, fits) — rejected: violates the CNSA 2.0
   Category 5 / `mldsa87` decision.

This is an architectural fork (options 1 and 3 touch a *core*), so it is brought for an
explicit decision before proceeding — consistent with the no-core-change-without-consult
rule. Sections 4–7 describe the ctl-injection design as built so far; it stands except for
how the key first enters factotum, which #1–#3 resolve.

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
