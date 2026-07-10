# Voice Mode for Lucia: Phase 1

Status: analysis handoff and implementation plan for branch `feat/gui-stt-tts`.
Not usable end-to-end yet.

## Implementation Status

Phase 1 structure (1.0–1.6) is implemented. The branch now has:

- macOS `#A` audio enabled in the emulator config with a CoreAudio-backed
  `emu/MacOSX/audio.c` implementation.
- `/dev/audioctl` support for 16000 Hz mono PCM, needed by speech capture.
- A host audio smoke test at `tests/host/audio_macos_test.sh`.
- `speech9p` additions for Kokoro helper config, `sayq`, `cancel`, `listen`,
  and `wake` files. Helper binaries are still external and may be absent.
- A unified speech-provider architecture: `speech9p` consumes exactly one
  provider mount (contract in docs/SPEECH-ARCHITECTURE.md — listen/wake/say/
  cancel plus optional ctl/voices) and runs no helper binaries itself. The
  in-tree `speechshim9p` adapts the external helper CLIs to that contract
  and is the boot-time default provider at `/n/speechshim`; a parakeet
  export or a remote 9P mount is the same one-line ctl switch. The shim
  hard-cancels active TTS by killing the helper process (devcmd `kill`),
  so barge-in silence is bounded by one audio chunk.
- Asynchronous serving of `listen`, `wake`, `hear`, and in-flight `say`/`sayq`
  result reads in `speech9p`, with Flush/Clunk cancellation of parked reads.
  A wake read blocked in a helper no longer freezes the serveloop, so `cancel`
  writes (barge-in), `ctl`, and `sayq` stay live while helpers run.
- `luciuisrv` support for `/n/ui/input-mode` and
  `conversation/voiceinput`, so keyboard mode can be paused while
  voice-originated turns still have a privileged path into `lucibridge`.
  Input-mode changes are broadcast on the global `event` stream.
- `lucibridge` support for `/voice mode on|off`, while preserving existing
  `/voice on|off` auto-speak behavior. Keyboard and voice input are read
  concurrently, so a mode switch takes effect immediately instead of after
  the next message on the previously selected path; typed plain text is
  paused (with a notice) while voice mode is active, but typed slash
  commands — including `/voice mode off` — still work.
- A resident `voicemode` daemon, pre-spawned at boot in an idle state. It
  activates on the `input-mode v` broadcast (with an input-mode poll
  fallback when the event stream is unavailable), runs the
  WAITING_WAKE → LISTENING → PROCESSING/SPEAKING loop, re-arms wake during
  the spoken response so a wake event acts as barge-in (`cancel`, then
  listen), handles spoken control intents (stop/cancel, keyboard,
  approve/deny), and returns to idle on `input-mode k`.
- `Esc` exits voice mode: `lucifer`'s kbdproc tracks input-mode from global
  events and writes `k` back to `/mnt/ui/input-mode` on Esc, which fans out
  to `voicemode` (cancels speech, idles) and `lucibridge` (resumes typing).
- Boot wiring in `lib/lucifer/boot.sh`: `speech9p` starts before
  `lucibridge` (so the speech resource registers), and `voicemode` is
  pre-spawned idle. Deviation from the original plan: the pre-spawn lives in
  `boot.sh` rather than `lucifer.b`, because boot.sh is where the sibling
  services (`luciuisrv`, `tools9p`, `lucibridge`) already start.
- `module/speech.m` streaming `Partial` record type with the documented
  `partial`/`final`/`error:` wire format for `/n/speech/listen`.
- Tests: `tests/speech_wake_test.b`, `tests/speech_listen_test.b`,
  `tests/speech_kokoro_test.b` (fake host helpers via ctl; includes
  serveloop-liveness assertions), and `tests/voicemode_test.b` (daemon state
  machine against a mock file tree), alongside the earlier
  `tests/speech9p_voice_test.b` and `tests/luciuisrv_test.b` coverage.

Still incomplete:

- No bundled Kokoro, whisper streaming, or openWakeWord helpers; install them
  externally per Host Dependencies below.
- No custom wake model.
- No robust Echo/VAD handling while TTS is active beyond what the helpers
  provide.
