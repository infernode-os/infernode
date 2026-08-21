---
name: ninep-server
description: Author a 9P file server or Veltro tool module the canonical InferNode way — choosing file2chan vs styxservers, the namespace sketch, registration, doc files, and the audit/nsaudit hooks. Use when creating or extending any service that serves files, or adding a tool agents can call.
---

# Authoring a 9P file server

Read [docs/DESIGN-PRINCIPLES.md](../../../docs/DESIGN-PRINCIPLES.md) first if you
haven't. The non-negotiables: the file tree IS the API (design it first,
propose it in an issue), placement follows schema authorship
([docs/NAMESPACE-LAYOUT.md](../../../docs/NAMESPACE-LAYOUT.md): `/mnt/<app>`
for trees we synthesize, `/n/<source>` for foreign imports), and data is
text lines, never JSON
([docs/9p-data-conventions.md](../../../docs/9p-data-conventions.md)).

## Choose the mechanism

- **`sys->file2chan`** — one or two flat files, no directory structure, no
  per-fid state. Smallest possible server. Example: `appl/cmd/ramfile.b`
  (its header comment states file2chan's limits honestly — you cannot
  observe truncate-on-open, and close notification is unreliable).
- **`styxservers` + `nametree`** — a directory tree, per-session state, a
  `ctl` file, blocking reads, or `Flush` handling. This is the default for
  a real service. Reference: `man/2/styxservers`, `man/2/styxservers-nametree`.
- **Hand-rolled `Navop` navigator** — only for generated/virtual trees where
  nametree's stored hierarchy doesn't fit. Example: `appl/veltro/tools9p.b`.

## Study these before writing (in order)

1. `appl/cmd/chatsrv.b` (~270 lines) — cleanest minimal styxservers+nametree
   server, including the hard part: the blocking-read / pending-request /
   Flush-cancel idiom.
2. `appl/cmd/mntgen.b` (~190 lines) — smallest; dynamic tree mutation.
3. `appl/cmd/gpusrv.b` — the clone/session-multiplexing idiom; its 35-line
   header comment is the best tutorial in the tree. Also `appl/cmd/webfs.b`
   (remote-backed service that still lives under `/mnt`).
4. `appl/cmd/auditfs.b` — the header-comment style every server should ship:
   every file explained, access-control-by-placement argued.
5. `appl/cmd/llmctl9p.b` — well-commented shape, but note its host-crossing
   read/write is marked KNOWN ISSUE; copy the structure, not the behavior.

## The styxservers skeleton

```limbo
Qdir, Qctl, Qstatus: con iota;

init(...)
{
    styx->init(); styxservers->init(styx); nametree->init();
    (tree, treeop) := nametree->start();
    tree.create(big Qdir, dir(".",      Sys->DMDIR|8r555, Qdir));
    tree.create(big Qdir, dir("ctl",    8r600,            Qctl));
    tree.create(big Qdir, dir("status", 8r444,            Qstatus));
    (tc, srv) := Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qdir);
    serveloop(tc, srv, tree);
}

serveloop(tc: chan of ref Tmsg, srv: ref Styxserver, tree: ref Tree)
{
    while((tmsg := <-tc) != nil) pick tm := tmsg {
    Readerror => break;
    Flush     => srv.reply(ref Rmsg.Flush(tm.tag));
    Read      =>
        c := srv.getfid(tm.fid);
        case int c.path {
        Qdir    => srv.read(tm);      # navigator answers dir reads
        Qstatus => srv.reply(styxservers->readstr(tm, status()));
        Qctl    => srv.reply(styxservers->readstr(tm, ""));
        }
    Write     => # tokenize the ctl line, validate the verb, act
    Clunk     => srv.clunk(tm);
    *         => srv.default(tmsg);
    }
    tree.quit();
}
```

File modes are part of the design: write-only control surfaces are `8r222`,
read-only data `8r444`. Reuse the error constants in `module/styxservers.m`
rather than inventing strings.

