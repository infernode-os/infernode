# NEWNS deadlock against trfs/mntgen — 2026-05-17

## TL;DR

Commit `89db5178 fix(ns): close formal-verification race windows` (May 14) added
an `acquire()` of the emulator VM lock immediately before the `Sys_NEWNS` /
`Sys_FORKNS` branches in `emu/port/inferno.c:Sys_pctl`. With the VM lock held,
`cclone(dot)` inside `NEWNS` blocks waiting on a 9P reply from any
Limbo-implemented file server on the namespace path (trfs serving `/n/local`,
mntgen serving `/n`, any other Styx server) — but those servers cannot run to
produce the reply because the caller holds the VM lock. Every `pctl(NEWFD|NEWNS,
fd::nil)` issued **after** the namespace contained any Limbo-served entry
deadlocked. That is the standard pattern every `Styxserver.new` uses, so the
symptom was: boot reaches the login screen, the user enters a password,
secstore unlock succeeds, then luciuisrv / wallet9p / tools9p all hang forever
as soon as they spawn their `tmsgreader`. Lucifer never starts; the UI freezes.

The data race the commit was actually trying to close — unlocked reads of
`pg->dot` / `pg->slash` in `namec` and an unlocked update in `kchdir` — is
covered by the rwlock on `pg->ns` that the same commit added to `chan.c` and
`sysfile.c`. The `acquire()` was a supplementary belt-and-braces step that
duplicated nothing the rwlock + `incref` pattern in `NEWNS` doesn't already
provide. Removing the `acquire()` eliminates the deadlock without re-opening
the race window.

## Symptom

On a fresh laptop dev build (`fix/infr-57-next` with `origin/master` merged,
SDL3 emu, arm64 macOS):

1. emu starts, profile runs, lucifer login screen appears.
2. User types secstore password and hits Enter.
3. Logon completes (`logon: secstore save-back enabled`).
4. Shell continues into boot.sh; backgrounded wallet9p / luciuisrv get spawned.
5. The next call to `Styxserver.new` blocks forever inside `<-sync`, waiting on
   the spawned `tmsgreader` to send. `tmsgreader` is stuck in
   `sys->pctl(Sys->NEWFD|Sys->NEWNS, fd.fd :: nil)`.
6. UI is frozen. Nothing further prints.

Output stops at exactly the line that precedes the first post-profile
`Styxserver.new`. The first `Styxserver` started during profile
(`auth/secstored`, started before trfs mounts `/n/local`) is the only one that
gets through `NEWNS` — its CWD is still on the trivial root namespace, so
`cclone(dot)` doesn't need a Limbo server to answer.

## Root cause walk-through

`emu/port/inferno.c:Sys_pctl` follows a "release on entry, re-acquire on exit"
pattern for blocking pctl flags:

```c
BlockingPctl = Sys_NEWFD | Sys_FORKFD | Sys_NEWNS | Sys_FORKNS
             | Sys_NEWENV | Sys_FORKENV;

if(f->flags & BlockingPctl){
    release();
    vmreleased = 1;
}
```

`release()` drops the VM lock so other Limbo threads can run while this pctl
does potentially blocking work. Before the May 14 commit, the lock stayed
released across every branch in the function and was re-acquired in a single
place at the end:

```c
if(f->flags & BlockingPctl)
    acquire();
```

The commit changed that to an early re-acquire before `NEWNS|FORKNS`:

```c
if((f->flags & (Sys_NEWNS|Sys_FORKNS)) && vmreleased){
    acquire();
    vmreleased = 0;
}

if(f->flags & Sys_NEWNS) {
    ...
    np.np->dot = cclone(dot);    /* now runs WITH the VM lock held */
    np.np->slash = cclone(dot);
    ...
}
```

`cclone` on a channel rooted in a Limbo file server (trfs, mntgen, llmsrv,
…) sends a 9P walk. The target server needs the VM lock to run its Limbo
handler. Caller holds the VM lock waiting for the reply. Deadlock.

The first `tmsgreader` after boot succeeded because, when it ran, the CWD was
still on the trivial root namespace populated by the C-side device drivers
(`#/`, etc.), and `cclone` on those channels does not bounce out to Limbo. By
the time profile's `trfs '#U*' /n/local` and `mount -ac {mntgen} /n` are
established and any subsequent code calls `pctl(NEWNS)`, the CWD has been
`cd`-ed under `/n/local`, so `cclone(dot)` walks into trfs and stalls.

## What was kept, what was reverted

The commit had three hunks:

| File | Change | Verdict |
|---|---|---|
| `emu/port/chan.c` | Add `rlock(&pg->ns)` around reads of `pg->dot`/`pg->slash` in `namec`; `wlock` around mount-tree updates | **Kept** — this is the actual race fix. |
| `emu/port/sysfile.c` | Add `wlock(&pg->ns)` around the `pg->dot` swap in `kchdir` | **Kept** — pairs with the rlock above. |
| `emu/port/inferno.c` | (a) Track `vmreleased`; (b) early `acquire()` before `NEWNS`/`FORKNS`; (c) restructured `NEWNS` to take `rlock(&pg->ns)` + `incref(&dot->r)` before `cclone` | (a) kept, (c) kept, **(b) removed** — the deadlock source. |

The restructured `NEWNS` already protects against the race that motivated the
acquire: it takes the `pg->ns` rlock, captures `dot`, `incref`s the channel,
releases the rlock, and only then calls `cclone`. The channel cannot be freed
during `cclone` because we hold a ref. There is no remaining window that the
VM lock would close.

Patch in `emu/port/inferno.c`:

```diff
-    if((f->flags & (Sys_NEWNS|Sys_FORKNS)) && vmreleased){
-        acquire();
-        vmreleased = 0;
-    }
-
+    /*
+     * Intentionally do NOT acquire() here for NEWNS/FORKNS.
+     * cclone(dot) in NEWNS (and pgrpcpy in FORKNS) can issue 9P
+     * requests to Limbo-implemented file servers (trfs serves
+     * /n/local, mntgen serves /n, etc.). Those servers need the VM
+     * lock to run. Holding it across cclone deadlocks the emulator.
+     */
     if(f->flags & Sys_NEWNS) {
```

## Why this wasn't caught earlier

- The headless build path doesn't hit lucifer/luciuisrv/wallet9p, so headless
  CI green-lit the change.
- The SDL3 GUI build was tested up to the login screen only — the user types a
  password, the boot proceeds, *then* the deadlock hits the first post-trfs
  Styx server. Anyone who tested before the May 14 commit landed didn't notice
  because their CWD when `Styxserver.new` ran happened to be on the C-side
  root; anyone who tested after, didn't get past the password.
- No automated test exercises `pctl(NEWFD|NEWNS, fd::nil)` from a namespace
  that contains a Limbo-served mount. A boot-smoke test would have caught it.

## Regression test

`tests/inferno/newns_after_trfs_test.sh` mounts trfs, then spawns a 9P server
(`tools9p`) and asserts that its mountpoint becomes visible within a generous
timeout. If `pctl(NEWFD|NEWNS, ...)` deadlocks, the mountpoint never appears
and the test fails.

## Related

- Original commit: `89db5178 fix(ns): close formal-verification race windows`
- Filed during this session for unrelated follow-ups surfaced after the fix
  let lucifer boot:
  - INFR-100 — settings opens to wrong tab from setup-chat link
  - INFR-101 — SDL3 input pipeline double-keypress regression across all
    widgets
  - INFR-102 — `/n/llm` empty after keyring-authenticated mount to hephaestus