- Tool/task cancellation is best-effort; hard cancellation of arbitrary
  tools is still future work. TTS helper processes ARE hard-cancelled
  (speechshim9p kills them via devcmd on `cancel`); in-flight wake/listen
  helper reads survive a flush and are drained on completion.
- Full end-to-end voice-only UX needs real helper installation and manual
  dogfood verification.

This document captures Claude's analysis findings, the decisions confirmed with
the user, and the approved Phase 1 plan for a local, Mac-only voice mode in
Lucia. It was written before implementation so the branch has a stable target
and reviewers can see both the intended architecture and the reasoning behind
it.

## Goal

Lucia is currently keyboard-driven. Phase 1 adds a hands-free mode:

1. Start Lucia.
2. Type `/voice mode on`.
3. Say `hey lucia`.
4. Speak an utterance.
5. Lucia transcribes it, sends it through the existing conversation path, and
   speaks the assistant response.
6. Say `hey lucia` during speech to interrupt, or press `Esc` to return to
   keyboard mode.

Phase 1 runs entirely on one Apple Silicon Mac using the laptop microphone and
speakers. Remote inference on a Jetson, remote audio binding, and pluggable
speech engine modules are Phase 2 work.

## Existing Starting Point

The repo already has useful scaffolding:

- `module/speech.m` defines batch TTS/STT data structures and engine interfaces.
- `appl/veltro/speech9p.b` exposes `/n/speech` with `ctl`, `say`, `hear`, and
  `voices`.
- `appl/cmd/lucibridge.b` has `/voice on|off`, but today that only toggles
  auto-speak for typed assistant responses.
- `docs/SPEECH-REMOTE-AUDIO.md` describes a later remote-audio direction.

The current gaps are:

- macOS has no active `/dev/audio` driver. `emu/MacOSX/emu` still comments out
  `audio audio`, and there is no `emu/MacOSX/audio.c`.
- `speech9p` is batch-oriented. It has no streaming listen file, wake-word file,
  queued TTS file, or cancellation file.
- STT is not wired into Lucia's conversation input.
- The UI has no voice-mode state machine and no mutual exclusion between typed
  input and voice input.
- Current local engines are oriented around `say`, Piper, and batch
  `whisper-cli`; Phase 1 wants Kokoro for TTS and streaming whisper.cpp for STT.
- No shipped engine implementation modules exist under `appl/lib/speech*`; the
  `cmd`, `api`, and local behavior is implemented inside `speech9p.b`, not as
  separately loadable `.dis` engines.
- The existing voice path is response-only: `lucibridge` gets assistant text and
  calls `speaktext()`. There is no current voice-in / voice-out loop.
- `docs/SPEECH-REMOTE-AUDIO.md` assumes missing remote plumbing exists. It
  names a useful direction, but Phase 1 cannot depend on that path yet.

## Analysis Findings to Preserve

Claude evaluated three deployment shapes before the final plan:

| Shape | Finding |
| --- | --- |
| Mac-only, all-local | Best Phase 1 target. Needs macOS `/dev/audio`, local engines, streaming/VAD, and Lucia voice-mode integration. Fastest to dogfood. |
| Mac as I/O terminal, Jetson as inference host | Good later target. Still needs macOS `/dev/audio`, plus remote audio, 9P export/bind, `rcmd`, catalog connection, and mount-path config. Too much for Phase 1. |
| Headless Jetson with USB headset | Avoids macOS audio by using Linux audio drivers, but does not match the current goal of opening the existing Mac UI and talking to it. |

The chosen ordering is Mac-local first, then Jetson/remote later. Reasons:

- The macOS audio driver is a shared prerequisite for both Mac-local and
  Mac-I/O-plus-Jetson deployments.
- Mac-local work is dogfoodable without a second machine, network setup, SSH, or
  9P export ceremony.
- It avoids combining three hard problems at once: CoreAudio driver work, new
  speech/voice UX, and unfinished remote Plan 9 plumbing.
- Streaming API design, VAD timing, and barge-in semantics are easier to tune on
  a single low-latency local loop before adding network latency.

Audio-layer finding:

- The audio I/O belongs in the host audio device layer exposed as `/dev/audio`,
  not in SDL3. SDL3 may own GUI/event work, but speech capture/playback needs to
  be available to Inferno programs and `speech9p` as a normal device.

