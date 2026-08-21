#!/bin/sh
# style-gate.sh — advisory checks for foreign paradigms (docs/DESIGN-PRINCIPLES.md).
#
# Advisory by default: findings are printed as GitHub ::warning::
# annotations and the script exits 0, so it never blocks a merge.
# Set STYLE_GATE_STRICT=1 to make findings fail (exit 1) once the
# tree is clean and the project decides to enforce.
#
# Checks:
#   1. POSIX-isms (&& / ||) in Inferno-side shell scripts. Inferno sh
#      is rc-style; && and || do not exist and scripts containing them
#      fail at runtime inside emu.
#   2. New JSON module users under appl/. JSON is legitimate only at
#      external boundaries (LLM wire formats, HTTP APIs); inside the
#      9P namespace the hierarchy is the schema (docs/9p-data-conventions.md).
#      Additions to the allowlist below need a stated boundary rationale
#      in the PR.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

warnings=0

warn() {
    # warn <file> <line> <message>
    warnings=$((warnings + 1))
    echo "::warning file=$1,line=$2::$3"
    echo "style-gate: $1:$2: $3" >&2
}

# --- Check 1: && / || in Inferno-side sh scripts -----------------------
# Inferno-side scripts are identified by a #!/dis/sh shebang on the FIRST
# line (a whole-file grep would false-positive on host tests that embed
# Inferno scripts in heredocs), plus everything under tests/inferno/ and
# lib/sh/ regardless of shebang.

inferno_scripts=$(
    {
        git ls-files 'tests/inferno/*.sh' 'lib/sh/*'
        for s in $(git ls-files '*.sh'); do
            case $(head -1 "$s" 2>/dev/null) in
            ('#!/dis/sh'*) echo "$s" ;;
            esac
        done
    } | sort -u
)

for f in $inferno_scripts; do
    [ -f "$f" ] || continue
    # Strip comment lines, then flag && or || .
    n=0
    while IFS= read -r line; do
        n=$((n + 1))
        case $line in
        \#*) continue ;;
        esac
        case $line in
        *"&&"*|*"||"*)
            warn "$f" "$n" "Inferno sh is rc-style: '&&'/'||' do not exist (use ';' or if {cmd} { ... }). See docs/LIMBO-FOR-GO-PROGRAMMERS.md, 'The shell'."
            ;;
        esac
    done < "$f"
done

# --- Check 2: JSON module use in appl/ outside the boundary allowlist --
# Every file here speaks JSON to something *outside* the system:
#   appl/lib/json.b        the parser library itself
#   appl/lib/llmclient.b   LLM HTTP wire format
#   appl/cmd/llmsrv.b      LLM HTTP wire format
#   appl/lib/ethrpc.b      Ethereum JSON-RPC
#   appl/lib/stripe.b      Stripe HTTP API
#   appl/lib/x402.b        x402 payment protocol
#   appl/veltro/agentlib.b LLM tool-schema adapter (replaceable shim)
#   appl/veltro/tools/spawn.b  serialized grants for the LLM boundary
json_allowlist='appl/lib/json.b
appl/lib/llmclient.b
appl/cmd/llmsrv.b
appl/lib/ethrpc.b
appl/lib/stripe.b
appl/lib/x402.b
appl/veltro/agentlib.b
appl/veltro/tools/spawn.b'

for f in $(git grep -l -e 'include "json\.m"' -e 'load JSON' -- 'appl/*.b' 2>/dev/null); do
    if ! echo "$json_allowlist" | grep -qx "$f"; then
        line=$(grep -n -e 'include "json\.m"' -e 'load JSON' "$f" | head -1 | cut -d: -f1)
        warn "$f" "${line:-1}" "New JSON use inside appl/. JSON belongs only at external boundaries; inside the namespace the hierarchy is the schema (docs/9p-data-conventions.md). If this IS a boundary, add the file to the allowlist in tools/style-gate.sh with a rationale."
    fi
done

# --- Result ------------------------------------------------------------

if [ "$warnings" -eq 0 ]; then
    echo "style-gate: OK — no foreign-paradigm findings"
    exit 0
fi

echo "style-gate: $warnings advisory finding(s)" >&2
if [ "${STYLE_GATE_STRICT:-0}" = "1" ]; then
    exit 1
fi
exit 0
