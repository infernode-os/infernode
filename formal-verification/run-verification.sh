#!/bin/bash
#
# Inferno Kernel Namespace Formal Verification Runner
#
# This script runs the TLC model checker to verify namespace isolation properties.
#
# Prerequisites:
#   1. Java 11+ installed (java -version)
#   2. TLA+ tools downloaded:
#      curl -L -o tla2tools.jar \
#        "https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar"
#
# Usage:
#   ./run-verification.sh [small|medium|large]
#
# Verification levels:
#   small  - 2 processes, 2 pgrps, 4 channels, 1 path (exhaustive; see results/)
#   medium - 3 processes, 4 pgrps, 4 channels, 3 paths (not exhaustible so far)
#   large  - 4 processes, 5 pgrps, 5 channels, 3 paths (not attempted)
#
# Every pgrp costs two channels (slash and dot) in the spec, so a copy
# (ForkWithForkNS/ForkWithNewNS) is only enabled while at least two channel
# ids remain.  The small level used to have MaxChannels=3: the first process
# took two, no copy was ever enabled, and every isolation invariant was
# vacuous over the whole 19.3M-state run.  Before the main run this script
# now checks that a copy, and a post-copy mount while parent and child are
# both live, are reachable under the chosen constants, and refuses to run
# otherwise.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TLA_DIR="$SCRIPT_DIR/tla+"
RESULTS_DIR="$SCRIPT_DIR/results"

# Check for tla2tools.jar
if [[ ! -f "$SCRIPT_DIR/tla2tools.jar" ]]; then
    echo "ERROR: tla2tools.jar not found!"
    echo ""
    echo "Please download it first:"
    echo "  cd $SCRIPT_DIR"
    echo '  curl -L -o tla2tools.jar "https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar"'
    exit 1
fi

# Check for Java
if ! command -v java &> /dev/null; then
    echo "ERROR: Java not found! Please install Java 11 or later."
    exit 1
fi

# Parse verification level
LEVEL="${1:-small}"

case "$LEVEL" in
    small)
        MAX_PROC=2
        MAX_PGRP=2      # one copy per behaviour
        MAX_CHAN=4      # 2 for the first pgrp, 2 for the copy (5, leaving one to allocate
                        # after the copy, did not finish on a 16 GB host: 60M+ distinct
                        # states at depth 12 with the queue still growing)
        MAX_PATH=1      # 2 paths did not finish either
        MAX_MOUNT=4
        MAX_CHANREF=2   # channel refcount bound; with the old implicit bound of 8
                        # this configuration passed 250M distinct states (depth 16,
                        # 21 GB of state) without finishing
        HEAP="${TLC_HEAP:-8g}"
        ;;
    medium)
        MAX_PROC=3
        MAX_PGRP=4
        MAX_CHAN=4
        MAX_PATH=3
        MAX_MOUNT=6
        MAX_CHANREF=3
        HEAP="${TLC_HEAP:-16g}"
        ;;
    large)
        MAX_PROC=4
        MAX_PGRP=5
        MAX_CHAN=5
        MAX_PATH=3
        MAX_MOUNT=8
        MAX_CHANREF=3
        HEAP="${TLC_HEAP:-32g}"
        ;;
    *)
        echo "Unknown level: $LEVEL"
        echo "Usage: $0 [small|medium|large]"
        exit 1
        ;;
esac

echo "========================================"
echo "Inferno Namespace Formal Verification"
echo "========================================"
echo ""
echo "Verification level: $LEVEL"
echo "  MaxProcesses: $MAX_PROC"
echo "  MaxPgrps:     $MAX_PGRP"
echo "  MaxChannels:  $MAX_CHAN"
echo "  MaxPaths:     $MAX_PATH"
echo "  MaxMountId:   $MAX_MOUNT"
echo "  MaxChanRef:   $MAX_CHANREF"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

# Generate temporary config file with selected parameters
CONFIG_FILE="$RESULTS_DIR/MC_Namespace_$LEVEL.cfg"
cat > "$CONFIG_FILE" << EOF
\* Auto-generated TLC configuration for $LEVEL verification
\* Generated: $(date)

SPECIFICATION Spec