Engine-layer finding:

- A full `.dis` plugin system for `TTSEngine`/`STTEngine` should wait until
  Phase 2. Phase 1 should add Kokoro and streaming STT directly in `speech9p.b`
  because that matches the current implementation shape and keeps the first
  usable path smaller.

Remote-audio finding:

- The remote-audio document is directionally useful, but its prerequisites are
  not implemented: 9P export of `/dev/audio`, bind tooling, `rcmd`, multi-step
  catalog connection, and mount-path configuration. Treat all of that as Phase
  2 plumbing.

## Confirmed Decisions

| Decision | Phase 1 choice |
| --- | --- |
| Deployment target | Local Mac only, Apple Silicon first |
| Activation | `/voice mode on` and `/voice mode off` |
| Wake behavior | Wake word: `hey lucia` |
| Wake model | Placeholder model first, custom `hey lucia` model in Phase 1.x |
| Keyboard behavior | Mutually exclusive; typing is paused while voice mode is active |
| Escape hatch | `Esc` always returns to keyboard mode |
| STT model | whisper.cpp `base.en` by default |
| TTS engine | Kokoro, default voice `af_bella` |
| Host helpers | External install; no vendored binaries |
| UI mic button | Deferred to Phase 1.x |
| Jetson / remote audio | Deferred to Phase 2 |

## Architecture

Five layers, bottom-up. Phase 2 should replace only layer 2 and add remote
transport; layers 1, 3, 4, and 5 should still apply.

| Layer | Component | Phase 1 work |
| --- | --- | --- |
| 1 | macOS audio driver | Add `emu/MacOSX/audio.c`; expose `/dev/audio` and `/dev/audioctl` |
| 2 | Host speech engines | Use Kokoro, streaming whisper.cpp, and openWakeWord helpers |
| 3 | `speech9p` | Extend `/n/speech` with streaming, wake, queue, and cancel files |
| 4 | `voicemode` daemon | New state machine that bridges speech events into Lucia input |
| 5 | Lucia UI integration | Add `/voice mode on|off`, status resources, paused typing |

Data flow:

```text
Lucia UI
  /voice mode on|off
  status resources: waiting, listening, processing, speaking
        ^
        | writes transcript to /n/ui/activity/{id}/conversation/input
voicemode daemon
  IDLE -> WAITING_WAKE -> LISTENING -> PROCESSING -> SPEAKING
        ^
        | /n/speech/wake, /n/speech/listen, /n/speech/sayq, /n/speech/cancel
speech9p
        ^
        | /dev/audio and /dev/audioctl
macOS CoreAudio driver
```

## State Machine

```text
        /voice mode on
            |
            v
          IDLE <------------------------- /voice mode off, Esc
            |
            v
      WAITING_WAKE
      typing paused; wake-word engine active
            |
            | wake word detected
            v
        LISTENING
        streaming STT and VAD
            |
            | final transcript
            v
       PROCESSING
       transcript injected into Lucia conversation input
            |
            | assistant response begins
            v
        SPEAKING
        Kokoro TTS playback
            |
            | playback done
            v
      WAITING_WAKE

During SPEAKING, wake-word detection remains active. A wake event writes
`cancel` to `/n/speech/cancel`, cuts off TTS, and transitions to LISTENING.
```

Mutual exclusion with typing uses a new single-byte UI file:

- `/n/ui/input-mode` returns `k` for keyboard mode or `v` for voice mode.
- `voicemode` writes `v` when it enters voice mode and `k` when it exits.
- `lucibridge` checks the file before blocking on conversation input; when it
  sees `v`, it sleeps briefly and rechecks instead of consuming typed input.

## Seamless Voice-Only UX Requirements

The baseline architecture routes voice through the existing Lucia conversation
and tool infrastructure by injecting the final transcript into
`/n/ui/activity/{id}/conversation/input`. That is the correct foundation: a
voice utterance should become the same kind of user turn as a typed message, so
the existing agent loop, native tool-use protocol, resource updates, and context
zone activity can be reused.

That routing is not, by itself, the full UX contract. The implementation must
also preserve the visible action feedback that typed/tool-driven Lucia already
has. Voice mode should not become a separate hidden path where the user hears
speech but cannot see which files, tools, resources, or activities are being
used.

