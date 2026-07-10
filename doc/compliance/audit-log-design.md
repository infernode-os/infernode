# Design — InferNode Tamper-Evident Audit Log (`/mnt/audit`)

**Status:** Authoritative design (supersedes the `SP800-92-audit-log-DESIGN.md` proposal stub).
**Implementation:** v1 security log **built and tested** — `auditfs` server (`log`/`chain`/
`head`/`verify`/`pubkey`/`ctl`), the `auditchain` hash-chain module (unit-tested), the
`auditverify` offline verifier, and the `audit` client lib. Checkpoint signing is
**factotum-held** (ML-DSA-87 via the `sign` proto): `auditfs` never sees the private key; the
public key is served at `/mnt/audit/pubkey`. Access control is namespace placement, as
designed (the write files are mode-open so any subject with `log` bound can append;
restriction is by *what is bound*, not by mode bits).
**Hardening pass (2026-07-10):** the enforcement gaps between this design and the code were
closed — see §5a. In brief: `auditverify -k` makes signatures **mandatory** (a rewrite that
strips `sig=` tokens or checkpoint records no longer verifies); `auditverify -a` checks the
chain against an **off-host copy of `head`** (the truncation defence); checkpoints **drive
themselves** (count + time cadence, signed-only — unsigned markers no longer exist); the
`checkpoint` event is **reserved** to the server on `log`; a boot `auditfs start` record makes
restarts visible and binds a log to its host; `verify` detects **live divergence** of the
backing file from the in-memory chain; `chain` reads stream by offset (no whole-file copy per
read); and the promised **fail-closed** emitters are real (secstored auth, 2fa lifecycle) via
the opt-in marker `Audit->ONFILE`.
**Integration:** `lib/sh/profile` mounts `auditfs` at `/mnt/audit` *before* `auth/secstored`,
and `secstored` emits the first events — `secstore authok user=<u>` / `secstore authfail`
(AU-2/AU-3) — via the loosely-coupled `audit` client lib (no-op if `/mnt/audit` is absent and
the install has not opted in). 2fa emits `enroll`/`addkey`/`disable`. Further emitters (login
UI, factotum key ops, CDS guard) and the vac content-store layer for agent provenance are the
next phases.
**Tracking:** EPIC 2 / [INFR-343]. **Date:** 2026-06-22; hardening pass 2026-07-10.
**Grounding:** read [`plan9-logging-rationale.md`](plan9-logging-rationale.md) (why Plan 9 has no
logging subsystem) and [`audit-log-prior-art.md`](audit-log-prior-art.md) (the prior-art survey)
first — this design is the disciplined consequence of both.

> **Read this first — the one-sentence design.** The audit log is **Plan 9 file-append
> logging, plus the two properties an audit trail provably requires that the native model
> lacks — tamper-evidence and completeness — added by *composing* existing InferNode services
> (a `keyring` hash chain + a `factotum`-signed checkpoint), exposed as one small 9P file
> server you can delete.** It is not a logging framework, not a daemon with a protocol, and
> not a journald. It adds exactly two properties along the single axis Plan 9's logging was
> silent on (integrity), and nothing else.

---

## 1. Why it is designed this way (read before asking "why not X")

A CISO, an Inferno purist, and a future maintainer will all ask the same question you did —
*why this way and not some other way?* Each answer is anchored in the rationale doc.

