# Prior Art — Immutable / Tamper-Evident Logging in the Plan 9 Family

**Purpose:** Survey existing immutable / append-only / tamper-evident / archival approaches in
Plan 9 (Bell Labs), Inferno, and 9front — plus the relevant general secure-logging literature —
to inform the InferNode tamper-evident audit-log service (EPIC 2 / [INFR-343]).
**Status:** Research input for the audit-log architecture pass. Not a design decision yet.
**Date:** 2026-06-22.

> Sourcing caveat: many canonical hosts (9p.io, cat-v.org, man.9front.org, swtch.com,
> Wikipedia) return HTTP 403 to automated fetch; several claims rest on search-engine extracts
> quoting those primary pages, cross-checked across sources, plus directly-fetched GitHub
> mirrors and — for the Inferno specifics — **this repository's own source**. Primary URLs are
> cited so they can be opened by hand.

---

## 1. Comparison of approaches

| Mechanism | How it makes data immutable | Cryptographic integrity? | Defends vs *compromised host/root*? | Cadence | In Inferno today? |
|-----------|------------------------------|--------------------------|--------------------------------------|---------|-------------------|
| **Plan 9 syslog** (`/sys/log/*`) | Nothing — `open;seek(end);write` to a plain file | None | No — ordinary mutable file, racy across writers | Real-time append | (analog only; no syslogd) |
| **Inferno `logfile`(4)** | RAM **ring buffer**, append-then-**overwrite**; silently drops data | None | No — not even persistent or lossless | Real-time, lossy | **Yes** (`appl/cmd/logfile.b`) |
| **Classic WORM dump** (Ken's fs) | Physical write-once media | None (media-enforced) | Partially — *media* prevents rewrite | Batch (~daily 5AM) | No |
| **cwfs / hjfs dump** (9front) | Software policy: never rewrite "worm" partition; read-only dump tree `/yyyy/mmdd[s]` | None | **No** — "worm" is a normal disk; root can rewrite bytes | Batch (~daily) | No |
| **gefs** (9front, CoW Bε-tree) | Copy-on-write snapshots; block ptrs carry a **64-bit block hash** | Integrity *check only* (corruption, not crypto) | No — snapshots are **deletable/mutable**; hash catches disk corruption, not adversaries | On-demand | No |
| **Venti** (content-addressed store) | Address = **SHA-1 of content**; write-once; append-only arenas; Merkle tree → one root score | **Yes** (SHA-1 content-addressing) | **Detect-only** — a full host compromise can rewrite blocks + recompute the Merkle tree unless the **root score is anchored externally**; WORM is *software policy*, not media | Real-time block writes possible, but tuned for archival (per-write index lookup, ~6.5 MB/s) | **Yes** — `vacput/vacget/vacfs`, `module/{venti,vac}.m` |
| **Fossil → Venti** | Live RW `/active`; periodic snapshots; **archival** snapshots pushed to Venti (immutable vac score; `VtRoot.prev` chains roots) | Yes, *for archived snapshots* | Detect-only (same as Venti); **live tail is mutable** until next archival snapshot | Snapshot (ephemeral hourly / archival daily, operator-set) | No (we have the Venti half, not Fossil) |
| **Schneier–Kelsey** forward-secure log | Per-entry **hash chain** `Yⱼ=H(Yⱼ₋₁,Cⱼ)` + per-entry MAC under an **evolving key** `Aⱼ₊₁=H(Aⱼ)`, old key destroyed | **Yes** (MAC + hash chain) | **Yes — forward security:** entries written *before* compromise cannot be forged/deleted undetectably even after the host is fully owned | Real-time, per-entry | No (would be built) |
| **CT / Trillian** Merkle transparency log | Append-only **Merkle tree**; periodically **signed tree head (STH)**; inclusion + consistency proofs; gossip catches split-views | **Yes** (Merkle + signatures) | Detects tampering & **equivocation**; trust distributed across monitors, not a single host | Batch-anchored (per-STH) | No (would be built) |

## 2. The archetypes that emerge

The survey collapses to **four distinct patterns**:

1. **Plain append, no integrity** — Plan 9 syslog, Inferno `logfile`. Real-time, simple, and
   *zero* tamper-evidence. (Inferno's `logfile` is worse than syslog for audit: it's a lossy
   RAM ring that silently elides data — disqualifying.)
2. **WORM / snapshot immutability by storage policy** — classic dump, cwfs/hjfs, gefs. Immutable
   *historical snapshots* for accident/corruption recovery, **batch** cadence, **no adversary
   model** (modern installs are software-policy on normal disks; gefs even allows deleting
   snapshots).
3. **Content-addressed Merkle immutability** — Venti (and Fossil's archival half). Cryptographic
   (a block's name *is* its hash), a whole archive named by one root score. But: SHA-1;
   *detect-only* (a host that controls the store can recompute the tree); and the safety only
   bites once the **root is anchored outside the store**.
4. **Purpose-built tamper-evident logs** — Schneier–Kelsey (forward-secure hash chain,
   per-entry, **survives host compromise**) and CT/Trillian (Merkle + signed heads, efficient
   O(log n) proofs, distributed non-equivocation). **Neither exists anywhere in the Plan 9
   family.**

**The headline finding:** *the Plan 9 world has no dedicated cryptographic tamper-evident log.*
It deliberately leaned on (2)/(3) — filesystem immutability (dump/Venti) — plus Unix-style
syslog, and never built (4). So for an audit-grade control, **there is no inherited machinery
to reuse on the logging side** — only Venti as an immutable *substrate*.

## 3. Which precedents match a tamper-evident *real-time* audit log

| Precedent | Gets right | Gets wrong (for our use) |
|-----------|-----------|--------------------------|
| **Venti** | Cryptographic content-addressing; Merkle root as a single anchor; native to Inferno; immutable-by-construction | SHA-1; detect-only without external anchor; dedup index per write (useless for unique records, throughput ceiling); archival-tuned |
| **Fossil** | The "live front-end + periodic immutable snapshot + chained roots" shape is exactly an audit log's shape | **Mutable live tail** — a real window where recent events aren't yet protected; complexity (deadlocks) drove 9front to drop it |
| **Schneier–Kelsey** | Per-entry, **real-time** tamper-evidence that **survives host compromise** (the property Venti lacks) | Single trusted verifier; O(n) verification; no archival store of its own |
| **CT / Trillian** | Efficient O(log n) proofs; non-equivocation via signed heads + gossip | Batch-anchored (gap before STH); heavier; designed for public multi-party logs |

The closest *shape* is **Fossil's** (live append → periodic immutable snapshot → chained roots),
and the closest *integrity substrate* is **Venti's** — but the property a security auditor
actually needs (tamper-evidence that holds **even if the logging host is later compromised**)
comes only from the **Schneier–Kelsey forward-secure** pattern, which the Plan 9 world never had.

## 4. Recommendations & pitfalls for the InferNode audit log

**Recommended synthesis — Plan 9 substrate + the forward-security Plan 9 never had:**

1. **Real-time front-end = forward-secure hash chain (Schneier–Kelsey).** Each event, as it
   lands, extends a hash chain and carries a MAC under a key that **evolves one-way per record
   (old key destroyed)**. This gives *per-event, real-time* tamper-evidence that **survives a
   later host compromise** — directly answering both the "real-time" and the "compromised host"
   questions. This is the piece with no Plan 9 precedent, and it's the one that makes the
   control credible to a CISO.
2. **Archival substrate = SHA-256-modernized vac/Venti.** Periodically seal sealed chain
   segments into the content-addressed store; the **root score** is the external anchor (print
   at shutdown / commit / sign). Reuses `vac`/`vacfs` (audit = mount read-only by score).
   Modernize the score hash to SHA-256 — **SHA-1 is a non-starter** for a security control
   (SHAttered, 2017), and there is **no existing SHA-256 Venti fork**, so this is our work
   (clean break, consistent with the project's crypto-modernization precedent).
3. **External anchoring / off-host (non-equivocation).** Optionally sign the periodic head with
   a factotum **ML-DSA** key (CT-style signed tree head) and/or ship heads off-box. This is what
   turns "detectable on this box" into "cannot equivocate."

**Pitfalls to avoid (each observed in the prior art):**
- **Don't build on Inferno `logfile`** — it's a lossy RAM ring that silently drops data.
- **Don't rely on a mutable live tail** (Fossil's flaw) — chain *every* event immediately; don't
  wait for a snapshot to make a record safe.
- **Don't use full Venti with its dedup index** — dedup is pointless for unique audit records and
  the per-write index lookup caps throughput; a **dedup-free append arena** (or periodic vac
  seal) fits better.
- **Don't equate WORM-on-disk with tamper-proof** — cwfs/hjfs/Venti on a normal disk are
  *tamper-evident*, not *tamper-proof*; only forward-secure keying + external anchoring (or true
  WORM/remote storage) resists a compromised host.
- **Don't ship SHA-1.**
- **Mind verification cost** — a linear chain is O(n) to prove one entry; if proof efficiency
  matters at volume, a Merkle structure (CT-style) gives O(log n). Likely overkill for v1.

**Net:** lean on **vac/Venti (SHA-256) as the immutable archival substrate** — the elegant,
native Plan 9 answer the owner identified — but front it with a **forward-secure hash-chained
append log** for real-time, host-compromise-resistant tamper-evidence, since *that* is the
property the entire Plan 9 lineage is missing.

## 5. Key sources

- Venti: Quinlan & Dorward, *Venti: a new approach to archival storage*, USENIX FAST 2002 —
  https://www.usenix.org/legacy/events/fast02/quinlan/quinlan_html/ ; venti(8) —
  https://9fans.github.io/plan9port/man/man8/venti.html ; https://en.wikipedia.org/wiki/Venti_(software)
- Fossil: Quinlan/McKie/Cox, *Fossil, an Archival File Server* —
  http://doc.cat-v.org/plan_9/4th_edition/papers/fossil/ ; fossil(4)/fossilcons(8) mirrors;
  https://en.wikipedia.org/wiki/Fossil_(file_system)
- Dump / WORM: Quinlan, *A Cached WORM File System*, SP&E 1991 —
  https://doc.cat-v.org/plan_9/misc/cw/cw.pdf ; cwfs(4) —
  https://github.com/Earnestly/plan9/blob/master/sys/man/4/cwfs
- gefs: Ori Bernstein — https://orib.dev/gefs.html ;
  https://git.9front.org/plan9front/plan9front/HEAD/sys/doc/gefs.ms/f.html
- Plan 9 logging: syslog.c — https://github.com/brho/plan9/blob/master/sys/src/libc/9sys/syslog.c ;
  authsrv.c — https://github.com/brho/plan9/blob/master/sys/src/cmd/auth/authsrv.c ;
  ratrace(1) — https://github.com/9front/9front/blob/master/sys/man/1/ratrace ;
  Security in Plan 9 — https://9p.io/sys/doc/auth.html
- Inferno (this repo): `man/4/logfile`, `appl/cmd/logfile.b`, `appl/cmd/auth/{logind,keyfs,secstored}.b`
- Secure-logging literature: Schneier & Kelsey, *Secure Audit Logs…*, ACM TISSEC 1999 —
  https://dl.acm.org/doi/10.1145/317087.317089 ; Crosby & Wallach, USENIX Security 2009 —
  https://www.usenix.org/legacy/event/sec09/tech/full_papers/crosby.pdf ; RFC 6962 (CT) —
  https://www.rfc-editor.org/rfc/rfc6962 ; Trillian — https://github.com/google/trillian
