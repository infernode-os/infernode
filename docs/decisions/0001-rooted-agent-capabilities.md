# ADR 0001: Root Agent Filesystem Authority in 9P Capabilities

Status: Proposed

Date: 2026-08-24

Tracking: [INFR-410](https://nervsystems-team.atlassian.net/browse/INFR-410)
(Epic), with INFR-405, INFR-406, INFR-407, INFR-408, and INFR-409

Evidence: [PR #534](https://github.com/infernode-os/infernode/pull/534),
run `RUN-20260823T182945Z`

## Context

Veltro treats a process namespace as its authority. A child agent should see
only the tools, paths, commands, and services deliberately delegated by its
parent. Grants must shrink monotonically down the process tree.

The audited escape-room regression demonstrated that mounting a delegated
scratch tree at a name inside a larger namespace did not make that mount point
a confinement root. An adversarial child supplied parent components to
filesystem tools and read synthetic canaries outside the delegated subtree.
The same run also showed that an invalid path request could be reported while
child provisioning continued, and that an omitted tool list could expand to a
broad default set.

The failure did not require a kernel exploit, a forged audit record, or a
network escape. It used ordinary pathname and delegation behavior. This makes
the immediate defects important, but it also identifies a more general design
requirement: filesystem authority cannot be represented by an ambient path
plus a promise that every caller will remain beneath it.

## Decision

Agent filesystem authority will be represented by rooted 9P capabilities, not
by arbitrary paths in the tool process's ambient namespace.

A filesystem grant names a file tree whose attach root is the upper boundary
of that authority. Filesystem tools walk from a fid rooted at that attachment.
They do not open caller-controlled absolute paths in an ambient namespace.
A walk at the grant root cannot reach a parent tree.

Namespace construction and child launch will be one fail-closed transaction:

1. Parse the complete requested grant.
2. Canonicalize its tool, path, command, network, and budget fields.
3. Reject the request unless every field is a subset of parent authority.
4. Construct the child namespace and rooted attachments without running the
   child.
5. Inspect the effective namespace and compare it with the validated grant.
6. Record the requested and effective authority in the audit chain.
7. Launch the child only after every preceding step succeeds.

Any error aborts the transaction. There is no partially provisioned child and
no successful activity identifier after a failed provisioning write.

## Required Invariants

### Rooted filesystem walks

- Each delegated file tree has an explicit attachment root.
- A client cannot walk above that root, including through `..`, mount, union,
  or rebinding behavior.
- Filesystem tools accept a grant name and a relative name within that grant.
  They do not interpret an agent-provided namespace-absolute path.
- Rejecting empty, absolute, dot-containing, or otherwise non-canonical names
  at tool boundaries remains required defense in depth. It is not the primary
  confinement mechanism.

The concrete file interface should remain small and textual. One acceptable
shape is:

```text
/mnt/agentfs/
    scratch/
        ... delegated tree ...
    source/
        ... read-only delegated tree ...
```

The names `scratch` and `source` identify grants. The trees below them come
from separate rooted attachments. Their parents are service structure, not a
route into the tool server's namespace.

### Runtime and data separation

Files needed to load and run Limbo modules are runtime authority. Files made
available to agent tools are data authority. Loading a tool module must not
make the module loader's namespace available through `read`, `list`, `find`,
`search`, `grep`, `write`, or `edit`.

An explicitly granted execution tool must run in a namespace constructed for
that execution. It cannot regain ambient filesystem authority through the
tool server or its parent process group.

### Monotonic delegation

For every authority dimension, a child grant is a subset of its parent's
effective grant:

```text
child tools      <= parent tools
child files      <= parent files
child commands   <= parent commands
child network    <= parent network
child budgets    <= parent budgets
```

An omitted field grants nothing. Callers that want a conventional set must
request a named, documented set explicitly. Defaults cannot expand authority.

### Truthful failure

Authority absent from the effective namespace is unnameable. The system does
not rely on a later policy denial for a visible object. Invalid grant syntax
fails before launch and is distinct from a valid grant for an absent object.

### Auditable construction

The audit chain records, at minimum:

- a digest of the complete requested grant;
- the validation result;
- a digest of the effective namespace manifest;
- the parent and child activity identifiers;
- the final provisioning result; and
- the first child lifecycle event, only after successful provisioning.

The exact namespace manifest is retained in sealed private evidence so its
digest can be independently verified. Public evidence is a separately
generated redacted artifact. Private result directories and files are created
with restrictive permissions from the start.

Audit capture does not make a failed namespace safe. If required audit setup
or signing fails, security-sensitive provisioning also fails.

## Consequences

### Benefits

- Confinement no longer depends on every filesystem tool reproducing pathname
  containment correctly.
- Delegation remains a Plan 9 namespace operation rather than a second policy
  engine.
- The same rooted service can be tested independently and reused by current
  and future tools.
- Requested authority, effective authority, and observed activity can be
  compared directly.
- A child creation result becomes reliable evidence that provisioning
  completed.

### Costs

- Existing tools that accept ambient absolute paths need a compatibility and
  migration plan.
- Tool and execution namespaces must be separated deliberately.
- Child creation needs a staging and verification phase before launch.
- Tests must cover composed namespaces and actual tool calls, not only helper
  functions or direct `stat` operations.

### Compatibility

Compatibility aliases may translate an old path into a named grant only at a
trusted caller boundary. They must resolve the grant before child launch and
must not pass the old path through to a filesystem tool. Compatibility mode
must never weaken the rooted-walk invariant.

## Verification Requirements

The implementation is not complete until automated tests demonstrate:

- parent walks fail at every grant root;
- absolute and non-canonical tool arguments fail;
- mount and union composition cannot expose a parent tree;
- mixed valid and invalid grants create no child;
- omitted authority fields do not expand authority;
- child grants cannot exceed parent grants in any dimension;
- shell and execution tools observe only their constructed namespaces;
- requested and effective authority records verify against retained manifests;
- delegated child actions appear in the verified audit timeline; and
- private evidence modes and public redaction are deterministic.

The external
[escape-room campaign](https://github.com/infernode-os/infernode-escape-room)
remains a release criterion. Unit and emulator tests are necessary but do not
replace an end-to-end adversarial run.

## Rollout

1. Fix atomic provisioning and remove authority-expanding defaults
   (INFR-405).
2. Introduce rooted filesystem grants and migrate filesystem tools
   (INFR-407).
3. Make private and public evidence handling deterministic (INFR-406).
4. Derive complete multi-actor timelines from verified audit records
   (INFR-408).
5. Retain namespace manifests and add independent campaign observation
   (INFR-409).
6. Re-run the smoke protocol and traversal regression before any broader
   campaign.

## Non-Goals

This decision does not claim protection against kernel vulnerabilities,
hardware attacks, covert channels, or denial of service. It does not replace
resource budgets or network isolation. It defines how delegated filesystem
and tool authority must be represented, constructed, and verified.
