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
- **Minimal factotum core surface.** The signing logic is an auto-discovered proto
  (`readprotos()`/`startproto()` load `/dis/auth/proto/*.dis`,
  [`factotum.b:525,602`](../../appl/cmd/auth/factotum/factotum.b)). The only core change is
  a small `genkey` ctl verb so factotum can *mint* the (10 KB) PQC key in-process — see
  §7a; without it the key cannot be injected over the 8192-byte ctl frame, and minting it
  inside factotum is also the strongest P2 (the SK never exists anywhere else).

## 3. Architecture

```
provisioning (once, after login):           runtime (every checkpoint):
  echo 'genkey proto=sign service=audit \      auditfs writectl("checkpoint"):
        alg=mldsa87 owner=audit' \               open /mnt/factotum/rpc
       > /mnt/factotum/ctl                       start proto=sign service=audit role=client
   -> factotum genSK in-process (SK never        write  <content bytes>
      leaves factotum); stores it as a key       read   <- certtostr(cert), chunked
      with secret !sk=<enc(sktostr)>;            append "head=.. seq=.. sig=hex(cert)"
      persist thread seals to secstore.
  pubkey: auditfs fetches via the sign         (auditverify recomputes the same content
      proto's op=pubkey, serves /mnt/audit/pubkey  and verifies the cert with the pubkey)
  (at boot, factotum loads the key from secstore)
```

`content` is the existing signed string: `audit-checkpoint <hex(tiphash)> <seq>`
([`auditfs.b:291`](../../appl/cmd/auditfs.b)). The proto hashes it (SHA-256) and signs
with the ML-DSA-87 SK it holds; `auditfs` hex-encodes the returned `certtostr` into the
record exactly as today. **`auditverify` is unchanged** — same keyring `Certificate`.

## 4. Components & changes (each flagged for review)

| # | File | Change | New code? |
|---|------|--------|-----------|
| 1 | **`appl/cmd/auth/factotum/proto/sign.b`** (new) | New `Authproto`. `interaction()`: `io.findkey(proto=sign … !sk?)`, reconstruct SK via `kr->strtosk(decode(!sk))`; `op=pubkey` returns `pktostr(sktopk(sk))`, else `io.read()` content, `kr->sign(...)`, return `certtostr` in ≤4000-byte chunks, `io.done(nil)`. | yes (proto) |
| 2 | **`appl/cmd/auth/factotum/proto/mkfile`** | Add `sign.dis` to `TARG`. | 1 line |
| 3 | **`appl/cmd/auth/factotum/factotum.b`** (core) | New `genkey` ctl verb: `genSK(alg,owner)` in-process, store key with secret `!sk=encodesk(sktostr)`; `encodesk` helper (`\n`→`@`, `=`→`~`). | small core edit |
| 4 | **`appl/cmd/auditfs.b`** | Replace in-process `signhead()`/`signsk` with a factotum driver (`Factotum->open()`+`rpc` start/write/read, chunk-reassembling). **Remove `-k` entirely.** Serve `Qpubkey` by fetching from factotum (`op=pubkey`) and caching. | moderate edit |
| 5 | **`lib/sh/audit-setup`** (new shell script) | Provisioning, Plan 9 idiom — one line: `echo 'genkey proto=sign service=audit alg=mldsa87 owner=audit' > /mnt/factotum/ctl`. No key material on disk; `mkauditkey`/`sk2line` no longer needed. | shell (~15 ln) |
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

## 7a. Key-injection size — RESOLVED by factotum self-generation (owner: option 1)

Empirically (build + emu): an **ML-DSA-87 key line is ~10 KB**, because `sktostr`
serializes the secret key **and** the public key (4896 + 2592 = 7488 bytes → ~10 KB
base64). The emu mount iounit is **8192 bytes** (`emu/port/devmnt.c` `MAXRPC =
IOHDRSZ+8192`), so writing that line to `/mnt/factotum/ctl` would split into two Twrites
and corrupt — *injecting* a PQC key over the wire is not viable.

**Resolution (owner decision): factotum self-generates the key** via a new `genkey` ctl
verb. The operator writes one short line — `genkey proto=sign service=audit alg=mldsa87
owner=audit` — and factotum runs `genSK` **in-process**: the secret key is born inside
factotum and never crosses the mount or exists in any other process — the **strongest**
form of P2. No size problem (the directive is tiny; the 10 KB never traverses 9P). The
public key is fetched on demand via the sign proto's `op=pubkey` mode. `mkauditkey` is
removed. The only cost is a small, contained `factotum.b` core change (the `genkey` verb
+ an `encodesk` helper), which the owner approved.

(Rejected alternatives: provision into secstore directly — needs the secstore filekey,
more moving parts, SK transits provisioning memory; raise emu `MAXRPC` — emu-wide blast
radius; downgrade to `mldsa65` — violates the CNSA 2.0 Category 5 decision.)

## 8. Testing status (honest)

- **Proven (deterministic):** `tests/auditsign_test.b` (3/3) exercises the exact path
  `genSK(mldsa87)` → `encodesk` → proto `decode` → `strtosk` → `sign` → `verify`, asserts
  the stored value is `=`-free / newline-free / whitespace-free, and that a signature does
  not verify over different content. This covers the crypto and the single-line encoding —
  the parts most likely to be subtly wrong.
- **Not yet verified live:** the running wire path (`genkey` → sign proto → `auditfs`
  driver) end-to-end. The ad-hoc `auth/factotum &` shell harness in the dev sandbox
  **hangs on any factotum `ctl` I/O** — and this was confirmed to affect the **unmodified**
  factotum too (reading `/mnt/factotum/ctl` hangs on stock factotum; reading `proto`
  works). So it is a harness/environment limitation, not a code regression: the bare shell
  does not bring factotum's ctl serving fully up the way the real boot / CI host-tests do
  (which write keys to ctl successfully). **Next step:** an integration test under the
  proper boot harness (à la `tests/host/wallet9p_test.sh`) or validation on a booted
  system. Manual recipe: after login, `sh /lib/sh/audit-setup`; `echo checkpoint
  >/mnt/audit/ctl`; `cat /mnt/audit/chain | auditverify -k /mnt/audit/pubkey`.
- **`auditfs` serveloop blocks during signing.** The checkpoint write drives factotum
  synchronously (as `kr->sign` did before). Infrequent + local, so acceptable; noted.
- **Missing-key edge in a GUI session.** If the audit key is absent *and* a needkey prompt
  agent is reading `/mnt/factotum/needkey`, a checkpoint could prompt/block; headless it
  degrades to unsigned immediately (`needfid == -1`). Provisioning makes this a
  misconfiguration case only.

## 9. Scope boundary

This change does **only** the factotum-held signing for audit checkpoints. It does not
touch the hash chain, the record format, the verifier's crypto, or any other factotum
key type. Agent-provenance (INFR-355) and AU-4/5/6/7 operational tooling remain separate.