The target user experience must not feel turn-based. The internal LLM/tool loop
may still process discrete turns, but voice mode should present a continuous
conversation and control surface: Lucia keeps listening for interruption,
correction, cancellation, or follow-up intent while work is underway.

Normal-mode UX:

- Voice-triggered agent turns must use the same context/resource activity UI as
  typed turns. Tool calls should mark the relevant tool resource active, upsert
  touched file/path resources, and return them to idle/done/error using the
  existing `lucibridge` context update paths.
- Speech tiles are only the audio state: waiting, listening, processing,
  speaking. They do not replace the context/resource activity view for actual
  work.
- When the user says "hey lucia, do X", the expected normal experience is:
  wake fires, Lucia accepts the utterance, the existing conversation/tool loop
  starts, and the context zone reflects the same tool/resource activity the user
  would see if they had typed "do X".
- Do not force the user into a strict speak-wait-hear-next cycle. After Lucia
  has enough confidence in the utterance or command intent, it should begin
  acting while still allowing the user to interrupt, refine, or cancel.
- Voice mode should support mid-action follow-ups. Examples: "actually use the
  other file", "stop", "show me what changed", "continue", "don't promote that",
  or "read the error". These should be routed as control intents against the
  active task where possible, not treated as unrelated new chat turns.
- Barge-in is not only for stopping TTS. It is the general mechanism for taking
  conversational control back from the system while it is speaking, using tools,
  waiting on a long operation, or asking for approval.
- TTS should not block listening. The system should be able to speak while a
  lower-volume wake/barge-in listener remains active, with echo handling or
  cancellation sufficient to avoid hearing itself as a new command.
- Destructive or sensitive operations still require approval. Voice mode needs
  a spoken and visual approval path before write/edit/exec-style operations can
  proceed.
- Long-running actions need voice control hooks while work is in progress:
  cancel, pause, resume, repeat status, and barge-in should be recognized even
  while tools or TTS are active.
- Spoken UI commands need intent mapping rather than assuming literal slash
  commands. For example, "bind this folder", "add grep", "show diff", and
  "promote this change" should map to the same existing slash/tool operations
  with confirmation where ambiguity or risk exists.
- Misheard or ambiguous commands need a correction flow. For risky or
  irreversible actions, ask for confirmation using the interpreted command:
  "I heard: promote changes under X. Confirm?"
- If speech recognition confidence is high and the command is low risk, avoid
  confirmation chatter. If confidence is low or the action is risky, confirm
  before acting.
- Assistant speech should be streamed or chunked so the user hears progress
  quickly, but tool/action execution should not wait for the whole spoken
  response to finish when the next operation is already clear.

Continuous-loop implications:

- `voicemode` needs a control channel into the active agent/task loop, not only a
  one-shot transcript injection path. At minimum, it must be able to cancel TTS,
  cancel or pause an active tool/task where supported, and submit a follow-up
  utterance against the current activity.
- The agent loop should expose enough state for voice mode to know whether Lucia
  is idle, listening, generating, speaking, waiting for approval, executing a
  tool, or blocked on an error.
- Voice mode should preserve a current "interaction focus" so short follow-ups
  like "stop", "that one", "open it", or "undo that" apply to the active file,
  tool, approval prompt, or task rather than starting from scratch.
- The normal UI should make continuous state legible without debug clutter:
  listening, acting, waiting-for-approval, speaking, paused, and error are
  enough for the default surface.

Debug-mode UX:

- Live partial transcript display should be debug-first. While enabled, partial
  STT text can update visibly while the user speaks, then freeze as the submitted
  user message once final. In normal mode, avoid making raw partial hypotheses a
  prominent UI element.
- Action lifecycle visualization should be debug-first: heard -> interpreting ->
  acting -> done/error. In normal mode, prefer the existing conversation,
  speech-state tile, and context/resource activity signals unless the user asks
  for verbose diagnostics.
- Debug mode should expose timing markers for wake detection, VAD finalization,
  transcript finalization, first token, first audio, tool start, and tool end so
  latency problems can be diagnosed without cluttering the default UI.

## Implementation Phases

### Phase 1.0: macOS Audio Driver

Why first: all low-latency local speech depends on working `/dev/audio` on
macOS.

