# A local model on a phone, a Pi, or bare metal — one pattern

*Design note, 2026-10-25. Reviews `IOS-ONDEVICE-LLM.md` (2026-05-27)
against what has changed since, adds the Raspberry Pi (hosted and
bare-metal) and Android, and sets out a single pattern all of them
follow. Nothing in it is built yet beyond what the May note recorded.
Figures from outside this tree are linked to their source and marked
where they are reported rather than measured here; the measurements
this pattern needs are listed at the end.*

## The pattern in one paragraph

**The contract is `/mnt/llm`, and nothing above it changes.** Every
consumer (veltrosrv and its agents, lucibridge, Xenith's `Agent`, the
shell) opens files under `/mnt/llm`; none of them knows where the model
is. What varies per machine is only *where the engine sits relative to
the namespace* — imported from a peer, beside emu on the host, or inside
the kernel — and *what the agent asks of it*, a profile sized to the
device. Three placements, one profile mechanism, one contract.

```
           veltrosrv · lucibridge · Xenith Agent · sh
                              │  open/read/write
                          /mnt/llm             ← the contract (docs/llm-mount.md)
                              │
                           llmsrv              ← the only thing that knows
          ┌───────────────────┼────────────────────┐
     P1 remote           P2 host-adjacent     P3 in-kernel
   mount -k peer      -b openai, loopback      -b local
   /mnt/llm over 9P   llama-server, MLX…       $Infer, libinterp
```

## What changed since May

