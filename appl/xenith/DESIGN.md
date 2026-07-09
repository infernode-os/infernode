# Xenith: AI Agent Operating Environment

## About This Document

**This is a conceptual design ideas document.** It captures ideas, possibilities, and directions we're exploring for Xenith. Nothing here is final architecture - these are seeds for thought and discussion. Ideas should be added freely; we can prune later when we understand the problem space better.

## Vision

Xenith is a fork of Acme designed to serve as a secure, observable, and interactive operating environment for AI agents. Built on Inferno's namespace isolation and 9P protocol, Xenith provides:

- **Containment**: Agents operate within constructed namespaces, seeing only what is explicitly bound
- **Transparency**: All agent activity is visible through Xenith's window system
- **Interaction**: Humans and agents communicate through the same text-based, filesystem-accessible interface
- **Extensibility**: Multimodal capabilities (images, audio) extend Acme's text-first philosophy

## Design Principles

**These principles from Plan 9/Inferno/Acme guide our thinking. We should not deviate without damn good reason - and "damn good reason" means the principle demonstrably fails, not that we found something shinier.**

### 1. Everything is a File

Following Plan 9 and Inferno, all resources are presented as files in a hierarchical namespace. No special APIs, no proprietary protocols - just read, write, and stat on file descriptors.

### 2. Namespace per Process

Each process has its own view of the namespace. Security comes from what is bound, not from access control lists. If a path isn't bound, it doesn't exist.

### 3. Small, Composable Tools

Each component does one thing well. Complex behavior emerges from composition, not from monolithic implementations. Prefer pipelines over plugins.

### 4. Text Streams

Text is the universal interface. Programs communicate through text streams that humans can read, intercept, and modify.

### 5. Simplicity

No unnecessary code. No bloat. If a feature can be achieved through composition of existing primitives, do not add new primitives. The right answer is usually the simplest one that works.

### 6. Plumbing over Hardcoding

Connections between components should be late-bound and configurable, not compiled in. Use plumbing rules, namespace bindings, and environment variables.

## Architectural Foundation

### Why Acme/Inferno?

1. **Filesystem-as-Interface**: Acme exposes itself through `/mnt/acme` (Xenith: `/mnt/xenith`). An AI agent can:
   - Create windows by opening `/mnt/xenith/new/ctl`
   - Write content to `/mnt/xenith/<id>/body`
   - Read user selections from `/mnt/xenith/<id>/addr` and `/mnt/xenith/<id>/data`
   - Respond to events via `/mnt/xenith/<id>/event`

   No special APIs needed - just file operations. This aligns naturally with how LLM tool interfaces work.

2. **Namespace Containment**: Inferno's per-process namespaces allow construction of the agent's reality:
   ```
   bind /llm /llm           # LLM access
   bind /tools /tools       # Permitted operations
   bind /scratch /scratch   # Working space
   # Nothing else exists from agent's perspective
   ```
   Security through architecture, not policy enforcement.

3. **Transparent Operation**: Every agent action manifests in Xenith windows:
   - Agent's reasoning visible in one column
   - Outputs in another column
   - File operations logged in another
   - Far more observable than terminal scrollback

4. **Bidirectional Interaction**:
   - Agent writes commands; human can middle-click to execute
   - Human edits agent's work directly in windows
   - Human writes instructions; agent watches event stream
   - Acme's mouse chording (B1, B2, B3) provides rich interaction vocabulary

## Related Research

The `../research` directory contains ongoing research on namespace-bounded security for AI agents. Key areas being explored:

- Namespace isolation as defense against indirect prompt injection
- Token efficiency of filesystem interfaces vs JSON schemas
- LLM capability to infer tool usage from namespace listings
- Formal verification of namespace confinement properties

**Note**: This research is ongoing. The findings inform our thinking but do not constrain our design. We build on Plan 9/Inferno principles first; the research validates (or challenges) those principles.

## Conceptual Architecture

How the pieces might fit together (not final, just one way to think about it):