Files:

- New `emu/MacOSX/audio.c`.
- Edit `emu/MacOSX/emu` to enable `audio audio`.
- Edit `emu/MacOSX/mkfile` to link the required Apple audio frameworks.
- Check whether SDL3/headless macOS mkfiles have independent `SYSLIBS` entries.

Driver contract:

- Implement the functions declared in `emu/port/audio.h`:
  `audio_file_init`, `audio_file_open`, `audio_file_read`,
  `audio_file_write`, `audio_ctl_write`, `audio_file_close`, and
  `getaudiodev`.
- Reuse `emu/Linux/audio-oss.c` as the closest structural template. Match its
  separate input/output locking shape and pause-state handling where applicable.
- Rely on `emu/port/devaudio.c` for the Inferno device registration once the
  macOS object is in the build.
- Use CoreAudio / AudioQueue APIs from C. Claude recommended AudioQueue over
  higher-level Objective-C APIs because it is C-callable, maps cleanly onto the
  existing host driver contract, and should support roughly 10-20 ms audio
  latency.
- Consult `emu/port/audio-tbls.c` for existing audio control value tables and
  map macOS devices/formats into those semantics rather than inventing a new
  control grammar.

Driver approach:

- Capture should configure an input AudioQueue at the Inferno-side STT-friendly
  default of 16000 Hz mono S16LE when possible. The capture callback feeds a
  ring buffer drained by `audio_file_read`.
- Playback should configure an output AudioQueue and a ring buffer fed by
  `audio_file_write`. The default playback format should match
  `Default_Audio_Format` unless `/dev/audioctl` changes it.
- Use AudioConverter or equivalent conversion when the hardware device rate or
  channel count differs from the Inferno-side format.
- Keep the implementation in C if possible; do not introduce Objective-C files
  unless the CoreAudio C API proves insufficient.

Implementation order inside Phase 1.0:

1. Scaffolding commit: enable the audio build entry, add a compiling stub
   `audio.c`, link frameworks, and prove `o.emu` still builds and starts.
2. Playback commit: implement `audio_file_write` and verify raw PCM playback
   through `/dev/audio`.
3. Capture commit: implement `audio_file_read` and verify record-then-playback.
4. Control commit: implement `audio_ctl_write` for rate, channels, encoding,
   device, and volume where practical.

Verification:

- Build the emulator.
- Build command bytecode with native `mk`.
- Record three seconds from `/dev/audio`, then play the raw data back through
  `/dev/audio`.
- Add `tests/host/audio_macos_test.sh` once there is a stable host smoke path.

### Phase 1.1: Kokoro TTS in `speech9p`

Why now: the current `/n/speech/say` path already exists, and adding a Kokoro
backend is smaller than introducing a full engine plugin system.

Files:

- Edit `appl/veltro/speech9p.b`.

Planned changes:

- Add `ENGINE_KOKORO` next to existing `cmd`, `api`, and `local` engines.
- Add a `saykokoro` path modeled on the existing local TTS path.
- Stream raw PCM output to `/dev/audio` instead of writing temporary files.
- Extend `ctl` parsing so `engine kokoro` and `voice af_bella` work.
- Keep existing `say`, `hear`, `ctl`, and `voices` behavior compatible.
- Pass Kokoro voice IDs through directly, for example `af_bella` and `am_adam`.

Host helper:

- Prefer an external `kokoro-onnx` install plus a thin wrapper command.
- Do not vendor model binaries or Python dependencies into the repo.
- A checked-in thin wrapper such as `bin/kokoro-cli` is acceptable if it only
  adapts the external install to the raw PCM contract; avoid C++ bindings in
  Phase 1.

Verification:

- Start `speech9p`.
- `echo 'engine kokoro' > /n/speech/ctl`.
- `echo 'hello world' > /n/speech/say`.
- Confirm audible speech and first-audio latency under 500 ms on target Mac.

### Phase 1.2: Streaming STT

Files:

- Edit `appl/veltro/speech9p.b`.
- Edit `module/speech.m` additively.

Planned changes:

- Add a streaming `Partial` concept with text plus final/non-final state.
- Add `/n/speech/listen`: blocking reads return transcript partials as they
  arrive.