CONSTANT MaxProcesses = $MAX_PROC
CONSTANT MaxPgrps = $MAX_PGRP
CONSTANT MaxChannels = $MAX_CHAN
CONSTANT MaxPaths = $MAX_PATH
CONSTANT MaxMountId = $MAX_MOUNT
CONSTANT MaxChanRef = $MAX_CHANREF

\* Safety Invariants
INVARIANT TypeOK
INVARIANT SafetyInvariant
INVARIANT RefCountNonNegative
INVARIANT NoUseAfterFree
INVARIANT MountTableBounded
INVARIANT NamespaceIsolation
INVARIANT NamespaceIsolationTheorem
INVARIANT UnilateralMountNonPropagation
INVARIANT CopyFidelity
INVARIANT PostCopyMountsSound
INVARIANT NoIsolationViolation

\* State constraint for bounded model checking
CONSTRAINT StateConstraint
ACTION_CONSTRAINT ActionConstraint

\* Alias for debugging
ALIAS Alias
EOF

cd "$TLA_DIR"

# Vacuity guard.  The isolation invariants are implications whose antecedent
# needs a copied pgrp (and, for the interesting case, a mount made after the
# copy while parent and child are both live).  Check that those states are
# reachable under these constants: TLC must find a violation of each probe
# in MC_Namespace.tla, quickly, or the main run would prove nothing.
VACUITY_CFG="$RESULTS_DIR/MC_Namespace_${LEVEL}_vacuity.cfg"
for probe in CopyNeverHappened LivePostCopyMountNeverHappened; do
    sed -e '/^INVARIANT/d' -e '/^ALIAS/d' -e '/^ACTION_CONSTRAINT/d' "$CONFIG_FILE" > "$VACUITY_CFG"
    echo "INVARIANT $probe" >> "$VACUITY_CFG"
    echo "Vacuity check: $probe must be violated under these constants..."
    set +e
    java -Xmx2g -jar "$SCRIPT_DIR/tla2tools.jar" -config "$VACUITY_CFG" -workers auto \
        -checkpoint 0 MC_Namespace.tla > "$RESULTS_DIR/tlc_vacuity_${LEVEL}_${probe}.txt" 2>&1
    set -e
    if ! grep -q "Invariant $probe is violated" "$RESULTS_DIR/tlc_vacuity_${LEVEL}_${probe}.txt"; then
        echo "ERROR: $probe was never violated: the constants make the isolation"
        echo "       invariants vacuous (no copy, or no post-copy mount, is reachable)."
        echo "       See $RESULTS_DIR/tlc_vacuity_${LEVEL}_${probe}.txt"
        exit 1
    fi
    echo "  reachable (probe violated, as required)"
done
rm -f "$VACUITY_CFG"
echo ""

echo "Running TLC model checker..."
echo "This may take a while depending on the verification level."
echo ""

# Run TLC with unbuffered output to avoid losing progress data
set +e
OUTPUT_FILE="$RESULTS_DIR/tlc_output_$LEVEL.txt"

# Build TLC command
TLC_CMD="java -XX:+UseParallelGC -Xmx${HEAP} -jar $SCRIPT_DIR/tla2tools.jar -config $CONFIG_FILE -workers auto -checkpoint 60 -deadlock"

# Add recovery flag if RECOVER env var is set
if [[ -n "$RECOVER" ]]; then
    TLC_CMD="$TLC_CMD -recover $RECOVER"
    echo "Recovering from checkpoint: $RECOVER"
    echo ""
fi

TLC_CMD="$TLC_CMD MC_Namespace.tla"

# Use stdbuf to disable buffering, tee with line buffering
stdbuf -oL $TLC_CMD 2>&1 | stdbuf -oL tee "$OUTPUT_FILE"

TLC_EXIT=${PIPESTATUS[0]}
set -e

echo ""
echo "========================================"
echo "Verification Complete"
echo "========================================"
echo ""
echo "Results saved to: $RESULTS_DIR/tlc_output_$LEVEL.txt"

if [[ $TLC_EXIT -eq 0 ]]; then
    echo "STATUS: ALL PROPERTIES VERIFIED"
    echo ""
    echo "The 11 invariants in $CONFIG_FILE held in every reachable state"
    echo "of the TLA+ model (not of the C code; see METHODOLOGY.md section 10)."
else
    echo "STATUS: VERIFICATION FAILED OR INCOMPLETE"
    echo "Check the output file for details."
fi

exit $TLC_EXIT