```
┌────────────────────────────────────────────────────────────────────┐
│                         XENITH (Window Manager)                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐               │
│  │ Source   │ │ Agent    │ │ Output   │ │ Logs     │  ... windows  │
│  │ Window   │ │ Convo    │ │ Window   │ │ Window   │               │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘               │
│       │            │            │            │                      │
│       └────────────┴────────────┴────────────┘                      │
│                           │                                         │
│                    /mnt/xenith (9P)                                 │
└───────────────────────────┬────────────────────────────────────────┘
                            │
         ┌──────────────────┼──────────────────┐
         │                  │                  │
    ┌────┴────┐       ┌─────┴─────┐      ┌────┴────┐
    │  /llm   │       │  /tools   │      │/scratch │
    │  (9P)   │       │   (9P)    │      │  (fs)   │
    └────┬────┘       └─────┬─────┘      └─────────┘
         │                  │
         │            ┌─────┴─────┐
    ┌────┴────┐       │ read_file │
    │ Claude  │       │ write     │
    │ OpenAI  │       │ execute   │
    │ Local   │       │ ...       │
    └─────────┘       └───────────┘

    ← Agent's namespace boundary →
    (sees only what's bound)
```

Human sees everything in Xenith. Agent sees only its constructed namespace.

## Comparison: Terminal vs Xenith

| Aspect | Terminal | Xenith |
|--------|----------|--------|
| Information layout | Linear text stream | Spatial arrangement |
| History | Scrolls away | Windows persist |
| Context | Single | Multiple parallel contexts |
| Security model | Sandbox/permissions | Namespace construction |
| Observability | Opaque | Transparent by design |
| Interaction | Command/response | Continuous, editable |

## The /llm Filesystem Interface

**Idea**: Expose LLM capabilities as a filesystem resource, following the "everything is a file" principle.

Two patterns are under consideration - both have Plan 9 precedent, and we haven't decided between them:

### Option A: Single Query File (Plan 9 style)

```
/llm/
├── prompt          # Write prompt, read response (like /dev/dns)
├── context         # Conversation history (read/write)
├── tools/          # Available tool definitions
│   ├── read_file
│   ├── write_file
│   ├── execute
│   └── ...
├── config          # Model parameters
│   ├── model       # Model name
│   ├── temperature
│   └── max_tokens
└── status          # Current state, token usage, etc.
```

Write a prompt, then read the response from the same file. Simple, follows the `/net/dns` pattern.

### Option B: Separate Prompt/Response Files

```
/llm/
├── prompt          # Write prompt text
├── response        # Read response (blocks until ready)
├── context/        # Conversation management
│   ├── clone       # Create new session
│   └── <session>/
│       ├── history # Read/write conversation
│       └── clear   # Reset context
├── config/
│   ├── model       # Model selection
│   ├── temperature
│   └── max_tokens
└── _status         # Token usage, rate limits
```

Separate files for input and output. More explicit, allows concurrent prompt preparation.

**Open question**: Which pattern better fits our use case? Both have Plan 9 precedent. We might prototype both and see what feels right, or find that the answer becomes obvious as we understand agent interaction patterns better.

## Possible Extensions

Ideas for extending Xenith beyond Acme's capabilities. Each would need to justify itself against the simplicity principle.

### Multimodal Capabilities

Acme is text-only. Ideas for extending beyond text:

1. **Image Display**: Window type that renders images
   - Leverage existing SDL3 graphics backend
   - Support common formats (PNG, JPEG, etc.)
   - Inline images in text windows, or dedicated image panes

2. **Audio Support**:
   - Playback for generated audio, notifications
   - Capture for voice interaction
   - Waveform visualization in windows

3. **Structured Data Views**:
   - JSON/tree viewers
   - Table displays
   - Graph/diagram rendering

