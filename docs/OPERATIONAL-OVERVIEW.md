# InferNode / Veltro — Operational Overview

## The Platform

Inferno OS running as a native process on macOS, Linux and Windows (with Android and iOS builds), with JIT compilers for AMD64, ARM64 and RISC-V (`emu -c1`). It boots in milliseconds. The emulator hosts a full Plan 9-style namespace — everything is a file, including AI services.

---

## The AI Stack

**llmsrv** is the native Limbo LLM service. It runs inside the Inferno emulator, self-mounts at `/mnt/llm`, and presents LLM providers (Anthropic API or Ollama/OpenAI-compatible) as a 9P filesystem: write a prompt to `/mnt/llm/{id}/ask`, read the response back. Sessions are cloned from `/mnt/llm/new`. It speaks native Anthropic tool_use protocol — the model gets proper JSON tool schemas and returns structured tool calls, not text it has to parse. For remote LLM access, dial and mount a remote llmsrv via 9P instead of running one locally.

**tools9p** is a 9P file server mounted at `/tool`. It registers tool modules and serves them as a filesystem: `/tool/tools` (what's active), `/tool/paths` (namespace paths), `/tool/ctl` (add/remove tools, bind/unbind paths; trusted clients write it as `/mnt/toolctl/ctl`). This is the unified configuration store — both the GUI and the agent harness write here.

**veltrosrv** (`appl/veltro/veltrosrv.b`) is the agent loop, served as files at `/mnt/veltro`. It restricts its own namespace to the grants it was started with, calls tools in a loop via the LLM, and re-reads tool and path state at the start of each turn.

**Veltro** (`appl/veltro/veltro.b`) is the command-line client of veltrosrv. You give it a task; it prints the agent's reply and terminates when the turn is done. Sessions can be resumed with `-r`.

**lucibridge** is Lucia's client of veltrosrv. It runs in the background, connects Lucia's conversation UI to the agent, and handles slash commands (`/bind`, `/unbind`, `/tools +/-name`) for interactive namespace management.

(See the Terminology section of `appl/veltro/SECURITY.md` for the harness/agent distinction.)

---

## The Tools

A running agent has tools registered by default:

| Category | Tools |
|----------|-------|
| File ops | `read`, `list`, `find`, `search`, `write`, `edit` |
| Execution | `exec`, `spawn`, `launch` |
| UI | `xenith`, `present`, `gap` |
| Data | `diff`, `json`, `memory`, `todo` |
| Net | `http`, `websearch` |
| VCS | `git` |
| Vision | `vision`, `gpu` |

Mail is not a tool: mail9p serves it as files at `/mnt/mail`.

The agent calls these via native tool_use. Parallel tool calls work. Subagents (via `spawn`) get their own isolated namespace and LLM session.

---

## Namespace Security

When an agent session starts, `nsconstruct` restricts the namespace:
- `/dis` reduced to `lib/`, `veltro/` (+ `sh.dis` if exec is active)
- `/dis/veltro/tools/` reduced to only the registered tool `.dis` files
- `/dev` reduced to `cons`, `null`, `time`
- `/n` reduced to capability-gated foreign imports (`/n/speech` only if explicitly granted via paths); `/mnt/git` is derived only for the fixed `git` tool (migrated from `/n/git`, INFR-401)
- `/tmp` writable only at `/tmp/veltro/scratch/`

The agent cannot see files it wasn't granted. Subagents can only narrow further.

---

## The GUI (Lucia)

A three-zone GUI running on Inferno's native draw stack:
1. **Conversation zone** — message history, text input
2. **Presentation zone** — agent output rendered as markdown/diagrams/PDF
3. **Context zone** — live tool and namespace configuration

In the context zone you can:
- Toggle individual tools on/off at runtime (agent picks up the change on the next turn)
- Browse the local filesystem and bind directories into the agent's namespace
- Mount catalog entries (network 9P mounts, local path bindings)
- See what's currently mounted under "─ Mounted ─"

All of this writes to `/mnt/toolctl/ctl`. The agent picks up the new state at the start of the next turn.

---

## Cross-Host

The same agent stack runs on a Jetson (Linux ARM64) over ZeroTier. 9P mounts work cross-host with Inferno keyring authentication (a hybrid post-quantum STS handshake: ML-KEM-768, or ML-KEM-1024 with ML-DSA-87 keys in CNSA strict mode via `CNSAMODE`) and, by default, `aes_256_cbc sha256` on the link (`mount`, `listen`). You can mount a remote Inferno namespace locally or vice versa.

---

## PDF

The system includes a native Limbo PDF renderer — no external libraries. 98.3% conformance across public test corpora. RC4, AES-128, AES-256 encryption support. Outline fonts (CFF/TrueType embedded). The agent can render and present PDF pages in the GUI.

---

## What it can do in practice

- Run multi-step agentic tasks with real tool use (web search, file read/write, git operations, code execution)
- Spawn parallel subagents for independent subtasks
- Operate with a GUI where the user can interactively reconfigure the agent's capabilities mid-session
- Present structured output (markdown, diagrams, PDFs) in a dedicated zone
- Do all of this in a security-isolated environment where the agent can only see what it was explicitly granted
