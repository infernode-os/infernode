# On-device models behind `/mnt/llm` — Apple Foundation Models first

*Design note, 2026-10-28. Nothing here is built yet. Research on Apple's
macOS 27 on-device model, what it can and cannot do for InferNode, and a
general shape for this and later on-device engines. It extends
[IOS-ONDEVICE-LLM.md](IOS-ONDEVICE-LLM.md) (the iOS engine plan) and the
gateway pattern of [CLAUDE-GATE.md](CLAUDE-GATE.md) and
[CODEX-GATE.md](CODEX-GATE.md). Per [DESIGN-PRINCIPLES.md](DESIGN-PRINCIPLES.md)
the namespace sketch below goes to an issue before any code.*

## Summary

- macOS 27 (released 2026-09-14, Apple silicon only) ships a rebuilt
  on-device model behind the Foundation Models framework, a preinstalled
  `fm` command, and an undocumented `fm serve` that speaks Chat Completions
  on loopback.
- **It is not a Veltro agent brain.** Its window is 4096 tokens on the
  builds most reports measured (8192 in Apple's WWDC demo), for
  instructions, prompt and reply together. Veltro's `lib/veltro/system.txt`
  alone is about 3K tokens before 44 tools' schemas. It is a good *second*
  model: private by construction, free, offline, with vision. It suits
  narrow work such as titles, short summaries, classification, extraction
  to a schema and describing an image.
- **The general shape:**
  1. **Gates.** Every on-device engine gets a thin host daemon (a *gate*)
     speaking the one wire shape `llmsrv` already speaks: OpenAI chat
     completions on loopback. Apple's would be `fm-gate`, in Swift on
     the framework.
  2. **A mount per provider.** Each provider is its own `llmsrv` tree under
     `/mnt/llms/<name>`, with `/mnt/llm` bound to the default.
     "On-device only" then becomes a namespace an agent is given, not a
     flag it is trusted to honour.
  3. **Capabilities as text.** Each provider says in a text file what it
     can do (window, tools, vision, where it runs), and consumers decide.
- This is consistent with the 2026-05-27 decision in
  [IOS-ONDEVICE-LLM.md](IOS-ONDEVICE-LLM.md#decision-2026-05-27-open-weight-basis-any-engine-stays-behind-the-seam):
  Apple's model is closed, so it is not the base for InferNode's own
  fine-tune. It may be *used*, but only behind the `llmsrv` seam, never
  wired into Veltro or lucibridge directly.

## What Apple shipped (research, 2026-10)

Apple's WWDC26 sessions are the primary sources. `fm serve` is in none of
them, and everything about it comes from people testing the 27.0
builds, who do not all agree. The confidence column says which is which.

| Fact | Confidence | Source |
| --- | --- | --- |
| On-device model rebuilt "from the ground up", better at logic and tool calling; takes images (`Attachment(...)` in a prompt) | Apple | [WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/) |
| `SystemLanguageModel().contextSize` (8192 in the demo); `tokenCount(for:)`; per-response `usage` | Apple | 241 |
| New `LanguageModel` protocol: one `LanguageModelSession` over the on-device model, `PrivateCloudComputeLanguageModel` (32K, reasoning), MLX/Core AI models, or a vendor's Swift package (Anthropic, Google) | Apple | 241, [WWDC26 339](https://developer.apple.com/videos/play/wwdc2026/339/) |
| `LanguageModel` / `LanguageModelExecutor` are Swift protocols; there is no out-of-process wire protocol | Apple | 339 |
| `fm respond` / `fm chat` / `fm schema` preinstalled; `--instructions`, `--image`, `--schema`, `--model pcc`; stdout pipes to `jq` | Apple | [WWDC26 334](https://developer.apple.com/videos/play/wwdc2026/334/) |
| Python SDK `apple_fm_sdk` (needs Xcode installed) | Apple | 334 |
| `sudo fm license` must be run once, machine-wide, before `fm` works | Testers | [clews.id.au](https://clews.id.au/til/macos-27-ships-an-on-device-llm-cli-called-fm/) |
| `fm serve --port 1976`: loopback only; `/v1/chat/completions`, `/v1/models`, `/health`; model must be `system` | Testers (consistent) | clews.id.au, [fm-proxy](https://github.com/gregbarbosa/fm-proxy) |
| `fm serve` streams when `stream` is absent; ignores `max_tokens` (honours `max_completion_tokens`); a capped reply still says `finish_reason: stop` | Testers (consistent) | fm-proxy, [dev.to/yrangana](https://dev.to/yrangana/what-i-learned-putting-macos-27s-on-device-model-behind-a-coding-agent-ckd) |
| `fm serve` and `tools`: "silently ignored" in one report; real `tool_calls` for `tool_choice: auto` in another, wrong tool "often" with five or more | Testers (**conflicting**) | clews.id.au vs fm-proxy |
| Window 4096 on most 27.0 builds; one tester got ~7.9K through | Testers (**conflicting**) | fm-proxy, dev.to/yrangana, [modelfit.io](https://modelfit.io/blog/macos-27-fm-cli-local-model-terminal/) |
| Requests are served one at a time; a runaway generation (nullable schema fields) keeps going after the client leaves and blocks everything behind it; a stuck "service unavailable" clears in 1–8 minutes | Testers | fm-proxy, dev.to/yrangana |
| Guardrails refused about 1 in 6 harmless news articles | Testers | dev.to/yrangana |
| PCC through `fm`: rejected on some machines, only from Terminal.app on others | Testers (**conflicting**) | clews.id.au, fm-proxy |

**Reading of it.** The framework is the stable, documented surface.
`fm serve` is a beta convenience whose behaviour changes between builds.
A gate built on the framework can read its own window, check availability
and stream properly. A gate wrapping `fm serve` inherits its quirks.

## What it means for InferNode

**Where it does not fit.** The agent loop (`appl/veltro/agentlib.b`,
`lucibridge`) sends the whole tool-calling system prompt and tool schemas
on every turn. At 4096 tokens there is no room left for the conversation.
`llmsrv`'s compaction would not save it either: with a 4096 window,
`marklimit` (`appl/cmd/llmsrv.b`) puts the mark at 2048, below the system
prompt itself.

**Where it fits:**

- **Private by construction.** A task given only this model in its
  namespace cannot send its data off the machine. No policy setting is
  needed to enforce that.
- **Narrow tools, not a general "ask".** The one write-up that put this
  model behind a coding agent came to the same conclusion: expose a few
  narrow operations, each stating its limits, and let the big model
  delegate to them. This is the LLM-as-tool shape of `INFR-2`. Examples
  are a task's title, a commit message, a summary of a short file, a
  label, a schema-shaped extraction, and what is in an image.
- **Offline fallback.** Plain chat (no tools) when no network is reachable.
- **Vision.** This is the first model on hand that takes an image. `/mnt/llm`
  has no image input yet. Adding one (`attach` a file to a session, sent
  as an image part) is a separate extension, and every vision-capable
  backend would gain from it.

## Design

### 1. Gates: one wire shape for every engine

`llmsrv` already reaches every non-Anthropic backend through one seam,
OpenAI chat completions over HTTP (`llmclient->askopenai`). claude-gate
and codex-gate showed that anything else can be put behind that seam by a
host daemon on loopback, which `emu` does not manage. On-device engines
are the general case of the same thing: each has a native, platform-only
API, so each gets a gate.

Today's informal contract becomes a written one. Every gate must:

| Endpoint | Must |
| --- | --- |
| `POST /v1/chat/completions` | Honour `stream` true *and* false (absent means false, as OpenAI defines it). Honour `max_tokens`. Report `finish_reason: length` when it cuts a reply. Return `tool_calls` for `tools`, or **refuse** them (400 naming the reason), never ignore them. Report a guardrail refusal as an error that says so, not as empty text. |
| `GET /v1/models` | List models, each with `context_window` (`llmclient->contextwindow` already reads that key, so `llmsrv` learns the window with no `window=` setting). |
| `GET /health` | `status` plus, when the engine cannot serve, a `reason` a person can act on (`apple-intelligence-off`, `model-downloading`, `device-not-eligible`, `license-not-accepted`). |

All gates listen on 127.0.0.1 only. As with claude-gate, loopback is the
trust boundary, and remote consumers reach the model through `llmsrv`'s
authenticated 9P export, never through the gate's port.

**`fm-gate` (macOS, Swift).** A small SwiftPM executable in
`tools/fm-gate/` with no dependencies beyond Foundation and
FoundationModels. It would listen on port 11437, next to claude-gate
(11435) and codex-gate (11436). It is built on the framework rather than
wrapping `fm serve`:

- **Window from the model.** `SystemLanguageModel.default.contextSize`,
  reported in `/v1/models`.
- **Availability from the model.** `availability` maps to `/health` reasons.
- **Tools by claude-gate's hanging handler.** The framework's `Tool`
  protocol runs tools in-process, which is the same inversion claude-gate
  solved. Each request's `tools` become `Tool`s whose `parameters` is a
  `GenerationSchema` built at runtime from the JSON schema
  (`DynamicGenerationSchema`, arguments as `GeneratedContent`). `call`
  answers the HTTP request with `tool_calls` and waits on a continuation.
  The next request's `role=tool` messages resume it.
- **Its own limits on the model.** One request at a time (the model's
  rule) with a queue, a deadline per request, and cancellation when the
  client goes away. The runaway generation that wedges `fm serve` must
  not wedge the gate.
- **Images.** A data-URL image part becomes an `Attachment`.

A mock mode (`FM_GATE_MOCK=1`), as claude-gate has, lets
`tests/host/fm_gate_test.sh` check the HTTP surface on any host, Linux CI
included.

**Phase 0 with no gate.** `fm serve` is usable today for plain chat,
after one fix in `llmclient`:

```sh
# host, once:  sudo fm license;  fm serve --port 1976
llmsrv -m /mnt/llms/apple -b openai -u http://127.0.0.1:1976/v1 -M system -C 4096
```

The fix: `buildopenairequestjson` omits `stream` on a non-streamed
request, and `fm serve` takes absence as "stream". The SSE body it sends
back would then fail `parseopenairesponse`. Sending `"stream":false`
explicitly is what OpenAI defines as the default, so every other server
is unaffected.

### 2. A mount per provider, `/mnt/llm` the default

Today one `llmsrv` serves one backend at `/mnt/llm`. An on-device model is
worth most *beside* the main one, so the change is to run one `llmsrv` per
configured provider, each on its own mount point (`-m` already exists),
and bind the default:

```
/mnt/llms/
├── claude/          an llmsrv tree, unchanged: new, models, caps, {id}/...
├── apple/           llmsrv -b openai -u http://127.0.0.1:11437/v1
└── ollama/
/mnt/llm  →  bind of /mnt/llms/claude    (the default; every consumer unchanged)
```

- **Nothing that uses `/mnt/llm` changes.** Veltro, lucibridge, wiki9p,
  msgwatch and the shell keep opening `/mnt/llm/new`.
- **The provider is a namespace a task is given.** `nsconstruct` already
  grants `/mnt/llm` by path. A task built with
  `bind /mnt/llms/apple /mnt/llm`, and no `/mnt/llms`, can reach only the
  on-device model. A skill or tool that wants a specific provider opens
  `/mnt/llms/<name>/new` by name, and the grant to that path is the
  capability.
- **Remote composes the same way.** A provider can be a 9P mount
  (`mode=remote` today) at `/mnt/llms/<name>` as well as a local `llmsrv`.

This is the multi-model half of `INFR-1`, done in the namespace rather than
inside `llmsrv`. `llmsrv` stays one backend per process, and the routing
decision stays with whoever builds the namespace (mechanism, not policy).

**Configuration** grows from one entry to several, in the same
`key=value` lines, read by `lib/lucifer/llmsrv.sh`, `lib/sh/profile`,
`lib/sh/serve-profile`, `llmctl` and Settings. A file without `llm=`
lines is read exactly as today and becomes the single provider `default`:

```
llm=claude backend=cli url=http://127.0.0.1:11435/v1 model=sonnet
llm=apple  backend=openai url=http://127.0.0.1:11437/v1 model=system
llm=nas    mode=remote dial=tcp!nas!5640 auth=keyring
default=claude
```

### 3. Capabilities as a text file

Today a consumer cannot ask a provider what it can do. The window is
learned silently per model, and nothing says whether tools or images
work. Each provider gets `/mnt/llms/<name>/caps`, read-only text, one
fact per line:

```
window 4096
tools yes
vision yes
reasoning no
where device
```

`where` is `device` (this machine), `lan` (a machine the user runs) or
`cloud` (someone else's), as the configuration declares it. `llmsrv`
fills the rest from the gate's `/v1/models` where the gate says, and
otherwise from configuration. A consumer chooses a provider by what it
needs: a delegation tool that wants vision and `where device` reads the
`caps` files under `/mnt/llms`. `llmsrv` makes none of these choices.

## Other platforms: the same gate shape

| Platform | Engine | Gate |
| --- | --- | --- |
| macOS 27 | Foundation Models (on-device; PCC needs an entitlement) | `fm-gate` (Swift) |
| iOS 27 | Foundation Models, and MLX per [IOS-ONDEVICE-LLM.md](IOS-ONDEVICE-LLM.md) | `fm-gate`'s core linked into the app (no separate daemons on iOS); Option A or B of that note |
| Linux | llama.cpp server, Ollama, vLLM, SGLang | none needed: already OpenAI-shaped |
| Windows | Foundry Local (OpenAI-shaped on loopback, to verify) | likely none; a probe for `/v1/models` |
| Android | Gemini Nano through Android's on-device AI APIs | a gate in the Android glue (`emu/Android`), to research |

The contract in §1 is what lets a new engine arrive as a gate and a
`llm=` line, with nothing else in the stack changed.

## Phasing

1. **`llmclient`: explicit `"stream":false`.** One line, with a test in
   `tests/` against a canned SSE-by-default server. This lets Phase 0 run
   against `fm serve` for plain chat.
2. **`/mnt/llms` and multi-entry config.** The boot scripts start one
   `llmsrv` per `llm=` line and bind the default. Settings lists the
   providers. `tests/host/` covers a two-provider boot (two mock gates),
   with the default bound and a task restricted to one.
3. **`caps`** in `llmsrv`, filled from `/v1/models` and configuration.
4. **`fm-gate`**: Swift on FoundationModels, mock mode and host test,
   launchd plist, `llmctl set apple`, and a Settings entry ("On-device
   (Apple)").
5. **Consumers**: a narrow Veltro tool (or a `spawn` budget) that delegates
   to a `where device` provider; image input for `/mnt/llm` as its own
   change.
6. **iOS**: `fm-gate`'s core in the app, per
   [IOS-ONDEVICE-LLM.md](IOS-ONDEVICE-LLM.md).

Phases 1–3 are useful without Apple: they give Ollama-beside-Claude today.

## Open questions (to settle on a macOS 27 Mac)

- Can a plain command-line executable (not an app bundle) use
  FoundationModels without an entitlement or an `fm license` step?
- Do dynamic tool schemas (`GeneratedContent` arguments with a runtime
  `GenerationSchema`) work for arbitrary JSON schemas, or only a subset
  (no `$ref`, no type arrays, as testers found for `fm serve`)?
- What is the real window on 27.x: 4096, 8192, or does it depend on the
  machine? The gate should report `contextSize`, not assume.
- What do Apple's acceptable-use terms for the framework permit when the
  model is served on loopback to other local processes?
- Apple Intelligence availability by region and language. One report says
  the new generation is English-only at launch. The gate's `/health`
  reason should cover this.

## References

- `appl/cmd/llmsrv.b`: the `/mnt/llm` server (`-m`, `marklimit`, `modelwindow`).
- `appl/lib/llmclient.b`: `buildopenairequestjson`, `contextwindow`.
- `lib/lucifer/llmsrv.sh`, `appl/wm/settings.b`, `appl/cmd/llmctl9p.b`: where configuration is read.
- `appl/veltro/nsconstruct.b`: how `/mnt/llm` is granted to an agent.
- `tools/claude-gate/`: the hanging tool handler `fm-gate` would reuse.
- Apple: [What's new in Foundation Models (WWDC26 241)](https://developer.apple.com/videos/play/wwdc2026/241/),
  [Bring an LLM provider to Foundation Models (339)](https://developer.apple.com/videos/play/wwdc2026/339/),
  [fm CLI and Python SDK (334)](https://developer.apple.com/videos/play/wwdc2026/334/).
- Testers: [fm-proxy](https://github.com/gregbarbosa/fm-proxy),
  [the model behind a coding agent](https://dev.to/yrangana/what-i-learned-putting-macos-27s-on-device-model-behind-a-coding-agent-ckd),
  [fm on macOS 27](https://clews.id.au/til/macos-27-ships-an-on-device-llm-cli-called-fm/).