4. **Markdown Rendering**:
   LLMs naturally produce markdown. Ideas for handling it:
   - Dedicated `markdown` window type that renders formatted output
   - Toggle on text windows: raw ↔ rendered (like a web browser's view-source)
   - Automatic detection based on content or `.md` extension
   - Inline rendering: headers become bold/large, code blocks get syntax highlighting, links become clickable

   This could be particularly useful for agent explanations, documentation generation, and structured responses. The question is whether to render inline (modifying the text appearance) or in a separate pane (preserving the raw text).

   **Key tension**: Xenith serves two audiences with different needs:
   - The LLM works natively in plain text/markdown - that's its medium
   - The human wants rendered output for readability (unless editing)

   Xenith is a framework for the LLM to organize context and resources, transparent to human oversight. But "transparent" means different things: the LLM needs raw text it can manipulate; the human needs readable presentation. How do we serve both? This needs more thought.

**Principle check**: Each extension must justify itself. Can the same be achieved with existing primitives? Only add if composition fails.

### Agent Control Interface

**Idea**: Dedicated control mechanisms for managing agent execution:

```
/agent/
├── status          # Running, paused, waiting
├── ctl             # Write: pause, resume, stop
├── resources       # Memory, tokens used
├── logs/           # Detailed operation logs
└── permissions     # Current namespace bindings
```

### Theming and Color Control

Xenith supports flexible color configuration through themes and environment variables.

#### Theme Selection

Use the `-t` flag to select a theme at startup:

```
xenith -t catppuccin    # Dark theme with Catppuccin Mocha palette
xenith -t dark          # Alias for catppuccin
xenith -t mocha         # Alias for catppuccin
xenith -t plan9         # Traditional Plan 9 pastels (default)
xenith                  # Default theme (plan9)
```

#### Available Themes

**plan9** (default): Traditional Acme colors - pale yellow text areas, pale blue-green tags, black text. The classic Plan 9 aesthetic.

**catppuccin**: Dark theme using the [Catppuccin Mocha](https://github.com/catppuccin/catppuccin) palette:
- Dark backgrounds (#1E1E2E base, #181825 empty areas)
- Light text (#CDD6F4)
- Blue accents for borders (#89B4FA)
- Red for button 2 / cut (#F38BA8)
- Green for button 3 / look (#A6E3A1)
- Mauve modifier button (#CBA6F7)

#### Environment Variable Configuration

Colors can be overridden individually via environment variables. Set these before launching Xenith:

**Body (text area) colors:**
- `xenith-bg-text-0` - Background color
- `xenith-fg-text-0` - Foreground (text) color
- `xenith-bg-text-1` - Selection background
- `xenith-fg-text-1` - Selection foreground
- `xenith-bg-text-2` - Button 2 (cut/execute) background
- `xenith-fg-text-2` - Button 2 foreground
- `xenith-bg-text-3` - Button 3 (look/plumb) background
- `xenith-fg-text-3` - Button 3 foreground
- `xenith-bord-text-0` - Body border color

**Tag colors:**
- `xenith-bg-tag-0` - Tag background
- `xenith-fg-tag-0` - Tag foreground
- `xenith-bg-tag-1` - Tag selection background
- `xenith-fg-tag-1` - Tag selection foreground
- `xenith-bord-tag-0` - Tag border

**Other colors:**
- `xenith-bord-col-0` - Column border
- `xenith-bord-row-0` - Row border
- `xenith-mod-but-0` - Modifier button color
- `xenith-bg-col-0` - Empty area background

#### Color Format

Colors can be specified in three formats:

1. **Hex** (UPPERCASE letters required): `#RRGGBB`
   ```
   xenith-bg-text-0=#1E1E2E
   ```

2. **Mixed** (two colors blended): `#RRGGBB/#RRGGBB`
   ```
   xenith-bg-text-0=#FFFFEA/#FFFFFF
   ```

3. **Named colors**: `black`, `white`, `red`, `green`, `blue`, `yellow`, `cyan`, `magenta`

**Important**: Hex colors must use UPPERCASE letters (A-F). Lowercase hex digits will not parse correctly.

#### Per-Window Color Control

Each window has a `colors` file for individual color customization:

```sh
# Read current colors
cat /mnt/xenith/1/colors

# Set red tag (warning)
echo 'tagbg #F38BA8
tagfg #1E1E2E' > /mnt/xenith/1/colors

# Reset to defaults
echo 'reset' > /mnt/xenith/1/colors
```

This enables agents to use color semantically:
- Yellow title bar for warnings
- Red for errors or dangerous operations
- Green for successful completion
- Visual vocabulary between agent and human

### Window Types

**Idea**: Extend Xenith's window system with specialized types:

- `text` - Standard Acme text window (default)
- `image` - Image display pane
- `audio` - Audio player/recorder
- `terminal` - Embedded terminal emulator
- `structured` - JSON/data viewer

## Security Model

### Namespace Construction

The agent's environment is explicitly constructed:

```limbo
# Create agent namespace
sys->pctl(Sys->NEWNS, nil);

# Bind only what agent needs
sys->bind("/services/llm", "/llm", Sys->MREPL);
sys->bind("/services/tools/safe", "/tools", Sys->MREPL);
sys->bind("/tmp/agent-scratch", "/scratch", Sys->MREPL|Sys->MCREATE);

# Agent cannot access anything not bound
# No /usr, no /home, no network unless explicitly provided
```

### Audit Trail

All file operations are logged:
- What the agent read
- What the agent wrote
- What commands it executed
- What events it received

### Human Override

At any point, human can:
- Pause agent execution
- Inspect all visible state
- Modify namespace bindings (grant/revoke capabilities)
- Edit agent's pending outputs
- Terminate agent

## Use Cases

### 1. Coding Assistant in Xenith

```
┌─────────────────────────────────────────────────────────────┐
│ /src/main.go                               Del Snarf Get Put│
├─────────────────────────────────────────────────────────────┤
│ func main() {                                               │
│     // Agent is editing here                                │
│ }                                                           │
├─────────────────────────────────────────────────────────────┤
│ Agent: Conversation                        Del Snarf        │
├─────────────────────────────────────────────────────────────┤
│ Human: Add error handling to main()                         │
│ Agent: I'll add error handling. Let me read the current...  │
├─────────────────────────────────────────────────────────────┤
│ Agent: Test Output                         Del Snarf        │
├─────────────────────────────────────────────────────────────┤
│ === RUN TestMain                                            │
│ --- PASS: TestMain (0.00s)                                  │
└─────────────────────────────────────────────────────────────┘
```

Agent has windows for:
- Source code being edited
- Test output
- Documentation references
- Conversation with user

User can edit code directly; agent sees changes via event stream.

### 2. Research Assistant

Agent creates windows for:
- Search results
- Document summaries
- Extracted data tables
- Citation management

All research is visible and editable by user.

### 3. System Administration

Agent monitors:
- Log files (tail windows)
- System metrics
- Alert conditions

Proposes actions in a window; user reviews and approves.

## Implementation Ideas

Possible approaches, not a fixed roadmap. The order might change as we learn.

### Incremental Approach

Build up gradually, validating against principles at each step:

1. **Foundation**: Get a basic agent loop running in Xenith
   - Agent can create windows
   - Agent can read/write window content
   - Human input reaches agent via event stream

2. **LLM Integration**: Connect to LLM via filesystem interface
   - Prototype both /llm interface patterns
   - Evaluate against simplicity principle

3. **Tool Integration**: Add tool access through namespace
   - Tools appear as files in agent's namespace
   - Invocation is just file I/O

4. **Multimodal**: Add image/audio only if text-based alternatives prove insufficient

5. **Hardening**: Error handling, persistence, documentation

### Alternative: Start with 9P Server

Another approach: build the /llm 9P server first (in Go, like the research prototypes), get it working standalone, then integrate with Xenith. This would let us experiment with the interface design before touching Xenith code.

### Philosophy

Whatever path we take: build the simplest thing that works, evaluate, refine. Don't add complexity until forced to.

## Open Questions

These are things we don't know yet. Good questions to keep in mind.

1. **Inner monologue display**: Dedicated window? Inline? Collapsible? Should agent reasoning be visible at all?
2. **Approval granularity**: Per-action? Per-category? Trust levels? What's the right balance between safety and friction?
3. **Permission escalation**: How does agent request new capabilities? Write to a special file? Special window?
4. **Session persistence**: Save/restore agent state? What exactly constitutes "state"?
5. **Multi-agent**: Separate namespaces? Shared windows? How do agents communicate with each other?
6. **LLM interface pattern**: Which best follows Plan 9 conventions? Does it matter, or will usage patterns make it obvious?
7. **Token accounting**: How do we track/limit LLM usage? Is this the agent's concern or the environment's?
8. **Error presentation**: How should errors from tools/LLM be surfaced? In the agent's window? Separate error log?
9. **Undo/rollback**: Can we undo agent actions? How far back? What's the model?
10. **Network access**: When/how should agents get network access? Always sandboxed? User-granted?

## Other Ideas

Random thoughts and ideas that don't fit elsewhere yet. Add freely.

- **Agent templates**: Pre-configured namespace setups for common tasks (coding, research, sysadmin)
- **Capability tokens**: Instead of binding paths, pass capability tokens that grant specific access
- **Streaming responses**: Agent output appears character-by-character, like watching someone type
- **Shared scratch space**: Multiple users/agents can collaborate on files in a shared namespace
- **Time-bounded sessions**: Agent automatically pauses after N minutes, requiring human check-in
- **Replay mode**: Record agent session, replay it later for review/training
- **Cost budgets**: Hard limits on token spend per session/task
- **Natural language namespace queries**: "What can I access?" returns human-readable capability list
- **Graduated trust**: Agent earns expanded capabilities through demonstrated safe behavior
- **Diff view**: Before agent writes, show proposed changes like a code review
- **Voice integration**: Talk to agent, hear responses (accessibility, hands-free operation)

## References

- Pike, R. "Acme: A User Interface for Programmers" (1994)
- Pike et al. "The Use of Name Spaces in Plan 9" (1992)
- Plan 9 Programmer's Manual, Section 4 (File Servers)
- Inferno Programmer's Guide
- Ongoing research: `../research`

---

*This is a living ideas document. Add freely, prune when the time is right.*
*Last updated: January 2025*
