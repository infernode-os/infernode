# InferNode Design Principles

How to think about design in this system — for human contributors
and AI agents alike. Read this before designing anything new.

Status: convention. The normative short form is the Design
Principles section of [AGENTS.md](../AGENTS.md); this document is
the reasoning behind it.


## Why this document exists

InferNode is a modernized Inferno® OS, and it inherits a design
tradition — Plan 9's — that is coherent, minimal, and different
from what most contributors arrive knowing. Solutions that are
idiomatic elsewhere (a REST endpoint, a JSON config, a policy
middleware, a client SDK) are foreign here, and foreign paradigms
do not compose with this system: they bypass the namespace, they
break the tool ecosystem, and they turn one security chokepoint
into two.

The practical consequence is blunt: work designed the foreign way
usually needs major revision before it can merge, which wastes
your time and ours. This document exists so that doesn't happen.
It explains the head-space, so you can design correctly from the
first sketch — and it explains *why*, because rules without
reasons get misapplied at the boundaries.

If you take one procedural rule from this page, take this one:
**design the file interface first, and show it to us before you
build.** In this system the file interface *is* the design.
A twenty-line namespace sketch can be reviewed in minutes;
three weeks of code cannot.


## The worldview

Four statements, each meant literally:

**Everything is a file.** Not "many things have file-like
wrappers" — everything. Networks (`/net/tcp/0/data`), processes
(`/prog/123/ctl`), the screen (`/dev/draw`), the LLM
(`/mnt/llm`), payments (`/n/wallet`), the audit trail
(`/mnt/audit/log`). Unix had this as a nice idea applied
inconsistently; Plan 9 took it seriously, and InferNode inherits
that seriousness. When you add a capability to the system, you
add it as files.

**The filesystem is the API.** A new service is a 9P file
server, not a library, not an RPC endpoint, not a daemon with a
bespoke socket protocol. Any program in any language — and any
AI agent — can use it with `open`, `read`, `write`. No SDKs.
No protocol buffers. Just files. (This is conceptually what MCP
does for AI tools, except the protocol is forty years simpler
and every existing tool already speaks it.)

**The namespace is the schema.** The directory hierarchy carries
the structure that other systems put into JSON objects, schemas,
and API documentation. `/mnt/sensors/station-1/temperature`
containing `22.5` needs no parser and no spec. Design the tree
and you have designed the interface.

**Text is universal.** Data crossing a 9P interface is plain
text: one value per file, one record per line, fields
space-separated. Every shell tool, every pipeline, and every
LLM consumes it natively. The full argument, with the record
format conventions, is in
[9p-data-conventions.md](9p-data-conventions.md) — read it
before serving any data. JSON is legitimate exactly at external
boundaries (an HTTP API you call, an LLM wire format you speak)
and is kept out of the namespace itself. When an adapter must
speak JSON outward, design the 9P surface as if the adapter will
one day be removed — because it will.


## Namespaces: the part you must internalize

This is the deep idea, and the security model falls out of it.

### Per-process, built, not given

On a conventional OS the filesystem is a shared fact: every
process sees the same tree, and access control is a pile of
checks layered on top. In InferNode every process has its *own*
namespace — its own private view of what exists. A namespace is
built, not given: it starts from what the parent chose to pass
down, and it is composed with two operations, `bind` and
`mount`, which graft trees onto names. Two processes can look at
`/mnt/llm` and see different servers, or one can see nothing
there at all. Composition replaces configuration: where another
system has a config file naming a backend, this system *mounts
the backend at the name the consumer already uses*.

### Authority is the namespace

Here is the inversion that makes this a security architecture
and not just an ergonomic one. On conventional systems a process
inherits the full authority of its user ID, and "least
privilege" is bolted on afterwards as policy that code must
remember to consult. InferNode inverts this: **a process's
authority *is* its namespace. If a name is not bound, the
process cannot express it.** There is no `/etc/passwd` to deny
access to, because it is not in the namespace at all. No ambient
authority; nothing to forget to check.

This is what documents in this repo mean by the phrase "by
construction": the property is structural — there is no code
path that could violate it — rather than a runtime check that
could be bypassed or misconfigured.