| Question | Answer | Because |
|----------|--------|---------|
| **Why not a syslog/journald-style logging daemon?** | We don't build one. | Plan 9 deliberately has none — logging is "write a line to a file." A central, always-on, policy-bearing collector is the exact subsystem the philosophy rejects (`plan9-logging-rationale.md` §2, §7). |
| **Why a 9P file server and not a kernel device or a library?** | A small Limbo `styxserver` at `/mnt/audit`. | "Everything is a file"; access control is namespace placement; no new C in the TCB; memory-safe Dis. (`rationale` §1, §8.1) |
| **Why a hash chain and not a hand-rolled forward-secure MAC (Schneier–Kelsey)?** | Chain + signed checkpoints, composed from existing primitives. | A bespoke evolving-key MAC subsystem is precisely the "encrusted mechanism" Plan 9 refuses. Composition (keyring + factotum + namespace) beats a new crypto subsystem. (`prior-art` §4; `rationale` §8.3) |
| **Why signed *checkpoints* and not a signature per record?** | Periodic + forced-on-high-value signed roots. | Per-record signing can't be hardware-gated at volume; checkpoints are the recognized CT/RFC-6962 pattern; the chain protects between checkpoints. (`prior-art` §2,§4) |
| **Why text lines and not JSON / a binary journal?** | Line-oriented `key=value` text. | "Text is the universal interface"; `cat`/`grep`/`vacfs` are the tools; no internal JSON (project rule). (`rationale` §2) |
| **Why local-first and not forced-remote?** | Local append; off-host is namespace policy (mount a remote sink at the path). | Mechanism-not-policy: ship the append+seal mechanism; leave *where it persists* to the namespace. (`rationale` §5) |
| **Why scoped to security events, not all system logs?** | Audit-only; operational logging stays on the native lossy path (`logfile`/console). | A "log everything centrally" service is the journald move Plan 9 rejects; only events needing integrity should pay the audit cost. (`rationale` §8.7) |
| **Why is it removable?** | Writers emit only if `/mnt/audit/log` is bound; the service is one standalone command. | Loose coupling via the namespace — absence = feature off. (§7) |

If a reviewer's "why not X?" isn't answered above, that's a doc bug — add the row.

## 2. What it must do (requirements)

**Functional:** one append-only sink many subsystems write to; tamper-evident (any edit,
reorder, deletion/truncation detectable); independently verifiable **offline**; access-
controlled by namespace placement; **complete** (no silent loss — unlike `logfile`).

**Non-goals (kept out on purpose):** not a SIEM; not log search/analytics; not operational/
debug logging; not retention/alerting policy; not the system's general logger.

**CISO / control requirements it must satisfy** (mapped in §9): SP 800-53 **AU-2, AU-3, AU-8,
AU-9, AU-9(3), AU-10, AU-12**; SP 800-92; PCI-DSS Req 10.5; ISO 27001 A.12.4.2; SOC 2 CC7.

## 3. Architecture — what is reused vs. what is new

```
   subsystems (login, factotum, cds, veltro)         auditor / CISO
        |  write "source event msg"                        |  read + verify
        v                                                  v
   ┌──────────────────────  /mnt/audit  (Limbo styxserver) ─────────────────┐
   │  log     write-only  → append + extend hash chain (keyring->sha256)    │
   │  chain   read-only   → records + per-record hash, oldest first         │
   │  head    read-only   → current tip hash + seq  (the anchor)            │
   │  verify  read-only   → "ok N" | "broken at seq K"  (self-check)        │
   │  ctl     write-only  → "checkpoint" (force a signed root)              │
   └──────────────┬───────────────────────────────────┬────────────────────┘
                  │ append-only backing file            │ sign tip
                  v                                      v
        /usr/inferno/audit/log (local)            factotum  (keyring->sign,
        — or a REMOTE sink, by namespace —         ML-DSA/Ed25519 audit key)
```

**Reused (composed), not built:** `keyring->sha256` (the chain), `keyring->sign` / `factotum`
(the checkpoint signature), `styxservers`/`styx` (the 9P server), the **namespace** (access
control + off-host placement), and — for the agent-logging extension (§8) — `vac`/`venti`
(content-addressed blob store) and `vacfs` (audit read path).

**New (the minimal delta):** one styxserver command (`auditfs`), one verifier command
(`auditverify`), a thin optional client lib, and the record/chain format. That is the entire
new surface.

## 4. Interface (the namespace) & record format

