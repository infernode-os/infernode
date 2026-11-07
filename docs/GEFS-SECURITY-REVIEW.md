# GEFS security review

Date: 2026-11-07

Reviewed InferNode integration pin `fb66e0893` (GEFS feature head
`93a597f2d`) and 9front `front` at
`d3d26512a2a5bde65497e0303c2e1617fd53905c`.

## Decision

GEFS should not be promoted without the hostile-media hardening and tests in
this review branch. Its normal filesystem, snapshot, crash-recovery and root
installation tests pass, but the reviewed code trusted checksum-covered disk
metadata as though the checksum made the producer trustworthy. MetroHash is
deliberately unkeyed: it detects accidental damage; it cannot authenticate a
disk image.

The finding is also present in the reviewed 9front source. It is inherited
behaviour, not a Limbo-port divergence. InferNode nevertheless has a stronger
reason to fix it before promotion because a bare-metal node can select GEFS as
its root source at boot.

## Threat boundary

The affected boundary is a disk, partition or ordinary image file supplied by
an attacker, including removable media and an image obtained over another
channel. On a GEFS-root node the result can occur before the normal userland is
available. This is not a network attack unless some separate service lets the
attacker replace or write the backing device.

GEFS itself has no authentication. A 9P attach name supplies the user name.
That is acceptable for its in-process `-M` mounts and a local pipe, but the raw
9P stream must not be exposed to an untrusted peer. If GEFS is exported, the
surrounding export must authenticate through factotum, with persistent secrets
coming from secstore. GEFS neither needs nor should acquire credential files.

## Findings

### GEFS-1: hostile metadata can escape parser bounds or hang recovery — high

`readblk` accepted a log's on-disk `logsz` and passed it directly to
`bufhash`; tree getters likewise trusted counts and offset tables after a
checksum matched. Allocation-log and deadlist chains had no cycle detection.
A checksum-valid producer could therefore cause a Limbo bounds exception or
make mount/check loop indefinitely.

The same trust extended to superblock geometry, arena sizes and block
pointers. Most invalid allocation entries stopped in an assertion, but a
crafted free range could enter allocator state outside its arena. Subsequent
writes were checked only for a non-negative address. On writable hostile media
that makes this an integrity issue as well as a boot/service denial of service.

The fix:

- records the whole-block device size and accepts only aligned, in-device
  reads and writes;
- validates superblock geometry, tree height, arena ordering, containment,
  usage and log heads before replay;
- bounds log lengths before hashing and validates every allocation/free entry
  against its arena;
- validates tree count tables, offsets, key/value lengths, pivot pointers,
  message operations and operation-specific payload sizes before getters run;
- detects allocation-log and deadlist cycles, requires the expected block
  type, and validates a complete deadlist before freeing any block;
- checks cached blocks against a caller-supplied hash and rejects root blocks
  whose type does not match the recorded tree height.

The disk format is unchanged and remains byte-compatible with 9front.

### GEFS-2: the opt-in write journal exposed raw blocks — low

`-W` is a crash-test facility that records every raw block write. It created
the journal mode `0644`, so another local user could read file contents and
metadata captured by a test or an accidental production invocation. It now
creates the journal mode `0600`; the crash test asserts that no group/other
permission survives. This journal is not an authentication credential, but it
can contain data that is every bit as sensitive.

## Model-free evidence

`tests/host/gefs_security_test.sh` reams a real filesystem, then constructs
five hostile images. Where a checksum covers the changed bytes, its Python
fixture recomputes the exact GEFS MetroHash64 value and updates the parent
pointer or superblock checksum.

At the unpatched integration pin:

| Image | Control result |
|---|---|
| log length `0xffff` | uncaught `array bounds error` |
| self-cycling allocation log | timed out after 5 seconds |
| self-cycling deadlist | printed `checking deadlist`, then timed out |
| checksum-valid tree count `0xffff` | uncaught `array bounds error` |
| checksum-valid negative `/adm/users` length | uncaught `negative array size` |

With the patch, all five are rejected with a GEFS corruption diagnostic; none
produces a module/bounds exception or timeout.

Regression results on macOS arm64, headless emulator:

- full required Dis rebuild: pass;
- `gefs_security_test.sh`: 5/0;
- `gefs_test.sh`: 20/0;
- `gefs_crash_test.sh`: 24/0 power-cut seeds, journal private;
- `gefsroot_test.sh`: 14/0.

## Upstream comparison and follow-up

The reviewed 9front `readblk` also hashes `b->logsz` before bounding it, its
tree getters trust the on-disk offset tables, `loadlog` has no chain-cycle
guard, and `unpacksb` does not validate the recorded geometry before use.
After InferNode's patch is settled, this should be reported upstream with the
format-preserving checks and minimal hostile-image constructions. Until then,
do not describe the issue as a porting omission.

The parser checks are deliberately structural, not cryptographic. They make a
hostile image fail closed; they do not make an untrusted disk authentic. If
authenticated storage becomes a requirement, it needs a separately designed
keyed/Merkle scheme whose keys remain in factotum/secstore.
