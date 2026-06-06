# Namespace layout — where things live, and why

**Status:** convention (Plan 9 / Inferno provenance review). For the general
namespace mechanics (per-process namespaces, synthetic devices, binds/mounts)
see [NAMESPACE.md](NAMESPACE.md); this doc is only about **placement
convention** — which top-level directory a mount belongs under.

## The one principle

> A tree's mount point is decided by *who authored its schema*, not by where its
> bytes physically live.

Two top-level mount points are constantly confused. They are not
interchangeable:

| Path    | Meaning                                                                 | Test |
|---------|-------------------------------------------------------------------------|------|
| `/n`    | **The import yard.** Foreign file trees imported *intact* from a remote system or local device, named per their *source*. The schema is *theirs*. | "Did I import someone else's tree wholesale?" |
| `/mnt`  | **Application mount points.** Trees a local program *synthesizes* — the schema is *ours* — even when the backing data is remote. | "Did a program here invent this schema?" |

The discriminator is **provenance of the schema**, never the location of the
data. `webfs` serves remote HTTP yet lives at `/mnt/web`, because *it* invents
the `ctl`/`uri`/`body` schema. `/mnt/acme`, `/mnt/wiki`, `/mnt/factotum` are all
already here for the same reason.

## Where MCP goes: `/mnt/mcp/<server>/`

An MCP (Model Context Protocol) server speaks JSON-RPC. An adapter (the `mc9p`
filesystem-IS-schema provider, or an `mcp9p`-style per-server adapter)
**synthesizes** the 9P projection it presents — `_meta/`, `tools/<tool>/{schema,
call}`, `ctl`. The schema is *ours*. Therefore every MCP mount is an application
mount point and belongs under **`/mnt/mcp/<server>/`**, never `/n/<server>`.

The transport underneath — local subprocess, local HTTP container, remote HTTP,
or 9P-over-Styx from a peer InferNode — is a **mount-time choice that affects
latency, never placement**. A server mounted over Styx from a remote node still
lives at `/mnt/mcp/<server>` because the *schema* (the adapter's 9P projection)
is ours regardless of which box runs the backing compute.

### Why this is the security fix, not cosmetics

Because `/mnt/mcp` is **ours to subdivide**, least-privilege falls out for free:
a sub-agent can be handed *exactly* `/mnt/mcp/<server>` and nothing else. The
alternative — widening the **vetted** `/n` whitelist to admit individual MCP
servers — would loosen the import yard's allowlist for trees that were never
imports. The `/mnt` distinction dissolves that tension: **the convention is the
security work.**

`nsconstruct->restrictns` grants `/mnt` subtrees per capability, mirroring the
existing `/n` block but for trees we author:

- `caps.mcproviders != nil` (a generic `mc9p` provider) → the whole `/mnt/mcp`.
- explicit `paths=["/mnt/mcp/<server>"]` → only that subtree (recursive
  `restrictpath`, so it drills as deep as the caps specify — down to a single
  tool if asked).
- `"mnt"` enters the root `safe` allowlist **only when** something under `/mnt`
  is granted; otherwise a confined agent sees no `/mnt` at all.

Child namespaces are one-directionally attenuated (`NEWPGRP → FORKNS →
restrictns`): a child can only ever see a *subset* of its parent's namespace,
and never modifies its own. Granting `/mnt/mcp/<server>` to a child is therefore
safe by construction — it cannot reach a server the parent didn't mount.

## Where the LLM goes: `/mnt/llm`

The `llm9p` projection (`new`, `clone`, `ask`, `system`, `tools`, `model`,
`usage`, `compact`, …) is a schema **InferNode authors** — `llmsrv` invents it;
the backend (Ollama, SGLang, the Anthropic API, an on-device runtime) only
supplies completions behind it. By the one principle, that makes it an
application mount point, **`/mnt/llm`**, exactly the `webfs`/`/mnt/web` case
(remote backend, our schema). It is *not* a `/n` import, despite the long habit
of writing `/n/llm`.

**Locality is not placement — it is just how the name gets populated.** The
canonical consumer-facing name is always `/mnt/llm`; *who* serves the bytes
behind it is a mount-time choice, invisible above the mount:

| Mode       | How `/mnt/llm` is populated                                              |
|------------|-------------------------------------------------------------------------|
| **local**  | `llmsrv` runs on this host and self-mounts at `/mnt/llm`                 |
| **remote** | `mount -k <keyfile> tcp!peer!5640 /mnt/llm` — a peer's exported `llm9p` tree **bound over** the canonical name |

Because every process gets its **own** namespace, "local for some, remote for
others" needs no structure at all: each process binds whichever backend it wants
onto its *own* `/mnt/llm`, and they never collide. There is therefore no
`/mnt/llm/<backend>` split to design — the single canonical name is correct even
for a mixed fleet. (Were a *single* process ever to need two live backends at
once — not today's design — that, and only that, would justify a structured
layout.)

The payoff is that `/mnt/llm` is gated by the **same** `restrictns`/`restrictpath`
`/mnt` machinery as `/mnt/mcp/<server>` — no hardcoded "always-granted" `/n/llm`
special case survives in any topology, local or distributed. One uniform
`/mnt`-rooted capability surface; consumers reference one path and never probe
for it.

## What stays on `/n`

Genuine foreign imports — a remote peer's *whole* served root or a device tree,
mounted intact under its source's name — correctly remain under `/n`. For
example:

| Mount      | Source                                                        |
|------------|---------------------------------------------------------------|
| `/n/local` | the host filesystem (`trfs '#U*'`)                            |

A remote LLM does **not** belong here even though it crosses the wire: you are
not importing a peer's tree to live *as* `/n/<peer>`, you are populating *your*
`/mnt/llm` from it (the remote-mode row above). The discriminator is always
"who invented the schema?", never where the bytes live — so a service whose 9P
schema *you* author is a `/mnt` candidate even when served from a remote node.

## The rest of the tree (reference)

| Path           | Holds                                                            |
|----------------|-----------------------------------------------------------------|
| `/appl/<x>`    | Limbo source (`.b`, `.m`)                                        |
| `/dis/<x>`     | compiled Dis bytecode **and** the command vocabulary (sh resolves commands relative to `/dis`) |
| `/mnt/<app>`   | application mount points we synthesize (`mcp`, `acme`, `wiki`, …)|
| `/n/<source>`  | foreign trees imported intact, named per source                 |
| `/srv`         | service registry — posted channels other procs can mount        |
| `/chan`        | `file2chan` endpoints                                            |

`/appl/foo.b` ↔ `/dis/foo.dis` is a deliberate source↔object mirror; don't break
it.

## Checklist for adding a new mount

1. **Did a program here author the schema?** → `/mnt/<app>/`.
2. **Did I import a foreign tree wholesale?** → `/n/<source>/`.
3. If it's an MCP server, the answer is always (1): `/mnt/mcp/<server>/`.
4. If a sub-agent needs it, grant the **narrowest** subtree via `caps.paths`,
   not the parent dir.
