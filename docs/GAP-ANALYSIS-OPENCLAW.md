# Gap Analysis: InferNode vs. OpenClaw

**Date:** 2026-05-08
**Branch:** `claude/openClaw-gap-analysis-NiyeY`
**Status:** Initial competitive analysis. Proposed Jira tickets at end.

---

## 1. What is OpenClaw?

OpenClaw is a self-hosted, model-agnostic **personal AI agent gateway**. It runs as a long-lived Node.js service that connects LLMs to (a) the user's local machine and (b) a wide fleet of messaging platforms used as the primary user interface. Originally published in late 2025 as "Clawdbot", renamed to "OpenClaw" in early 2026 after a trademark dispute, and currently shepherded by an independent open-source foundation after its founder joined OpenAI.

Public traction as of early 2026: ~247k GitHub stars, ~47k forks, ~44k community-built skills, releases every ~2 days.

### Main uses (what OpenClaw is *for*)

1. **Personal AI assistant reachable through everyday chat apps** — users talk to their agent in WhatsApp / Signal / Telegram / iMessage / Slack / Discord etc. instead of a bespoke chat UI.
2. **Multi-channel routing into per-account agents** — each inbound channel/peer is mapped to an isolated agent workspace with its own session memory.
3. **Computer-use automation** — shell, file system, and web automation via 100+ "AgentSkills" (the community has shipped ~44k).
4. **Voice control** — wake-word activation on macOS/iOS, continuous-voice on Android, ElevenLabs TTS plus system fallbacks.
5. **Visual scratchpad ("Live Canvas" / A2UI)** — agents render structured UI artifacts the user can see and manipulate.
6. **Cron / scheduled triggers** — agents act on a schedule, not just on inbound messages.
7. **Companion clients** — macOS menu bar app, iOS / Android "node" apps that extend reach off the main host.
8. **BYOK model flexibility** — cloud APIs (Anthropic, OpenAI, etc.) or fully local models; privacy-first posture.

### Architectural shape

A central **gateway** process (Node.js) holds sessions, routes channel events to agent workers, exposes a plugin/skill SDK, and coordinates voice + canvas surfaces. Plugins are JavaScript/TypeScript packages installed dynamically.

---

## 2. InferNode capability inventory (current state)

Captured from the codebase on `claude/openClaw-gap-analysis-NiyeY`.

### Core OS / runtime
- Dis VM with portable 64-bit Limbo bytecode.
- JIT on AMD64 (~14× speedup) and ARM64 (~8–10× speedup) — `libinterp/comp-amd64.c`, `libinterp/comp-arm64.c`. **No Windows JIT.**
- Per-process namespaces with formal verification (TLA+, SPIN, CBMC) — `formal-verification/tla+/Namespace.tla`.
- 9P filesystem protocol everywhere (client + server).
- TCP/IP, DHCP, DNS native.
- Quantum-safe crypto: ML-KEM, ML-DSA, SLH-DSA (FIPS 203/204/205); plus ed25519, secp256k1, ECDSA, SHA-256, BLAKE2b.

### Veltro (AI agent system)
- 39 tool modules under `appl/veltro/tools/`: websearch, webfetch, vision, hear, say, read/write/edit/find/grep/diff, git, shell, exec, spawn (subagents), task, plan, todo, json, list, search, wiki, memory, http, charon (browser), payfetch (x402), keyring, present, launch, fractal, gpu.
- LLM client (`module/llmclient.m`) supports Anthropic Messages API and OpenAI-compatible Chat Completions; native tool-use protocol; channel-based streaming.
- Per-agent config: model, temperature, system prompt, thinking budget.
- Four agent prompting strategies: default, explore, plan, task.
- Namespace-isolated subagents via `spawn`, capability attenuation, 2-min timeout, 50-step cap (`appl/veltro/SECURITY.md`, `appl/veltro/nsconstruct.b`).
- Local vision via TensorRT (`/mnt/gpu`) with Anthropic fallback.
- Speech: STT + TTS via `speech9p`.
- `mc9p` — *filesystem-as-schema* alternative to MCP (no JSON wire overhead).

### Developer tooling
- Native `limbo` + `mk` build chain (`MacOSX/arm64/bin/`).
- Custom test framework (`module/testing.m`) with auto-discovery; runs inside emu.
- Xenith editor — Acme fork with AI-aware window management (`appl/xenith/`).
- Optional SDL3 GUI (Lucia three-zone tiling shell, Metal/Vulkan/D3D).
- 100+ markdown docs in `docs/`.

### Networking / services
- 9P file servers: `llmsrv`, `tools9p`, `wallet9p`, `speech9p`, `wiki9p`, `mc9p`.
- `httpd`, `styx.sh`/`rstyx.sh`.
- `webclient` with TLS.
- `git` tool.

