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

If you take two procedural rules from this page, take these.
**First, assume the system can already do it.** Most new
capabilities are a composition of name spaces, commands and
modules that already exist, and the right deliverable is a
few `mount`s, `bind`s and a pipeline, not a program ("Compose
before you write", below). **Second, when something new really
must be built, design the file interface first, and show it to
us before you build.** In this system the file interface *is*
the design. A twenty-line namespace sketch can be reviewed in
minutes; three weeks of code cannot.


## The worldview

Four statements, each meant literally:

**Everything is a file.** Not "many things have file-like
wrappers" — everything. Networks (`/net/tcp/0/data`), processes
(`/prog/123/ctl`), the screen (`/dev/draw`), the LLM
(`/mnt/llm`), payments (`/mnt/wallet`), the audit trail
(`/mnt/audit/log`). Unix had this as a nice idea applied
inconsistently; Plan 9 took it seriously, and InferNode inherits
that seriousness. When you add a capability to the system, you
add it as files.

**The filesystem is the API.** A new service is a 9P file
server, not a library, not an RPC endpoint, not a daemon with a
bespoke socket protocol. Any program in any language — and any
AI agent — can use it with `open`, `read`, `write`. No SDKs.
No protocol buffers. Just files. And the universality runs both
ways: a service written in *any* language integrates by serving
9P — Limbo is the language of the canonical in-tree core, not an
entry requirement for connectors and ancillary services, which
live outside the tree and meet the system at the mount point.
(This is conceptually what MCP does for AI tools, except the
protocol is forty years simpler and every existing tool already
speaks it.)

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

### This is checked, not merely asserted

The namespace isolation property — that a mount performed in one
process group never appears in another's mount table except by
its own action — is stated as a TLA+ invariant and model-checked
exhaustively at small scale (the medium run is incomplete), with
SPIN models of the locking and of three fixed races and CBMC
harnesses over `pgrpcpy` (`formal-verification/`). Those are checks
of a specification and of one function's deep copy; the TLA+ model
cannot express shared mount structure, so it does not by itself
rule out the C bug. The claim
"a small TCB you can actually verify" is the project's thesis;
design that respects the chokepoint keeps the thesis true.
Design that adds a second enforcement path dilutes it.


## Compose before you write

The commonest mistake, for agents above all, is not a bad file
interface. It is writing software at all. Asked for something
new, the instinct is to start a program; the question that
should come first is whether the system already does it once
its pieces are arranged. In InferNode it usually does, because
it composes at every level: name spaces (`mount`, `bind`,
`export`, `import`, `cpu`), commands and pipelines (the shell,
its loadable modules, the host's own programs through `os`),
and Limbo modules (`module/*.m`, a library for nearly everything
in the tree). New code is the last resort, and when it is
needed it should be the smallest piece that lets a composition
work, not a replacement for it.

**The requirements come first.** The ladder below does not
replace them; it is how to read them. What has to be true (which
traffic, which machines, what peer, what guarantees) decides
what is built, and the ladder finds the least new software that
makes it true. The examples under each rung show how a
requirement can be met by composing; none of them is the answer
to every request that shares its name.

**When no requirement is given**, or it is not known, start with
the composition: it is cheap to build, easy to undo, and likely
to meet the objective sooner than anything written. Say which
requirement you assumed, so it can be corrected, and explain
what you did in the terms of this document: what was composed,
why that meets the objective without new software, and what it
does not cover, naming the section that explains it. A user who
does not yet know how InferNode works learns it from that, in a
few lines, not a lecture. Anything that costs the user (new
software, a dependency, the kernel) is still put to them first.

Most of the time an agent misses a composition, it is not
because it weighed one and rejected it, but because it did not
know the pieces were there. So the first step is to look:
`man/1` (commands), `man/4` (file servers), `man/2` and
`module/` (modules), and "What the system already gives you",
below. Then state the job as a name space (what must be
reachable, from where, under what name) before thinking about
code.

Work down this ladder, and stop at the first rung that does the
job.

**1. Compose name spaces.** Ask whether `mount` and `bind` of
things that already exist build the name space the job needs.

- *An example: a VPN.* Say the requirement is that this
  machine's connections leave through an office machine that
  runs InferNode. That needs no tunnel written: the office
  machine runs
  `listen -k key 'tcp!*!5650' {export /net}`; here:

  ```
  mount -k key 'tcp!office!5650' /n/office
  bind '#I' /n/localnet
  bind /n/office /net
  ```

  Every connection dialled afterwards in that name space is the
  office's, its names resolved by the office's `cs`, the link
  authenticated and encrypted by the mount; this machine's own
  stack carries only the mount. For one shell, do it in that
  shell. For the whole system, do it early in boot, before
  anything forks a name space of its own, and everything started
  after inherits it. The details: the mount to the office is
  dialled through the local `/net` before the bind replaces it;
  only programs started after the bind see it, so it belongs in
  boot, not in a profile some programs never read; and the local
  stack is kept at `/n/localnet` because, if the office goes
  away, `/net` is hung up with it. When the office is back,
  `mount -k key '/n/localnet/tcp!192.0.2.10!5650' /net` mounts it
  over `/net` again through the local stack, by address (the
  local stack has no connection server of its own). All of it
  is tested on two emulators (`tests/host/net_import_test.sh`): a
  connection dialled after the bind appears in the office's
  `/net/tcp`, not this machine's. A VPN with other requirements
  (a commercial endpoint, the host's own programs, a particular
  protocol) may need more; the ladder is how to find how much.
- *"Play sound on the other machine."* Mount its `/dev` and bind
  its `audio` over yours ("Compose, don't invent", below:
  `speech9p` was never changed to do this).
- *"Run this on the Jetson's GPU."* `cpu` or `rcmd` to it, or
  mount its service; the name stays the same either way.
- *"Keep a copy of this state."* Put it under `/usr`, which is
  durable and snapshotted, and is a bind, not an API
  ("What the system already gives you", below).

**2. Compose tools.** Ask whether existing commands, piped and
bound, do the transforming. The shell is a real language with
loadable modules (`sh-std(1)`, `sh-regex(1)`, `sh-expr(1)`), and
`sh-file2chan(1)` lets a script serve a file, so a small service
can be twenty lines of `sh`. The host's programs are one `os`
away: `os ffmpeg ...` is cheaper than a port and better than a
rewrite. For a simple job this rung is the end: the answer is
the commands, kept as a script only if someone will run them
again, and no new software is written.

**3. Compose modules.** When code is needed, most of it should
already exist. Before writing a parser, a protocol, a codec or a
server loop, look in `module/` and `appl/lib/`: `bufio`,
`styxservers` and `nametree`, `imgload`, `layers`, `nmea`,
`jpeg`, the crypto in `keyring`, and many more. A new program
that is mostly calls to these is a small program.

**4. Build the composition, then measure it.** For a large job
the composition is the first version, not a sketch to be thrown
away. Build it from what exists, run it against the real
requirement (the throughput, the latency, the number of clients,
the machine it must run on) and find where it falls short. Then,
for each weak point, in this order:

- *Can a better composition fix it?* Usually it can. A 9P stream
  across a network was slow because each read waited for its
  reply; the fix was keeping several reads in flight
  (`parread(2)`), not a socket. Raw frames between machines were
  too large; the fix was an encoder that serves `jpeg/` beside
  the feed's frames and a decoder that mounts it (`videnc(1)`),
  with the feed, the display and the transport still
  compositions.
- *Only then, the missing mechanism.* If no arrangement of
  existing pieces can meet the requirement, write the one piece
  that cannot be composed, and serve it as files so everything
  around it stays composed. vision(4) is new software because
  nothing ran a detector; the camera feed, the picture, the
  overlay, moving work between GPU and DLA, and running it on
  another machine are all mount, bind and a line written to a
  `ctl` file.

New software is justified when, and only when, a composition was
built (or shown concretely to be impossible) and failed a stated
requirement that a better composition could not meet. "It would
be cleaner as one program" is not a reason, and neither is "I
did not know the system did that": the second is a reason to
look.

**When composition is the wrong answer.** There are real cases,
and they are few. A composition inside InferNode does not reach
the host's own processes: in hosted InferNode, the macOS or Linux
programs beside the emulator do not use its `/net`, and a
requirement that they do is not met by a bind. And a far end that
does not speak 9P (a commercial VPN endpoint, a vendor's API) has
to be spoken to in its own protocol, which is new code; even
then, the result is served as files (a `/net`, a `/mnt/<app>`)
so that everything above it is still a bind. Invoking this
carries the same burden as everything else: name the requirement
the composition cannot meet ("the peer speaks WireGuard and will
not run InferNode", "the host's own browser must use the
tunnel"). Most claimed exceptions turn out to be compositions
made in the wrong place, a bind too late or in the wrong name
space; the VPN example above shows one.

**Hard trade-offs go to the user.** The ladder settles most
choices; where it does not, the agent does not decide. When the
rules conflict or the cost falls on the user (whether a measured
shortfall justifies new software, whether an exception holds,
isolation against portability in "Where the code runs", any new
dependency), stop and put it to the person you are working for:
the options, what each costs, and a recommendation. A
contributor puts it in the proposal issue. What the rules do
settle (`/mnt/<app>` or `/n/<source>`, text not JSON) is not a
question; asking it is noise.

What to show for it. A job finished at rungs 1 to 3 needs no
proposal: show the commands, with the requirement they meet and
what they do not cover. A proposal for new software
("Proposing a new service or tool", below) starts with the
composition that was tried, what it was measured against, and
where it fell short, and its namespace sketch shows how the new
piece sits inside the composition rather than replacing it.


## Where the code runs

When something new must be written, the second decision is where
it runs. From safest to least safe:

1. **Limbo, in InferNode.** The default. The system's own logic,
   anything that bears on security (authentication, an agent's
   capabilities, audit), anything that must run on the native
   kernel and on phones, and any open protocol small enough to
   implement (mail9p speaks IMAP and SMTP in Limbo). Measure
   before deciding Limbo is too slow: run it compiled (`emu
   -c1`), not interpreted.
2. **A host service over 9P, on this machine or another.** For
   what InferNode should not carry: host hardware (a GPU, an
   NPU), large foreign libraries, vendor SDKs and their sign-in
   flows, heavy compute. llmsrv's backends are the model, and
   `tools/trtsrv` the local form (`mount -A {os trtsrv >[1=0]}`).
   It runs in a process of its own, so its crashes are its own,
   and it may be written in any language. The InferNode side is
   an adapter: often only a `mount`, the file contract and a man
   page.
3. **A builtin module in C** (`$Tensor`, `$Bayer`, `$Math`). For
   a hot inner loop, measured under the JIT, that must run where
   there is no host to call. It is C in `libinterp`, linked into
   the emulator and the native kernel and running with their
   authority: a bug in it is not an exception in one program but
   the emulator ending or the board panicking. Every argument is
   hostile, and its edges are tested.
4. **A device in the kernel or the emulator.** The last resort:
   only to reach hardware, or a platform interface only the
   emulator's own process can call (`#o` is in the emulator
   because iOS and Android give location only to the app). Its
   file interface is the smallest that does the job. Drivers are
   written in Limbo first where they can be; the native kernel's
   USB class and touch drivers are.

Building a service into hosted InferNode is rung 4, since an
emulator device is kernel code; binding in a local host service
is rung 2. Prefer binding it in.

**The consumer never knows where it runs.** A program reads
`/mnt/x`; whether that is a local host process, another machine
or Limbo is decided by what is mounted there, as `/mnt/llm` is.
So a host service is designed as a 9P file interface from the
start, not as `os` calls scattered through Limbo code. A one-off
`os cmd` in a pipeline is fine; a capability other programs use
is served as files. Where there is a host to call differs: the
native kernel has none of its own and binds services from
another machine; a phone cannot start host processes, so its
services are remote; a hosted desktop can do either.

**A host service is untrusted.** It runs with the host's
authority, outside InferNode's name-space confinement, and its
own dependencies are not ours to vouch for: if one of them is
compromised, the service can answer anything. So its 9P surface
is the only boundary that matters. The mount is authenticated
(keyring, not `-A`); agents are granted its files narrowly,
never the service; secrets reach it through factotum, not the
host's environment; and every consumer treats its answers as
input from a stranger, as the hostile-server tests of export(2),
styxservers(2) and the mount driver do. JSON and vendor APIs
stay behind it; text files face InferNode.

Rungs 2 and 3 trade isolation for portability. A host service is
safer, but there is none on the native kernel or a phone; a
builtin module runs everywhere, inside the kernel. Which matters
more is a trade-off for the user, not the agent.


## Dependencies are a decision

InferNode is meant to be secure by default, and that includes
its supply chain. Every third-party library it carries is code
it runs with someone else's release process behind it. There is
no automatic rule for when one is acceptable: each is a decision
for the maintainer. An agent stops and asks before adding one;
an outside contributor opens an issue before the pull request.
The case made covers:

- **The alternatives, exhausted first**, in order: a
  composition, an existing module, a host service kept out of
  the tree, a rewrite. Most dependencies are filtered out here.
- **Whether it ships**: in a release artifact, or in the default
  build. A library linked into the emulator or the kernel (SDL3,
  libfido2) is carried by every build and runs with their
  authority; that is the highest bar.
- **How it is pinned**: an exact version and a lock file or
  hash, audited by the security workflow ("The host boundary",
  below: a version without a hash still floats).
- **Why it is worth the risk**: who maintains it and how
  actively, how widely it is used, its history, what it can
  reach, and how it would be removed if it went bad.

**A rewrite is often the safer dependency.** Writing code is
cheap now. A few hundred lines of our own, tested, are usually
less risk than a small, lightly used or poorly kept library that
can rot or be taken over. A rewrite of a parser or a cipher is
checked against the original's answers, generated once and
committed as files, as the tree's known-answer tests are
against OpenSSL, 9front and Python. Code is ported from BSD,
9front or Plan 9 sources, never from GPL code.

**What stays outside is tolerated more.** A host service in a
repository of its own does not ship with InferNode, and its
dependencies are its own; the InferNode side is the mount. The
tools that tests use to make their answers (OpenSSL, Python's
libraries) run in CI only and never ship. Neither is a free
pass: a host service is still untrusted ("Where the code runs",
above), and a host service kept in this tree with dependencies
of its own is the same decision as any other.


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
[NAMESPACE-LAYOUT.md](NAMESPACE-LAYOUT.md). The trees that
predated the convention (`/n/git`, `/n/wikia`, `/n/speech`,
`/n/wallet`) have moved to `/mnt` (INFR-400 through INFR-403); do
not copy their old names for new work.

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
session's files, gone when they are all closed. Study
`appl/cmd/visionfs.b` — its header comment and `man/4/visionfs` say
what each file does, and its sessions show both waiting reads and a
reader's own place in a stream — and `appl/cmd/webfs.b`.

**Exemplars worth studying** before writing your own:
`visionfs.b` (clone multiplexing), `webfs.b` (remote-backed
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

**Compose in space, in time, and in both.** The aim is radical
composability, and there is more than one kind; each fits a
different shape of problem, and they compose with each other.

*In time* is the pipeline: a stream flowing one way through
stages, each with one reader.
`{while {} {ns; echo; sleep 1}} | ns2mmd | wm/page -s` draws the
machines a name space reaches and redraws it as mounts come and
go: text in, text out, one consumer, nothing to steer. A pipeline
has no names and no state, and it gives backpressure for nothing.
When the problem has that shape, it is the simplest correct
structure, and a file server would be ceremony.

*In space* is the name space: what can be reached, from where, by
whom, built by `mount` and `bind`. A camera's feed on one machine,
recognition on another and a window on a third were joined by a
mount on each and one bind: the feed read by two machines at once
and joinable mid-stream, the detections laid over the picture by
binding a session's `layer/` into the feed's (and taken off by
unmounting it), the session moved from GPU to DLA by a line
written to its `ctl` while the stream ran. A pipe gives none of
that: it has one reader, no back channel, no late joiner, and it
ends at the machine. And because the arrangement lives in the name
space, `ns` can report it; a pipeline's shape is known only to the
shell that built it.

*In both* is the usual case, and it is composition composed: the
name space wires the stages together and decides who sees what;
pipelines do the transforming inside a stage; a stage's results
are served as files so the next can be bound. vision(1)'s
`vision/detect`, `vision/draw` and `vision/crop` are filters
piped through; visionfs reads a mounted feed and serves layers for
anyone to bind; ns2mmd is a pipeline over a file, `ns`, that
describes the name space. The rule of thumb: one consumer, one
direction, nothing to steer, pipe it; several consumers, control,
a late joiner, another machine, or anyone else needing to see it,
serve it as files and bind it.

The cost to know: a pipe streams, while a 9P read is a request
and its reply. Over a network a stream read as a file pays a round
trip a message unless its reader keeps several reads in flight. A
file interface that carries a stream should be designed so it can
be read that way (whole frames, offsets that mean something), not
abandoned for a socket.

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


## The mouse: each button has one job

Every graphical program follows Plan 9's division of the buttons, so a
hand that knows one program knows them all. This is the canon we align
with first; improving on it is a later, deliberate change made
everywhere at once, never one program at a time.

| Button | Job | Examples |
|---|---|---|
| 1 | point: select, drag, pan | text selection; page's drag; wm/wm's frame reshape |
| 2 | act on the content: the program's operations or edit menu | wm/sh's cut, paste, snarf, send; page's zoom, fit, turn, write; acme/Xenith's execute; sam's edit menu |
| 3 | choose or manage: windows, files, a list to pick from, look | wm/wm's New, Resize, Move, Delete, Hide; sam's window and file menu; page's pages; acme/Xenith's look; wm/sh's plumb |

Chords build on this (in text, button 1 held then 2 cuts, then 3
pastes), so a program that moves its edit menu to button 3 breaks them
as well as the habit. A program with a single menu and nothing else to
do with the buttons (clock, lens) may raise it on any button.

Menus are not modal: press, move to an item, release to choose it; a
release on no item closes the menu having done nothing.

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
man doc icons module services locale usr mnt n appl` into every tarball, .app, and .zip. A
"dev-only" helper placed under `lib/` is in every user's install — its
placement *is* a release decision. Development-rig material lives in the
external `infernode-os/infernode-escape-room` repository; CI and release
ring-fences keep it out of product artifacts deliberately.


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
| A new program with no composition tried first | Which mounts, binds, commands and modules were tried, measured against what? ("Compose before you write") |
| A tunnel, proxy, relay or sync daemon | Would mounting the far end's `/net` or tree, and a bind, do it? |
| A new kernel or emulator device, or a builtin module in C | Why not Limbo, or a host service bound in? ("Where the code runs") |
| A new third-party library, crate or package | Was it put to the maintainer, with the alternatives tried? ("Dependencies are a decision") |
| "Access denied" errors reachable by a confined process | Denial should be absence. |
| A second copy of a security predicate | Share the function. |
| A global "busy"/"in-use" flag any client can wedge | Per-fid session state, torn down at clunk; exclusivity is `DMEXCL`. (See "The fid is the session" in the ninep-server skill.) |
| An operations menu on button 3, or a window/list menu on button 2 | Button 2 acts on the content, button 3 chooses or manages: see "The mouse". |
| UI policy (chords, bindings, gestures) inside a device driver | Drivers deliver events; policy lives in the window system. |
| An effectful file an agent can reach, guarded by a flag | Proposal/commit split; put the commit in a namespace the agent doesn't have. |
| `&&`, `\|\|`, POSIX loops in Inferno-side scripts | Inferno `sh` is rc-style; see [INFERNO-SHELL.md](INFERNO-SHELL.md). |
| GNU make / `limbo -o` by hand | `mk` and `tools/compile-limbo.sh`; the module's `PATH` constant decides the target. |

None of these is an absolute prohibition — JSON is right at
external boundaries; a flat config is right for the host-side
build. The smell is finding one *inside* the namespace, doing a
job the namespace does better.


## Proposing a new service or tool

First work through "Compose before you write". If the job is
done by mounts, binds, commands and existing modules, there is
nothing to propose: do it, or show the commands. Otherwise, open
an issue before you build, containing:

1. The composition tried: the name spaces, commands and modules
   that do the job without new software, what they were measured
   against, and where they fell short; or why no composition can
   do it at all.
2. The namespace sketch: the tree, each file's read/write
   behavior, one example shell session, and where the new piece
   sits in the composition it completes.
3. Placement and why (`/mnt/<app>` or `/n/<source>`).
4. What existing services it composes with (audit? factotum?
   venti? the wallet?), and what it deliberately does not do.
5. If agents will reach it: which files are grantable, which are
   control-plane and must never be, and whether any file pairs a
   sensitive read with egress.
6. The test plan — unit tests in Limbo (`module/testing.m`),
   namespace contract tests from Inferno sh, host-side
   integration if it needs the emulator boundary.
7. Where it runs ("Where the code runs") and any dependency it
   adds ("Dependencies are a decision"), with the case for each.
8. The trade-offs for the maintainer to decide: each tension the
   rules do not settle, its options and what each costs.

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
- `man/2/styxservers`, `man/4/mail9p`, `appl/cmd/visionfs.b` —
  how to write and document a file server.
- `doc/limbo/limbo.ms`, `doc/styx.ms`, `doc/sh.ms` — the
  original Bell Labs papers, in-tree.

The compressed form of all of the above, from
`appl/xenith/IDEAS.md`:

> The filesystem is the API.
> The namespace is the schema.
> Everything is a file.