### Denial is absence, and that matters

An agent confined to `/appl/veltro` that tries to read
`/appl/cmd/date.b` does not get "permission denied." It gets
**"file does not exist"** — because in *its* world, the file
does not exist. This is called the truthful environment, and it
has a real security payoff: there is no probing oracle. A
confined process cannot map the shape of what it is being denied,
because denial and nonexistence are the same observation.

If you ever find yourself writing a check that produces an
"access denied" error for a path an agent can name, stop: the
right fix is almost always to make the path unnameable instead.

### Attenuation composes downward

Namespace restriction is an allowlist operation: a shadow
directory is built containing only the permitted entries and
bound over the original (`restrictdir()` in
`appl/veltro/nsconstruct.b`; the model is specified in
[appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md)). Because
a child forks an already-restricted namespace and can only
narrow it further, delegation is safe by default: a subagent can
be handed exactly `/mnt/mcp/one-server` — or a single tool —
and it cannot reach anything its parent didn't have. Grants
shrink monotonically down the process tree. You never need a
policy engine to reason about what a delegation chain can do;
you read its namespace.

The agent side of this is worth noting: each turn, the running
agent's actual namespace is injected into its context, and
`cat /tool/tools` shows the restricted view, not the full
catalogue. The enforcement mechanism and the agent's
self-knowledge are the same object. There is no concept of an
"unavailable" tool — an ungranted tool simply isn't there.

### This is verified, not asserted

The namespace isolation property — that a mount performed in one
process group never appears in another's mount table except by
its own action — has been model-checked exhaustively at small
scale and to 3.17 billion distinct states at medium scale, with
supporting SPIN models for the concurrent code and CBMC proofs
over the C implementation (`formal-verification/`). The claim
"a small TCB you can actually verify" is the project's thesis;
design that respects the chokepoint keeps the thesis true.
Design that adds a second enforcement path dilutes it.


## Design the file interface first

When you build a new service or tool, the deliverable to think
about — and the thing to put in your proposal issue — is the
namespace sketch: the tree your server presents, what each file
reads and writes, and a sample shell session.

```
/mnt/sensors/
    ctl                # write: 'poll 30', 'reset'
    status             # read: 'ok 12 stations'
    station-1/
        temperature    # read: '22.5'
        humidity       # read: '0.65'
        log            # read: one reading per line

; cat /mnt/sensors/station-1/temperature
22.5
; echo poll 30 > /mnt/sensors/ctl
```

That sketch is reviewable in minutes, and most design errors are
visible in it. Conventions to follow:

**Placement: who authored the schema?** A tree's mount point is
decided by who authored its schema, not by where its bytes live.
`/mnt/<app>` is for trees a local program synthesizes — the
schema is ours — even when the backing data is remote (`webfs`
serves remote HTTP at `/mnt/web`, because *it* invents the
`ctl`/`uri`/`body` schema). `/n/<source>` is the import yard:
foreign trees imported intact, named by their source
(`/n/local`, a remote peer's root). The full argument, and why
the convention is itself security work, is in
[NAMESPACE-LAYOUT.md](NAMESPACE-LAYOUT.md). A few older trees
predate the convention (`/n/wallet`, `/n/git`, `/n/wikia`,
`/n/speech`); do not copy them for new work — their migrations
are tracked as INFR-400 through INFR-403.

**Control files, not config files.** A service is configured and
commanded by writing text to its `ctl` file, and reports through
readable files (`status`, `event`), not through a config file it
parses at startup or an API it exposes. Where a write changes a
value that can also be read, the write format matches the read
format.

**Writes are RPCs — on both sides.** The server rejects a bad
request with an error reply, so failures land at the writer. The
caller's dual: a 9P write can fail, and its error is the server
talking to you — a caller that logs the error and continues has
not handled it. Hardening lands as new error replies; validation
you passed last month may reject you today, and your caller must
surface that, never swallow it.

**Sessions via the clone pattern.** When clients need per-session
state, serve a `clone` file: reading it allocates a session and
returns its id, and a directory of that name appears with the
session's files. Study `appl/cmd/gpusrv.b` — its 35-line header
comment is the best tutorial on this idiom in the tree — and
`appl/cmd/webfs.b`.

**Exemplars worth studying** before writing your own:
`gpusrv.b` (clone multiplexing), `webfs.b` (remote-backed
`/mnt` service), `auditfs.b` (a five-file surface whose header
comment explains every design choice), `man/4/mail9p` (the man
page format a service should ship with), and
`appl/veltro/tools9p.b` (the tool registry). The `styxservers`
library (`man/2/styxservers`) does the protocol bookkeeping;
`sys->file2chan` suffices when you are exposing one or two flat
files with no directory structure.

**Records are text lines.** One value per file; one record per
line; fields space-separated, most significant first; RFC 3339
timestamps; key-value data as directory hierarchy, not encoded
into a file. All of this is argued and specified in
[9p-data-conventions.md](9p-data-conventions.md).


## Mechanism, not policy

The house rule, from AGENTS.md: *prefer namespace, mount,
process-group, file-permission, and protocol-shape solutions
over bolted-on policy code.* What follows is that rule applied,
with the reasoning. These are real decisions from this
codebase, not hypotheticals.

**Restricting paths.**
Wrong: a check inside the tool —
`if(!pathwithin(args, granted)) return "ERROR: path not granted";`
Right: bind a shadow directory so ungranted paths do not exist.
Why: the policy check ran in one place, but paths are reachable
from many (the `exec` tool bypassed the check entirely, because
shell command arguments can't be reliably parsed). The bind
covers every avenue at once, because every avenue goes through
name resolution. Policy code guards a door; the namespace
removes the room.

**A signing oracle.**
Wrong: hide the wallet's raw `sign` file from agents by
namespace restriction.
Right: there is no raw `sign` file at all.
Why: signing an attacker-chosen 32-byte hash can authorize an
arbitrary transfer, so the capability is dangerous to *any*
holder. Namespace narrowing controls who can reach a file; it
cannot make a fundamentally unsafe interface safe. When an
interface can't be attenuated into safety, remove it and expose
a safe one instead (structured `pay` proposals and `authorize`
requests that the wallet validates and budget-checks).

**Effects an agent proposes but must not commit.**
Wrong: let the agent write to the effectful file, gated by an
approval flag it could learn to set.
Right: the proposal/commit split. Agent-visible files create
inert proposal objects (`/mnt/msg/draft`); the trusted
controller's files (`pending`, `approve`, `deny`) are simply
never bound into an agent namespace, and the commit copies
approved data across the authority boundary.
Why: a proposal file is not an effect capability. The model
cannot mint approval, because approval lives in a namespace the
model does not inhabit. This is the general pattern for message
sends, file edits, and payments alike.

**Protecting the audit trail.**
Wrong: an ACL system for log access.
Right: `/mnt/audit` serves `log` write-only (mode 222) and
`chain`/`head`/`verify` read-only (444); an agent's namespace
gets *only* the `log` file bound in.
Why: access control by placement. A process that can append to
its own trail but cannot name `chain` cannot rewrite history —
tamper-evidence by construction, not by an ACL that must be
right in every configuration.

**Authentication for a confined process.**
Wrong: bind `/mnt/factotum` into the sandbox so code can
authenticate.
Right: bind only factotum's `proto`/`rpc` files, so factotum
acts as a delegated authenticator; the keys and control surface
stay outside.
Why: reading factotum's `ctl` leaks key attributes. Delegate
the operation, don't expose the authority.

**Scheduling future work.**
Wrong: a scheduler service with a job registry and a cron
syntax.
Right: a sleeping subagent in its own attenuated namespace,
registered in `/prog` like every other process; cancellation is
`echo kill > /prog/$pid/ctl`.
Why: the system already has processes, sleep, and a process
interface. A scheduler would be a second registry to secure,
audit, and keep consistent — new mechanism where composition of
existing mechanism suffices.

**Observability.**
Wrong: a metrics endpoint with an exporter and a scrape format.
Right: a readable file; one line per counter. `ventisrv` started
with `-s /chan/ventisrvstats` serves its counters exactly that
way, and `cat` is the monitoring interface.
Why: `grep` and `awk` are your dashboard. Every consumer speaks
file already.

**Two components must agree on a security predicate.**
Wrong: each keeps its own copy of the check.
Right: one shared function (`NsConstruct->walletcontrolpath`),
loaded by both.
Why: two copies of a security predicate that disagree mean one
of them re-opens what the other closed.

A test for your own designs: if your mechanism would still be
needed on a system with correct namespaces, it is probably real;
if it exists to compensate for names an agent shouldn't have
had, fix the namespace.


## Compose, don't invent

**Distribution is namespace composition.** `speech9p` only ever
touches its local namespace — so audio moves between machines by
composing namespaces before the server starts (export `/dev` on
one host, mount it and bind over `/dev/audio` on the other), with
zero changes to `speech9p` itself. Location transparency is not a
feature to build; it falls out of the model. Likewise `/mnt/llm`
is the canonical name whether a local `llmsrv` self-mounts there
or a remote one is mounted with
`mount -k <keyfile> tcp!peer!5640 /mnt/llm`. Locality is not
placement — it is just how the name gets populated. Never write a
consumer that probes for where a service "really" is.

**New guarantees come from composing services.** The
tamper-evident audit log is not a logging subsystem: it is a
`keyring` hash chain plus a `factotum`-signed checkpoint,
exposed as one small file server you could delete. Its off-host
anchoring "machinery" is `cp /mnt/audit/head <elsewhere>`. When
you need a new guarantee, reach for the services that exist —
factotum for signing, secstore for secrets at rest, venti for
write-once content, the namespace for confinement — before
writing anything resembling a framework.

**Ship mechanism; leave policy to the namespace.** The audit
server appends and seals; *where* the log persists, how long,
and whether it ships off-host are decided by what you mount at
the path. Retention policy is a mount decision, not a code
feature.

**Do not build the grand unified anything.** No central logger,
no plugin registry, no service bus, no vector store for
documentation (the reader of the docs index is an LLM — it does
semantic matching natively; a vector store would be a lossy
approximation of a capability the reader already has, plus a new
daemon). Small pieces, composed by mounting.


## What the system already gives you

Before building infrastructure, check this list. These exist,
are wired into boot, and new features are expected to compose
with them.

**Audit** (`/mnt/audit`, `man/4/auditfs`). If your feature
touches authentication, identity, credentials, or takes an
irreversible action on a user's behalf, emit an audit record:
one write — `echo 'mysvc event k=v' > /mnt/audit/log` or
`audit->log(...)`. Absence of `/mnt/audit` is a silent no-op,
never a dependency. The server assigns sequence and time, so
writers cannot forge ordering. For operations that must not
proceed unaudited, honor the fail-closed marker
(`/usr/inferno/audit/on`), the way `secstored` refuses a session
it cannot seal. Do not invent severity levels, do not emit JSON,
and never write a `checkpoint` event — that word is the
server's.

**Agent provenance** (`man/2/auditprov`). Veltro seals every
agent trajectory — prompts, tool calls, capability grants — into
the audit chain, with bulky payloads stored write-once in venti
and pinned by SHA-256. If you add a tool, an agent loop, or a
spawn path, add the matching provenance emitters and do not
widen a child's audit grant beyond the write-only `log` file.
Capability grants are first-class records: the namespace is the
record.

**Durability** (`docs/PERSISTENCE.md`, `man/8/snapd`). The
contract: system updates replace the system tree and never touch
`/usr`; all of `/usr` is durable; snapshots (daily venti
archives, one text line per snapshot: timestamp + `vac:` score)
add history on top. The design consequence for you: state a user
would be upset to lose goes under `/usr`, where durability is
free; state written anywhere else in the emu root is deleted by
the next update. There is no persistence API to call — it's a
`bind`.

**Secrets and signing.** Keys live in factotum/secstore; ML-DSA
signatures are made *by* factotum so services never hold private
keys. Never write a key to a file your service reads, and never
prompt for credentials a factotum protocol could supply.

**Payments** (`wallet9p`). Budgets, approval queues, and
EIP-712 validation are the wallet's job. If your feature spends,
it writes a proposal to the wallet and the human approves out of
band; it never handles key material or signs anything.

**Capability lint** (`man/1/nsaudit`). If you change what an
agent can be granted, run `nsaudit` and update the authority
manifests under `lib/veltro/nsaudit/` — a missing manifest entry
is a deliberate fatal error, because silent fallback is how
manifests rot. Remember its scope: nsaudit is advisory; the
namespace is still what enforces.


## The host boundary

The principles above govern the world inside the namespace. A feature
also touches the host — installers, downloads, boot scripts, release
artifacts — and that boundary has its own rules, each of which exists
because a real contribution violated it:

**Anything fetched is pinned and verified.** An installer that clones
a third-party repository at default-branch HEAD and executes the build
hands code execution on every user's machine to whoever controls that
repository. Clones pin a commit SHA; model and blob downloads pin a
revision URL (not a mutable branch ref); and files are verified
against a SHA256 manifest committed in this tree before they are
installed. A version pin without a hash pin still floats — the hash is
the guarantee, the version is documentation.

**An installer never builds-and-executes unpinned HEAD.** Same rule,
stated for the case that hides it: "clone, compile, run" is execution
of unreviewed code even though no binary was downloaded.

**Boot never executes files authored outside the tree.**
Configuration is data: the tree's code parses `key value` lines, or
the running service accepts ctl writes. A host-writable script that
boot runs verbatim is a persistence hook for anything that can write
the file — however convenient it was to generate at install time.

**Placement is shipping.** The release copy loop packs `dis lib fonts
module services locale usr mnt` into every tarball, .app, and .zip. A
"dev-only" helper placed under `lib/` is in every user's install — its
placement *is* a release decision. Development-rig material lives
outside those directories; `tests/agent-harness/` and its CI
ring-fence are the precedent for keeping something out of artifacts
deliberately.


## The honest boundaries

A philosophy is trustworthy only if it states its own limits.

**Injected text is a different trust class.** The namespace
confines *code* absolutely, because code's attack surface is the
filesystem. It cannot confine what a sentence does to a language
model. Text that will enter an agent's context as instructions
must be locally authored or operator-reviewed; text arriving
over a foreign mount is data to display, never instructions to
inject. And no prompt compensates for granting a compromised
model both confidential data and unrestricted egress — the
namespace invariant is to never combine sensitive reads with
egress in one grant. See the prompt-injection invariants in
[appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md).

**Verification is bounded.** The formal results are exhaustive
within stated bounds, with an abstraction gap documented in
`formal-verification/README.md`, and three real races were found
(and mitigated) in the host threading layer. Honesty about this
is a repo convention: claims cite evidence (`path:line`, the
test, the model), and known gaps are written down with tracker
keys rather than rounded up to "secure."

**`nsaudit` passing is not "safe."** It means "free of the
authority compositions nsaudit knows to check for." Advertise
that ceiling, never more. A tool that over-claims is worse than
no tool.


## Smells — foreign paradigms to catch in review

If a design contains one of these, it needs a second look before
any code is written:

| Smell | The InferNode question |
|---|---|
| JSON crossing a 9P interface | Why isn't the hierarchy the schema? ([9p-data-conventions.md](9p-data-conventions.md)) |
| A policy check on a path the caller can name | Why is the path nameable at all? |
| A config file a service parses at startup | Why not a `ctl` file — or a mount? |
| Boot (or a service) *executes* a file written outside the tree | Configuration is data: parse `key value` lines or accept ctl writes. A host-writable script run at boot is a persistence hook, not a config. |
| A client library other programs must link | Why isn't `open`/`read`/`write` enough? |
| A daemon with a bespoke socket protocol | Why not a 9P server? |
| A central registry/manager/bus | What existing mechanism composes instead? |
| "Access denied" errors reachable by a confined process | Denial should be absence. |
| A second copy of a security predicate | Share the function. |
| A global "busy"/"in-use" flag any client can wedge | Per-fid session state, torn down at clunk; exclusivity is `DMEXCL`. (See "The fid is the session" in the ninep-server skill.) |
| UI policy (chords, bindings, gestures) inside a device driver | Drivers deliver events; policy lives in the window system. |
| An effectful file an agent can reach, guarded by a flag | Proposal/commit split; put the commit in a namespace the agent doesn't have. |
| `&&`, `\|\|`, POSIX loops in Inferno-side scripts | Inferno `sh` is rc-style; see [LIMBO-FOR-GO-PROGRAMMERS.md](LIMBO-FOR-GO-PROGRAMMERS.md#the-shell). |
| GNU make / `limbo -o` by hand | `mk` and `tools/compile-limbo.sh`; the module's `PATH` constant decides the target. |

None of these is an absolute prohibition — JSON is right at
external boundaries; a flat config is right for the host-side
build. The smell is finding one *inside* the namespace, doing a
job the namespace does better.


## Proposing a new service or tool

Open an issue before you build, containing:

1. The namespace sketch — the tree, each file's read/write
   behavior, one example shell session.
2. Placement and why (`/mnt/<app>` or `/n/<source>`).
3. What existing services it composes with (audit? factotum?
   venti? the wallet?), and what it deliberately does not do.
4. If agents will reach it: which files are grantable, which are
   control-plane and must never be, and whether any file pairs a
   sensitive read with egress.
5. The test plan — unit tests in Limbo (`module/testing.m`),
   namespace contract tests from Inferno sh, host-side
   integration if it needs the emulator boundary.

A maintainer can approve, redirect, or point at prior art in one
pass — before any of your time is spent on implementation.


## Keeping this document honest

This document only earns its keep if it actually prevents wasted
work, so it has a feedback loop:

- **Reviewers cite sections, not opinions.** A review comment that
  asks for a design change should point at the section here (or in
  a companion doc) that explains why. That keeps rejections
  impersonal and fast — and it tests the document: if there is no
  section to cite, the gap is the document's, not the
  contributor's.
- **Misses get filed.** When a contributor or agent goes wrong in
  a way this document should have prevented — or a section is
  cited and still misread — open an issue labeled `principles-gap`
  saying what was misunderstood. Those issues are this document's
  revision queue.
- **Perishable facts live elsewhere.** This document states
  principles, which age well. Current-state facts (what CI gates,
  which harness is unverified, tool inventories) belong in the
  skills under `.claude/skills/` and in the referenced docs, where
  they are expected to be maintained. If you find a dated claim
  here, that is a `principles-gap` issue too.


## Further reading

In reading order for a new contributor:

- [TUTORIAL-9P-SERVICE.md](TUTORIAL-9P-SERVICE.md) — this
  document put into practice: design, build, test, and document a
  complete service (`countfs`), every artifact shipping in-tree.
- [9p-data-conventions.md](9p-data-conventions.md) — data
  formats across 9P; the no-JSON argument in full.
- [NAMESPACE-LAYOUT.md](NAMESPACE-LAYOUT.md) — `/mnt` vs `/n`;
  why the convention is security work.
- [appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md) — the
  canonical agent security model: restriction mechanics,
  prompt-injection invariants, the spawn sequence.
- [compliance/SP800-207-zero-trust.md](compliance/SP800-207-zero-trust.md)
  — the no-ambient-authority argument, in its sharpest form.
- [PERSISTENCE.md](PERSISTENCE.md) — the durability contract
  and its Plan 9 lineage.
- [LIMBO-FOR-GO-PROGRAMMERS.md](LIMBO-FOR-GO-PROGRAMMERS.md) —
  the language, mapped from what you already know.
- `man/2/styxservers`, `man/4/mail9p`, `appl/cmd/gpusrv.b` —
  how to write and document a file server.
- `doc/limbo/limbo.ms`, `doc/styx.ms`, `doc/sh.ms` — the
  original Bell Labs papers, in-tree.

The compressed form of all of the above, from
`appl/xenith/IDEAS.md`:

> The filesystem is the API.
> The namespace is the schema.
> Everything is a file.
