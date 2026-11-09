# Security review: PR #1015 (`brick`, sdg, and TLS pinning)

Status: **candidate remediation complete; publication CI and hardware acceptance remain**

This review was first pinned to InferNode PR #1015 head
`08846129d207c1d535682e0ad37ca883a4e75c57` and was re-reviewed at
`b66d0f2944ca98ecd141d21f483c021b4b64478d` on 2026-11-07.  The original
companion firmware baseline was styxbrick `review-3`, `93a90ba`.  The completed
requirements re-review also covers current styxbrick main
`e23114cb675b5ada72f60f3903596cdfc44d0525` and the divergent review-follow-up
documents at `438c0c7e974e168021da5b10c2f1a6f23716c83e`; see
[PR-1015-STYXBRICK-REQUIREMENTS-REVIEW.md](PR-1015-STYXBRICK-REQUIREMENTS-REVIEW.md).

## 2026-11-08 remediation review

The current candidate is `170a0b3413c478794fb019c25c329ba2bc7a4950` on
`security/pr1015-factotum`.  It combines the reviewed PR head with the D2/sdg
fix `4f7e8d2b7`, current-master integration at `4b90a0248` (master pin
`507950f90`), the requirements record, and the factotum/pairing fix
`424683092`.  Commit `170a0b341` closes the TLS parser and release-gate work.
This is a candidate branch, not the published PR head.

The architecture decision is now explicit: Choice A from the requirements
review is accepted for the initial release.  A trusted, narrowly confined
`brick` controller may retrieve runtime secrets from factotum; factotum is not
in the D2 renewal hot path.  Operation-only TLS/Noise providers remain a
possible later hardening step, not a claim about this implementation.

| Finding | Candidate status |
|---|---|
| P1015-01 ordinary secret files | **Fixed in candidate.** Four purpose-scoped secrets persist through factotum; the profile contains public state only; draft cleartext files migrate only after a successful save. |
| P1015-02 release/renew ordering | **Fixed in candidate** by serialized, generation-checked D2 state and the parked-renewal regression. |
| P1015-03 low-order X25519 | **Fixed** at the reviewed PR pin and retained after integration. |
| P1015-04 counter durability/serialization | **Fixed in candidate.** Failed writes fail closed, two slots survive torn state, and the lock is ownership-safe rather than age-stolen. |
| P1015-05 through P1015-07 | **Fixed in candidate** by transport invalidation and strict local/remote frame bounds. |
| P1015-08 TLS baseline/parser agreement | **Fixed in candidate.** The merged TLS path is the current-master implementation.  The handshake and provisioning regression share one strict SPKI-pin verifier, which rejects truncated/trailing certificates, non-minimal DER lengths, a wrong SPKI tag and nonzero BIT STRING unused bits. |
| P1015-09 release gates | **Fixed in candidate.** D2, sdg, factotum/pairing and factotum-backed TLS client-auth regressions are build/CI gates.  Every TLS case reloads an encrypted keyfile in a fresh emulator; no private scalar is read from the namespace. |
| P1015-10 pairing transaction | **Fixed to the accepted minimum.** Pairing persists one complete local candidate before USB writes and retries idempotently.  True device-side atomic staging remains a future styxbrick interface change. |
| P1015-11 and P1015-12 | **Fixed in candidate** by rollback/non-live state and lease validation. |

The new factotum contract makes `sync` a real durability barrier: no backend
and backend I/O failures are returned to the ctl writer, and dirty state is
retained after a failed save.  `brick pair` and `brick key` serialize on an
`ORCLOSE` profile lock.  Pairing first validates the device's public state,
constructs the complete local TLS/sdg/PSK/D2 candidate, synchronously saves it,
and only then performs idempotent USB writes.  `-R` is the only implicit-key
replacement path.

Evidence on this exact candidate:

- `tests/host/brick_factotum_test.sh`: 31 passed, 0 failed, twice.  This covers
  backend-less refusal, an actual encrypted-keyfile write failure, unchanged
  USB configuration on both failures, lock cleanup, public-only profiles,
  secret elision, idempotent retry, restart recovery, explicit rotation, and
  post-save migration/removal of all four draft cleartext files.
