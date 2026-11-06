# Remote kernel security assimilation

This note records the security review performed while assimilating
`origin/master` at `59dbf672cbf1` into `security/0.9.0-patch`.  It complements
the source-by-source 9front ledger in `9FRONT-SECURITY-AUDIT.md`; it does not
extend that ledger's pinned 9front baseline.

## Scope

The incoming range added the multi-VM native kernel work from #944 and the
native-fuzzing/OOM hardening that followed it.  The review concentrated on
authority crossings, process cleanup, shared kernel state, allocation-failure
unwinds, device exposure, and code that overlaps this patch branch.

The files changed by both lines of work were:

```
emu/port/chan.c        emu/port/devip.c       libinterp/draw.c
os/bcm/uartmini.c      os/ip/devip.c          os/port/chan.c
os/port/portdat.h      os/port/proc.c         os/port/sysfile.c
port/devdraw.c         tests/host/baremetal_test.sh
```

Git resolved those overlaps without a textual conflict.  They were reviewed
as merged code rather than accepted on that basis alone.

## Security disposition

- **The `#X` multi-VM device does not widen a confined agent.** `vmrun()`
  copies the writer's namespace, environment, descriptors and user; it does
  not manufacture new file authority.  Veltro's `restrictns()` removes the
  boot-time `/dev/vm` binding by replacing `/dev` with exactly `cons`, `null`
  and read-only `time`, and `pctl(NODEVS)` rejects a direct `#X` attach.  The
  namespace regression requires that exact three-file `/dev` view, while the
  device regression proves the kernel rejects devices outside `|esDa` after
  `NODEVS`.
- **The `#X` controls are cleanup-critical.** A command started by `vmrun()`
  begins as a first Prog in the target VM and therefore receives a fresh
  process group.  If an agent could reach `#X`, it could outlive cleanup of the
  caller's group.  This is not treated merely as a same-authority convenience:
  hiding `/dev/vm` and blocking `#X` are part of the confinement boundary.
- **The multi-VM shared-state conversions are paired with lifetime fixes.**
  module tables, heaps, collector state and schedulers are per-VM; shared
  kernel objects retain explicit locks/refcounts.  Later fixes in the same
  incoming range cover cross-VM kill handling, group waits, devprog reads,
  mount clunks, compilation locking, and VM identity while crossing into a
  different interpreter.
- **Fault-injection findings are fixes, not enabled production attack
  surfaces.** The new chaos device is present only in the dedicated chaos
  kernel configuration.  Normal native device tables do not publish it.
  The findings it drove include clean allocation-failure unwind for channels,
  Progs, queues and mount requests; bounded lock/clunk waits; and repaired
  request/list ownership.
- **Hardware entropy is fail-closed.** Native key generation now requires the
  platform hardware generator instead of silently treating timing-derived
  output as equivalent entropy.  Platform generator access is serialized.
- **The subsequent kernel CSPRNG merge preserves and strengthens that rule.**
  A single qlocked ChaCha20 generator now serves every native random entry
  point.  Its first key still requires 32 accepted hardware bytes; it performs
  fast key erasure before returning output, reseeds after one second or one
  megabyte, refuses a repeated 32-byte seed and a repeated 32-bit word, and
  stops serving an old key after ten minutes without hardware recovery.  The
  explicit QEMU-only `insecurerandom` escape remains loudly marked and is not
  enabled on boards.  Waiters release the Dis VM, so an empty generator cannot
  freeze unrelated Progs.  DNS now draws a fresh unpredictable id for every
  query instead of exposing a startup-seeded sequence.  Review of the lock,
  counter, rekey, reseed, stale-key and failure paths found no widening or
  fallback to unauthenticated entropy.
- **The merged network and device paths retain this branch's checks.** The
  devip ownership/permission, negative-attach, conversation bounds, state
  unwind, route/interface lifetime, transport-length, TCP sequencing and IP
  fragmentation changes remain present after the merge.  The incoming virtio
  used-ring bound, export queue-tail repair, UART and devdup fixes add further
  validation without weakening them.
- **Interpreter/JIT changes close concrete memory-safety and liveness faults.**
  The incoming range zeroes the first frame, fixes destroy-state preservation,
  propagates pending kills after builtin calls, bounds scratch storage, and
  corrects several architecture-specific JIT exception paths.  The associated
  focused regressions are included in the merged host suite.

