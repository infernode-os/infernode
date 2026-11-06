# Security review: post-report remote delta

**Reviewed range:** InferNode `008e74363..c7d892104`  
**Disposition:** two agent-containment defects fixed on
`security/0.9.0-patch` by `dc2a35402`; focused gates pass  
**Method:** source review and model-free target/control tests; no live-model
campaign

This is the delta review required by the security ledger after assimilating
the remote work that landed after the report-pack and PR #1069 reviews.  It
covers the new Veltro git and Xenith work, namespace-current-directory fix,
Claude gateway isolation, keyring collector fix, mobile display changes, and
the formal-verification correction.  The native camera code did not change in
this range.  InferNode still does not contain `gefs` at the reviewed pin.

## Findings fixed in the release branch

### DR-01 — High, hosted: git worker escaped the repository

`appl/veltro/tools/git.b` starts its write worker before namespace restriction
so it can update the user's repository.  The new `add` and `rm` operations
passed model-supplied names directly to that unrestricted worker.  Absolute
names and `..` therefore named any file visible to the host-side emulator:
`add` could put an ungranted file into a blob and a later commit/push could
exfiltrate it; `rm` could delete an outside file after a matching poisoned
index entry.  Read-side `cat` and ref operations also concatenated unchecked
paths into the git/fs hierarchy.  A host symlink below the repository was a
second escape because the pre-restriction worker had not entered `NODEVS`.

The release-branch fix:

- records the absolute directory in which the tool started and accepts only
  normalized relative work-tree paths below it;
- refuses `..`, absolute paths, empty components, and every `.git` component;
- validates object hashes, branch/ref names, remote names, and every path
  loaded from the persistent Inferno staging index;
- forks the read and write workers' namespace groups and applies `NODEVS`, so
  they retain the already-open repository view without device attach or host
  symlink traversal authority;
- refuses deletion of the current branch, checks a fast-forward merge for
  local changes, and publishes checkout/merge refs only after the target tree
  was installed.

`tests/host/veltro_git_security_test.sh` constructs traversal, absolute,
symlink, read, remove, and ref attacks against a real git tool endpoint.  Every
attack is refused, the outside sentinel remains unchanged, and a local add
still succeeds.

### DR-02 — Medium, conditional: Xenith `contentcmd` remained allowed

Commit `b4e3cc49a` correctly changed created window names to labels, restricted
body reads to the granted file or an exact `+Errors` case, and replaced the
arbitrary ctl pass-through with an allowlist.  Its description says document
commands are refused, but the allowlist still contained `contentcmd`.
Xenith implements that verb by calling the active document renderer's command
method; the web renderer includes navigation and reload operations.  If a
user or another UI action attached a document to the agent-owned window, the
agent could drive it in Xenith's desktop namespace despite the stated
layout-only policy.

The release branch removes `contentcmd`.  The remaining commands affect only
the owned window's layout or display state.  The source regression
`tests/host/veltro_xenith_policy_test.sh` pins both the denied command set and
the label/exact-`+Errors` checks.

## Reviewed changes with no release blocker

### Restricted current directory

Commit `ae452362d` fixes a real namespace escape: after restriction, the
process previously retained its pre-restriction current-directory channel, so
a relative `../` lookup could see a sibling outside the grant.  Reopening the
saved directory name in the restricted namespace, with `/` as the fail-closed
fallback, matches the namespace capability model.  This composes correctly
with the existing lower-case path checks, `NODEVS`, shadow directories, and
hidden cowfs metadata.

### Git staging and git/fs

Commits `71b71d85a`, `a43acd844`, `027428efc`, and `f4b88671d` repair staging,
argument order, ref refresh, and repository selection.  Keeping Inferno's
text staging file at `.git/inferno-index` avoids corrupting a host Git binary
index, and deriving an empty staging state from HEAD preserves untouched
files.  The new authority-bearing worker was the source of DR-01; with that
fixed, its remote password is requested from factotum for the push and is not
written to the repository, staging file, or product configuration.

The git library suite passes 40/40 after the changes.

### Keyring collector lifetime