- Keep `/n/speech/hear` as the existing batch path.
- Wrap the whisper.cpp streaming binary or an equivalent small helper.
- Treat `/n/speech/listen` as per-fid state. Each open reader should have its
  own stream/channel so unrelated clients do not consume each other's partials.
- The wire format should be documented beside the code; Claude's plan used a
  simple `Partial` ADT shape with `text` and `isfinal`.

Why streaming matters:

- Voice mode should send the LLM request as soon as VAD detects end-of-speech,
  not after a full tempfile-based whisper pass completes.
- By the time VAD fires, the final transcript should be at most one chunk away.

Verification:

- `cat /n/speech/listen`.
- Speak into the Mac microphone.
- Confirm partials arrive and one final transcript is emitted after
  end-of-speech.

### Phase 1.3: Wake Word and VAD

Wake word:

- Use openWakeWord or an equivalent local helper.
- Phase 1 may use a placeholder wake model while preserving `hey lucia` as the
  user-facing phrase.
- Add a `wakemodel` ctl key for the model path.
- Claude preferred openWakeWord because it is open source, ONNX-based,
  lightweight, and supports custom-trained wake words.
- Porcupine was rejected for Phase 1 because its useful tiers require an
  account-bound access key and commercial-use constraints.
- Whisper-based wake detection was rejected because continuously transcribing to
  regex-match the wake phrase costs more CPU and has worse latency than a
  purpose-built wake-word model.

VAD:

- Use whisper.cpp streaming VAD first.
- Treat a separate Silero VAD helper as Phase 1.x only if whisper.cpp VAD is
  not good enough.
- Start with a configurable threshold around `vadthold 0.6`; tune from real
  microphone tests rather than hardcoding assumptions.

Files:

- Edit `appl/veltro/speech9p.b`.

Planned changes:

- Add `/n/speech/wake`: reads block until wake-word detection, then return a
  line containing model, score, and timestamp.
- Add `/n/speech/cancel` for TTS interruption.
- Add `/n/speech/sayq` for queued or streaming response playback.

Verification:

- `cat /n/speech/wake`.
- Say `hey lucia`.
- Confirm a wake event appears.
- Confirm background speech/noise does not trigger at the configured threshold.

### Phase 1.4: `voicemode` Daemon

Files:

- New `appl/cmd/voicemode.b`.
- Edit `appl/cmd/mkfile`.

Responsibilities:

- Own the voice-mode state machine.
- Watch `/n/speech/wake`.
- Read `/n/speech/listen`.
- Inject final transcripts into `/n/ui/activity/{id}/conversation/input`.
- Queue assistant response chunks to `/n/speech/sayq`.
- Write `/n/speech/cancel` for barge-in.
- Write `/n/ui/input-mode` to pause and resume typed input.
- Update UI context resources for waiting, listening, processing, and speaking.
- Treat `Esc` or `/voice mode off` as unconditional exit.
- Determine the active activity ID from `/n/ui/active` if available; otherwise
  fall back to the most recent activity under `/n/ui/activity`.
- While processing, watch for the next assistant response so response chunks can
  be queued to speech as they arrive.

Open implementation detail:

- Confirm whether `luciuisrv` already exposes global key events. If not, add a
  minimal `/n/ui/keys` file that `voicemode` can read for `Esc`.

Verification:

- Run `voicemode` manually.
- Flip voice mode on.
- Confirm transcript injection reaches the existing Lucia conversation path.
- Confirm state resources update.
- Confirm barge-in cancels speech and returns to listening.

### Phase 1.5: Lucia Integration

Files:

- Edit `appl/cmd/lucibridge.b`.
- Edit `appl/cmd/luciuisrv.b`.
- Edit `appl/cmd/lucifer.b`.

Planned changes:

- Extend `/voice` parsing:
  - `/voice on|off` remains auto-speak for typed interactions.
  - `/voice mode on|off` becomes the new hands-free state.
- Add pause-aware conversation input in `lucibridge`.
- Add `/n/ui/input-mode` in `luciuisrv`.
- Add or reuse a key-event stream for `Esc`.
- Pre-spawn `voicemode` in an idle state from `lucifer` to avoid first-use
  startup latency.
- Register voice-mode status resources alongside the existing speech resource,
  using the same resource-tile pattern already present in Lucia.

