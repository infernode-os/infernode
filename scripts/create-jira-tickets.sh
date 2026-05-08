#!/usr/bin/env bash
# Create the OpenClaw gap-analysis tickets in Jira.
#
# Usage:
#   export JIRA_EMAIL='you@nervsystems.com'
#   export JIRA_TOKEN='ATATT...'
#   export JIRA_PROJECT_KEY='INF'        # or whichever key the InferNode project uses
#   export JIRA_SITE='nervsystems-team.atlassian.net'
#   ./scripts/create-jira-tickets.sh                # dry-run by default; prints payloads
#   ./scripts/create-jira-tickets.sh --apply        # actually POST to Jira
#
# Why a script and not direct API calls from the assistant?
# The Anthropic egress proxy this assistant runs in does not allowlist
# *.atlassian.net (HTTP 403 "host_not_allowed"). Run this from your machine.
#
# Discovers the project key automatically if JIRA_PROJECT_KEY is unset and
# a single project's name contains "infernode" (case-insensitive).

set -euo pipefail

: "${JIRA_EMAIL:?Set JIRA_EMAIL}"
: "${JIRA_TOKEN:?Set JIRA_TOKEN}"
: "${JIRA_SITE:=nervsystems-team.atlassian.net}"

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then APPLY=1; fi

api() {
    # api METHOD PATH [JSON_BODY]
    local method="$1" path="$2" body="${3:-}"
    local url="https://${JIRA_SITE}${path}"
    if [[ -n "$body" ]]; then
        curl -sS -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
             -H 'Accept: application/json' \
             -H 'Content-Type: application/json' \
             -X "$method" \
             --data "$body" \
             "$url"
    else
        curl -sS -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
             -H 'Accept: application/json' \
             -X "$method" \
             "$url"
    fi
}

