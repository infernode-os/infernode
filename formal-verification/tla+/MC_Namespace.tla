--------------------------- MODULE MC_Namespace ---------------------------
(***************************************************************************
 * Model Checking Configuration for Namespace Specification
 *
 * This module configures the TLC model checker with appropriate
 * constants and properties to verify.
 *
 * Usage:
 *   tlc MC_Namespace.tla -config MC_Namespace.cfg
 *
 * Or with the TLA+ Toolbox, select this module as the model.
 ***************************************************************************)

EXTENDS NamespaceProperties, IsolationProof, TLC

\* =========================================================================
\* MODEL CONSTANTS
\* =========================================================================

\* Constants are declared in Namespace.tla (imported via EXTENDS chain).
\* Their values are assigned in the .cfg file via CONSTANT directives.
\* No re-declaration needed here.

\* =========================================================================
\* STATE CONSTRAINT
\* =========================================================================

\* Limit state space for finite model checking
StateConstraint ==
    /\ Cardinality(processes) <= MaxProcesses
    /\ next_pgrp_id <= MaxPgrps + 1
    /\ next_chan_id <= MaxChannels + 1

\* =========================================================================
\* ACTION CONSTRAINT
\* =========================================================================

ActionConstraint ==
    /\ next_pgrp_id' <= MaxPgrps + 1
    /\ next_chan_id' <= MaxChannels + 1

\* =========================================================================
\* INVARIANTS TO CHECK
\* =========================================================================

\* Core type safety
INVARIANT_TypeOK == TypeOK

\* Primary safety invariant
INVARIANT_Safety == SafetyInvariant

\* Full correctness including isolation
INVARIANT_Full == FullCorrectness

\* Non-trivial isolation properties
INVARIANT_Isolation == NamespaceIsolation
INVARIANT_IsolationTheorem == NamespaceIsolationTheorem
INVARIANT_NonPropagation == UnilateralMountNonPropagation
INVARIANT_CopyFidelity == CopyFidelity
INVARIANT_PostCopySoundness == PostCopyMountsSound
INVARIANT_NoViolation == NoIsolationViolation

\* =========================================================================
\* VACUITY PROBES (run-verification.sh requires TLC to VIOLATE these)
\* =========================================================================

\* Every isolation invariant above is an implication whose antecedent needs a
\* pgrp with a parent.  If no copy is reachable under the chosen constants,
\* they all hold vacuously.  That happened: with MaxChannels=3 the first
\* process took both channels and ForkWithForkNS was never enabled, so the
\* exhaustive 19.3M-state small run checked the theorem on zero copies.
\* run-verification.sh model-checks each probe first and refuses to run
\* unless TLC finds a violation (i.e. the state is reachable).

CopyNeverHappened == \A pg \in PgrpId : pgrp_parent[pg] = 0

LivePostCopyMountNeverHappened ==
    ~(\E pg_child \in PgrpId :
        LET pg_parent == pgrp_parent[pg_child] IN
        /\ PgrpInUse(pg_child) /\ pg_parent # 0 /\ PgrpInUse(pg_parent)
        /\ \E path \in PathId, cid \in ChannelId :
            /\ <<path, cid>> \in post_copy_mounts[pg_parent]
            /\ cid \notin copy_snapshot[pg_child][path]
            /\ cid \in mount_table[pg_parent][path])

\* =========================================================================
\* PROPERTIES TO CHECK
\* =========================================================================

\* Mount locality (temporal)
PROPERTY_MountLocality == MountLocalityProperty

\* Progress
PROPERTY_Progress == Progress

\* =========================================================================
\* SYMMETRY OPTIMIZATION
\* =========================================================================

\* Process IDs are symmetric (any permutation is equivalent)
ProcessSymmetry == Permutations(1..MaxProcesses)

\* Channel IDs are symmetric
ChannelSymmetry == Permutations(1..MaxChannels)

\* Path IDs are symmetric
PathSymmetry == Permutations(1..MaxPaths)

\* =========================================================================
\* DEBUG HELPERS
\* =========================================================================

\* Alias for printing state in error traces
Alias == [
    procs |-> processes,
    proc_pgrp |-> process_pgrp,
    pgrps |-> {pg \in PgrpId : pgrp_exists[pg]},
    pgrp_refs |-> [pg \in {p \in PgrpId : pgrp_exists[p]} |-> pgrp_refcount[pg]],
    mounts |-> [pg \in {p \in PgrpId : pgrp_exists[p]} |->
                    [path \in PathId |-> mount_table[pg][path]]],
    slash |-> [pg \in {p \in PgrpId : pgrp_exists[p]} |-> pgrp_slash[pg]],
    dot |-> [pg \in {p \in PgrpId : pgrp_exists[p]} |-> pgrp_dot[pg]],
    parents |-> [pg \in {p \in PgrpId : pgrp_exists[p]} |-> pgrp_parent[pg]],
    post_mounts |-> [pg \in {p \in PgrpId : pgrp_exists[p]} |-> post_copy_mounts[pg]],
    snapshots |-> [pg \in {p \in PgrpId : pgrp_exists[p] /\ pgrp_parent[p] # 0} |->
                      copy_snapshot[pg]],
    chans |-> {c \in ChannelId : chan_exists[c]},
    chan_refs |-> [c \in {ch \in ChannelId : chan_exists[ch]} |-> chan_refcount[c]]
]

=============================================================================
