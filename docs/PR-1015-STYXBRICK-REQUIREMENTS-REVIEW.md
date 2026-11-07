# PR #1015: styxbrick requirements and credential-boundary review

Status: **requirements review complete; architecture decision open**

This is the cross-repository review requested before changing PR #1015's
credential design.  It deliberately separates requirements from a preferred
implementation.  The earlier security review correctly objected to persistent
cleartext secrets under `/usr/$user/keyring/brick`, but went too far when it
prescribed operation-only factotum protocols for every key without first
accounting for styxbrick's provisioning and real-time requirements.

## Reviewed pins and method

- InferNode PR #1015: `b66d0f2944ca98ecd141d21f483c021b4b64478d`.
- InferNode master: `507950f904806c7c8d3d93bb9e41d7931add9f57`.
- styxbrick implementation and final review-fix evidence:
  `e23114cb675b5ada72f60f3903596cdfc44d0525`.
- styxbrick review follow-up documents:
  `438c0c7e974e168021da5b10c2f1a6f23716c83e`.
  This branch and current styxbrick main both descend from `review-3`
  (`93a90ba`) but have diverged: current main contains the firmware fixes and
  rerun evidence, while the follow-up branch contains the consolidated threat
  model and proposed longer-term revisions.  Neither pin alone is a complete
  review record.

The review traced `brick pair`, TLS, sdg, D2, factotum persistence and
namespace construction against styxbrick's README, `D2-SPEC.md`,
`STYX-DGRAM.md`, `DEPLOYMENT.md`, `SECURITY-MODEL.md`, review reports, source,
and committed bench records.  A local styxbrick test run was attempted, but
the required mbedTLS archive was not installed and its host Makefile expects a
Linux libstdc++ layout; the committed review-fix evidence was therefore
source-checked but not independently rerun on this macOS host.

## Requirements established by styxbrick

### Trust and authority

- The network is hostile.  USB is the privileged provisioning path.
- The current baseline explicitly trusts the commander host with every key it
  holds.  Compromise of that commander permits actuation, subject to D2's
  device-side freshness, session and lease rules.
- A companion computer is an untrusted forwarder and must not receive the USB
  provisioning path or the keys.
- Physical capture of the brick is total compromise at the current baseline:
  its flash is not secret and secure boot is not enabled.
- A Veltro agent is a distinct, less-trusted principal.  It must not receive
  ambient factotum, keyring, USB provisioning or unrestricted `brick d2`
  authority merely because the trusted commander has them.

This means raw key material in a deliberately trusted `brick` controller is
not, by itself, a violation of styxbrick's threat model.  Persisting that
material as ordinary namespace files is still contrary to InferNode's
credential architecture and unnecessarily enlarges the set of processes that
can acquire it.

### Key ownership and provisioning

- The brick generates its TLS P-256 and sdg X25519 private keys using its TRNG;
  they never leave the brick.
- The commander owns its TLS P-256 and sdg X25519 private keys.  Their public
  identities are installed on the brick over USB.
- The sdg PSK and D2 HMAC key are generated on the commander and written to the
  brick over trusted USB.  The PSK is per pairing; the D2 key is per brick in
  the current design.
- `sdg.ctr` is durable, non-secret anti-replay state.  It must not be rolled
  back, shared by independent allocators, or restored independently of its
  pairing.
- Wi-Fi credentials are also delivered over USB.  They need protected
  commander-side sourcing if retained, but the present command reads them
  transiently from standard input rather than keeping a `brick` credential
  file.

Consequently, an absolute requirement that the PSK and D2 key “never enter
`brick`” is incompatible with the current provisioning protocol unless
factotum itself drives USB or the firmware pairing protocol changes.  Even an
operation-only runtime design needs an explicit, narrowly scoped provisioning
operation or a new key-agreement protocol.

### D2 is a real-time availability boundary

The device defaults to `tau = 200 ms`, limits grant issuance to 20 per second,
and requires the commander to use exactly one network round trip and compute
promptly.  InferNode defaults to a 500 ms lease and renews every lease/5, or
every 100 ms; a shorter device `leasemax` shortens that interval.  Styxbrick's
bench evidence treats false failsafe as a safety-relevant availability event,
not merely a benign authentication failure.

Putting factotum in every D2 grant/command renewal would therefore add a shared
service, its scheduler latency, its restart behavior and its RPC queue to the
hot safety path.  With several bricks, all renewal streams could depend on one
factotum.  This may be made sound, but it is not automatically safer: it needs
latency distributions under load, fault injection, restart behavior and
multi-brick lease-lapse tests before adoption.  The current evidence does not
support making it a merge requirement.

TLS CertificateVerify and an sdg Noise handshake are much less frequent.
Operation-only providers are technically more plausible there, although TLS
currently accepts a raw 32-byte P-256 scalar and sdg would require factotum to
run the stateful IKpsk2 handshake or return session keys.  Both are interface
changes, not substitutions of one file read.

### Pairing is not transactional

`brick pair` presently writes the peer pins, sdg peer, sdg PSK and D2 key in
separate operations, and records commander state in separate files.  The
firmware's A/B configuration store makes each individual save durable, but it
does not make the whole cross-device pairing atomic.  An interruption can
leave the two ends describing different pairings.

