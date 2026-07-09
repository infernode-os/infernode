# Why Plan 9 / Inferno Have No General-Purpose Logging Subsystem — and What It Means for Our Audit Log

**Purpose:** Ground-truth the design rationale behind the *absence* of a Unix-style logging
framework (syslogd / journald) in Plan 9 and Inferno, so the InferNode audit-log service
(EPIC 2 / [INFR-343]) aligns with — rather than violates — established Plan 9/Inferno design
principles.
**Method:** Five-angle deep research over primary papers, source code, man pages, and
community discussion. Each claim below is marked **[DOCUMENTED]** (a primary source states or
proves it) or **[INFERENCE]** (a well-founded reading of documented general principles, not a
logging-specific quote). This distinction is deliberate: the honest finding is that *most of
the "why" is inference from articulated general philosophy, plus the proof-in-the-code.*
**Date:** 2026-06-22.

> Sourcing caveat: this session's egress policy blocked direct fetches of 9p.io, cat-v.org,
> man.9front.org, usenix.org, and the 9fans/9front archives (403 at the proxy). Verbatim
> passages were recovered via search-engine extraction of those primary pages and via
> directly-fetched GitHub mirrors of the Plan 9/Inferno source trees; Inferno specifics were
> read from **this repository's own copies**. Primary URLs are cited for manual re-verification.

---

## 0. The load-bearing fact (reframes the whole question)