Commit `1b7cb53d8` stores the creating algorithm's `SigAlgVec` in each private
key, public key, and certificate, and uses it when freeing native key
material.  This avoids dereferencing a collected Limbo `SigAlg` wrapper.  The
vectors themselves are allocated once during keyring initialization and
remain reachable from the process-wide algorithm registry, so the replacement
pointer has the required lifetime.  The emulator now also refuses to route a
collector error through a user Prog's exception handler.

After rebuilding `libinterp.a` and relinking the emulator (an emulator-only
relink had initially exercised the stale library), `keyring_sweep_test`
passes Ed25519 and ML-DSA, 2/2.

### Claude gateway session isolation

Commit `14766ebcf` removes project instructions, Git state, auto-memory, and
organization memory from Claude-gate turns and disallows the CLI's built-in
tools.  The release branch additionally gives every turn its own empty
temporary directory and removes it after normal completion, error, or stale
turn cancellation; concurrent turns no longer share a working directory.
Python compilation succeeds.  The HTTP mock suite could not run in this
workspace because `aiohttp` is not installed and reported its documented
skip.

The gateway is loopback-only and does not copy its authentication into
InferNode.  It does, however, use the host Claude CLI's vendor-managed
subscription login.  That credential is outside factotum/secstore.  This is
an explicit boundary for an optional host connector, not a second InferNode
credential store.  A policy requiring literally every credential on the host
to be factotum/secstore-backed must exclude this connector or replace
subscription CLI authentication with a factotum-mediated provider flow; the
current CLI offers no such flow.  InferNode-owned Git, TLS, Wi-Fi, D2, and
agent service credentials remain subject to the factotum/secstore rule.

### Staged changes in the Agent window

The Agent window lists cowfs changes and requires the user's explicit Apply
or Discard.  Overlay selection is scoped by the activity id plus a hyphen;
the authoritative `basepath` is in `.cowmeta`, which tool namespaces hide
from the agent.  Apply runs in the UI process only after the user action.
No new path from model output to a promotion destination was found.

### Mobile and formal-verification changes

The iOS/iPad work changes simulator coverage, resize handling, and layout; it
adds no device, file, network, or credential authority.  Its new dimensions
come from the local SDL window/safe-area events, not remote protocol input.

Commit `d4be11b45` is a security-positive correction to evidence, not a
runtime containment change.  It identifies that the earlier small TLA+ run
could not reach namespace copy, adds reachability/vacuity probes, and narrows
claims unsupported by the models.  The checked-in configuration and result
artifacts were reviewed.  The reported five-hour, 7.1-billion-generated-state
run was not repeated during this delta review.

## Camera and GEFS status

There is no camera source change in `008e74363..c7d892104`; the gates in
[CAMERA-SECURITY-REVIEW.md](CAMERA-SECURITY-REVIEW.md) still apply before any
real imagery source is enabled.  Repository search and history inspection
find no InferNode `gefs` implementation at `c7d892104`.  The 9front audit's
only pinned GEFS entry remains an inapplicable dead-code removal.  A GEFS
review cannot be source-pinned until that code or a PR exists in this
repository.

## Verification record

- full macOS arm64 platform libraries: build passes;
- macOS headless emulator relink: passes;
- `git_test`: 40 passed;
- `keyring_sweep_test`: 2 passed;
- `veltro_git_security_test.sh`: passes;
- `veltro_xenith_policy_test.sh`: passes;
- Veltro git and Xenith modules: compile and install;
- `python3 -m py_compile tools/claude-gate/claude_gate.py`: passes;
- Claude-gate HTTP mock suite: skipped, `aiohttp` unavailable;
- post-merge native virt cross-build: 2 passed, 0 failed;
- post-merge strict native fuzz seeds 100–103: 4 passed across four VMs,
  leak checking enabled;
- post-merge hosted `kill_deadserver_test`: 4/4 tests passed in each of four
  consecutive runs.

The earlier broad host-suite attempt remains non-green for two unrelated mock
backend startup failures (`agent_delegation`, `agentloop_characterization`)
and was stopped during the long bare-metal phase after the focused kernel
gates passed.  It must not be represented as a full-suite pass.