A sound minimum is local-first and retryable:

1. generate or stage a complete candidate pairing on the commander;
2. persist and verify that candidate synchronously;
3. provision the brick from the same immutable candidate; and
4. make retry/recovery use that candidate rather than silently generating a
   replacement.

True device-side atomic pairing needs a staged/commit interface or a combined
configuration transaction.  A naive single text record may not fit the
firmware's 256-byte file data bound, so that change must be designed in the
styxbrick interface rather than assumed in InferNode alone.

### Factotum capabilities and persistence

Factotum's authority is primarily the ability to name and use its RPC service
in a namespace.  A custom `proto=brick` that returns raw bytes can improve key
selection and lifecycle handling, but it does not authenticate the `brick`
executable: any process with the same factotum RPC capability can request the
same operation.  Conversely, an operation-specific protocol is useful only if
the capability can be delegated without also granting broader factotum use.

InferNode already recognizes this limitation: shared factotum RPC can expose
unrelated credentials, so agent namespaces keep it out by default and grant it
only to selected fixed-function tools.  The controlling security boundary for
#1015 must remain a narrow trusted controller namespace, not an assertion that
the name of a factotum protocol identifies its caller.

The current persistence API also has a correctness defect that must be fixed
before pairing relies on it.  `echo sync > /mnt/factotum/ctl` waits for
`dosave()`, but the persistence thread always replies zero and the ctl write
always succeeds even when saving to the keyfile or secstore failed.  Pairing
therefore cannot presently prove that its locally generated candidate is
durable before it modifies the brick.

On a hosted node, factotum can use encrypted keyfile/secstore persistence.  On
the current headless bare-metal node, factotum intentionally starts unlocked
and empty and receives keys at boot.  A #1015 design must state whether that
platform is unsupported, obtains keys from a boot provisioner, or adopts a
new noninteractive protected-store unlock mechanism; silently requiring a
secstore prompt is not viable.

## Architecture choices

| Choice | Security gain | Cost and residual risk |
|---|---|---|
| **A. Protected storage, trusted controller**: store secrets in factotum/secstore; allow the narrowly confined trusted `brick` controller to retrieve and retain those it needs | Removes persistent ordinary secret files; fits the current commander trust model and wire protocol; keeps factotum out of the D2 hot path | Raw secrets exist transiently in the trusted process; shared factotum RPC must not enter agent namespaces; memory compromise of the commander remains in scope by design |
| **B. Hybrid provider**: protected storage; a narrow provisioning export; operation-only TLS and possibly sdg; D2 key retained by a dedicated trusted controller | Reduces exposure of long-term signing/handshake keys without adding factotum to every D2 renewal | New TLS/sdg interfaces and tests; provisioning still needs an explicit secret path; more components and failure modes |
| **C. Fully operation-only factotum**: factotum performs TLS, Noise, D2 MAC and provisioning | Strongest separation from the controller process if RPC capabilities are also narrowly delegated | Large redesign; factotum becomes a real-time safety dependency; current provisioning cannot satisfy it without direct USB access or firmware changes; must prove timing and recovery on multi-brick workloads |
| **D. Pairing/owner-credential redesign** | Can reduce cable operations, improve revocation and eventually remove some shared-secret provisioning | Cross-repository wire and firmware change; overlaps styxbrick's post-1.0 owner-key roadmap; should be a deliberate protocol revision, not an incidental PR #1015 fix |

These are not mutually exclusive over time.  The review supports A as the
minimum correction and identifies B as a plausible hardening direction, but
does not select between them.  C or D require new threat, timing and deployment
evidence before they can replace the present design.

## Decisions required before implementation

1. Is the trusted `brick` controller inside the commander trust boundary, as
   styxbrick specifies, or is same-user process compromise a new threat that
   #1015 must resist?
2. Which platforms must support persistent unattended keys at first release?
3. Is factotum allowed in the D2 renewal path, and what measured latency and
   failure budget would make that acceptable?
4. Is PR #1015 allowed a narrow provisioning export, or must provisioning be
   redesigned with styxbrick now?
5. Should TLS and sdg provider APIs be part of #1015, or follow after the
   storage, pairing and containment fixes?
6. Do we first add device-side staging/commit, or accept documented local-first
   recovery for the initial release?

## Corrections to the original security disposition

- **Still a blocker:** persistent private keys, PSKs and D2 keys as ordinary
  files under `/usr`.
- **Still a blocker:** the release/renew race and the other independent High or
  merge-gate findings in the main #1015 review.
- **Withdrawn as an unsupported requirement:** every cryptographic operation
  must be performed by factotum before #1015 can merge.
- **Withdrawn as impossible under the current protocol:** the PSK and D2 key
  must never enter the trusted provisioning controller.
- **New prerequisite:** make factotum `sync` report persistence failure and
  define crash-recoverable, local-first pairing before relying on it as the
  credential store.
- **New review gate if factotum enters D2's hot path:** bench timing, overload,
  restart, multi-brick and false-failsafe evidence.

This review changes the proposed remedy, not the finding that #1015 is not yet
ready to promote or merge.
