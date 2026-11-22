# Security review: native camera device

Status: **test-pattern implementation may remain; hardening is required before
a real camera source is enabled or the interface is delegated**

This review is pinned to InferNode camera source commit
`16948f6ced372ed08eb2db9594f9551888208d33`, merged by PR #1006 as
`80189fa777022abe7a3bda2995b9545d0a6fafa1`, and reviewed in the integrated
tree at `065adcd61972f31c017f2a83fb27bc48a0ccb1e8`.  PR #1056 changed only the
host test's console capture; it did not change the device.

The shipped source is a generated test pattern.  There is no sensor, DMA,
firmware, USB-camera, or user-space camera bridge in this pin.  Accordingly,
this review covers the `#V` file interface, buffer ownership, arithmetic,
locking contract, namespace placement, and the boundary a future real source
would cross.  It does not claim to review a real camera driver that is not in
the tree.

## Security disposition

The current test-pattern source does not expose room imagery and its fixed
modes keep the present arithmetic in range.  Veltro's restricted namespace
also replaces `/dev` with exactly `cons`, `null`, and read-only `time`, then
applies `NODEVS`; an agent cannot see `/dev/camera` or reattach `#V`.

Those controls do not make the general camera interface ready for a real
sensor.  A camera is a privacy capability and must be delegated by namespace,
not ambient in every ordinary process.  The retained-frame allocation model
also permits kernel-memory exhaustion, and the source contract deliberately
holds the global camera lock across a blocking driver callback.  Both must be
resolved before real imagery is enabled.

## Findings

### CAM-01 — High when streaming: retained opens can exhaust kernel memory

`os/port/devcam.c:216-267` allocates a raw capture buffer and a separate output
buffer for every open of `frame` or `raw`.  The output remains attached to the
Chan until close (`camclose`, lines 457-470).  There is no byte, frame, user, or
device-wide quota.

At the largest advertised mode, one `frame` open transiently uses about
15 MiB (5.97 MiB raw plus 8.96 MiB RGB) and retains about 8.96 MiB.  A native
process may hold up to 4,000 descriptors (`MAXNFD`), and additional processes
multiply that total.  Once an authorized process has written `stream on`, any
process that can read the globally inherited device can retain frames until
the kernel pool is exhausted.

Required change: account retained bytes in `#V`, reserve before allocation,
and refuse an open that would cross a deliberately small global budget.  The
reservation must be released on every allocation, capture, open, and close
error path.  A later streaming/ring interface may use bounded shared buffers,
but must not reintroduce unbounded per-open retention.

Tests required: hold opens without reading or closing until the documented
limit is reached; prove the next open is refused without pool damage; close
one and prove capacity returns; repeat at every mode and inject allocation and
source errors at each reservation point.

### CAM-02 — Blocker for real imagery: the camera is ambient, not delegated

`os/init/osinit.b:209-215` binds `#V` after `/dev` at boot, so every ordinary
namespace forked from boot inherits `/dev/camera`.  `frame` and `raw` are mode
0444 (`os/port/devcam.c:71-76`).  The control is owner-writable, but after the
owner enables streaming all ordinary readers can capture the next frame.

This is not presently a confidentiality disclosure because the only source is
the synthetic colour pattern.  It becomes one the moment a real source is
registered: enabling a camera for one application silently enables capture by
every process that retained the boot namespace.  The man page's advice to
grant an agent only the camera files it needs does not address this ambient
native exposure.

Required change before a real source is enabled: do not place real camera
frames in ambient `/dev`.  Mount a camera capability only into the namespace
of the trusted capture service/application, with control and frame authority
separable.  Veltro must continue excluding it by default and any future grant
must be explicit, read-only where possible, and represented in nsaudit.

Tests required: a process outside the granted namespace cannot name the
camera; a process with frame-only authority cannot start, stop, or reconfigure
it; revocation closes or invalidates outstanding capture authority; `#V`
attachment remains rejected after `NODEVS`.

### CAM-03 — Medium: the source contract blocks while holding global control

`shoot()` takes `cam.lk` before allocation and keeps it while
`cam.src->next()` waits for a frame and while debayering the result.
`camera.h:10-12` makes this a driver contract: every source method is called
with the global lock held and may sleep or error.  Consequently a stalled real
source blocks `stream off`, source/mode changes, status reads, and every other
capture.  An `off` method cannot concurrently wake a `next` method because it
cannot acquire the same lock.

The synthetic source sleeps for at most one configured frame interval and a
killed open unwinds through the error handler, so this is a future-driver
boundary rather than a demonstrated permanent wedge in the test source.

Required change: separate short-lived state serialization from capture
ownership.  Define an explicit cancellable source contract, snapshot a
validated configuration with a generation/ref, and allow `stream off` or
device teardown to wake an in-flight capture without waiting for the global
state lock.  Do not call a blocking source callback while holding that lock.

Tests required: a source parked forever in `next`; concurrent status and
`stream off`; killed opener; source removal/teardown; and a late frame from a
prior generation that must not be published after reconfiguration.

### CAM-04 — Medium before additional sources: registration trusts metadata

`addcamsrc()` checks only the four-source array bound.  `usesrc()`, `shoot()`,
`debayer()`, and the test pattern assume a valid default index, positive even
dimensions, bounded products, positive frame rate, a four-character Bayer
cell containing red/blue/two green sites, 8..16 significant bits, and complete
method pointers.  A malformed in-kernel source can therefore cause invalid
pointer arithmetic, bad shifts, division/modulo by zero, undersized allocation,
or an out-of-bounds mode access.

The single compiled-in source satisfies those assumptions, so this is not an
attacker-controlled input in the reviewed pin.  A real driver must not be
registered until `addcamsrc()` validates the complete descriptor and every
mode, including overflow-safe upper bounds for raw and converted lengths.

Tests required: a registration harness for every invalid field and boundary,
including dimensions whose products fit `int` but not the allocation/output
types.

## Refuted candidate findings

- A negative `pread` offset does not reach `camread`: `rread()` in
  `os/port/sysfile.c` rejects every negative offset with `Enegoff` before
  calling a device.
- The current agent namespace does not inherit `/dev/camera`; `restrictns()`
  reconstructs `/dev` from an exact three-name allowlist and `NODEVS` blocks a
  later direct attach.
- The current fixed modes do not overflow `shoot()`'s length arithmetic, and
  the test-pattern Bayer metadata is valid.  The issue is the unchecked source
  interface promised to future kernel drivers, not hostile ctl text selecting
  arbitrary dimensions.

## Existing verification and missing gates

`os/init/camtest.b`, gated by `tests/host/baremetal_test.sh`, checks ctl parsing,
fixed modes, frame/raw sizes and pixels, pacing, and refusal while stopped.  It
is useful functional coverage but does not exercise concurrency, cancellation,
allocation failure, retained-open limits, namespace privacy, malformed source
registration, or teardown.  Those are the security gates required above.