- `brick_d2_test.dis -v`: 1 passed, including a renewal parked across release.
- `sdg_test.dis -v`: 19 passed with localhost UDP enabled, including counter
  failure/concurrency, low-order DH and malformed local/remote frames.
- `factotum_test.dis -v`: 13 passed, 2 skipped because that unit invocation did
  not mount a live service.
- `tests/host/secstore_logon_test.sh`: 12 passed with localhost enabled,
  including persistence and fresh-process reload.
- `tests/host/tls_clientauth_test.sh`: 12 passed, 0 failed.  Six live TLS 1.3
  cases cover the correct credential/pin, P-256 plus ChaCha20, absent client
  certificate, wrong pin, mismatched key/certificate and pin-only operation.
  Six exact-verifier cases cover a valid certificate and five malformed DER
  constructions.  The test is in Linux host CI shard 1.
- `tests/host/tls_matrix_test.sh`: 12 passed, 0 failed; the malformed-server
  regression passed 3/3.
- namespace fail-closed and live nsaudit profile checks passed; the complete
  Dis manifest build produced all 1,186 required modules; all 365 tracked test
  scripts have executable mode.

A local all-tests invocation was also attempted, but is not recorded as green:
the pre-existing `baremetal_test.sh` FAT32 fixture exists immediately after its
QEMU session and then disappears before the adjacent offline readback, causing
four cascading harness failures.  The same cluster reproduced in an isolated
bcm2837-only run; it does not exercise the files changed by this candidate.
The required published-branch CI result remains the authority for the complete
matrix rather than silently converting that harness failure into a pass.

The source-level security blockers and candidate-local release gates are now
closed.  Promotion still requires the ordinary published-branch CI result and
the hardware acceptance evidence required by the repository guidelines; no
hardware actuation is claimed here.  If bare-metal pairing or rotation must
work unattended in this release, it also needs a protected noninteractive
persistence backend; the present unlocked, injected-key boot supports runtime
use but deliberately refuses provisioning that cannot prove persistence.

## 2026-11-07 re-review

The disposition is unchanged: **do not promote from draft or merge**.
The new head makes material progress, but it does not touch `brick.b`'s
credential ownership or D2 state machine.  A read-only merge check against
current master `507950f90` still produces a real conflict in `tests/mkfile`;
the commits after the earlier `858fcb50d` review pin do not change the
factotum, TLS or #1015 provider analysis.

| Finding | New-head status |
|---|---|
| P1015-01 ordinary secret files | **Open blocker**; storage finding unchanged, prescribed provider boundary revised after styxbrick requirements review |
| P1015-02 release/renew ordering | **Open high**; unchanged |
| P1015-03 low-order X25519 | **Fixed at this pin** by `b66d0f294`; 16-case SDG regression passed |
| P1015-04 counter durability/serialization | **Partially fixed**; writes now fail closed and use two synced slots, but stale-lock reclamation is not ownership-safe |
| P1015-05 transport lapse state | **Open medium**; unchanged |
| P1015-06 authenticated reply framing | **Open medium**; unchanged |
| P1015-07 local frame bound | **Open medium**; unchanged |
| P1015-08 TLS baseline/parser agreement | **Partially fixed** by the master merge and `5ebd00abe`; current-master conflict and differential-DER coverage remain |
| P1015-09 release gates | **Partially fixed**; `sdg_test.dis` is runner-discovered, but the TLS script and D2 oracle are still not gates |
| P1015-10 through P1015-12 | **Open**; unchanged |

Post-review remediation exists locally at
`4f7e8d2b7ebef99fcc5b4f4d5cf2b3bb361c7d5a` on
`security/pr1015-state-framing`.  It is not part of the reviewed PR pin and is
not treated as published.  It serializes/invalidate D2 state snapshots,
removes timestamp-based counter-lock stealing, marks transport loss non-live,
bounds and validates both sides of the sdg 9P relay, refuses unsafe lease
intervals, and rolls back failed staged writes.  Its focused D2 target/control
test passed 1/1, the expanded sdg suite passed 19/19, and the full Dis build
produced all 1,176 manifest modules.  It must be rebased with #1015 and reviewed
in that final tree before P1015-02 and P1015-04 through P1015-07, P1015-11 and
P1015-12 can be closed.