discover_project_key() {
    local match
    match=$(api GET '/rest/api/3/project/search?query=infernode' \
        | python3 -c '
import json, sys
d = json.load(sys.stdin)
vals = d.get("values", [])
if len(vals) == 1:
    print(vals[0]["key"])
elif len(vals) == 0:
    sys.exit("no project matched \"infernode\"")
else:
    print("AMBIGUOUS:" + ",".join(v["key"] + "(" + v["name"] + ")" for v in vals), file=sys.stderr)
    sys.exit(2)
')
    echo "$match"
}

if [[ -z "${JIRA_PROJECT_KEY:-}" ]]; then
    echo "JIRA_PROJECT_KEY unset — discovering from /project/search?query=infernode ..." >&2
    JIRA_PROJECT_KEY=$(discover_project_key)
    echo "Using project key: $JIRA_PROJECT_KEY" >&2
fi

# ADF (Atlassian Document Format) helper: turn a markdown-ish block into a single
# paragraph node per line. Keeps the script dependency-free.
adf_doc() {
    python3 - "$@" <<'PY'
import json, sys
text = sys.argv[1]
content = []
for line in text.splitlines():
    line = line.rstrip()
    if not line:
        continue
    content.append({"type":"paragraph","content":[{"type":"text","text":line}]})
print(json.dumps({"type":"doc","version":1,"content":content}))
PY
}

# Each ticket: SUMMARY :: ISSUETYPE :: PRIORITY :: BODY
# Issue types must exist on the project. "Story", "Epic", "Task" are typical defaults.
TICKETS=()
add() { TICKETS+=("$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"); }

add "OAuth2 / OIDC client subsystem" "Story" "Highest" "Why: prerequisite for every messaging-platform adapter; we currently have no standard third-party identity flow.
Done when:
- module/oauth.m interface + reference impl in appl/lib/oauth.b.
- Token storage layered on factotum/secstore.
- Auth-code + PKCE + refresh-token flows working end-to-end against at least one provider (GitHub) in a manual test.
- Namespace-restricted: token cache reachable only by the agent that minted it.
Source: docs/GAP-ANALYSIS-OPENCLAW.md (gap G10)."

add "Messaging channel framework + 3 reference adapters (Signal, Slack, Telegram)" "Epic" "Highest" "Why: OpenClaw's primary differentiator is reaching the agent through chat apps users already use. InferNode has zero channel adapters today.
Done when:
- appl/veltro/channels/ framework with channel adapter interface (module/channel.m).
- Three working adapters: Signal (signal-cli or libsignal), Slack (Events API), Telegram (Bot API).
- Inbound message -> agent invocation -> reply round-trip on each.
- Adapters run inside attenuated namespaces; credentials only via OAuth subsystem + factotum.
- Documented add-a-new-channel guide.
Source: docs/GAP-ANALYSIS-OPENCLAW.md (gap G1). Depends on T1."

add "Persistent per-peer agent sessions" "Story" "High" "Why: without this, a multi-channel agent forgets every conversation on restart.
Done when:
- Per-peer session adt with conversation history, tool budgets, per-peer model overrides.
- 9P-backed persistence (sessions survive emu restart).
- memory tool reads/writes the active session by default.
- Garbage-collection policy for stale sessions documented.
Source: docs/GAP-ANALYSIS-OPENCLAW.md (gap G2)."

add "MCP gateway: server + client" "Epic" "High" "Why: lets InferNode consume the public MCP ecosystem and exposes Veltro tools to MCP clients (Claude Desktop, Claude Code, etc.).
Done when:
- JSON-RPC 2.0 MCP server in front of tools9p (transport: stdio + HTTP+SSE).
- MCP client that mounts a remote MCP server as a 9P tree under /n/mcp/<name>/.
- At least one external MCP server (filesystem or fetch) consumable by a Veltro agent.
- Veltro tools usable from Claude Desktop in a manual test.
Source: docs/GAP-ANALYSIS-OPENCLAW.md (gap G4). Builds on existing mc9p."

add "Cron / scheduled agent triggers" "Story" "High" "Why: agents that only react to direct invocation can't do meaningful background work.
Done when:
- cron9p service exposing scheduled-job control files.
- Tool: schedule for agents to register their own jobs (subject to budget).
- Triggers cleanly invoke an agent run with the right session + namespace.
- At least one example: a daily summarize-starred-GitHub-issues job.
Source: docs/GAP-ANALYSIS-OPENCLAW.md (gap G5)."

add "Observability: tracing + per-agent run logs" "Story" "Medium" "Why: as soon as agents are reachable from messaging platforms, something will go wrong silently. We need to see it.
Done when:
- module/trace.m emitting spans from llmclient.m, tool dispatcher, channel adapters.
- Sink: 9P log file by default, optional OTLP/HTTP exporter.
- xenith integration to view a recent agent run as a span tree.
- Trace IDs propagate across spawn'd subagents.
Source: docs/GAP-ANALYSIS-OPENCLAW.md (gap G9)."

add "Skill plugin system for non-Limbo authors" "Epic" "Medium" "Why: compiled-Limbo-only is the structural reason InferNode will never reach OpenClaw's skill volume. Lower the bar without lowering the security floor.
Done when:
- Skill manifest format (skill.toml or similar) declaring required capabilities, tools, namespace.
- Loadable runtime: declared skills can be JSON-RPC subprocesses, MCP servers (via T4), or .dis modules - not just the last.
- Capability requests are explicit and namespace-enforced; deny-by-default.
- Reference: 3 skills in non-Limbo languages.
- Publish-a-skill docs.
Source: docs/GAP-ANALYSIS-OPENCLAW.md (gap G3)."

add "Embedding + vector index for agent memory" "Story" "Medium" "Why: the current memory tool is a key-value scratchpad. OpenClaw-class assistants do retrieval-augmented memory.
Done when:
- Embedding tool (provider-agnostic; Anthropic + local sentence-transformers).
- 9P-mounted vector index (HNSW or similar, wrapping an existing C lib).
- memory tool gains semantic recall mode.
- Benchmark: 10k-document recall under 100 ms on the dev box.
Source: docs/GAP-ANALYSIS-OPENCLAW.md (gap G11)."

# --- Hardening tickets (S1-S4): derived from documented OpenClaw incidents -----

add "Capability-token tool dispatch + immutable audit log" "Epic" "Highest" "Why: OpenClaw's CVE-2026-32922 (pairing-token to admin RCE, CVSS 9.9) is the canonical confused-deputy attack on an agent control plane. Generalising our existing spawn attenuation into first-class capability tokens prevents the entire class.
Done when:
- module/cap.m defines a capability token (scope, parent, expiry, signed by parent's cap).
- Tool dispatcher (tools9p) verifies the caller's token against the requested tool + arguments before dispatch.
- spawn issues child tokens that are provably attenuated (TLA+ invariant: child.scope subset of parent.scope).
- Per-agent immutable audit log on 9P (append-only file with sequence numbers + hash chain).
- All channel-sourced invocations carry a token derived from the channel adapter's grant.
Source: docs/GAP-ANALYSIS-OPENCLAW.md section 4a + ticket S1."

add "Skill signing, reproducible builds, capability manifests" "Epic" "Highest" "Why: ClawHavoc put 824+ malicious skills (~20% of the OpenClaw registry) into circulation through ClawHub. If we ship the plugin system (T7) without supply-chain controls baked in we will repeat that incident on our own ecosystem. This ticket gates T7.
Done when:
- Manifest format declares: required tools, FS roots, network egress hosts, peripherals - runtime denies anything not declared.
- All skill artifacts signed with SLH-DSA (already shipped); signature verified at install and at every load.
- Reproducible-build attestation alongside the artifact; registry signs metadata; mismatched binary refuses to load.
- Registry is mirror-able offline; an air-gapped install is identical to an online one.
- Typosquat protection: registry rejects names within edit-distance <=2 of an existing popular skill without manual review.
- 'Required prerequisite' social-engineering blocked: a skill's docs cannot trigger another install path; only the manifest can.
Source: docs/GAP-ANALYSIS-OPENCLAW.md section 4a + ticket S2. Hard dependency for T7."

add "Outbound network allowlist + content provenance taint" "Story" "High" "Why: closes the credential-exfiltration pattern from ClawHavoc (skills POSTing tokens to attacker webhooks) and the April 27 2026 disclosure (prompt-injected outputs redirecting API traffic to attacker hosts).
Done when:
- Each agent (and each skill) declares allowed egress destinations (host[:port]) in its manifest.
- http, webfetch, payfetch tools enforce the allowlist; deny is a hard error, logged.
- Tool outputs from external sources are wrapped with a provenance marker that survives into the next prompt.
- A tainted argument to a sensitive tool (http POST, write outside scratch, keyring.read) requires explicit re-confirmation - second tool call from a non-tainted code path, or user approval.
- Provenance taint propagates across spawn boundaries.
Source: docs/GAP-ANALYSIS-OPENCLAW.md section 4a + ticket S3."

add "Channel-input quarantine: planner/executor split" "Epic" "High" "Why: OpenClaw's ~17% defense rate against prompt injection is a topology problem, not a prompting problem. Inbound channel bytes should never share a context window with the tool-using LLM unmediated.
Done when:
- Channel adapters (T2) deliver messages to a planner agent that has no tools - it can only emit a structured intent.
- A separate executor agent receives the intent (not the raw text) plus a minimal, named context bundle, with the original channel text behind a provenance marker.
- Spoofed [System Message] and similar in-band injection patterns are stripped/escaped at the adapter; planner sees structured envelope only.
- Agent-hijacking benchmarks (NIST CAISI subset + OpenClaw red-team corpus) run in CI and gate releases; target >=90% defense rate at launch, regression-tested on every model bump.
- Persistent session memory (T3) tags every stored entry with the channel/peer that produced it; recall API filters by trust level.
Source: docs/GAP-ANALYSIS-OPENCLAW.md section 4a + ticket S4. Closely coupled with T2 and T3."

build_payload() {
    local summary="$1" issuetype="$2" priority="$3" body="$4"
    local description; description=$(adf_doc "$body")
    python3 - "$JIRA_PROJECT_KEY" "$summary" "$issuetype" "$priority" "$description" "$body" <<'PY'
import json, sys
proj, summary, issuetype, priority, desc_json, body = sys.argv[1:]
labels = ["openclaw-gap-analysis", "competitive-parity"]
# Flag the hardening tickets (S1-S4) for security filtering.
if "ticket S1" in body or "ticket S2" in body or "ticket S3" in body or "ticket S4" in body:
    labels.append("security")
    labels.append("hardening")
payload = {
    "fields": {
        "project": {"key": proj},
        "summary": summary,
        "issuetype": {"name": issuetype},
        "priority": {"name": priority},
        "description": json.loads(desc_json),
        "labels": labels,
    }
}
print(json.dumps(payload))
PY
}

echo "--- Creating ${#TICKETS[@]} tickets in project ${JIRA_PROJECT_KEY} on ${JIRA_SITE} ---" >&2
echo "Mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)" >&2
echo

for t in "${TICKETS[@]}"; do
    IFS=$'\x1f' read -r summary issuetype priority body <<<"$t"
    payload=$(build_payload "$summary" "$issuetype" "$priority" "$body")
    if [[ $APPLY -eq 1 ]]; then
        echo "POST: $summary"
        resp=$(api POST '/rest/api/3/issue' "$payload")
        echo "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "key" in d:
    print(f"  -> {d[\"key\"]}  https://'"$JIRA_SITE"'/browse/{d[\"key\"]}")
else:
    print("  ERROR: " + json.dumps(d, indent=2))
    sys.exit(1)
'
    else
        echo "DRY-RUN: $summary  ($issuetype, $priority)"
        echo "  payload: $(echo "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["fields"]["description"]={"...adf...":True}; print(json.dumps(d))')"
    fi
done

echo
echo "Done. Re-run with --apply to actually create the tickets." >&2
