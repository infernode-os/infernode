# Tutorial: Writing a 9P Service

This walkthrough builds a complete InferNode service the canonical
way — design first, then code, test, and man page. Every artifact
it produces ships in this tree, compiles, and passes in CI, so you
can read the finished thing next to each step:

| Artifact | Path |
|---|---|
| The service | `appl/cmd/countfs.b` (~200 lines) |
| Its bytecode | `dis/countfs.dis` (built by `mk install`) |
| Contract test | `tests/inferno/countfs.sh` |
| Man page | `man/4/countfs` |

The service is deliberately tiny: a counter. Three files, three
control verbs. Small enough to hold in your head; complete enough
to exercise every convention a real service uses. The reasoning
behind those conventions is in
[DESIGN-PRINCIPLES.md](DESIGN-PRINCIPLES.md) — this page is the practice
to that theory.


## Step 1 — Design the file interface first

Before any code, write the namespace sketch: the tree, each file's
read/write behavior, and a sample shell session.

```
/mnt/count/
    ctl        # write-only: 'add n' | 'set n' | 'reset'
    value      # read-only: current count, decimal, one line
    log        # read-only: one line per change:
               #   <rfc3339-utc> <verb> <old> <new>

; echo add 5 > /mnt/count/ctl
; cat /mnt/count/value
5
; cat /mnt/count/log
2026-08-21T14:32:00Z add 0 5
```

Notice what the sketch already decided, with no code written:

- **The API.** Any program, shell, or AI agent that can open, read,
  and write files can use this service. There is nothing else to
  learn.
- **The access policy.** `ctl` is write-only, `value` and `log` are
  read-only. That is the entire security model, and it is carried
  by file modes, not by checks in code.
- **The data format.** Text. One value per file; one record per
  line; fields space-separated; RFC 3339 timestamps. Every rule
  comes from [9p-data-conventions.md](9p-data-conventions.md).

For a real service this sketch goes in a **proposal issue** (use
the "New Service / Tool Proposal" template) before implementation.
A reviewer can approve or redirect it in minutes — that is the
cheapest design review you will ever get.

Two more sketch-time decisions:

**Placement.** `/mnt/count`, not `/n/count`: this program *authors
its schema*, and trees we synthesize live under `/mnt`
([NAMESPACE-LAYOUT.md](NAMESPACE-LAYOUT.md)). `/n` is the import
yard for foreign trees mounted intact.

**Mechanism.** `countfs` has a directory, per-file behaviors, and
error replies, so it uses the `styxservers` library with a
`nametree` (see `man/2/styxservers`). If it were one or two flat
files with no tree, `sys->file2chan` would suffice (see
`appl/cmd/ramfile.b`).


## Step 2 — The skeleton

Open `appl/cmd/countfs.b` and read along. The shape is the same as
every nametree server in the tree (`chatsrv.b` is the closest
sibling):

**Qid paths are small constants.** Each file in the tree gets one;
they become the case labels of the serve loop:

```limbo
Qdir, Qctl, Qvalue, Qlog: con iota;
```

**The tree is the sketch, verbatim.** Building it is four lines,
and the modes are the access policy from step 1:

```limbo
(tree, treeop) := nametree->start();
tree.create(big Qdir, dir(".", Sys->DMDIR|8r555, Qdir));
tree.create(big Qdir, dir("ctl", 8r222, Qctl));
tree.create(big Qdir, dir("value", 8r444, Qvalue));
tree.create(big Qdir, dir("log", 8r444, Qlog));
```

**The server reads Tmsgs from a channel and replies.** `countfs`
serves on file descriptor 0, which is what the `mount {countfs}`
idiom expects:

```limbo
(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qdir);
```

The serve loop handles only what this service cares about — reads
of its two data files, writes to `ctl` — and hands everything else
to the library:

```limbo
while((tmsg := <-tc) != nil){
    pick tm := tmsg {
    Read =>
        c := srv.getfid(tm.fid);
        ...
        case int c.path {
        Qdir   => srv.read(tm);          # navigator answers dir reads
        Qvalue => srv.reply(styxservers->readstr(tm, sys->sprint("%d\n", count)));
        Qlog   => srv.reply(styxservers->readstr(tm, lg));
        }
    Write =>
        ...                              # tokenize, act, reply
    *  =>
        srv.default(tmsg);               # Walk, Open, Stat, ... for free
    }
}
```

`styxservers->readstr` clips to the client's offset and count for
you — partial reads, re-reads, and EOF all behave correctly with
no bookkeeping.

**The ctl handler is a tokenizer and a case.** The write format is
exactly what a person types at the shell — that symmetry is the
convention, not a coincidence:

```limbo
(n, flds) := sys->tokenize(s, " \t\n");
case hd flds {
"add"   => count += int hd tl flds;
"set"   => count = int hd tl flds;
"reset" => count = 0;
*       => return "unknown control request";
}
```

Returning an error string turns into an `Rmsg.Error`, which the
writer sees as a failed write — `echo bogus > ctl` fails loudly at
the caller, where failures belong.