The counter lock needs one owner, not an age-only lock file.  At present a
process paused for more than 30 seconds can still own the critical section
while another allocator removes its lock as stale and enters.  The first can
then resume and remove the replacement owner's lock.  A forward wall-clock
step can trigger the same reclamation.  This invalidates the unconditional
claim that allocators “take turns.”  Prefer a single factotum-owned allocator
along with the Noise credential, or remove stale reclamation and fail closed;
an ownership token helps only if replacement/removal can be made conditional
on the same file identity.

Evidence added for this pin:

- `sdg_test.dis -v`: 16 passed, 0 failed (counter failure/concurrency and
  honest, wrong-PSK, malformed-key, and low-order handshake cases).
- `tests/host/tls_matrix_test.sh`: 12 passed, including TLS 1.2/1.3, HRR,
  P-256/P-384, refusal of wrong name/root/signature.
- `tests/tls_clientauth_test.sh`: 6 passed, including correct pin/client key
  and refusal of missing client certificate, wrong pin, and wrong key.
- Source re-check confirmed the remaining frame, D2, pairing, lease, and
  credential findings below are unchanged.  No hardware actuation was run.

The review covers the new credential lifecycle, TLS client authentication and
pinning, the Noise IKpsk2 client, the datagram-to-9P relay, and the D2 commander.
It also checks the branch against current InferNode master rather than treating
the older reviewed TLS implementation as the integration target.

## Disposition

The feature has a coherent file interface and the device-side D2 checks remain
the final safety boundary, but the commander is not ready to merge.  Four gates
are decisive:

1. Secret commander credentials are ordinary files.  This contradicts
   InferNode's factotum/secstore architecture and is a merge blocker.  The
   exact provider boundary remains an architecture decision after the
   styxbrick requirements review; operation-only factotum for every use is no
   longer asserted as a merge requirement.
2. A renewal can overtake `release` and reassert the released output until its
   lease expires.  The commander therefore does not presently keep the
   documented immediate-release contract.
3. The sdg client does not reject failed/low-order X25519 exchanges and does not
   fail closed when it cannot durably advance its initiation counter.
4. The branch conflicts with a substantially hardened and redesigned TLS
   implementation on master.  It needs a clean rebase and a fresh review of the
   resulting TLS path, not a mechanical conflict resolution.

## Findings

### P1015-01 — Blocker: commander secrets bypass factotum/secstore

`appl/cmd/brick.b:20-28`, `159-212`, `290-303`, `358-365`, and `779-800`
store and read these secrets below `/usr/$user/keyring/brick`:

- the TLS P-256 private scalar;
- the sdg X25519 private key;
- the sdg PSK; and
- the D2 HMAC key.

Mode 0600 is not the InferNode credential boundary.  It leaves cleartext
credentials in the ordinary namespace, bypasses encrypted secstore persistence,
and requires every process that can read the directory to receive raw signing,
handshake, and actuation authority.  The project rule is explicit:
`docs/DESIGN-PRINCIPLES.md` says keys live in factotum/secstore and that callers
should receive the operation, not the private key.

Required change:

- Persist all four secrets through factotum's protected persistence rather
  than ordinary files, selected by stable public attributes such as device
  identity and purpose.
- Keep factotum, provisioning and unrestricted D2 authority out of agent
  namespaces.  Run the trusted controller in a deliberately narrow namespace.
- Fix factotum `sync` so persistence failure reaches the writer, then make
  pairing local-first and retryable from one immutable, durably verified
  candidate before modifying the brick.
- Choose the runtime provider boundary explicitly.  A narrowly confined
  trusted controller retrieving runtime keys is consistent with styxbrick's
  present commander trust model.  Operation-only TLS or Noise providers are
  possible hardening.  Putting factotum in every D2 renewal is a real-time
  safety dependency and requires timing, overload, restart and multi-brick
  evidence; it is not required by this review without that evidence.

