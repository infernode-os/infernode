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

## What stays on `/n`

Genuine foreign imports — a remote peer's served tree or a device tree, mounted
intact — correctly remain under `/n`. For example:

| Mount      | Source                                                        |
|------------|---------------------------------------------------------------|
| `/n/local` | the host filesystem (`trfs '#U*'`)                            |
| `/n/llm`   | a remote InferNode's `llm9p`, imported over Styx              |

(Borderline cases exist: a service whose 9P schema *you* author — even when
served from a remote node — is by this test a `/mnt` candidate, not a `/n`
import. Apply the "who invented the schema?" test rather than going by where the
bytes live.)

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