**Gotcha:** `Styxserver.new` spawns a reader process and blocks on a sync
channel; a `pctl(NEWNS)` in the wrong place can deadlock it against other
Limbo-served mounts. See
`docs/postmortems/2026-05-17-newns-vm-lock-deadlock.md` before touching
namespace calls near server startup.

## The fid is the session

Per-client state — busy flags, parked reads, a helper fd, anything that
exists because *this* client is using the service — hangs off the fid,
never off a global. 9P guarantees the server hears about client death:
the mount driver clunks a dead process's fids, and a connection hangup
clunks everything on it. So:

- Tear session state down in the **Clunk** handler; cancel the
  outstanding parked request in **Flush**. If cleanup only happens along
  one client's happy-path exit, any other client (a crash, a stray
  `cat`) wedges the service permanently.
- A resource that admits one holder at a time is expressed as
  **exclusive-open** (`DMEXCL` in the file's mode) so a second open
  fails honestly at open time — not as a first-come global busy flag
  that only the winner can clear.
- `chatsrv.b` shows the pending-request/Flush-cancel idiom; `gpusrv.b`
  shows per-session state behind `clone`.

And on the client side of any 9P interface: **a write can fail — check
the reply.** A ctl write that gets `Rmsg.Error` and is merely logged to
stderr has not happened; callers that drop data on a failed write turn
a server-side validation into silent data loss.

## Veltro tool modules (agent-callable tools)

The contract is `appl/veltro/tool.m`: five functions —
`init() name() doc() exec(args) schema()` — stateless by design.
`exec` takes a tokenized ctl line and returns plain text, or
`"error: ..."`. Schema properties are string-only, declared in the order
`exec`'s argv parser expects.

Checklist for a new tool:
1. Module in `appl/veltro/tools/<name>.b` following `appl/veltro/tools/http.b`.
   If the tool needs privileges (a mount, network), acquire them in `init()`
   *before* namespace restriction and talk to a spawned worker over a
   channel — see `appl/veltro/tools/git.b`.
2. Register in the static `TOOL_PATHS` table in `appl/veltro/tools9p.b` —
   unregistered tools do not exist, by design.
3. Doc file `lib/veltro/tools/<name>.txt` (rigid format — copy
   `lib/veltro/tools/git.txt`: one-line summary, short paragraph, `Usage:`,
   `Examples:`). It is served at `/tool/<name>/doc` and injected into agent
   prompts; the module's `doc()` is only the fallback.
4. Authority manifest entry under `lib/veltro/nsaudit/authorities/` — a
   missing entry is a deliberate fatal error. Run `nsaudit` (`man/1/nsaudit`)
   and check the CI fixtures in `tests/nsaudit-fixtures/`.
5. Provenance: agent-facing effects need `auditprov` emitters
   (`man/2/auditprov`), and irreversible actions an audit record
   (`echo 'src event k=v' > /mnt/audit/log`; absence of the mount is a no-op).
6. Security review: never pair a sensitive read with egress in one grant;
   effectful operations use the proposal/commit split (agent writes a
   proposal file; approve/deny files are never bound into agent namespaces).

## Serving over the network

`styxlisten -k <keyfile> <addr> export /path` on the server;
`mount -k <keyfile> tcp!host!port /mnt/<app>` on the client. Authenticated
by default — the `-A` (no-auth) form is for throwaway local experiments
only. The canonical name is the same whether the backend is local or
remote; consumers never probe for locality. Full stack description:
`docs/NODE-INTEROP-TESTING.md`; worked cross-host example:
`docs/SPEECH-REMOTE-AUDIO.md`.

## Ship with it

- A man page in `man/4/` modeled on `man/4/mail9p` (per-file read and write
  semantics spelled out).
- Tests at the right tier: Limbo unit tests for logic, a `tests/inferno/`
  sh test for the namespace contract, a `tests/host/` test only if the host
  boundary matters. See the `limbo-test` skill.