No new privilege-widening path was found in this incoming range.  The notable
dependency is explicit: future code must not grant `/dev/vm` or `#X` to a
confined workload unless its lifecycle is deliberately moved under the same
cleanup policy.

## Verification

The merged tree builds successfully with the complete root install followed by
`build-macos-headless.sh`.

A fresh full `tests/host/baremetal_test.sh` run completed all three native
targets with **520 passes, 7 failures and 1 skip**.  Every changed security and
kernel path passed, including:

- valid IPv4 fragmentation and rejection of every reassembly length lie;
- short UDP/TCP rejection, negative attach, TCP half-open reaping, window
  scaling, and the descending one-byte resequencing limit;
- authenticated 9P, interface teardown/rebind and network hot-plug;
- the 90-second four-core scheduler soak with no detector firing;
- virtio, GICv2/GICv3, xHCI, storage, entropy fail-closed behavior and all
  bcm2711 gates; and
- the new four-VM contention, cross-VM 9P, cross-VM kill and 75-second stress
  tests, including complete cleanup ten seconds after the stress ends.

The seven failures were unrelated existing harness/fixture noise: the known
nil-test output ordering, two console-marker captures (CPU listener and network
console), and four consequent FAT/card checks after that console sequence.
There was no panic, unhandled exception, scheduler detector, failed security
packet, or multi-VM failure.

The broad host run exposed three test-isolation assumptions while exercising
the merged runtime.  The AWK test now explicitly bounds the emulator instead
of depending on the first Prog's exit to tear down a multi-VM process.  Audit
signing now removes a prior run's log before minting a fresh key, and its unit
test uses the production ML-DSA-87/SHA-384 combination.  Focused reruns of AWK
(31/0), audit signing (strict anchored verification) and agent delegation all
pass.

The remainder of the host matrix exposed four more portability or assertion
problems, all corrected and rerun:

- the incoming RWLock stress harness used unnamed POSIX semaphores, which
  macOS does not implement; its queued per-Proc wake now uses a mutex and
  condition variable with the same one-wake semantics, and the full reader /
  writer exclusion stress passes;
- allocator diagnostics may contain an image-relative symbol on platforms
  that support it or the documented raw-PC fallback on PIE macOS builds;
- a refused task can leave an empty mount-point directory, so the test now
  checks for the child server's metadata file rather than confusing the
  directory with a live tool mount; and
- the presentation checksum no longer uses GNU `head -c -1` on macOS.

The stalled-model regression now waits for bounded completion instead of
racing a single-CPU emulator against a three-second sleep.  The backend stays
permanently stalled throughout, and the independent llmsrv request completes.
GPS passed after the required complete Limbo install made the newly added
module available.

Multi-VM also invalidated the internal runner's old assumption that exit of
the initial Prog stops the emulator.  `runner.dis` now explicitly halts only
after writing its complete result.  The authoritative network-enabled run is
**258 passed, 0 failed and 33 environmental skips**.  The restricted-sandbox
run's three localhost failures were reproduced as sandbox `EPERM` and all
passed when localhost announce/dial was allowed.

The same lifecycle rule exposed eleven GUI drivers that printed their final
success marker but left a window manager or service alive, so macOS waited for
each host-side deadline.  Those drivers now halt explicitly after their last
artifact and marker, matching the GUI drivers that already did so.  Focused
macOS ARM64 reruns pass for edit, dir, ftree, OSK core, login, four display
sizes, all themes, a 400-action fuzz run, full Lucifer and mobile boots.  The
four-size OSK check now completes in 22 seconds rather than four 120-second
deadline waits; full Lucifer cases retain their intentional boot delay but no
longer idle to the deadline.

`tools/verify-dis-build.sh` produced all **1,171** manifest modules.  The
macOS build also regenerated the checked-in device and root tables, adding the
incoming location device and `/prof` root entry that their source
configuration already declared.

After the kernel CSPRNG merge, its independent host model passes all nine
cases: no source, non-VM waiter, explicit insecure mode, construction,
long-request rekeying, dry-after-seed expiry, stuck source, repeated seed and
4,096 distinct requests.  The post-merge hook also rebuilt the changed DNS
module successfully.