The following are public or non-secret state and may remain ordinary files:
the TLS/SPKI pin, the brick X25519 public key, the client certificate, and the
sdg monotonic counter.  The counter still needs the durability changes in
P1015-04.  Wi-Fi credentials must be factotum/secstore-backed.  The existing
`wpapsk` protocol returns a passphrase transiently to the trusted supplicant and
records that as technical debt; it is not precedent for persistent cleartext
`brick` credential files.

Tests required in every design: protected-store restart round trip; factotum
key selection by device; persistence-error propagation; interrupted pairing
and idempotent retry; absence of the four secrets from the ordinary namespace;
and confirmation that a confined agent cannot name factotum's control surface,
USB provisioning or ungranted brick operations.  An operation-only design must
also prove no RPC returns raw runtime key material.  A raw-runtime-key design
must prove that only the trusted controller namespace receives factotum and
that key buffers are not exposed through its served file tree.  See the
companion requirements review for the alternatives and their additional
gates.

### P1015-02 — High: an in-flight renewal can undo `release`

`appl/cmd/brick.b:575-599` snapshots all held outputs and spawns `renew()` in a
separate Prog.  `release` at lines 552-559 clears local `held` state and sends a
grant-free command without waiting for or invalidating that renewal.  A renewal
that already captured the old list can obtain its grant after `release`, take a
higher sequence number, and send `set` containing the released output.

The device keeps arming for `RELEASE`, so unlike `SAFE`, the later `set` is
valid.  The released output can therefore be driven again while the local file
reports `released`, until the stale renewal's lease expires.  This contradicts
the man page's promise that release takes the output to failsafe "at once".

Required change: serialize all D2 command creation and transmission, or attach
a generation to renewal snapshots and discard an obsolete renewal before it
can allocate a sequence number or write.  `safe` and `release` must form a
barrier against older work.  Do not rely only on sequence ordering: the stale
renewal can legitimately receive the later sequence.

Test required: a deterministic fake D2 server that parks a renewal at grant
read, applies `release`, then resumes the renewal.  No later command may contain
the released output, and the device oracle must remain at failsafe.  Exercise
the same barrier for `safe`, reconnect, and session replacement.

### P1015-03 — Medium: failed X25519 exchanges are mixed into the Noise state

`appl/lib/sdg.b:152-155` unconditionally passes `keyring->x25519()` to
`mixkey()`.  Current master deliberately returns nil for an all-zero shared
secret, following the applicable 9front hardening already recorded in
`docs/9FRONT-SECURITY-AUDIT.md`.  The sdg code treats nil as HKDF input and
continues instead of rejecting the peer.  The pinned branch predates even that
primitive-level rejection and accepts the all-zero output directly.

This weakens Noise IK's static-DH authentication under a low-order configured
server key or peer ephemeral key.  The PSK remains a separate authentication
factor, so this review does not claim an unauthenticated network takeover, but
the protocol must not silently collapse from two factors to one.

Required change: make `Hs.dh` return an error, reject nil or non-32-byte shared
secrets at every `es`, `ss`, `ee`, and `se` step, and validate all configured
key lengths before starting a handshake.

Tests required: the X25519 low-order representatives for both the configured
responder static key and message-2 ephemeral key; malformed key lengths; and a
valid Noise interoperability vector after the change.

### P1015-04 — Medium: the initiation counter fails open and is not serialized

`appl/lib/sdg.b:251-281` claims the counter is persisted before transmission,
but ignores create and write failure and returns the new counter anyway.  The
file is truncated in place, so a crash can leave it empty.  Two commander
processes can also read the same old value and transmit the same next value.

The consequences are replay-state loss and avoidable commander lockout after a
restart, clock step, restore, or concurrent mount.  They are availability and
state-integrity failures rather than a demonstrated D2 actuation bypass.

Required change: one owner must allocate counters under serialization, write a
temporary file, sync/close it, atomically replace the old state, read it back or
otherwise confirm the commit, and refuse to send if any step fails.  Factotum
may own this state when it owns the Noise handshake.

Tests required: unwritable store, short/failed write, crash at each update
point, backward clock, empty/corrupt prior state, and two concurrent allocators.

### P1015-05 — Medium: transport loss is recorded but the local session remains live