Note what the implementation does **not** contain: no permission
checks (the modes and the kernel do it), no config file (`ctl` is
the configuration), no JSON (the hierarchy is the schema), no
logging framework (the log is a file you `grep`).


## Step 3 — Build it

```sh
export ROOT=$PWD
export PATH=$PWD/MacOSX/arm64/bin:$PATH    # or Linux/<arch>/bin

tools/compile-limbo.sh appl/cmd/countfs.b
```

`compile-limbo.sh` reads the module's `PATH` constant
(`/dis/countfs.dis`) and emits to exactly that location. Never run
`limbo -o` by hand — compiling to the wrong target while emu loads
the old bytecode is this repo's most notorious time sink (the
`limbo-dev` skill and CLAUDE.md both tell the story). Alternatively
`cd appl/cmd; mk install` after adding `countfs.dis` to the
mkfile's `TARG` list — which is also what makes CI build it.


## Step 4 — Try it interactively

```sh
./emu/MacOSX/o.emu -c1 -r$PWD sh -l
```

```
; mkdir -p /tmp/count
; mount {countfs} /tmp/count
; echo add 5 > /tmp/count/ctl
; echo add 2 > /tmp/count/ctl
; cat /tmp/count/value
7
; cat /tmp/count/log
2026-08-21T14:32:00Z add 0 5
2026-08-21T14:32:04Z add 5 7
; echo bogus > /tmp/count/ctl
echo: write error: unknown control request
```

On a booted system with `mntgen` serving `/mnt`, you would mount at
`/mnt/count` directly. Note the last line: the bad verb failed *at
the writer*, with the server's error text.

That cuts both ways. When you are the *caller* of a 9P interface, a
write is an RPC and its error reply is the server talking to you —
a caller that logs the error to stderr and carries on has not
handled it, and if it already consumed the data it meant to write,
it has silently lost it. Servers get hardened over time; validation
your write passed last month may reject it today. Check the reply,
surface the failure, and never discard the payload on error.


## Step 5 — The contract test

The namespace sketch is a contract, and contracts get tests. The
right tier for "service X serves files Y with behavior Z" is an
Inferno-side shell test — the cheapest harness that can observe it
(see the `limbo-test` skill for the tier table).

`tests/inferno/countfs.sh` asserts everything step 1 promised: the
tree's contents, initial state, each verb's arithmetic, the log's
line count and field layout, rejection of unknown verbs, and — this
matters — that the *modes* hold: reading `ctl` fails, writing
`value` fails. The security model is in the interface, so the test
can verify it from the outside.

Two Inferno-sh rules the test demonstrates, both learned the hard
way:

- **Scripts must be committed executable** (mode 100755) —
  `sh->system()` execs the path, and a 644 script fails as "file
  does not exist". CI enforces this (`tools/verify-sh-exec.sh`).
- **A failed sh redirection raises, even inside `if {...}`.** To
  assert "writing this file fails", make the *command* attempt the
  open (`cp /dev/null $f`), not a sh redirection (`echo x > $f`) —
  the latter aborts the whole script instead of failing the
  condition.

Run it:

```sh
./emu/MacOSX/o.emu -r. /dis/sh.dis /tests/inferno/countfs.sh
```

(then Ctrl-C: emu stays alive while the mounted server runs — the
expected behavior for any backgrounded 9P service.)


## Step 6 — The man page

A service ships with a man page that specifies every file's read
and write semantics — the man page *is* the interface spec.
`man/4/countfs` follows the house pattern; `man/4/mail9p` is the
fuller model for a real service. Add the entry to `man/4/INDEX`.


## Step 7 — What a real service adds

`countfs` stops where the tutorial stops. Growing it into a
production service is more of the same conventions, not different
ones:

- **Per-session state** → the `clone` pattern: reading `clone`
  allocates a session directory. Study `appl/cmd/gpusrv.b` (its
  header comment is the best tutorial in the tree) and
  `appl/cmd/webfs.b`.
- **Blocking reads / events** → hold the `Tmsg.Read` and reply when
  data arrives; cancel it on `Flush`. `appl/cmd/chatsrv.b` shows
  the pending-request idiom in ~30 lines. The moment you hold
  per-client state — a parked read, a busy flag, a helper fd — the
  fid is the session: key the state to the fid and tear it down in
  `Clunk`, which 9P guarantees you receive even when the client
  dies. See "The fid is the session" in the `ninep-server` skill.
- **Irreversible actions** → emit an audit record: one write to
  `/mnt/audit/log`, no-op if absent (`man/4/auditfs`).
- **Agent access** → decide which files are grantable and which are
  control-plane; effectful operations get the proposal/commit split
  (`appl/veltro/SECURITY.md`).
- **Serving across the network** → nothing in the code changes:
  `styxlisten -k <keyfile> tcp!*!PORT export /mnt/count` on one
  host, `mount -k <keyfile> tcp!host!PORT /mnt/count` on another.
  Location transparency is the model working, not a feature you
  add.

When your design is sketched, open the proposal issue — and welcome
to the tree.
