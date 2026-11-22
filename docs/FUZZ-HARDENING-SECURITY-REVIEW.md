# Security review: PR #1069 fuzz-derived hardening

Status: **substantially sound; two cleanup defects fixed here; three
availability residuals and deterministic fault gates remain**

This review is pinned to PR #1069 base
`ae36deda20b72b603e3376e071c989e07f7108b1`, head
`c17daccdaf6a2faea0e7741bfc5c1170b66e0ac3`, and merge
`c4bdd0f1f9608303ca8d9fd16d0b7a60a512273d`.  It supplements the integrated
kernel review at [REMOTE-KERNEL-SECURITY-REVIEW.md](REMOTE-KERNEL-SECURITY-REVIEW.md),
which already records the broad build, host, native, multi-VM, and CSPRNG
verification.  It does not treat a clean fuzz run as proof: each class below
was checked against the ownership or cleanup invariant its fix is meant to
restore.

## Disposition

The parser, interpreter/JIT, allocation-unwind, scheduler/lock, exportfs,
devmnt, and virtio changes are real hardening rather than seed suppression.
In particular, they move untrusted lengths and device-owned links behind local
bounds, undo partially published objects on allocation failure, preserve the
current Prog/frame before raising an exception, and bound teardown waits on a
server that may never answer.

The review found a defect in the new low-memory group-kill path: it retained
a group pointer across `killprog`, which may release the VM and free that
group.  The security branch now reacquires groups by their non-reused id in
both hosted and native kernels.  Strict native replay also found that a marked
kill could be delivered yet swallowed inside nested 9P error handling, after
which the revoked Prog slept again with no owner left to retry it.  The branch
now makes revocation durable until the Prog returns to its VM and limits a
killed mount call to one flush before orphaning its request chain.  The
remaining open items are availability/recovery problems, not evidence that
the repaired parser or device memory-safety paths are still exploitable.

## Review by failure class

### Parsers and file servers

The Styx/Ninep size and rune fixes reject or correctly encode the problematic
inputs before slicing/packing.  The memfs fixes use overflow-safe range
reasoning and distinguish an absent block from readable bytes.  The devprog
listing changes stop treating `snprint`'s negative no-room result as a byte
count and take references/copies while the VM is held, then perform blocking
namespace/fd work after release.  Focused Styx, Ninep, memfs, devprog read, and
namespace-lock tests accompany these changes.

No adjacent signed-size or second-parser bypass was found in the modified
paths.  This does not replace the separate protocol review of code outside the
PR.

### Interpreter and JIT

The builtin exception patches restore the caller's PC/frame before a raised
exception is matched to a handler.  The MacFRAM/MacMFRA paths now set `R.PC`
on the path that can raise.  Compile failure completes type code generation
before relocating any module link, and a refused allocation falls back to the
unchanged interpreter module while releasing the compile lock.  Channel
enqueue failure is reported before removing the Prog from the run queue, and
`alt` undoes earlier queue insertions before raising.

These invariants are exercised under both interpreter and JIT by the byte,
nil-module, kill-during-call, builtin-exception, small-module, fold, and real
conversion regressions.  Review found no path in the modified code that
publishes half-relocated module code or raises with a different Prog current.

### Allocation failure and partially constructed objects

Mount and IP queue construction now allocates/checks every required queue
before publishing the Mnt/Conv and unwinds the partial object on failure.
First-Prog/channel allocation similarly leaves no runnable object with missing
storage.  The later devmnt correction creates a flush before putting the
stack-resident watchdog on the global list; if flush allocation fails, the
original call is orphaned under the same tag-preservation rule.

The general shape is correct: construct privately, publish last, and undo in
reverse ownership order.  The important exception was group cleanup, recorded
next.

### FZ1069-01 — High under memory pressure: group pointer survived deletion

Commit `07b8c7ff67b2422d645d7a8330d4946ae41329b1` added a no-allocation
`killgrp` fallback.  `/prog/<pid>/ctl` may target a group other than the
writer's.  `killprog` can release the VM, delete the target's last Prog, and
free its `Progs`; the fallback then traversed or cleared `g->flags` through the
stale pointer.  The hosted normal-allocation path already documented this
exact lifetime rule and used stable ids, but the new fallback did not.  Native
also retained `p`/`g` across the wait for another group kill and cleared the
normal path's possibly freed `g`.

