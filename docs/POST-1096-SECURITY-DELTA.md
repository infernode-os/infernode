# Security review: post-#1096 remote delta

**Reviewed range:** InferNode `c7d892104..858fcb50d`

**Disposition:** three defects fixed on `security/0.9.0-patch`; focused
native and hosted gates pass

**Method:** source review and model-free target/control tests; no live-model
campaign

This review covers the work merged after the earlier post-report delta:
the native `destroystack` repair and sanitizer workflow, login interface
selection, SDR read-ahead, native IP address rejection, bare-metal CNSA-mode
selection, and USB touch-screen support.  The release hardening from PR #1096
also lies in the range, but is reviewed in
[POST-REVIEW-DELTA-SECURITY-REVIEW.md](POST-REVIEW-DELTA-SECURITY-REVIEW.md).

## Findings fixed

### D2-01 — Medium, physical/local: hostile HID report descriptors were unbounded

`os/init/mouseusb.b` parses a USB device's HID report descriptor on bare
metal.  Report Size and Report Count are attacker-controlled HID global
items, each up to four bytes.  The new parser multiplied them and used Count
as an allocation loop bound without a limit.  A malicious USB pointer could
therefore request billions of `Field` records, or wrap a bit offset and evade
the later additive report-length check.  This is a board availability attack
from an attached device, not a native-kernel memory overwrite: the parser is
a Limbo class-driver process, but exhausting the shared heap or CPU affects
the node.

The fix caps a descriptor to 4,096 fields and each report to 32,768 bits,
checks multiplication by division before changing an offset, and rewrites
`getf`'s additive bound as subtraction checks so integer overflow cannot make
an out-of-range bit index look valid.  The device-free `mouseusb -t` self-test
now includes four-byte Count and Size attacks followed by otherwise valid X/Y
fields; both must be rejected without entering their claimed loops.

### D2-02 — Low, native multicore: CNSA policy latch could race first use

Commit `43dc5e1b` correctly makes `/n/dos/cnsamode` an existence-only policy
flag, not a credential.  It throws a one-way kernel switch before boot starts
anything that authenticates.  Keys and passwords remain in factotum/secstore.

The switch's `cnsastrict` and `cnsaasked` words were nevertheless read and
written unlocked.  A privileged runtime `cnsamode on` racing the first
authentication on another core could observe `cnsaasked == 0`, set the policy
to strict, and still let the handshake cache the earlier non-strict answer.
The machine would then report strict mode while that process used ML-KEM-768.
The normal `osinit` ordering does not race, but the sysctl contract promised
the invariant independently of that ordering.

The two-word transition is now under a native spin lock in both architecture
`getenv` implementations and the sysctl writer.  The one-way and too-late
tests remain in the virt harness.

### D2-03 — Low, hosted portability: stack fix ordered unrelated C pointers

Commit `1cdceae13` fixes a real invalid free when a Prog is killed between a
`frame` instruction and its call, and `kill_uncalled_test` is a good targeted
regression.  Its new test for whether `R.FP` belonged to the newest separately
allocated stack extension used relational comparison on pointers to distinct
C allocations.  ISO C leaves that ordering undefined, so an optimizing host
compiler was not required to preserve the address comparison the VM needs.

The comparison now casts all three addresses to `uintptr`.  After rebuilding
`libinterp.a` and relinking the emulator, `kill_uncalled_test` completes all
3,000 kills under both the interpreter and JIT.

## Reviewed with no new blocker

- **Sanitizer automation.** The Linux-only ASan/UBSan build now links, runs
  both suite modes nightly, runs `sysfuzz`, uses pinned actions, minimal
  workflow permissions, time bounds, and retained reports.  It does not add a
  production authority surface.  The stack finding above is adjacent source
  review prompted by the campaign, not a failure of the workflow.
- **Native IP connect validation.** `isipaddr` rejects names and unspecified
  destinations before the native stack can wait on a SYN to 0.0.0.0.  Numeric
  IPv4, IPv6, and one-number IPv4 forms remain accepted.  The state and lock
  unwind are unchanged.
- **SDR read-ahead.** The bounded channel retains at most four 64 KiB chunks.
  The reader reports errors before exit and is killed on a consumer fatal
  path.  It inherits the demodulator's process group, so group revocation also
  reaches it.  No new namespace or credential authority is introduced.
- **Login interface selection.** The persisted value is a non-secret choice
  constrained to the boot script's fixed offered list before use.  Passwords
  remain masked and flow through secstore into factotum; the new tests cover
  wrong-password refusal and factotum remaining empty until successful
  unlock.  Interface names do not become shell code.
- **Touch gesture and pointer delivery.** The kernel pointer changes only add
  bounded finger event delivery.  The descriptor parser was the hostile-input
  defect and is fixed above; touch gesture state itself is bounded to sixteen
  published fingers.

## Work deliberately not conflated with this pin

GEFS is not present on `master` at `858fcb50d`, but it is present on the Pi 5
integration line through `origin/integ/pi5-all` at `fb66e0893` (GEFS feature
head `93a597f2d`).  That is now a source-pinned review target, not “absent”; it
requires its own on-disk corruption, crash-recovery, 9P permission, namespace,
and arithmetic review before promotion.

PR #1015 has also advanced beyond the reviewed head.  Its Noise-DH, counter,
and TLS pinning fixes do not clear the existing merge block: the commander
credentials still must move from ordinary files into protected
factotum/secstore persistence, and the D2 renewal/release barrier still needs
closure and regression evidence.  The later cross-repository requirements
review leaves the exact runtime provider boundary open rather than requiring
operation-specific factotum for the D2 hot path; see
`PR-1015-STYXBRICK-REQUIREMENTS-REVIEW.md`.  Its delta will be rechecked
separately.

## Verification

- post-merge Dis rebuild: passes;
- AArch64 virt kernel cross-build: passes;
- device-free `mouseusb -t`, including hostile Size, Count, and contact-count
  cases: passes;
- `kill_uncalled_test -c0`: 3,000 kills, pass;
- `kill_uncalled_test -c1`: 3,000 kills, pass;
- macOS arm64 `libinterp.a` rebuild and headless emulator relink: pass;
- `git diff --check`: pass.

The sandboxed virt run reached the shell but could not bind the host UDP
socket used by `qemu_net_security.py`; subsequent harness checks then lacked
their expected network/disk session output.  Those lines are environment
failures, are not counted as passes, and do not replace the focused gates
above or the already-green upstream CI run at the reviewed pin.