`appl/cmd/brick.b:650-669` calls `lapse()` when authority first becomes
unprovable, but the transport-error arm does not clear `d.armed`.  Consequently
`armedstr()` at lines 707-713 still reports `live`, tick handling keeps spawning
renewals, and a subsequent successful command may clear `failsince` without an
explicit re-arm if the device has not yet latched.

This does not defeat the brick's lease expiry, but it makes the commander state
and audit record disagree and violates the documented rule that an authority
lapse requires an explicit arm.

Required change: on the first unprovable transport error, atomically mark the
local commander disarmed, stop renewal, retain the lapse reason, and require a
new explicit `arm` after transport/session recovery.  The test must observe the
local files as well as the device oracle.

### P1015-06 — Medium: authenticated sdg replies are fed to 9P without frame validation

`appl/lib/sdg.b:539-573` matches the request id and writes `p[4:]` directly to
the mount pipe.  It does not verify that the inner 9P length equals the
authenticated plaintext length, that the tag matches the pending request, or
that the reply type is structurally valid for a 9P reply.

Authentication excludes an unauthenticated network forger, but a compromised,
buggy, or parser-confused paired device remains a protocol boundary.  A bad
length can desynchronize the pipe byte stream and deliver one datagram as
multiple or partial 9P messages.

Required change: before writing, require at least a complete 7-byte 9P header,
an exact inner length in `[7, MSIZE]`, the pending tag, and a reply type (or
`Rerror`) appropriate to the request.  Drop the session on a structural
violation rather than forwarding ambiguous bytes.

### P1015-07 — Medium: the relay's local frame reader can grow without bound

`appl/lib/sdg.b:440-460` appends to `buf` until the claimed 32-bit 9P size is
available.  A size below seven only breaks the parsing loop; a huge or negative
decoded size also leaves the buffer accumulating.

This input comes from the local mount side, not the hostile network, so the
finding is containment/robustness rather than a remote exploit.  Enforce
`7 <= size <= MSIZE` as soon as four bytes exist, terminate the relay on a bad
frame, and cap buffered bytes.  Add zero, 1..6, high-bit, and `MSIZE+1` tests.

### P1015-08 — Blocker: the TLS patch targets an obsolete security baseline

Current master and #1015 both modify `appl/lib/crypt/tls.b`, `module/tls.m`,
their mkfiles, the test manifest, and the Dis manifest.  Git reports the PR as
conflicting.  Since the feature base, master TLS has gained, among other work:

- server authentication that fails closed and server-controlled parser
  hardening;
- P-384 and post-quantum key exchange, including CNSA-strict behavior;
- multi-record handshake handling and HelloRetryRequest;
- certificate/IP-name verification changes; and
- connection-state lifetime and cancellation cleanup.

Required change: rebase first, preserve all current checks and state cleanup,
then re-review client CertificateRequest/CertificateVerify and SPKI pinning in
the merged state.  Pin verification must use the same parsed leaf/key object as
CertificateVerify, or carry differential malformed-DER tests; two independent
DER parsers selecting a key from the same certificate is unnecessary risk.

The intended pin semantics are otherwise sound: an exact SPKI pin deliberately
replaces CA/name validation, and proof of possession still comes from the
server's CertificateVerify.  The comparison at the reviewed pin is
fixed-length rather than early-exit.

### P1015-09 — Blocker: the security tests are not release gates

The PR adds only TLS interoperability coverage.  There are no InferNode tests
for the sdg handshake/relay or D2 commander.  `tests/tls_clientauth_test.sh` is
under `tests/`, while `run-tests.sh` discovers host tests only under
`tests/host`; no CI workflow invokes it.  It also compiles a `.dis` file with a
hand-written `limbo -o` command instead of using `mk install`, and reports a
missing OpenSSL as success rather than the repository's skip status.

Required gates before promotion:

- move/wire the TLS interop test into the host suite and use built manifest
  output;
- add malformed CertificateRequest, malformed DER/SPKI, wrong pin, correct
  key/wrong certificate, and modern-master TLS regression cases;
- add model-free sdg client tests for low-order DH, counter failures,
  authenticated malformed replies, and input frame bounds;