**[DOCUMENTED]** Plan 9 *does* ship `syslog` — and it is a **~60-line libc function, not a
daemon**. `sys/src/libc/9sys/syslog.c` opens `/sys/log/<name>`, takes a lock, `seek`s to EOF,
and `write`s one text line (`sysname: time: mesg`); if the file or console won't open it also
prints to `#c/cons`. No socket, no `/dev/log`, no facility/severity routing, no binary
journal, no rotation, no collector. A code search of the full tree for `syslogd` returns
**zero files**. (Source: https://github.com/brho/plan9/blob/master/sys/src/libc/9sys/syslog.c ;
Go's stdlib confirms syslog is "not implemented on Plan 9": https://pkg.go.dev/log/syslog)

So the accurate framing is **not** "Plan 9 rejected logging." It is: **Plan 9 kept the
*function* `syslog` and reduced it to its irreducible core — append a text line to a file —
and discarded the daemon, the wire protocol, the config language, and the retention policy.**
Everything below explains *why that reduction is principled, not lazy.*

## 1. Everything-is-a-file + per-process namespace → a log needs no subsystem

**[DOCUMENTED]** The three founding principles ("Plan 9 from Bell Labs", `sys/doc/9.ms`):
resources are named/accessed like files; one protocol (9P) accesses them; per-process
namespaces join services into one private hierarchy. *"9P is really the core of the system; it
is fair to say that the Plan 9 kernel is primarily a 9P multiplexer."* And the payoff: *"By
reducing 'object' to 'file', Plan 9 gets some technology for free"* — access control, naming,
and network transparency come prepackaged. (https://github.com/0intro/plan9/blob/master/sys/doc/9.ms)

**[INFERENCE]** Therefore a log is just a file that already *has* access control, naming, and
network transparency — so a dedicated logging mechanism would be redundant machinery. The
papers draw this "reduce to file" argument for `/proc`, the window system, `ftpfs`, etc.;
they never draw it for logs specifically. But `syslog.c` proves logging in fact follows it.

## 2. Do-one-thing-well / don't-accrete-mechanism → a logging daemon is unwelcome

**[DOCUMENTED]** McIlroy's Unix philosophy (BSTJ 1978): *"Make each program do one thing well…
Expect the output of every program to become the input to another… Write programs to handle
text streams, because that is a universal interface."* Pike & Kernighan, *"cat -v Considered
Harmful"* (1983): adding features "does not make it easier for users… it just makes the manual
page thicker"; the remedy is do-one-thing-well + compose. Pike, *"Systems Software Research is
Irrelevant"* (2000): a lament against complexity-accretion; *"concentrate on interfaces and
architecture."* (https://harmful.cat-v.org/cat-v/ ; https://www.lysator.liu.se/c/pikestyle.html)

**[INFERENCE]** A `syslogd` — a long-running daemon + socket protocol + facility/severity
config + rotation policy — is the canonical "encrusted subsystem" this culture refuses. The
people who would not let `cat` grow a `-v` flag would not bless a logging daemon when
`write()` to a file already exists. (No primary source names "logging daemons" as the target
of this critique — it's the direct corollary.)

## 3. The file system absorbs retention / rotation / archival

**[DOCUMENTED]** Plan 9's daily WORM dump snapshots the whole tree to write-once storage and
keeps it forever: *"The philosophy of the Plan 9 file system is that random access storage is
sufficiently cheap that it is feasible to retain snapshots permanently."* *"Once a file is
written to WORM, it cannot be removed… there is no df command."* History is mounted by date
(`/n/dump/1995/0315`). And the explicit backup stance ("The Use of Name Spaces in Plan 9"):
**"There is no backup system as such; instead, because the dump is in the file name space,
backup problems can be solved with standard tools such as cp, ls, grep, and diff."** Venti
later hardens it: content-addressing *"enforces a write-once policy, preventing accidental or
malicious destruction of data."* (https://9p.io/plan9/about.html ; https://9p.io/sys/doc/names.html ;
https://www.usenix.org/legacy/publications/library/proceedings/fast02/quinlan/quinlan.pdf)

**[INFERENCE]** Unix's logrotate + journald-retention exist mainly to bound disk growth and
age data out. Plan 9 inverts every premise (WORM never deletes; history is the dated dump;
retention policy is "keep everything"), so the *functions* that machinery provides are
absorbed into the storage layer. The authors say this **for backup, verbatim**; extending it
to *logging/rotation/retention* is the analyst's step — sound, because in Plan 9 logs are not
a special category, they are just files, and the FS versions/retains/immutabilizes all files
uniformly.

## 4. The namespace absorbs centralization / forwarding

**[DOCUMENTED]** Centralized shared servers are the architecture: diskless terminals/CPU
servers share one file server; *"one database on a shared server contains all the information
needed for network administration"* ("The Organization of Networks in Plan 9", `net.ms`). Any
9P-served directory can be mounted by any machine (`import`/`exportfs`).

**[INFERENCE]** So `/sys/log` on a shared server is *already* a central log location for many
diskless clients — 9P + mount **is** the transport, making a syslog wire protocol (UDP 514,
relays, forwarders) redundant. The premises are explicit; the logging conclusion is not stated
anywhere — it falls out of the topology.

## 5. Mechanism vs policy — the cleanest articulation

**[DOCUMENTED]** Plan 9 keeps *mechanism* minimal and in the kernel (one protocol, one
abstraction) and pushes *policy* to user level: *"9P is the only protocol the kernel knows;
other protocols are provided by user-level translators,"* and any process customizes its own
namespace. **[INFERENCE, direct]** Logging policy is therefore *not* baked into the OS:
`syslog()` appends to `/sys/log/<name>`; *where* that resolves, whether it's local/remote/
forwarded, what rotates, and who reads it are decided by the namespace and ordinary file
tools. The Unix/systemd contrast is sharpest here — journald promotes logging into an
OS-resident, always-on, policy-bearing subsystem with a binary store only `journalctl` reads.

## 6. Inferno pushes the same logic harder (embedded, no disk)

**[DOCUMENTED]** Inferno targets machines with as little as **1 MB of RAM and no assumable
disk** (set-top boxes, handhelds) — `doc/bltj.ms` (BLTJ 1997). Its model is identical:
resources are files over **Styx**; durability/aggregation is the (possibly remote) file
server's job, imported into the namespace. Mechanism-not-policy is explicit: *"the system does
not impose its own [policy]."* Its logging primitive, `logfile(4)`, is a **memory-based
append-only *circular* buffer** that **never blocks the writer** and **silently drops** the
oldest bytes under pressure — documented behavior, with the silent-loss caveat called out in
BUGS, and a source comment showing they consciously chose not to even mark elisions. The
kernel's own `/dev/klog` is the same bounded-RAM-tail shape. (This repo: `doc/bltj.ms`,
`man/4/logfile`, `appl/cmd/logfile.b`, `man/3/cons`.)

**[INFERENCE, strong]** A lossy, non-durable RAM ring is the *correct* primitive when the
floor is 1 MB and there may be no disk: O(1) bounded memory, never stalls the producer,
assumes no storage. Persistence is achieved by mounting a durable server at the log path —
deliberately out of scope for the OS.

## 7. The honest meta-finding (the ground truth you asked for)

**[DOCUMENTED-by-absence]** Across primary papers, source, man pages, *and* the 9fans/9front
archives, **no source explicitly poses or answers "why no logging daemon."** There is no
manifesto, and — tellingly — **no community debate**: in a community that argues vigorously
about governance, fs choice, ssh, platforms, logging-framework advocacy is essentially absent.
Practitioners just append per-service output to files (`auth/cron >>/sys/log/cron >[2=1] &`)
or call `syslog()` into a named `/sys/log/<svc>` file; inspection is `cat`/`grep`, not a query
tool. No `logfs` / structured logger was ever proposed or built.

**The conclusion:** the absence of a logging subsystem is **emergent, not decreed.** Plan 9
never made a decision *against* a logging framework — the question never arose, because
everything-is-a-file + 9P + the dump absorbed the requirement so completely that logging never
registered as a distinct problem needing its own subsystem. *The rationale is proved by the
code and by what was never built, not by an essay.*

---

## 8. What this means for the InferNode audit log (design alignment)

The research is not academic — it sets hard guardrails for our design:

1. **Be a file server, not a daemon-with-a-protocol.** The audit log must present as a 9P
   file service (`/mnt/audit`), written with `write()` and read with ordinary tools — the
   native idiom. *(Our design already is this.)* ✅
2. **Access control by placement, not by a logging ACL system.** Bind write-only `log` into a
   subject's namespace; never bind `chain`/`verify`. Pure Plan 9. ✅
3. **Compose existing services; invent no subsystem.** Use **vac/Venti** (the native
   content-addressed immutable store) as the substrate and **factotum** (the native credential
   agent) for signing — *not* a bespoke crypto subsystem. ✅ (This is why the vac + signed-root
   design beats a hand-rolled forward-secure MAC machine.)
4. **Text lines, the universal interface.** Records are line-oriented `key=value` text — **no
   binary journal, no JSON.** Auditing is `cat`/`grep`/`vacfs`, plus a tiny verifier. ✅
5. **Mechanism, not policy.** Ship the append+seal *mechanism*; leave *policy* — where it
   persists, retention, off-host shipping — to the namespace (mount a remote vac/Venti at the
   path). Retention/centralization come from the substrate + topology, exactly as Plan 9
   intends. ✅
6. **Add the smallest possible delta, and only where needed.** Plan 9 logging is
   *tamper-indifferent and lossy* because it never needed integrity. An audit log needs
   exactly two properties the native model lacks: **tamper-evidence** and **no silent loss**.
   We add *only* those two, by composing existing primitives — not a journald-style framework.
7. **Do NOT build a grand unified logger.** The strongest alignment conclusion: a central,
   always-on collector for *all* logs is precisely the journald move Plan 9's whole stance
   rejects. So **the audit log stays narrowly scoped to security + agent-provenance events**;
   general/operational logging stays on the native lossy path (`logfile`/console). Only events
   that *need* integrity pay the audit cost. This settles the earlier "audit-only vs general
   `/mnt/log`" question: **audit-only.** (A minimal durable `/mnt/log` could be added later if
   wanted, but it must remain "append to a file server," never a framework — and it is not
   needed for the audit mission.)

**Net:** our design is aligned *by construction* — it is "Plan 9 file-append logging, plus the
two properties (tamper-evidence, completeness) that an audit trail provably requires, added by
composing vac + factotum rather than by importing a subsystem." We are extending the native
model along the one axis it was silent on (integrity), not replacing it with a Unix-style one.

## 9. Sources

- Plan 9 from Bell Labs / 9.ms: https://github.com/0intro/plan9/blob/master/sys/doc/9.ms · https://9p.io/sys/doc/9.html
- The Use of Name Spaces in Plan 9: https://9p.io/sys/doc/names.html ("no backup system as such")
- The Organization of Networks in Plan 9: https://github.com/0intro/plan9/blob/master/sys/doc/net/net.ms
- Plan 9 overview (dump philosophy): https://9p.io/plan9/about.html
- syslog(2) implementation (proof: no daemon): https://github.com/brho/plan9/blob/master/sys/src/libc/9sys/syslog.c
- Quinlan, A Cached WORM File System (SP&E 1991): https://doc.cat-v.org/plan_9/misc/cw/cw.pdf
- Quinlan & Dorward, Venti (FAST 2002): https://www.usenix.org/legacy/publications/library/proceedings/fast02/quinlan/quinlan.pdf
- McIlroy, Unix philosophy (BSTJ 1978): https://en.wikipedia.org/wiki/Unix_philosophy
- Pike & Kernighan, "cat -v Considered Harmful" (1983): https://harmful.cat-v.org/cat-v/
- Pike, "Systems Software Research is Irrelevant" (2000): http://herpolhode.com/rob/utah2000.pdf
- Inferno (this repo): `doc/bltj.ms` (BLTJ 1997), `man/4/logfile`, `appl/cmd/logfile.b`, `man/3/cons`
- Practitioner idiom (cron via redirect): https://github.com/AnastasiosPapalias/Plan9/blob/main/9front-qemu-training.md
- Go stdlib (syslog absent on Plan 9): https://pkg.go.dev/log/syslog
