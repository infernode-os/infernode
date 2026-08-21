# Persistence — what survives, and why it is shaped this way

**The contract: system updates replace the system tree and never touch
`/usr`. All of `/usr` is durable. Snapshots add history on top;
durability never depends on them.**

## 1. The design, in one screen

There is no disk image. Hosted InferNode's root (`emu -r`) is a host
directory — an app bundle, an install dir, or a dev checkout — and it
is treated as **replaceable system content**: `dis/`, `/lib`,
`/module`, fonts. Two mechanisms keep everything the user cares about
out of it:

1. **The host home is the user's file space.** Desktop boots mount the
   host filesystem (`trfs`) and set the Inferno home to the host home
   directory. Documents never live inside the app.
2. **`/usr` is bound whole from `~/.infernode/usr`** (`lib/sh/profile`).
   Every user home — `/usr/inferno` and anything `newuser(8)` creates —
   plus service state that lives under `/usr` (secstore, the audit
   chain and its venti store, snapshot markers and logs) resolves to
   the durable side. Delete the app, install a newer one: the same
   `~/.infernode` binds over it and nothing is lost. First boot seeds
   `/usr/inferno` from the shipped skeleton, once; afterwards the
   durable copy is authoritative (skeleton changes in later releases
   do not propagate into existing homes — the historical norm).

Config overlays outside `/usr` (`/lib/ndb`, theme, veltro state,
`/lib/keyring`) are individual binds, unchanged; see
`docs/DEVELOPER-GUIDE.md` and `docs/SETTINGS-CONVENTIONS.md`.

On top of durability sits **history**: with snapshots enabled
(`Settings → Snapshots`, or `touch /usr/inferno/snapshots/on`),
`snapd(8)` archives the whole of `/usr` plus the non-secret config overlays
outside it (theme and `/lib/veltro`, durable side first) daily into a local
write-once venti store as one vac archive. Credential-bearing `/lib/keyring`
and endpoint configuration under `/lib/ndb` are excluded by default; selecting
them explicitly with `snapd -p` places them in the score-addressed,
unauthenticated store. Each snapshot is one line — a date and a
45-byte score — in `/usr/inferno/snapshots/log`; any past state mounts
read-only with `vacfs(4)` or extracts with `vacget(1)`. Identical
content dedupes, so a snapshot costs only what changed.

## 2. Why this shape — the historical record

This design re-creates, for hosted installs, exactly the contract the
originals had. From the primary sources:

- **Plan 9 updates never touched `/usr`.** `replica/pull` applied a
  published change log; `applylog` *"will not overwrite local changes"*
  (replica(8)), and `/usr` was structurally outside the distribution
  protos. 9front's `sysupdate` (a `git/pull` of the system tree) keeps
  the same shape.
- **Inferno's own update procedure was conflict-aware.** `install/inst`
  MD5-checked every file against the previous release and skipped
  anything *"locally modified"* or *"locally created"*; `/usr/<user>`
  was preserved because the packages simply did not contain it
  (`lib/proto/inferno` ships only the `usr/inferno` skeleton). Major
  upgrades demanded a fresh tree — which is precisely what an app
  update is. Hence: the durable side must carry `/usr` wholesale.
- **User creation was `cp -r /usr/inferno /usr/<name>`** (doc/install.ms
  "Adding new users"); upstream `logon` never created homes ("There is
  no home directory … *mounted* on this machine"), and `kfscmd(8)`'s
  `newuser` was documented inside a roff ignore-block, never
  implemented. `newuser(8)` finishes that arc.
- **`/usr` was never a partition on native Inferno.** Every shipped
  kernel init mounts one filesystem at `/` (kfs, logfs, dosfs — or a
  Styx server's entire root, in the network-computer configuration
  where `FILESERVER` is *"needed only by clients with no storage of
  their own"*). Separation was update-tool discipline, not disk layout.
  A future baremetal InferNode may keep that (one FS + conflict-aware
  updates) or give `/usr` its own partition; the hosted overlay maps to
  either without change.
- **Venti was the archive, never the live store — and the archive was
  always on.** Plan 9's fossil (live) archived daily into venti
  (permanent); `/n/dump` made every day walkable, and
  `fossil flfmt -v <score>` could rebuild a file system from a single
  archived score. Restore-from-snapshot was disaster recovery, not the
  persistence mechanism — which is why durability here comes from
  placement and snapshots are the time machine.

## 3. Operational summary

| State | Lives at (host) | Survives app update | Survives `rm -rf ~/.infernode` |
|-------|-----------------|--------------------:|-------------------------------:|
| User documents | host home (via `/n/local`) | yes | yes |
| `/usr` (homes, secstore, audit chain + store, snapshot log) | `~/.infernode/usr` | yes | no — that *is* the reset switch |
| Config overlays (`/lib/ndb`, theme, veltro, keyring) | `~/.infernode/lib`, `~/.infernode/tmp` | yes | no |
| Snapshot venti store | `~/.infernode/venti` | yes | no |
| System tree | the app / checkout | replaced | yes |

The snapshot store lives **outside** `/usr` deliberately: a snapshot
of `/usr` must not contain its own store. Off-host copies of
`~/.infernode/venti/data` (append-only) plus the snapshot log give the
full disaster-recovery story — any logged score reconstructs that
day's `/usr` from the copy.

Ports: the snapshot venti listens on the canonical venti port
(`tcp!127.0.0.1!17034`, per `lib/ndb/common`); the audit content store
uses `tcp!127.0.0.1!17040` (override: `auditventi` env). Both are
localhost-only; the venti protocol is unauthenticated. The profile repairs
the backing Venti directories to mode 0700 and their data/index files to
0600 on every boot, including upgrades from older installations.

Capacity: `snapd` warns (status file, audit log when auditing is on)
past 80% of the store's configured maximum. Venti is write-once —
reclaiming space means starting a fresh store, by design.

## 4. What we deliberately do not do

- No restore-from-snapshot as the durability story (see §2).
- No automatic migration of `/usr` across skeleton changes — seeding is
  first-boot-only, the historical norm.
- No InferNode-side primary home yet. A contemplated future shape —
  closer to the original logon model — is that each person gets a real
  `/usr/<name>` (via `newuser(8)`) as their PRIMARY home, with the host
  home union-bound *into* it rather than standing in for it, and
  InferNode-created files living there. Deferred: the current
  host-home-as-home setup is robust, and the hard requirement — an app
  update must never lose user data — is already met by the overlay.
- No remote-`/usr` default. The network-computer configuration (mount a
  server's `/usr`, roam with signer certificates) remains possible —
  the overlay is just a bind, and a user `namespace` file can mount
  over it — but the shipped default is single-machine, as it was in
  every Inferno release.

## 5. See also

`newuser(8)`, `snapd(8)`, `ventisrv(8)`, `vacfs(4)`, `auditprov(2)`,
`docs/DEVELOPER-GUIDE.md` (the `~/.infernode` tree),
`docs/compliance/audit-log-design.md` (§8, the audit store),
`docs/NAMESPACE-LAYOUT.md`.