Fix in this branch (`f42d31ddd`): group ids are leader pids and never reused.
Both kernels now find the surviving group through current Progs by id after
every `killprog`; error cleanup and final flag clearing do the same.  Native
also revalidates the target pid/group after releasing and reacquiring the VM
while waiting for an earlier kill.

Verification: the hosted headless emulator builds; the native virt kernel
cross-builds; `kill_deadserver_test` passes 4/4, including a catch-all around
the blocked read that must not retain a ctl-killed Prog.  A deterministic test
that refuses precisely the pid-list allocation is still required before this
item is considered a complete regression gate.  The chaos campaign can reach
the path but is probabilistic and its CI job is not a release gate.

### Mount teardown and dead 9P servers

The one-second killed-call and five-second ordinary-exit watchdog preserves
the essential 9P rule: a tag is not reused while the server may still answer.
Answered flushes retire the original request; late replies retire orphaned
requests; mount close handles the caller/orphan ownership split.  Moving fd
table close before namespace close and delaying exportfs's old-environment
close until after its reply remove the two self-dependencies demonstrated by
the original constructions.  `kill_deadserver_test` covers killer, killed
reader, and ordinary exiter cases with a server that never answers.

#### FZ1069-02 — Medium, fixed: killed Prog could sleep again after delivery

The strict native replay (`seed 100`, `max`, four cores, GICv3, 1 GiB,
multi-threaded TCG, 10-second run) repeatedly ended with Progs recorded as
`exiting ... killed` while their interpreter Procs still slept in mount RPCs.
The first observed run had three such Progs; later runs had as many as eight
in one group.  This is a real containment failure: `/prog/<pid>/ctl` recorded
revocation, but the target continued to own a kernel Proc and its namespace.

Two races are repaired in this branch.  `release()` now publishes `iprog`
under the Proc rendezvous lock and preserves a kill already recorded during
that transition as `intpend`.  `swiprog` now checks and interrupts the exact
`Proc.iprog` under that same lock instead of reading it unlocked and then
interrupting a possibly changed owner.  A later kill of an already-`Pexiting`
Prog retries the wake, and the VM treats `Pkilled` as ownership revocation.
Those changes made the delivery exact but did not finish the fix.  Native
tracing proved the target Proc was woken, `mountio` received `Eintr`, and its
watchdog fired; an outer 9P/name-lookup error handler then translated the
interrupt and the still-`Pkilled` Prog entered the same read again.  There was
no remaining owner required to issue a second kill.

The final correction (`f42d31ddd`) makes `Pkilled` durable at the sleep
boundary until the released Prog returns to the VM.  Deliberate exit cleanup
is exempt and keeps its bounded device-specific waits.  In devmnt, a killed
call sends at most one flush: a second interrupt while that flush's watchdog
is armed orphans the chain immediately.  This second rule is essential.
Unconditionally polling `Pkilled` without bounding flush creation was tested
and discarded because it allocated a fresh flush on every refused sleep and
reproducibly exhausted the mount-RPC pool.

Verification: the hosted `kill_deadserver_test` passes 4/4, including a
catch-all around a blocked read; the macOS headless emulator and native virt
kernel build; and strict native four-VM runs for seeds 100–103 all pass with
`-L` under `max`, four cores, GICv3, 1 GiB, multi-threaded TCG, ten-second
runs, and two-second epochs.  `nativefuzz -L` subtracts the documented
three-Prog harness baseline rather than misreporting the harness itself as a
leak (`5a86630ee`).

A deterministic native multi-VM regression should still park targets on both
sides of release publication, kill them from their home and another VM, and
prove every pid disappears.  The fixed seed matrix is strong construction
evidence but not a permanent race gate.

#### FZ1069-03 — Medium availability: orphan tags and requests are unbounded

