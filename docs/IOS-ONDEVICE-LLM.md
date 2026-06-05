# On-device LLM inference on iOS — `/mnt/llm` backend swap

*Design note for iOS Phase C (`docs/IOS.md:162`). The 9P surface at
`/mnt/llm` stays exactly as it is today; only the thing behind it changes.
This document records why that is cheap, what the reusable prior art is
(Full Moon / MLX), and the two concrete wiring options with their
trade-offs. Nothing here is built yet.*

## Motivation: the seam already exists

InferNode does **zero in-process LLM inference today.** `/mnt/llm` is a 9P
filesystem facade (`appl/cmd/llmsrv.b`) over an HTTP client
(`appl/lib/llmclient.b`) that talks to Ollama (OpenAI-compatible) or the
Anthropic API. Every consumer — Veltro (`appl/veltro/agentlib.b`,
which just `open`s `/mnt/llm/$id/ask` and read/writes it), lucibridge
(`appl/cmd/lucibridge.b`), the shell — is backend-agnostic. The only
native compute that exists in the tree is `libinterp/gpu.c` (TensorRT
*vision* on Jetson); there is no LLM engine, no llama.cpp, no ggml, no
MLX anywhere.

That clean separation is the whole reason on-device inference is
tractable: we do **not** port a model into Limbo or Dis. We stand up a
native inference engine on the device and point the existing backend
seam at it. The `/mnt/llm/$id/{ask,stream,model,system,temperature,tools,
context,...}` contract is unchanged, so Veltro, lucibridge, and the UI
need **no modification**.

## Prior art: Full Moon is a runtime, not a model