### 4.1 Files
| File | Mode | Purpose |
|------|------|---------|
| `log` | write-only, append | write `source event msg`; server seals it into a record. The event `checkpoint` is **reserved** to the server (a writer must not mint records the verifier gives special semantics) |
| `chain` | read-only | the sealed records, oldest first (see 4.2); streamed by offset from the backing file |
| `head` | read-only | `<tiphash> <seq>` — the anchor to publish/ship |
| `verify` | read-only | `ok <count>`, `broken at seq <n>`, or `diverged: ...` (the backing file replays clean but disagrees with the live chain — it was modified behind the running server) |
| `pubkey` | read-only | the audit public key, fetched from factotum (empty if signing is not provisioned) |
| `ctl` | write-only | `checkpoint` forces a signed root now (for high-value events); errors if factotum holds no signer key |

**Access by placement:** a subject's namespace gets **only `log`** bound (write-only) — never
`chain`/`head`/`verify`/`ctl`. So any subject (including a malicious agent) can append to its
own trail but **cannot read or rewrite history** — tamper-evidence against the writer itself,
by construction.

### 4.2 Record format (line-oriented text, no JSON)
```
seq  time        source   event      hash             message
1    1783700238  auditfs  start      9ce71e…(64 hex)  host=nerva3 replay=ok
1042 1783711504  login    unlock     7b2290…          user=alice aal=3 key=yk-37602882
1043 1783711800  -        checkpoint 4a90ff…          head=2862aa… seq=1042 sig=6d6c…(hex cert)
```
- `seq` decimal, **server-assigned** monotonic (caller can't forge order).
- `time` **server-assigned** epoch seconds (caller can't backdate; text, so `date` converts).
- `source` short tag; `event` verb; `message` free `key=value` remainder (server escapes newlines
  and forces source/event to single tokens).
- `hash` = the chain hash for that record (see §5). The caller writes only `source event msg`.
- Record 1 of every server run is `auditfs start host=<sysname> replay=ok|broken@<n>`:
  restarts are visible in the trail, and a log is readably bound to its host.

## 5. Integrity model

- **Genesis:** `H[0] = SHA256("infernode-audit-v1")`.
- **Chain:** `H[n] = SHA256(H[n-1] ‖ record_n)` where `record_n` includes seq+time+fields.
  Editing/reordering/deleting any record changes `H[n]` and every `H[>n]`.
- **Checkpoints (the anchor):** the server drives its own cadence — a signed root at least
  every `CHECKEVERY` records and within `CHECKMS` of any new record — and one can be **forced
  on high-value events** via `ctl`. A checkpoint record signs
  `"audit-checkpoint " ‖ hex(H[tip]) ‖ " " ‖ seq` with an audit key held by **factotum**
  (ML-DSA-87 default). The record's own time is chained, so the signature needn't repeat it.
  Checkpoints are public-verifiable with the audit **public** key — no secret needed by the
  auditor (a CISO win). The chain protects the records *between* checkpoints.
  **Signed-only:** a checkpoint exists only if factotum signs it. An unsigned marker proves
  nothing the chain doesn't already, and the strict verifier reads one as tampering; a
  chain-only install (no signer key) simply has no checkpoints and relies on `-a` anchoring.
- **External anchoring:** `head` is copied off-host per namespace policy (`cp /mnt/audit/head
  <elsewhere>` — no machinery), and `auditverify -a <head-copy>` requires the chain to reach
  that seq with that tip. This is what catches **truncation**, which is chain-valid by
  construction, and full rewrites on installs without a signer key.
- **Strict verification:** with `-k <pubkey>`, *every* checkpoint must carry a verifying
  signature and at least one must be present. Rationale: the chain holds no secret, so a
  privileged rewrite can recompute every hash — the signatures are the only thing it cannot
  mint, so tolerating their absence would hand the attacker a clean bypass.
- **Startup:** the server recomputes the chain from the backing file (**failing loud** on a
  break) and seals an `auditfs start` record carrying the replay outcome. While running,
  `verify` re-replays the file and reports `diverged` if it no longer matches the live tip.
- **Bounded tail (honest residual):** records after the last signed checkpoint are chain-
  protected but not yet anchored; the built-in cadence bounds the window to
  min(`CHECKEVERY` records, `CHECKMS`).
- **Time (AU-8):** timestamps come from the system clock; trusted/synced time (NTP, attested
  clock) is a deployment requirement, stated in the operator doc.
- **Durability (honest residual):** appends go through the host page cache (Inferno has no
  fsync); a power cut can lose the newest records, indistinguishable from tail truncation —
  another reason the anchor cadence matters.
- **Completeness / fail-closed:** the opt-in marker (`Audit->ONFILE`,
  `/usr/inferno/audit/on`) means *this install requires auditing*. Security-critical writers
  honour it: `secstored` refuses an authenticated session whose `authok` cannot be sealed;
  `2fa` refuses enroll/addkey/disable up front when the sink is unwritable (those operations
  can't be undone to satisfy the log). Installs that never opted in keep the loose-coupling
  contract: absent sink, no-op.

## 6. Threat model (summary)

| Adversary | Outcome |
|-----------|---------|
| In-namespace process / malicious agent edits past entries | Can't — only `log` is bound; can't reach `chain`. Append-only. |
| Forges ordering / backdates | Can't — server assigns seq + time. |
| Writer mints a fake `checkpoint` record through `log` | Can't — the event is reserved; the write errors. |
| Privileged host edits the raw backing file | **Detected** — chain + externally-anchored signed checkpoint don't match. Live edits also surface as `diverged` on `verify`. (Tamper-evident, not tamper-proof — see `prior-art`.) |
| Rewrites the whole chain to stay consistent (hashes recomputed) | Must forge a signed checkpoint (key in factotum, ideally hardware-gated) — can't. **Requires the strict verifier**: `auditverify -k` refuses unsigned or missing checkpoints, so stripping them doesn't help. |
| Truncates the tail (chain-valid by construction) | **Detected against an off-host `head` copy** (`auditverify -a`); the signed cadence bounds the loss window. Not detectable from the file alone — honest residual. |
| Writer claims a false `source` tag | **Honest residual** — the tag is claimed, not derived: `/mnt/audit` is one attach, so all writers share the mount's uname. Mitigation is placement (a subject holds only `log`, can't read the tip to make forgery convincing) and per-subject mounts where attribution matters. |
| Subject that shouldn't see logs | Not bound into its namespace → can't name `/mnt/audit`. |

## 7. Loose coupling & tear-out (a hard requirement)

- **Emit is namespace-gated.** A writer does "write to `/mnt/audit/log` if it exists." If the
  service isn't bound, emitting is a no-op (or a hard error for fail-closed callers) — the rest
  of the system has **no compile- or run-time dependency** on the audit service.
- **The service is one standalone command** (`auditfs`). Removing the feature = stop mounting
  it; writers degrade gracefully. No hooks buried in the kernel or libraries.
- **The client lib is optional sugar.** `audit->log(source,event,msg)` is a ~20-line helper
  that just opens `/mnt/audit/log` and writes; callers may equally do `echo … >/mnt/audit/log`.
- **The backing is swappable** (mechanism-not-policy): local file today, remote sink or
  `vac`/Venti later — same record format, no caller change.

If we dislike it, we delete one command, one lib, and the mount line. That's the test.

## 8. Extending cleanly to AI-agent logging (designed-in, not built yet)

v1 is a **security log**. The agent-provenance extension (prompts, completions, tool calls,
spawns — see the earlier discussion) drops in **without reworking the spine**:

1. **Same chain, same files, same record format.** Agent events are just more `source=veltro`
   records.
2. **Bulk content by reference.** A large prompt/completion is stored as a **vac block** (the
   content store layer) and the record carries `content=<vacscore>` — the chain line stays
   tiny, identical content dedupes, and the sensitive payload is separable from the broadly-
   auditable trail (confidentiality/minimization). This is the one *additive* layer (vac as the
   content store + `vacfs` as the read path); it does not change v1's mechanism.
3. **Same namespace property.** Agents get write-only `log` bound → they record their own
   trajectory but can't rewrite it.
4. **Volume knob.** High-volume agent records use cheap per-record hashing + amortized
   checkpoint signing (the reason B/chain was chosen over a per-record MAC).

So the v1→agent path is *add a content-store layer and wire emitters*, never a redesign.

## 9. CISO / control mapping (how this closes the AU gap)

| Control | Requirement | How met | Phase |
|---------|-------------|---------|-------|
| **AU-2** Event logging | Log defined events | subsystem emitters → `log` | v1 (security) → v2 (agent) |
| **AU-3** Record content | Sufficient fields | seq/time/source/event/msg + hash | v1 |
| **AU-8** Timestamps | Reliable time | server-assigned UTC; trusted-time = deploy policy | v1 (+doc) |
| **AU-9** Protect audit info | Tamper-evident, append-only | hash chain + signed checkpoints; write-only `log` | v1 |
| **AU-9(3)** Crypto protection | Cryptographic integrity | SHA-256 chain + ML-DSA/Ed25519 signed roots | v1 |
| **AU-10** Non-repudiation | Attributable | signed checkpoints (factotum key) | v1 |
| **AU-12** Record generation | Across components | namespace-placed `log`, many writers | v1→v2 |
| **AU-11** Retention | Keep ≥ required | backing store + off-host; Plan 9 "retain permanently" ethos | policy/deploy |
| **SP 800-92 / PCI 10.5 / ISO A.12.4.2** | Secure, change-detectable logs | the above, verifiable offline by public key | v1 |
| **Off-host copy** (PCI 10.5.3-4) | Separate trust domain | namespace: mount a remote sink at the path | deploy (designed-in) |
| **Fail-closed** | Don't act un-audited | per-caller policy (login = hard error) | v1 (+doc) |

Honest residuals (disclosed, not hidden): the **bounded tail** between checkpoints; **off-host**
and **trusted-time** are deployment configuration; **FIPS-validated** crypto module is the
pre-existing SC-13 gap (`FIPS-140-3-readiness.md`), not introduced here.

## 10. Module layout & phasing

**v1 (security log) — the first PR(s):**
- `appl/cmd/auditfs.b` — the `styxserver` (append + chain + checkpoints + the 5 files). *Core.*
- `appl/cmd/auditverify.b` — offline verifier (recompute chain, check signatures with public key).
- `module/audit.m` + `appl/lib/audit.b` — optional thin client (`log(source,event,msg)`).
- `man/4/auditfs`, `man/1/auditverify` — docs incl. operator guide (time, off-host, fail-closed).
- `tests/auditchain_test.b` — the pure chain: genesis/extend determinism, tamper detection.
- `tests/auditverify_test.b` — the adversarial verifier suite: whole-file rewrite, stripped
  signatures/checkpoints, truncation vs anchor, forged checkpoint head, wrong signing key.
- `tests/auditsign_test.b` + `tests/host/audit_signing_test.sh` — the signing path, offline
  and live (factotum genkey → signed checkpoint → strict anchored verify).

**v1 wiring (small, reviewed individually):** `login`/`2fa`, `factotum` emit to `/mnt/audit/log`.

**v2 (agent provenance):** add the vac content-store layer + `content=<score>`; wire
`appl/veltro/{spawn,subagent,nsconstruct}` emitters (route the existing `emitauditlog`).

## 11. What we deliberately do NOT build
No daemon/socket protocol; no facility/severity config language; no binary journal; no internal
JSON; no log search/index; no central collector for all logs; no retention/rotation engine
(the substrate + namespace handle persistence/placement). Each omission is a Plan 9-alignment
choice from `plan9-logging-rationale.md` §8.

## 12. References
- [`plan9-logging-rationale.md`](plan9-logging-rationale.md), [`audit-log-prior-art.md`](audit-log-prior-art.md)
- [`SP800-53-controls.md`](SP800-53-controls.md) (AU rows), [`FIPS-140-3-readiness.md`](FIPS-140-3-readiness.md) (SC-13)
- In-tree idioms: `appl/lib/styxservers.b`, `module/{styx,styxservers,keyring,vac,venti}.m`,
  `appl/cmd/logfile.b`, `appl/veltro/nsconstruct.b` (`emitauditlog`).