### Integrations
- Anthropic, OpenAI-compatible HTTP APIs.
- Whisper-compatible STT, OpenAI-compatible TTS.
- x402 payment protocol on EVM testnets (Sepolia, Base Sepolia) via `wallet9p` — ERC-20, EIP-3009, Permit2.
- Factotum + secstore for credential management.

---

## 3. Gap analysis

Each gap is rated by **severity for parity with OpenClaw** (P0 = blocking parity, P1 = major, P2 = nice-to-have) and **complexity** (S/M/L).

| # | Gap | Severity | Complexity | Notes |
|---|-----|---------:|-----------:|-------|
| G1 | **No messaging-platform channel adapters** (Signal, Telegram, WhatsApp, Slack, Discord, iMessage, Matrix, Teams, etc.). InferNode has zero. OpenClaw has 20–50+. | **P0** | L | The single biggest reason a non-developer would pick OpenClaw. Need a `channels/` subsystem + at least 3 reference adapters. |
| G2 | **No persistent agent / session state across reboots.** `memory` tool is in-process only. OpenClaw routes sessions per peer/account and survives restarts. | **P0** | M | Persist conversation state, tool budgets, per-peer agent identity. Likely a 9P-backed store. |
| G3 | **No skill/plugin system for non-Limbo authors.** All Veltro tools are compiled `.dis` modules. OpenClaw has 44k community-authored skills because installation = `npm i`. | **P1** | L | Need a runtime-loadable skill format with manifest, sandboxed exec, and a registry. Could leverage existing namespace isolation as a strength. |
| G4 | **No MCP server compatibility.** `mc9p` is a 9P-native MCP analogue, but the broader ecosystem speaks JSON-RPC MCP. We can't consume third-party MCP servers, and our tools aren't reachable from MCP clients. | **P1** | M | Add a JSON-RPC MCP gateway translating to/from `tools9p`. Bidirectional: server (expose Veltro tools) + client (mount external MCP servers as 9P). |
| G5 | **No scheduling / cron / event triggers** for agents. OpenClaw has cron + event sessions. InferNode agents only run when invoked. | **P1** | S | A `cron9p` service plus an agent-invocation API. Composable with G2. |
| G6 | **No companion / mobile client surfaces.** OpenClaw ships macOS menu-bar + iOS / Android nodes. InferNode's only surface is `emu` + Xenith. | **P2** | L | Could be partially served by G1 (chat-app delivery) without building native apps. |
| G7 | **No wake-word / continuous voice.** `say`/`hear` exist but require explicit invocation. | **P2** | M | VAD + wake-word model running locally; integrate with existing `speech9p`. |
| G8 | **No "live canvas" / structured-UI surface for agent output.** Xenith is text-first. OpenClaw's A2UI is a differentiator. | **P2** | L | Possibly a Xenith pane that renders agent-emitted structured artifacts (graphs, tables, mini-apps). |
| G9 | **No observability / tracing.** No OpenTelemetry, no metrics, no per-agent run logs queryable after the fact. | **P1** | S | Span emission from `llmclient.m` + tool dispatcher; sink to a 9P log file or OTLP exporter. |
| G10 | **No third-party auth providers.** No OAuth/OIDC for Google, GitHub, Slack, etc. — required for any of the channel adapters in G1. | **P0** *(prereq for G1)* | M | OAuth2 client + token store on top of factotum/secstore. |
| G11 | **No vector store / RAG primitives.** No embeddings, no similarity search. Limits memory and document Q&A. | **P1** | M | An embedding tool + a 9P-mounted vector index (could wrap an existing C library). |
| G12 | **No agent marketplace / installer UX.** Tools and agents are discovered via filesystem only. | **P2** | M | Depends on G3 first. |

### Priority ordering (recommended)

1. **G10** (OAuth/OIDC) — unblocks G1.
2. **G1** (messaging adapters) — closest thing to a single-feature parity move; pick 3 channels (Signal, Slack, Telegram).
3. **G2** (session persistence) — required for G1 to feel right.
4. **G4** (MCP bridge) — leverages our existing `tools9p` and unlocks the wider tool ecosystem.
5. **G5** (scheduling) — small, high-leverage.
6. **G9** (observability) — small, but important the moment any of the above ship.
7. **G3** (plugin system) — the long-tail differentiator, but heavy.
8. **G11** (RAG / vector store) — important for "actually useful" memory.

G6/G7/G8/G12 are explicitly deferred.

---

## 4. Strategic note

InferNode's defensible advantages over OpenClaw are *not* in the long checklist above — they're in **(a)** formally-verified namespace isolation, **(b)** the 9P substrate that makes capability attenuation and remote-mounting trivial, and **(c)** quantum-safe crypto. The gap-closure work above should preserve those properties: every channel adapter, OAuth client, and skill plugin should run inside an attenuated namespace by default. Don't ship a parity feature that breaks the security story.