Verification:

- `/voice mode on` pauses typed input and activates voice resources.
- `/voice mode off` cancels in-flight speech and resumes typing.
- `Esc` resumes typing even while audio or speech helpers are active.
- Existing `/voice on|off` auto-speak behavior still works.

### Phase 1.6: Tests and Docs

Tests:

- New `tests/host/audio_macos_test.sh`: host-side audio smoke test.
- New `tests/speech_kokoro_test.b`: `engine kokoro` TTS smoke path.
- New `tests/speech_listen_test.b`: streaming STT partial/final behavior.
- New `tests/speech_wake_test.b`: wake-word event behavior.
- New `tests/voicemode_test.b`: daemon state-machine behavior with mocked
  speech files.

Docs:

- Keep this file updated as implementation reality changes.
- Add a short Phase 2 pointer to `docs/SPEECH-REMOTE-AUDIO.md` after Phase 1
  structure is stable.

## Host Dependencies

Use the repo installer to prepare the host helpers and print the Inferno ctl
configuration block:

```sh
tools/install-speech-helpers.sh
```

The installer is macOS-first and safe to re-run. It installs Homebrew
`whisper-cpp` when Homebrew is available, creates an isolated venv under
`~/.local/share/infernode-speech/venv`, installs pinned `kokoro-onnx` and
`openwakeword` packages, downloads the Kokoro model/voices and a whisper.cpp
`base.en` model, and generates these provider-contract wrappers:

```text
~/.local/share/infernode-speech/bin/kokoro-cli
~/.local/share/infernode-speech/bin/whisper-stream-cli
~/.local/share/infernode-speech/bin/openwakeword-cli
```

After `/n/speech` is mounted, paste the ctl block printed by the installer.
The helper-mode block has this shape:

```sh
echo 'kokorobin /Users/me/.local/share/infernode-speech/bin/kokoro-cli' > /n/speech/ctl
echo 'whisperstreambin /Users/me/.local/share/infernode-speech/bin/whisper-stream-cli' > /n/speech/ctl
echo 'wakebin /Users/me/.local/share/infernode-speech/bin/openwakeword-cli' > /n/speech/ctl
echo 'whispermodel /Users/me/.local/share/infernode-speech/models/ggml-base.en.bin' > /n/speech/ctl
echo 'voice af_bella' > /n/speech/ctl
echo 'wakeword hey jarvis' > /n/speech/ctl
echo 'wakethreshold 0.5' > /n/speech/ctl
echo 'duplex half' > /n/speech/ctl
```

Then start InferNode, press `Alt+V` (or Esc then `v`) to enter voice mode, and
speak the wake phrase.

**The spoken wake phrase is currently "hey jarvis"**, because the only
pretrained openWakeWord model available today is `hey_jarvis`. Saying
"hey lucia" will not trigger wake until a custom hey-lucia model is trained
and dropped into `~/.local/share/infernode-speech/models/openwakeword/`
(pass it explicitly with `--model` in the `wakebin` command). The
`whisper-stream-cli` wrapper runs whisper.cpp in VAD mode: each utterance is
transcribed after you stop speaking and emitted as a single `final` record —
so expect turn latency of roughly the utterance length plus transcription
time, and no live partials from this particular wrapper (a parakeet provider
supplies partials).

Topology 2/3 users can keep the microphone as a namespace device instead of
letting helper CLIs grab the host mic directly:

```sh
echo 'micmode device' > /n/speech/ctl
echo 'whisperstreambin /Users/me/.local/share/infernode-speech/bin/whisper-stream-cli --stdin --model /Users/me/.local/share/infernode-speech/models/ggml-base.en.bin --rate 16000 --chans 1' > /n/speech/ctl
echo 'wakebin /Users/me/.local/share/infernode-speech/bin/openwakeword-cli --stdin --word hey jarvis --threshold 0.5 --rate 16000' > /n/speech/ctl
```

`micmode device` means `speechshim9p` pumps 16 kHz s16le mono PCM into the
configured helper commands' stdin. The generated openWakeWord wrapper supports
that stdin-PCM path. Current Homebrew `whisper-cpp` exposes `whisper-stream` as
a host-capture program, not a stable stdin-PCM streaming filter, so the generated
`whisper-stream-cli --stdin` reports an `error:` record instead of pretending to
transcribe. For real stdin streaming STT, use a helper that actually consumes
stdin PCM and emits `partial` / `final` records.