- add a scripted D2 fake/server oracle for renewal/release ordering, transport
  lapse, reconnect without auto-arm, failed writes, and command serialization;
- run the full InferNode suite after the rebase, not only the new tests.

### P1015-10 — Medium: pairing is not transactional

`appl/cmd/brick.b:159-212` changes the brick's TLS peer before all local and
remote sdg/D2 material is durably committed.  Later failures can leave the
device and commander with different generations of keys, requiring physical
USB repair.  The same concern applies to writing a new device PSK/D2 key before
factotum/secstore persistence succeeds.

Required change: generate and persist a complete pending credential set first;
apply it to the device; verify the resulting public identity/status; then
atomically promote the pending set locally.  If the device offers no staging
transaction, document and test an idempotent USB recovery path that never
silently selects a mixed generation.

### P1015-11 — Low: failed output writes leave hidden staged authority

At `appl/cmd/brick.b:566-574`, the requested value and `held` flag are changed
before `d2send`.  A failed write therefore remains in the renewal/next-arm
state even though the caller received an error.  Depending on the failure, a
later arm can actuate a value whose original write failed.

Required change: either roll local state back on failure, or make staging an
explicit, separately named interface whose readback truthfully reports it.
The ordinary value file should not turn a failed RPC into deferred actuation.

### P1015-12 — Low: commander timing options accept unsafe values

`-l` accepts zero, negative, and excessively small values, and
`d2clock(leasems / 5)` can become a zero-delay loop.  Validate the requested
lease before starting any Prog, enforce the device-reported constraints and a
nonzero clock interval, and test the boundary values.

## Companion firmware dependencies

The current styxbrick implementation pin
`e23114cb675b5ada72f60f3903596cdfc44d0525` closes G1, G2, F3/S1, F4 and F5.
It was independently rebuilt against mbedTLS 3.6.6 and rerun in Ubuntu 24
amd64: the unchanged host suite passed under ASan/UBSan, including Styx, D2,
sdg, configuration A/B recovery, X25519 and admission; all mutation-suite
mutants were caught; and 10-second libFuzzer smoke campaigns for Styx, sdg and
configuration completed without a crash (622,882, 992 and 305,737 executions,
respectively).

Two bounded firmware residuals remain explicit.  BLE admission F2 is relevant
only when the optional BLE transport is built and is not fixed at this pin.
The committed F6 initiation-flood measurement did not lapse D2, but a
same-address attacker can consume reconnect slots (4/8 observed) and delays
other reconnections by about 7.6 seconds; changing that availability policy is
a firmware design decision, not an InferNode client patch.  Neither residual
grants an unauthenticated actuator command.  Hardware/bench actuation was not
independently rerun for this InferNode review.

These device findings do not excuse the InferNode client findings above.  The
black-channel design deliberately requires each side to keep its own invariants.

## Evidence run

- Source review of every PR file and the current corresponding master paths.
- Cross-check against styxbrick `docs/review/GATE4-REVIEW-2026-10-30.md`,
  `SDG-REVIEW-2026-10-30.md`, their reproducers, D2-SPEC, STYX-DGRAM, the
  security model, and the later proposed revisions.
- Three standard `mk install` builds in a clean detached checkout of the exact
  PR head: `appl/lib`, `appl/cmd`, and `tests`; all completed successfully on
  macOS arm64.  This proves compilation only.
- Merge-tree review against current master, including the overlapping TLS and
  manifest paths.
- Independent styxbrick `e23114c` host rebuild with mbedTLS 3.6.6, ASan/UBSan,
  the complete mutation suite and three libFuzzer smoke campaigns.

Not run and not claimed: a live model campaign, hardware/bench actuation, or
hostbrick D2 integration.  The sdg impairment and wired TLS host gates are
covered by the candidate regressions above.

## Exit criteria

PR #1015 may be promoted from draft only when all Blocker and High items are
fixed with regressions, every Medium item is fixed or explicitly accepted with
a bounded deployment argument, the branch is rebased and the merged TLS path
is re-reviewed, the companion firmware baseline is named, and the full CI plus
the relevant bench/impairment matrix is green.  Record the new reviewed commit
here; do not silently treat later pushes as covered by this review.