A permanently silent or malicious mounted server can accumulate one retained
tag/Mntrpc (and sometimes a flush) for each abandoned call until the mount is
closed, eventually exhausting the global 16-bit tag space and associated
memory.  Reusing those tags on a live byte stream would be unsafe, so the
present behavior is preferable to aliasing a late reply, but it is not a
complete availability policy.

Required follow-up: count orphans per mount and impose a small budget.  Once
crossed, fail/close the mount transport and reclaim only after the connection
is unambiguously dead; do not recycle a tag while late replies remain
possible.  Add a deterministic silent-server soak that crosses the budget and
proves unrelated mounts retain tags and progress.

### Locks, scheduler, and cleanup

Raising to `PriLock` before test-and-set closes #640's preemption window; the
holder recorded in each Lock is diagnostic and does not determine ownership.
The group-kill no-memory intent is correct—cleanup must not require the memory
it is meant to free—and the stable-id correction above repairs its lifetime.
Bounded clunk waits prevent unresponsive servers from consuming every kernel
Proc.  The scheduler and error-stack detectors in the native suite remain the
right long-run gate.

#### FZ1069-04 — Medium operational availability: total pool starvation can
still stop the recovery path

With a hosted main pool configured far below the workload's minimum, every
Prog, including the one that would kill other Progs, may wait for memory that
only those Progs can release.  The new waiting allocators replace panics with a
diagnosed standstill but do not guarantee recovery.  This is explicit in
`docs/NATIVE-FUZZING.md`.

Required follow-up: define a minimum supported pool size and reject smaller
startup values, then reserve enough non-user-contendable memory for kill,
close, and error unwinds.  A memory-consuming workload must not be able to
consume the recovery reserve.  Gate both rejection below minimum and cleanup
progress at the supported minimum.

### Virtio/device boundary

`vqcollect` now validates a used head against range and the driver's private
busy map, and returns descriptor chains through the driver's private link and
length records rather than device-writable descriptor fields.  Virtio-net
also bounds the device-reported received length before advancing a Block.  The
modified path therefore closes the demonstrated out-of-range, double-free,
nil-cookie, loop, and overlength packet cases.

#### FZ1069-05 — Medium with an untrusted device/hypervisor: rejected lies
leak queue capacity until reset

When a used-ring entry lies about ownership, the driver cannot safely infer
which real request completed.  It discards the entry and leaves outstanding
descriptors busy.  Repeated lies can reduce virtio-net receive room to zero.
This is memory-safe fail-closed behavior, but it turns a transient or malicious
device fault into permanent interface loss.

Required follow-up: after a small bogus-entry threshold, quiesce and reset the
queue/device, fail every outstanding request exactly once, rebuild private and
shared rings, and repost receive buffers.  Never guess which descriptor the
device intended.  Test reset with disk, network, and input requests in flight.

### Fault-injection surface and test gates

The chaos controls and hooks are compiled only under `-DCHAOS`; `/dev/chaos`
is absent from ordinary kernels.  Rates start disabled.  Review of production
device tables/configuration found no independent way to enable the hooks.

CI runs six fixed hosted sysfuzz seeds and focused JIT regressions.  It does
not run the native campaign, the chaos build, sanitizer campaign, or a
deterministic fail-at-N allocation matrix as a release gate.  Several OOM
fixes therefore have excellent discovery evidence but weaker permanent
regression evidence than the parser/JIT fixes.

Required gate: provide a deterministic, scoped fail-at-N allocator usable by
tests (not production namespaces), enumerate each repaired construction point,
and require the expected error plus invariant checks after every injected
failure.  Keep a small native multi-VM seed matrix in CI or a required
pre-merge hardware/QEMU job, with retained artifacts on failure.

## Known campaign limits

The review preserves rather than hides the campaign's other open observations:
hosted seeds 704/904 have a rare unexplained heartbeat stop, and a grossly
undersized pool can cause the standstill above.  A fuzzer's failure to
reproduce either is not a refutation.  Conversely, one-core QEMU `-icount`
with sleep disabled was established as a QEMU event-loop artifact and is not
counted as a kernel finding.