Host smoke coverage lives in `tests/host/speech_helpers_test.sh`. It exercises
TTS/PCM and no-mic wrapper paths only; microphone-dependent wake/STT checks are
left to an interactive TCC-approved session.

## End-to-End Verification Target

After all Phase 1 work lands:

1. Build native prerequisites and emulator.

   ```sh
   export ROOT=$PWD
   export PATH=$PWD/MacOSX/arm64/bin:$PATH
   ./scripts/bootstrap-libs.sh
   ./build-macos-sdl3.sh
   cd appl/cmd && mk install
   ```

2. Run host audio smoke test.

   ```sh
   ./tests/host/audio_macos_test.sh
   ```

3. Run speech tests.

   ```sh
   ./emu/MacOSX/o.emu -r. /tests/speech_kokoro_test.dis
   ./emu/MacOSX/o.emu -r. /tests/speech_listen_test.dis
   ./emu/MacOSX/o.emu -r. /tests/speech_wake_test.dis
   ./emu/MacOSX/o.emu -r. /tests/voicemode_test.dis
   ```

4. Run manual voice-mode smoke test.

   ```text
   ./run-lucia.sh
   /voice mode on
   say: hey lucia, what time is it?
   expected: transcript appears as user input, assistant responds, response is spoken
   say: hey lucia while response is speaking
   expected: TTS stops and system returns to listening
   press Esc
   expected: voice mode exits and typing resumes
   ```

Acceptance targets:

- Wake-word detection latency: under 200 ms from utterance end to wake event.
- End-of-speech to final transcript: under 800 ms with whisper.cpp `base.en`.
- Assistant first token to first audio: under 500 ms with Kokoro.
- Barge-in to TTS silence: under 200 ms.

## Planned Files

| Path | Action | Phase |
| --- | --- | --- |
| `emu/MacOSX/audio.c` | New CoreAudio platform driver | 1.0 |
| `emu/MacOSX/emu` | Enable `audio audio` | 1.0 |
| `emu/MacOSX/mkfile` | Link CoreAudio/AudioToolbox as needed | 1.0 |
| `appl/veltro/speech9p.b` | Add Kokoro, streaming STT, wake, queue, cancel | 1.1-1.3 |
| `module/speech.m` | Add streaming partial type additively | 1.2 |
| `appl/cmd/voicemode.b` | New voice-mode state machine daemon | 1.4 |
| `appl/cmd/mkfile` | Build `voicemode` | 1.4 |
| `appl/cmd/lucibridge.b` | Add `/voice mode on|off` and pause-aware input | 1.5 |
| `appl/cmd/luciuisrv.b` | Add `/n/ui/input-mode` and key-event path | 1.5 |
| `appl/cmd/lucifer.b` | Pre-spawn idle `voicemode` | 1.5 |
| `tests/host/audio_macos_test.sh` | Host audio smoke test | 1.6 |
| `tests/speech_kokoro_test.b` | Kokoro TTS test | 1.6 |
| `tests/speech_listen_test.b` | Streaming STT test | 1.6 |
| `tests/speech_wake_test.b` | Wake-word test | 1.6 |
| `tests/voicemode_test.b` | Voice daemon test | 1.6 |
| `docs/SPEECH-REMOTE-AUDIO.md` | Add Phase 2 pointer after Phase 1 stabilizes | 1.6 |

## Out of Scope for Phase 1

- Custom-trained `hey lucia` wake model.
- UI microphone button.
- Pluggable speech engine `.dis` modules.
- Jetson-hosted inference.
- 9P remote-audio bridge implementation.
- Multilingual STT/TTS.
- Voice biometrics or multi-speaker disambiguation.

## Immediate Next Step

Start Phase 1.0 with the scaffolding-only commit:

1. Add a compiling `emu/MacOSX/audio.c` stub that exports the required symbols.
2. Enable the macOS audio object in `emu/MacOSX/emu`.
3. Link the required audio frameworks.
4. Rebuild the macOS emulator and confirm it starts.

Do not mix playback, capture, and control handling into the scaffolding commit.