---

## 5. Proposed Jira tickets

These map to the priority-ordered gaps above. Eight tickets, each epic-sized. Acceptance criteria are concrete enough to scope a sprint against.

See `scripts/create-jira-tickets.sh` for a runnable script that posts these to `nervsystems-team.atlassian.net` once you set `JIRA_EMAIL`, `JIRA_TOKEN`, and `JIRA_PROJECT_KEY`.

### T1 — OAuth2 / OIDC client subsystem (G10)
**Type:** Story · **Priority:** Highest
**Why:** Prerequisite for every messaging-platform adapter; we currently have no standard third-party identity flow.
**Done when:**
- `module/oauth.m` interface + reference impl in `appl/lib/oauth.b`.
- Token storage layered on factotum/secstore.
- Auth-code + PKCE + refresh-token flows working end-to-end against at least one provider (GitHub) in a manual test.
- Namespace-restricted: token cache reachable only by the agent that minted it.

### T2 — Messaging channel framework + 3 reference adapters (G1)
**Type:** Epic · **Priority:** Highest
**Why:** OpenClaw's primary differentiator; non-developers reach the agent through the chat apps they already use.
**Done when:**
- `appl/veltro/channels/` framework with channel adapter interface (`module/channel.m`).
- Three working adapters: **Signal** (signal-cli or libsignal), **Slack** (Events API), **Telegram** (Bot API).
- Inbound message → agent invocation → reply round-trip on each.
- Adapters run inside attenuated namespaces; credentials only via T1 + factotum.
- Documented "add a new channel" guide.

### T3 — Persistent per-peer agent sessions (G2)
**Type:** Story · **Priority:** High
**Why:** Without this, a multi-channel agent forgets every conversation on restart.
**Done when:**
- Per-peer session adt with conversation history, tool budgets, per-peer model overrides.
- 9P-backed persistence (sessions survive `emu` restart).
- Memory tool reads/writes the active session by default.
- Garbage-collection policy for stale sessions documented.

### T4 — MCP gateway: server + client (G4)
**Type:** Epic · **Priority:** High
**Why:** Lets InferNode consume the public MCP ecosystem and exposes Veltro tools to MCP clients (Claude Desktop, Claude Code, etc.).
**Done when:**
- JSON-RPC 2.0 MCP server in front of `tools9p` (transport: stdio + HTTP+SSE).
- MCP client that mounts a remote MCP server as a 9P tree under `/n/mcp/<name>/`.
- At least one external MCP server (filesystem or fetch) consumable by a Veltro agent.
- Veltro tools usable from Claude Desktop in a manual test.

### T5 — Cron / scheduled agent triggers (G5)
**Type:** Story · **Priority:** High
**Why:** Agents that only react to direct invocation can't do meaningful background work (digest emails, run nightly checks, etc.).
**Done when:**
- `cron9p` service exposing scheduled-job control files.
- Tool: `schedule` for agents to register their own jobs (subject to budget).
- Triggers cleanly invoke an agent run with the right session + namespace.
- At least one example: a daily "summarize starred GitHub issues" job.

### T6 — Observability: tracing + per-agent run logs (G9)
**Type:** Story · **Priority:** Medium
**Why:** As soon as agents are reachable from messaging platforms, *something* will go wrong silently. We need to see it.
**Done when:**
- `module/trace.m` emitting spans from `llmclient.m`, tool dispatcher, channel adapters.
- Sink: 9P log file by default, optional OTLP/HTTP exporter.
- `xenith` integration to view a recent agent run as a span tree.
- Trace IDs propagate across `spawn`'d subagents.

### T7 — Skill plugin system (non-Limbo authors) (G3)
**Type:** Epic · **Priority:** Medium
**Why:** Compiled-Limbo-only is the structural reason InferNode will never reach OpenClaw's skill volume. Lower the bar without lowering the security floor.
**Done when:**
- Skill manifest format (`skill.toml` or similar) declaring required capabilities, tools, namespace.
- Loadable runtime: declared skills can be JSON-RPC subprocesses, MCP servers (via T4), or `.dis` modules — not just the last.
- Capability requests are explicit and namespace-enforced; deny-by-default.
- Reference: 3 skills in non-Limbo languages.
- "Publish a skill" docs.

### T8 — Embedding + vector index for agent memory (G11)
**Type:** Story · **Priority:** Medium
**Why:** The current `memory` tool is a key-value scratchpad. OpenClaw-class assistants do retrieval-augmented memory; we should too.
**Done when:**
- Embedding tool (provider-agnostic; Anthropic + local sentence-transformers).
- 9P-mounted vector index (HNSW or similar, wrapping an existing C lib).
- `memory` tool gains semantic recall mode.
- Benchmark: 10k-document recall under 100 ms on the dev box.

---

*Authored as part of the openClaw gap-analysis session.*