| | May (IOS-ONDEVICE-LLM.md) | Now |
|-|-|-|
| Agent harness | lucibridge + agentlib | veltrosrv at `/mnt/veltro` (`af1d759`); lucibridge is its client. Still only opens `/mnt/llm/$id/*`: the seam holds. |
| Long sessions | client-driven compaction | llmsrv compacts at the end of a turn, never inside a tool exchange (`0ac2540`, `fe79927`); the mark is `-c` or `ctl autocompact`. This is what makes a small context window usable at all. |
| Tool narrowing | — | A spawned agent loads only its delegation budget's tools (INFR-486, `tests/host/spawn_budget_test.sh`). The mechanism a small-model profile needs already exists. |
| Bare metal | Pi 3B+ only | Pi 4B on a board since 2026-10-15: four A72 cores, the JIT, 3.9GB usable, GENET at 932 Mbit/s in, the card at 19 MB/s (`os/bcm2711/README.md`). A machine you would run a 1–3B model on. |
| Apple | Foundation Models rejected: closed weights | WWDC26: Foundation Models is now a **protocol**. Any engine conforming to `LanguageModel` is called the same way as Apple's, and MLX ships one (`MLXLanguageModel(modelID: "mlx-community/…")`) ([WWDC26 339](https://developer.apple.com/videos/play/wwdc2026/339/)). Apple's own on-device model was rebuilt, is "better at logic and tool calling", gained image input, and shows a context of 8192 ([WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/)). Core AI succeeds Core ML ([InfoQ](https://infoq.com/news/2026/06/apple-core-ai-wwdc)). |
| Models | Llama 3.2 3B on device; GPT-OSS 20B on a server | Add **Gemma 4 E2B/E4B** (Google, 2026-04-02, Apache 2.0, native function calling, aimed at phones and Pis) ([report](https://www.implicator.ai/google-releases-gemma-4-under-apache-2-0-dropping-its-custom-ai-license/)), **Ministral 3 3B** (Mistral, an allowed family), **Granite 4.0 Micro**, **Phi-4-mini** and **SmolLM3** to the candidates. All are Apache 2.0 or MIT; Llama's licence is the most restrictive of the set ("Licences", below). |
| Android engines | llama.cpp or "something" | llama.cpp has three Snapdragon backends: CPU, Adreno over OpenCL, and the Hexagon NPU ([llama.cpp docs](https://huggingface.co/datasets/echodict/llama.cpp/blob/main/docs/backend/snapdragon/README.md)). One user's report puts Hexagon at the CPU's speed but much cooler ([report](https://reddit.sentinel-team.org/posts/1t0k6fj/snapshots/2026-05-02T03%3A06%3A21.60641Z)). Google's LiteRT-LM runs Gemma 4 with function calling but has no official OpenAI-shaped server ([LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)). |
| llama.cpp internals | "pure C/C++, links into the C build" | Its CPU backend is now mostly C++: 8 of the 10 top-level sources in `ggml/src/ggml-cpu` are `.cpp` ([tree](https://github.com/ggml-org/llama.cpp/tree/master/ggml/src/ggml-cpu)). Fine beside emu; not something to put in a kernel (P3 below). |

**What still holds from May.** Open weights are required, because the
on-device model is to be an InferNode fine-tune (the IOL pipeline).
Apple's own model is still closed, so it is still not the basis. And
decoupling still holds: any engine, Apple's included, sits behind
`llmsrv`. The WWDC26 protocol doesn't change that. It is a Swift API
shaped like our seam, and it could be useful *inside* the iOS app as a
way to host MLX, but `/mnt/llm` remains the only contract agents see.

**What the May note got wrong, or that is now stale.**
`IOS-ONDEVICE-LLM.md` called llama.cpp "pure C/C++" that "drops into
the C build the way `gpu.c` does". That is true for linking it into emu
on a host. It is not true for the native kernel, and it is no longer
pure C. Its "Allowed families" list predates Gemma 4's Apache 2.0
release. Whether to add Gemma is the project owner's call; it is not
Chinese-origin, so the stated exclusion does not cover it. And its
licensing line, "clean for our use", holds for the Apache-licensed
models but not for Llama, its on-device pick: see "Licences", below.

## Licences

*Checked 2026-10-25 against each model card and licence text, linked.
A summary of what the texts say, not legal advice; a deployment for a
government or defence user should have counsel read the licence
itself.*

What InferNode needs from a licence: to download the weights at
install (pinned, hashed) or bundle them in the iOS and Android apps; to
**fine-tune them and distribute the fine-tune** (the IOL pipeline);
and to impose nothing on users that an MIT project cannot pass on. The
project already ships a CNSA 2.0 mode, so government and defence users
are in scope, and use restrictions matter as much as commercial ones.

| model | from | licence | use restrictions | on a fine-tune | for InferNode |
|-|-|-|-|-|-|
| Gemma 4 E2B, E4B | Google | Apache 2.0 ([card](https://huggingface.co/google/gemma-4-E2B-it), [text](https://ai.google.dev/gemma/docs/gemma_4_license)) | none in the licence text | Apache's notices | **clean** |
| Ministral 3 3B, 8B (`-2512`) | Mistral | Apache 2.0 ([3B](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512), [8B](https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512)) | none | Apache's notices | **clean** |
| Granite 4.0 Micro (3B) | IBM | Apache 2.0 ([card](https://huggingface.co/ibm-granite/granite-4.0-micro)) | none | Apache's notices | **clean** |
| SmolLM3 3B | Hugging Face | Apache 2.0 ([card](https://huggingface.co/HuggingFaceTB/SmolLM3-3B)) | none | Apache's notices | **clean** |
| Phi-4-mini (3.8B) | Microsoft | MIT ([card](https://huggingface.co/microsoft/Phi-4-mini-instruct)) | none; trademarks per Microsoft's guidelines | MIT's notice | **clean** (no express patent grant, unlike Apache) |
| GPT-OSS 20B | OpenAI | Apache 2.0, plus a policy of one sentence: comply with applicable law ([card](https://huggingface.co/openai/gpt-oss-20b), [policy](https://huggingface.co/openai/gpt-oss-20b/blob/main/USAGE_POLICY)) | none beyond the law | Apache's notices | **clean**; server-side |
| Llama 3.2 1B, 3B | Meta | Llama 3.2 Community Licence ([card](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct)) | its Acceptable Use Policy, incorporated by reference, prohibits "Military, warfare, nuclear industries or applications, espionage", anything subject to ITAR, and "Operation of critical infrastructure, transportation technologies, or heavy machinery" ([AUP](https://github.com/meta-llama/llama-models/blob/main/models/llama3_2/USE_POLICY.md)); a licence from Meta above 700M monthly users | the model's name **must begin with "Llama"**; "Built with Llama" displayed in the product | **usable, with conditions**; see below |
| Gemma 3, 3n and earlier | Google | Gemma Terms of Use ([terms](https://ai.google.dev/gemma/terms)) | the Prohibited Use Policy, which must be passed on to recipients as an enforceable term; Google may restrict use "remotely or otherwise" | the same terms, a Notice file | **avoid**; Gemma 4 replaces them |
| Ministral 3B, 8B (`-2410`) | Mistral | Mistral Research Licence ([card](https://huggingface.co/mistralai/Ministral-8B-Instruct-2410)) | no commercial use without a separate licence | — | **avoid**; the `-2410` and `-2512` names differ only in the suffix |
| LFM2 | Liquid AI | LFM Open Licence v1.0 ([text](https://huggingface.co/LiquidAI/LFM2-1.2B/blob/main/LICENSE)) | commercial use only by entities under US$10M annual revenue; terminates automatically on any breach | — | **avoid**: an integrator over the threshold is unlicensed, and we cannot vet who that is |
| Hailo AI HAT+ 2 models | various | — | — | — | excluded by origin (Qwen, DeepSeek) |

**Llama, the incumbent, is the most restrictive of the usable
candidates.** Three of its terms bear on this project:

- **The military clause.** In November 2024 Meta said it was waiving it
  for US government agencies and their contractors, and for their
  counterparts in the UK, Canada, Australia and New Zealand, while
  saying "Our Acceptable Use Policy remains in place"
  ([TechCrunch](https://techcrunch.com/2024/11/04/meta-says-its-making-its-llama-models-available-for-us-national-security-applications),
  [IEEE Spectrum](https://spectrum.ieee.org/ai-used-by-military)). That
  is a public statement, not a term of the licence. The AUP text names
  no exception. A defence deployment that relies on the waiver needs
  that reliance confirmed by counsel, and ideally by Meta in writing.
- **The naming rule.** An InferNode fine-tune of Llama would have to be
  called "Llama-something", and the apps would have to show "Built with
  Llama".
- **Flow-down.** The licence and its AUP travel with every copy, so a
  user of an InferNode release would be bound by them too.

**The Apache-licensed models have none of this.** Gemma 4 E2B, Ministral
3 3B and Granite 4.0 Micro are tool-calling models of the same class as
Llama 3.2 3B.

### Decision (2026-10-25): clean licences only

Settled with the project owner:

- **InferNode uses, recommends, defaults to and offers only models
  whose licence permits military and tactical use without
  conditions:** Apache 2.0 or MIT, with no use policy beyond complying
  with the law. This adds to the May rules (open weights; no
  Chinese-origin models) and does not replace them.
- **Eligible now:** Ministral 3 (`-2512`), Mistral Small 3.2, Mistral
  NeMo, Granite 4.0, SmolLM3, Phi-4-mini, GPT-OSS; Gemma 4 on the texts,
  with the Prohibited Use Policy's scope confirmed before it ships.
- **Out:** Llama, every version (its AUP), and not kept as a baseline
  either; Gemma 3, 3n and earlier; Ministral `-2410`; LFM2; and, as
  before, Qwen, DeepSeek and GLM.
- **The device default is chosen by the model-eval run** (step 2 under
  "Order of work") from the eligible set. Until then the installers
  offer `granite4:micro` (2.1GB in Ollama, text only, the nearest in
  size to the `llama3.2:3b` they offered), `ministral-3:8b` and
  `gpt-oss:20b`.
- **A licence is only the first gate.** It does not settle export
  control, ITAR on the *application*, or a service's own rules for
  fielding AI. Those belong to whoever deploys it.

**Testing is not using** (settled the same day). `tests/model-eval/`
keeps testing Qwen. GLM was tested too, and has since been dropped from
the matrix; the reasons are below. They are popular for running models
locally, so a user may well choose one under the installer's "Custom",
and the harness should work with what users run. InferNode does not
recommend, default to or ship them.

What the matrix runs, against what is current (2026-10-25, from the
publishers' pages and Ollama's library):

| family | in the matrix | current | small / phone-sized | licence |
|-|-|-|-|-|
| Qwen | `qwen3.6:27b` (April 2026) | Qwen3.8-27B (August 2026): vision, thinking **on by default** at `xhigh` ([card](https://huggingface.co/Qwen/Qwen3.8-27B)) | Qwen3.5 0.8B, 2B, 4B, 9B (February–March 2026): vision, tools, thinking off by default for the small ones ([2B card](https://huggingface.co/Qwen/Qwen3.5-2B)); 1.2GB, ~3GB and ~3.5GB in Ollama | Apache 2.0 |
| GLM (Zhipu, as Z.ai) | `GLM-4-32B-0414` (April 2025); **dropped 2026-10-25** | GLM-5.x is 321B–753B and only in Ollama's cloud; locally, GLM-4.7-Flash, a 30B mixture of experts with 3B active per token: tools, thinking ([card](https://huggingface.co/zai-org/GLM-4.7-Flash)) | none: Zhipu publishes no current chat model under 9B (GLM-OCR at 1B reads documents only) | MIT |

How popular, by Ollama pulls ([library](https://ollama.com/library?sort=popular)):
the Qwen families together have well over 100M, more than any other
publisher's apart from Llama's (`qwen2.5` 43.6M, `qwen3` 41.5M, `qwen3.5`
23.4M, `qwen3.6` 7.3M, `qwen3.8` 4.9M). GLM's local models are niche:
`glm-4.7-flash` has 2.1M. The clean models for comparison: `gemma4`
27.8M, `gpt-oss` 14.2M.

Zhipu has been on the US Entity List since January 2025
([Bloomberg](https://www.bloomberg.com/news/articles/2025-01-16/us-blacklists-tencent-backed-ai-startup-as-tech-curbs-deepen)).
That restricts exports *to* Zhipu, not downloading its published
weights.

**GLM was dropped from the matrix (2026-10-25).** In June it behaved
like gpt-oss (`tests/model-eval/cross-model/README.md`), so it found
nothing the baselines did not. Its model there was eighteen months old.
The current local successor, GLM-4.7-Flash, sees little use, and Zhipu
publishes no small model to test the edge case with.

One note on
Gemma: Google's site still links its 2024 Prohibited Use Policy from
the Gemma 4 pages, and that policy's own scope is just "Gemma". The
Gemma 4 licence text is plain Apache 2.0 and the Gemma Terms of Use list
only Gemma 1 to 3n, so on the texts the policy does not bind Gemma 4.
That should be confirmed before Gemma 4 ships.

**Conversions are derivatives, and a supply-chain risk.** A GGUF or
MLX file is the original model under the original licence. Third-party
conversions (`mlx-community`, community GGUFs) are someone else's
artefact. Convert from the publisher's own weights, at a pinned
revision, and record both hashes in the manifest
(`DESIGN-PRINCIPLES.md`, "The host boundary"). An Apache model's
distribution then needs its `LICENSE` and any `NOTICE` alongside the
weights, and modified files marked as modified, which a fine-tune is.

**Size check for the 4GB boards.** Gemma 4 E2B is 2.3B effective
parameters but 5.1B with its embeddings ([card](https://huggingface.co/google/gemma-4-E2B-it)).
Google's own runtime lists it at 2.58GB ([LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)).
Ollama's `gemma4:e2b` (Q4_K_M, with its vision and audio parts) is
4.6GB, and `ministral-3:3b` (with its vision encoder) is 3.0GB;
`granite4:micro` is 2.1GB, and `granite4:micro-h` (the hybrid) 1.9GB
([Ollama](https://ollama.com/library/granite4/tags)). On a 4GB Pi 4,
Granite 4.0 Micro is the clean 3B-class model that leaves room for a KV
cache. A text-only conversion of the other two is a measurement for
step 1.

## The three placements

### P1 — remote: import `/mnt/llm` from a peer

```
mount -k /lib/keyring/serve-llm 'tcp!llmhost!5640' /mnt/llm
```

**Works today, on every platform, bare metal included,** with no code.
The peer is `serve-llm` (`docs/HEADLESS-LLM-DAEMON.md`): a headless emu
whose `llmsrv` fronts Ollama or llama-server. It runs on a Jetson, a
Mac, or a Pi 5 under Pi OS. The bare-metal Pi 4 has the network for it
(GENET at line rate) and the keyring for authenticating it. "Local"
here means the LAN, not the device. That is the right answer for the
Pi 3B+ (1GB) and the RISC-V boards, and it is how a device defers to a
larger model.

Use the keyring (the default) or `--cnsa`, never `--anon-lan`, unless
the wire is one you trust.

### P2 — host-adjacent: an engine beside emu, spoken to over loopback

```
llmsrv -b openai -u http://127.0.0.1:PORT/v1 -M <model>
```

On any hosted platform, run an engine that speaks OpenAI chat
completions on loopback. Then start the `llmsrv` that exists today
against it. This is May's "Option A", generalised:

| host | engine | acceleration | how it runs |
|-|-|-|-|
| macOS | llama-server, Ollama, MLX (SwiftLM) | Metal | separate process; works today |
| Linux, Jetson | llama-server, Ollama | CPU, CUDA, Vulkan | separate process; works today |
| Pi 5 / Pi 4 under Pi OS | llama-server | CPU (NEON; dot-product on the Pi 5's A76 only) | separate process; hosted emu (`build-linux-arm64.sh`) |
| Android | llama.cpp | CPU, Adreno OpenCL, Hexagon | a thread in the APK's process via JNI, or llama-server under Termux for a first test |
| iOS | MLX (SwiftLM) or llama.cpp | Metal | a thread in the app's process; there is no second process on iOS |

**What an engine must do to sit here.** This is the conformance
checklist, and the first thing to test against any candidate:

1. OpenAI `/v1/chat/completions` **with tools**: `tool_calls` out, `tool`
   messages in. For llama-server that means `--jinja`, so it applies the
   model's own chat template.
2. Streaming SSE with `stream_options.include_usage`, *or* a single
   JSON body. `llmclient` takes either (`tests/llmclient_sse_fallback_test.b`).
3. `/v1/models`, read by `/mnt/llm/models`.
4. **Reuse of the KV cache for a repeated prefix.** llmsrv sends the
   whole history on every request, as the OpenAI API requires, so an
   engine that does not cache the prefix pays to process the system
   prompt again on every step. On a Pi or a phone that cost is the
   whole budget (see "Fit", below). llama-server does this by default
   (`cache_prompt`).
5. Bound to `127.0.0.1` and **requiring a bearer key**. On Android, and
   in principle on iOS, any other app on the device can connect to a
   loopback port. Generate a random key per boot, give it to the engine,
   and put it in factotum as the `openai` key. llmsrv already reads
   factotum for that key and sends it as `Authorization: Bearer`
   (`appl/cmd/llmsrv.b`, `appl/lib/llmclient.b:525`), so nothing in
   InferNode changes.

### P3 — in-kernel: an engine as a built-in module

```
llmsrv -b local -M /n/models/llama-3.2-1b-q4_0.gguf
```

A bare-metal kernel has no host to run llama-server on, so P2 does not
exist there. If the model is to run *on* the Pi 4 rather than be
imported, the engine has to live inside the system. Its home is
**`libinterp`**, as a built-in module (`$Infer`) beside `$GPU`
(`libinterp/gpu.c`, `module/gpu.m`), for three reasons that are facts
about this tree:

- `libinterp` is linked by both emu and the native kernel. One engine
  then serves bare metal and, if wanted, the hosted platforms: this is
  May's "Option B" with one implementation instead of one per platform.
- On the native kernel it is the one library built with floating point,
  and `procsave` saves the whole FP/SIMD register file for every
  process (`os/arm64/main.c`, the comment above `procsave`). NEON
  kernels and their worker kprocs are safe there. Everywhere else in
  `os/` is `-mgeneral-regs-only`.
- `kproc` has the same signature under emu and the native kernel, so
  the worker pool for the matrix multiplies is written once.

**Mechanism in C, policy in Limbo.** The module does what only native
code can do fast, at the level of tokens. Everything particular to a
model family stays in Limbo, in llmsrv's `local` backend, where it can
be reviewed and changed without rebuilding a kernel:

```
Infer: module {
	PATH: con "$Infer";
	load:     fn(weights: array of array of byte, meta: string): (int, string); # per-tensor blocks
	tokenize: fn(h: int, s: string): array of int;
	detok:    fn(h: int, t: array of int): string;
	newctx:   fn(h: int, nctx: int): (int, string);        # a KV cache: one per session
	eval:     fn(c: int, t: array of int, keep: int): string; # keep: prefix tokens already cached
	sample:   fn(c: int, temp: real, topp: real, seed: int): int;
	freectx:  fn(c: int);
	unload:   fn(h: int);
};
```

Chat templates (Llama 3's, Gemma 4's), tool-call parsing, stop
sequences and the decision of what to keep are Limbo. The C side is a
GGUF reader, a forward pass for one or two architectures, and one or two
quantisations (Q4_0, Q8_0) with NEON kernels. That is the scale of
`llama2.c`, not of ggml. Do not try to import ggml into the kernel: its
CPU backend is C++.

**Constraints the board sets, from this tree:**

- **Memory.** A 4GB Pi 4 gives Dis about 3.9GB (`os/bcm2711/README.md`,
  "On the board"); an 8GB board's top 4GB is not mapped yet. That fits
  a 1B model (~0.7GB at Q4) or a 3B one (~1.9GB) with a KV cache. The
  pools refuse any single block over 1GB (`emu/port/alloc.c`,
  `tests/host/pool_nomem_test.sh`), so weights are loaded per tensor,
  which GGUF's layout gives you anyway. There is no `mmap`.
- **Loading.** At the card's 19 MB/s, a 1.9GB model takes about 100 s
  to read. From a peer over GENET at ~110 MB/s it is about 17 s. Either
  way, load once at boot and keep it loaded.
- **The A72 has no dot-product instructions** (it is ARMv8.0; `SDOT`
  arrived with ARMv8.2, which the Pi 5's A76 has). Quantised matrix
  multiplies on a Pi 4 are slower per clock than on a Pi 5, beyond the
  memory-bandwidth difference.
- **The weights are untrusted input to the kernel.** A GGUF file is a
  parser target; llama.cpp's own GGUF reader has had memory-safety bugs.
  Keep the reader small, bound every offset and size by the file's
  length, fuzz it on the host, and load only weights whose SHA-256 is in
  a pinned manifest (`DESIGN-PRINCIPLES.md`, "The host boundary").
- **Runes.** Hosted platforms have 21-bit runes (`c7d957b`); check
  what the native kernel does with a model's emoji before trusting
  `detok`.

P3 is a new built-in module and a new llmsrv backend, so it starts as a
proposal issue with this sketch (`DESIGN-PRINCIPLES.md`, "Proposing a
new service or tool"), not as code.

## Fit: the profile, and why prompt processing is the budget

Generating tokens is the number people quote. **Processing the prompt
is the number that decides whether an agent is usable** on these
machines. Veltro's system prompt is 14,220 bytes before any tool
definitions (`tests/host/agentloop/golden/veltrosrv-say.txt`:
`prompt 14220 bytes`), roughly 3,500–4,000 tokens.

What has been reported for Raspberry Pis (CPU only, not measured here):

| board | model | generation | source |
|-|-|-|-|
| Pi 5 8GB | Llama 3.2 3B | 4.61 tok/s | [Geerling](https://github.com/geerlingguy/ai-benchmarks) |
| Pi 5 16GB | Llama 3.2 3B | 4.88 tok/s | [Geerling](https://github.com/geerlingguy/ai-benchmarks) |
| Pi 400 (BCM2711, a Pi 4) | Llama 3.2 3B | 1.60 tok/s | [Geerling](https://github.com/geerlingguy/ai-benchmarks) |
| Pi 5 | Llama 3.2 1B Q4_K_M (Ollama) | 11.22 tok/s | [Slips](https://stratospherelinuxips.readthedocs.io/en/develop/immune/research_rpi_llm_performance.html) |
| Pi 5 | TinyLlama 1.1B Q4_0 (llama.cpp) | 14.4 tok/s | [comparison](https://medium.com/@omkar121212/ollama-vs-llama-cpp-on-raspberry-pi-5-8e7fbeb310de) |

Prompt-processing rates are scarcely published. One reported Pi 5
figure for a 1.1B model is about 108 tok/s. If that holds, the system
prompt alone costs about 35 s on a Pi 5 with a 1B model before the first
token, several times that with a 3B model, and more again on a Pi 4.
These are estimates to replace with measurements, but the conclusion
does not depend on the exact figures: **without prefix caching, every
agent step pays that cost again; with it, only the first does.**

So the profile for a small device is three settings, all of which are
mechanism that already exists or is listed above:

1. **Fewer tools.** A delegation budget (INFR-486) naming a handful of
   tools: a shorter prompt, and fewer wrong calls from a weak model.
   A shorter system prompt variant for small models goes with it.
2. **A compaction mark sized to the window.** `llmsrv -c` (or `ctl
   autocompact`) at about 75% of the model's real context. **Gap:**
   llmsrv's `CONTEXTLIMIT` is a constant 200000 (`appl/cmd/llmsrv.b`),
   so `/mnt/llm/$id/usage` reports the wrong denominator for every
   local model. It should come from the backend (llama-server's
   `/props` gives `n_ctx`) or from the profile.
3. **The prefix kept stable.** Compaction rewrites the history, so it
   should leave the system prompt and tool definitions exactly as they
   were at the head of the request; otherwise each compaction
   invalidates the cache. For P2 engines that can save a cache to disk
   (llama-server's slot save and restore), the system prompt's cache
   can be computed once and loaded at boot.

Weak models also make the namespace matter more, not less. A 3B model
will sometimes call the wrong tool with confident arguments. What it
can then reach is what was bound in front of it, and nothing else.

## Per machine

| machine | placement now | placement next | model fit | notes |
|-|-|-|-|-|
| Mac, Linux workstation | P2 | — | GPT-OSS 20B and up | the peer every other row can import from |
| Jetson | P2, and P1 server | — | 7–20B | `serve-llm` host |
| Pi 5 (Pi OS) | P2 | P1 server for bare-metal Pis | 1B–3B; 4B at a push | AI HAT+ 2 (Hailo-10H, 8GB of its own) runs only vendor-converted models, mostly from families this project excludes, and reviews disagree on its speed, one finding the CPU faster ([review](https://www.hardware-corner.net/local-llms-raspberry-pi-ai-hat-plus-2/)). Not in the pattern now; it could sit behind P2 later. |
| Pi 5 (bare metal) | — | — | — | No port: the RP1 southbridge. Raspberry Pi published a partial draft RP1 datasheet in 2023 ([CNX](https://www.cnx-software.com/2023/10/07/raspberry-pi-rp1-datasheet-block-diagram/)); whether it is enough for Ethernet and USB is worth re-checking before the next board is chosen. The GICv3 it needs already boots under `virt`. |
| Pi 4 (Pi OS) | P2 | — | 1B; 3B is slow | ~1.6 tok/s at 3B |
| Pi 4 (bare metal) | **P1** | P3 | 1B (3B fits, slowly) | P1 against a Pi 5 or Jetson today; P3 is the spike |
| Pi 3B+ (bare metal) | P1 | — | — | 1GB |
| RISC-V (`virt`, PolarFire) | P1 | — | — | no vector unit on the U54s |
| Android | P1, or P2 via Termux | P2 in-process | 1B–3B; Gemma 4 E2B | loopback key (P2 rule 5) matters most here |
| iOS | P1 | P2 in-process | Granite 4.0 Micro, Ministral 3 3B, Gemma 4 E2B to try (SwiftLM was proven with Llama 3.2 3B, now out: prove it again with one of these) | `-c0` does not matter to inference, which is native; the memory entitlement does |

## Order of work

Each step is useful on its own and none needs the next. The proposed
INFR tickets are not filed yet.

1. **Measure.** `llama-bench -p 512 -n 128` on a Pi 5 and a Pi 4 under
   Pi OS for Granite 4.0 Micro (and its hybrid), Ministral 3 3B, Gemma 4
   E2B, Phi-4-mini and SmolLM3, with each model's resident memory. Then the
   number that matters: time to the first token for Veltro's real
   prompt through `/mnt/llm`, first turn and second, which shows whether
   prefix caching works through llmsrv.
2. **Score the candidates.** Run `tests/model-eval/` (an OpenAI-shaped
   harness already) against each candidate behind llama-server, with
   the small-model tool budget. This decides the device model better
   than any leaderboard.
3. **The small-device profile.** A tool budget, a short system prompt,
   `-c` per model, and `CONTEXTLIMIT` from the backend. This is all
   Limbo, all testable on a laptop against a small model.
4. **P1 recipe for bare metal.** A bare-metal Pi 4 mounting `/mnt/llm`
   from a Pi 5 running `serve-llm`, written up in `docs/BAREMETAL.md`,
   with a host test if the harness can stand up the pair.
5. **P2 on the phones.** In-process engine threads with a per-boot
   bearer key: Android first (llama.cpp via the NDK, Hexagon or Adreno
   later), iOS next (SwiftLM is proven; decide whether to use the
   WWDC26 `LanguageModel` adapter inside the app).
6. **P3 spike.** A proposal issue with the `$Infer` sketch, then a
   C engine for one architecture and Q4_0 under emu first (where it can
   be debugged and compared with llama.cpp token for token), then on
   the bare-metal Pi 4.

## References

- `docs/llm-mount.md`: the contract.
- `docs/IOS-ONDEVICE-LLM.md`: the May note this one reviews.
- `docs/HEADLESS-LLM-DAEMON.md`: `serve-llm`, the P1 peer.
- `emu/Android/README.md`, `docs/HELLAPHONE.md`, `docs/IOS.md`: the
  phone ports.
- `docs/BAREMETAL.md`, `os/bcm2711/README.md`: the bare-metal Pi 4.
- `appl/cmd/llmsrv.b`, `appl/lib/llmclient.b`: the backend dispatch.
- `libinterp/gpu.c`, `module/gpu.m`, `appl/cmd/gpusrv.b`: the
  built-in-module precedent.
- `docs/DESIGN-PRINCIPLES.md`: proposals, mechanism and policy, the
  host boundary.