[Full Moon (`fullmoon`)](https://github.com/mainframecomputer/fullmoon-ios)
is an open-source iOS/iPadOS/macOS/visionOS chat app by Mainframe. The
important fact for us: **there are no proprietary "Full Moon models."**
What is Metal-optimised is the *runtime* —
[MLX Swift](https://github.com/ml-explore/mlx-swift) (Apple's open ML
framework, which lowers to Metal 3 and exploits unified memory). The
weights it runs are **standard open-weight models converted to MLX
4-bit format**, publicly hosted on Hugging Face under
[`mlx-community`](https://huggingface.co/mlx-community). Full Moon ships
`Llama-3.2-1B-Instruct-4bit` (~0.7 GB) and `Llama-3.2-3B-Instruct-4bit`
(~1.8 GB) and can pull others (Qwen, Mistral, DeepSeek-R1 distills).

So the reusable asset is the **MLX-Swift-on-Metal inference path**, and
the models are free and public. The exact models Full Moon uses, plus
the whole MLX catalogue, are available to us.

## Recommended models (tested against the agent harness)

The MLX catalogue is open to us, with two hard constraints: **not every
size works with the Veltro agent stack** (its system prompt carries the
full tool-calling template, and very small models can't follow it), and
**no Chinese-origin models** — Qwen and DeepSeek distills are excluded
regardless of quality. Allowed families: **Llama (Meta), Mistral, GPT-OSS.**

- **Not recommended: `Llama-3.2-1B-Instruct-4bit`.** Observed 2026-05-27
  (SwiftLM on Metal, driven through `/mnt/llm`): to a plain "Hello" it
  emitted a raw tool-call JSON *example* instead of a reply — too weak for
  the tool template. Keep it only as a download-speed / plumbing smoke test.
- **On-device pick: `mlx-community/Llama-3.2-3B-Instruct-4bit`** (~1.8 GB,
  Meta; the Full Moon default). Tested through `/mnt/llm` — coherent and
  format-following. This is the working on-device model.
- **Tried, not recommended on-device: `Ministral-3-8B-Instruct-2512-4bit`**
  (Mistral, ~4.5 GB). Despite the size it dropped multi-step reasoning at
  4-bit (narrated the right steps for `3-1+2` but answered "2"), so we stay
  on Llama-3.2-3B for the device.
- **Server-side muscle: GPT-OSS** — `gpt-oss-20b-MXFP4-Q4` (~12 GB, Mac/
  desktop; too large for the phone, reached via remote `/mnt/llm`). The better
  tool-user, and where the device defers over the seam.

## Decision (2026-05-27): open-weight basis; any engine stays behind the seam

Settled with the project owner:

- **Open weights are required.** InferNode's on-device model will be a
  *fine-tune* for InferNode (cf. the IOL corpus/training pipeline), which
  needs an open-weight base. So the basis is an open-weight model
  (Llama/Qwen/…) converted to MLX 4-bit — exactly the `mlx-community`
  path above.
- **Apple's Foundation Models framework (iOS 26) is rejected as the
  basis.** Its on-device model is *closed*: no public weights, API-only,
  no fine-tuning beyond LoRA adapters, and it cannot be relocated off the
  device. That fails both the fine-tuning requirement and the InferNode
  premise that inference is a portable service you run where the compute
  is.
- **Decoupling is non-negotiable.** *If* Apple FM (or any other engine)
  is ever used, it must sit behind the `llmsrv` seam — the Option-A
  localhost-OpenAI shim or an Option-B `backend=` dispatch — never wired
  directly into Veltro/lucibridge. Nothing in the agent stack may couple
  to a specific engine.

## Engine choice: MLX vs llama.cpp (the real decision)

| | MLX (Swift) | llama.cpp (C/C++) |
| --- | --- | --- |
| Apple-silicon perf | Best; Apple-blessed, Metal 3, neural accelerators | Very good; Metal backend |
| Language / packaging | Swift + SwiftPM | Pure C/C++ |
| Fit with our build | Awkward — our iOS emu is an `mk SYSTARG=iOS` xcrun **cross-compile to `libemu.a`**, *not* an Xcode/SwiftPM project (`docs/IOS.md:79`) | Clean — links into the existing C build like any other lib |
| Model format | MLX 4-bit (HF `mlx-community`) | GGUF |

**Lower-friction path for our mk toolchain is llama.cpp**; it drops into
the C build the way `libinterp/gpu.c` already does for TensorRT.
**Higher-ceiling path is MLX**, which is what Full Moon proves out but
drags Swift packaging into a build that currently has none. This is the
first thing Phase C has to decide.

## Wiring options

### Option A — embed an OpenAI-compatible local server (fastest, zero Limbo/9P changes)

Run a tiny in-app inference server that speaks the OpenAI API on
`127.0.0.1`, then launch the existing `llmsrv` against it with its
current flags:

```
llmsrv -b openai -u http://127.0.0.1:PORT/v1 -M llama-3.2-3b-instruct-4bit
```

The entire `/mnt/llm` + Veltro + lucibridge stack runs untouched.
[`SharpAI/SwiftLM`](https://github.com/SharpAI/SwiftLM) is exactly this
— a native MLX Swift, OpenAI-compatible inference server for iOS/macOS —
so this is the lowest-friction proof of life. Cost: a second
HTTP hop and an extra in-process listener.

### Option B — native built-in Dis module (tighter, more work, production shape)

Wrap llama.cpp/MLX as an emu built-in module exposed to Limbo via a
`.m` interface, following the existing `libinterp/gpu.c` precedent, and
add a `backend="local"` dispatch in `llmsrv.b`'s `callbackend`. No
localhost socket, no second HTTP server, inference is one C call away
from the 9P layer. This is the right long-term shape.

Both options leave the `/mnt/llm` filesystem layout identical; the change
is purely at the HTTP/local boundary inside (Option A) or just below
(Option B) `llmsrv`.

## Constraints and caveats

- **JIT is a non-issue.** The iOS emu is interpreter-only (`-c0`) by
  Apple's W^X policy (`docs/IOS.md:46`). Inference is *native compiled
  code with a Metal backend*, not Dis bytecode, so the no-JIT contract
  doesn't touch it.
- **Memory entitlement.** Needs
  `com.apple.developer.kernel.increased-memory-limit`. 1B-4bit
  (~0.7 GB) is comfortable; 3B (~1.8 GB) is fine on recent iPhones,
  tight on older hardware. Bound model size to device class.
- **Licensing.** MLX = MIT, Full Moon app = MIT, llama.cpp = MIT;
  weights under their own open licences (Llama community licence,
  Apache-2.0, etc.). Clean for our use.
- **App Store posture.** A self-contained app that runs no *downloaded
  executable code* is reviewable, but a model download path and a
  "terminal" reputation draw scrutiny — same open question already
  logged in `docs/IOS.md:188`. Decide TestFlight-only vs. submission
  before polish.

## Recommended sequencing

1. Decide engine: **llama.cpp** for first signal (build fit), revisit
   MLX for perf ceiling.
2. **Option A** spike to prove the round-trip: local OpenAI server +
   unmodified `llmsrv -b openai` → `/mnt/llm` → Veltro answers a prompt
   fully offline on a device.
3. Benchmark tok/s on target hardware; size the model floor per device.
4. If the second hop or the extra listener is unacceptable, graduate to
   **Option B** (built-in module + `backend="local"`).

## References

- `docs/IOS.md` — iOS port plan; Phase C is the parent of this note.
- `appl/cmd/llmsrv.b` — the 9P `/mnt/llm` server (backend dispatch lives here).
- `appl/lib/llmclient.b`, `module/llmclient.m` — the HTTP client seam.
- `libinterp/gpu.c` — existing native-module + `.m` precedent (TensorRT vision).
- [fullmoon-ios](https://github.com/mainframecomputer/fullmoon-ios),
  [mlx-swift](https://github.com/ml-explore/mlx-swift),
  [mlx-community on HF](https://huggingface.co/mlx-community),
  [SwiftLM](https://github.com/SharpAI/SwiftLM).
