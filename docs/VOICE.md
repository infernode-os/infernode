# Voice over 9P

InferNode does voice calls without inventing a call protocol. Each device
exports `/dev/audio` over 9P; the peer mounts it; two `cat`s carry the
audio. `mount` is the call. `kill` is the hangup. No SIP, no INVITE, no
signalling.

The design was sketched in INFR-185. The arc that lands it on real
hardware runs from there through INFR-198. As of this writing the bridge
is demonstrated end-to-end on macOS, iOS (iPhone 17 Pro Max) and Android
(Samsung A55).

## The shape

Each side runs this once:

```
bind -a '#A' /dev                       # devaudio onto /dev
sh /lib/voice/listen                    # announces tcp!*!7070,
                                        # exports /dev under that mount
```

Either side dials:

```
sh /lib/voice/dial tcp!peer-ip!7070
```

`voice/dial` does the four cats that are the call:

```
cat /dev/audio  > /n/voice/audio &      # my mic   -> peer speaker
cat /n/voice/audio > /dev/audio &       # peer mic -> my speaker
```

(The other two of the "four" are the inverse hookups on the peer's side
once it dialled back, in the bidirectional case. For one-sided test rigs
you can read either direction independently.)

Hang up by killing the cat pids the script printed; the network mount
times out and the listener accepts the next dial.

## Platforms

The audio backend (`emu/MacOSX/audio-sdl3.c`) is shared across macOS,
iOS, and Android:

- **macOS:** `audio-sdl3.c` direct, driving CoreAudio via SDL3.
  - Mic capture from the CLI emu is gated by macOS TCC (INFR-199). The
    listener can speak playback fine without it but its mic stays
    silent until launched from a permission-granted bundle.
- **iOS:** `emu/iOS/audio-sdl3.c` is a one-line forwarder around the
  macOS source plus `emu/iOS/audiosession.m`, which configures
  `AVAudioSession` in `.playAndRecord` mode with `.voiceChat`. The
  voice-chat mode is what gives the iPhone hardware AEC (no feedback
  when two phones share a room) and what raises the foreground TCC mic
  permission prompt at the right moment (INFR-186 / INFR-190).
- **Android:** `emu/Android/audio-sdl3.c` is the same one-line forwarder
  (INFR-188). SDL3 drives AAudio under the hood; the APK's manifest
  carries `RECORD_AUDIO` so first-use prompts inside Lucifer.

The `audio_file_*` contract from `emu/port/audio.h` is identical on every
platform. The only platform difference is what `audio_platform_init()`
does — a no-op on macOS / Linux desktop, the AVAudioSession setup on
iOS.

## Two things the test rig taught us the hard way

### 1. Bounded queues (INFR-194)

`SDL_AudioStream`'s queue is unbounded. On a sustained voice flow the
playback side accumulates whatever the network feeds it faster than the
device drains at real time, and the audio drifts minutes behind the
speaker. `audio_file_write` / `audio_file_read` now cap the queue
depth at a configurable budget; when the queue exceeds it, the head is
dropped so the speaker stays in sync with the talker.

The cap is **off by default** so non-voice workloads (audiotone, music)
keep their smooth unbounded queue. `voice/listen` and `voice/dial`
opt in by writing two verbs to `audioctl` as their first action:

```
echo 'play_buffer_ms 100' > /dev/audioctl
echo 'rec_buffer_ms  100' > /dev/audioctl
```

100 ms is the voice-grade default. WebRTC sits at 20-50 ms; the trade is
smoothness under packet loss vs. latency. Tuning is in INFR-197.

### 2. SDL audio reaches working state only when initialised right (INFR-195)

The headless CLI emu doesn't call `SDL_Init(SDL_INIT_VIDEO)` at startup
(only the GUI build does). Calling `SDL_InitSubSystem(SDL_INIT_AUDIO)`
standalone produces an audio subsystem that *looks* initialised but
that `SDL_OpenAudioDeviceStream` later rejects as "Audio subsystem is
not initialized." The pattern that actually works:

- `SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "coreaudio")` so SDL3 doesn't
  silently fall back to the dummy backend.
- `SDL_Init(SDL_INIT_AUDIO)` (canonical entry point, idempotent past
  the first call).
- A **pre-warm** in `voice/listen` that opens `/dev/audio` once inside
  the `listen` block — same address space as the export server — so
  the peer's later open just bumps a refcount instead of trying to
  re-initialise SDL audio from a worker thread.

The recording prewarm on a CLI macOS emu still surfaces "No default
audio device available" (TCC gating, INFR-199). The bridge still works
one-way in that case — Mac plays what the phone says, Mac mic stays out
of the bridge.

## Testing recipes

### Mac ↔ Mac loopback (no devices needed)

```
./emu/MacOSX/o.emu -r$PWD -c0 sh /lib/voice/test-tone
```

Spins up its own listener, mounts the local 9P export, pumps an
`audiotone` pulse train through every byte of the export path, plays
the decoded result. If you hear ten short 1 kHz beeps over ~5 s, the
codec + 9P + 4-cat bridge all work.

### Mac ↔ iPhone

```
# On Mac (Terminal):
./emu/MacOSX/o.emu -r$PWD -c0 sh /lib/voice/listen

# On iPhone, in a Lucifer task-activity shell:
sh /lib/voice/dial tcp!mac-ip!7070
```

iOS prompts for microphone permission on the first audio open. Tap
Allow. From that point the Mac mic can be heard on the iPhone speaker
and vice-versa. Wear headphones — there's no AEC on the Mac side
(INFR-186 covers the iPhone side).

### Mac ↔ Android

Same shape with Samsung. INFR-189 unblocked the local-from-macOS APK
build; INFR-188 wired the shared audio backend; INFR-194 + INFR-195
made the bridge usable both ways.

```
adb shell input text "$(printf 'sh /lib/voice/dial tcp\x21mac-ip\x217070')"
adb shell input keyevent 66
```

(`\x21` escapes `!` so zsh's history expansion doesn't mangle it.)

### Phone ↔ Phone

The product story. Not yet verified on hardware — tracked in INFR-198.
Both phones should be able to do this today; what's untested is the
iOS listener accepting incoming connections under `UIBackgroundModes`
rules (`audio` + `voip`, already set) and whether typing the dial
command into the iPhone Lucifer shell stays survivable in practice.

## Optional opus codec path (INFR-187)

`/dev/opus` wraps `libopus` as a Plan-9 device — `enc`, `dec`, `ctl`,
`status`. Same `mount` model, just feed the encoded frames through
instead of raw PCM. The use case is cellular — raw PCM is ~1.4 Mbps,
opus cuts it to ~24 kbps. macOS builds link `libopus` via Homebrew;
iOS / Android opus cross-builds are an open follow-up.

```
# Set up
mkdir -p /n/opus
bind '#Z' /n/opus
echo 'rate 48000' > /n/opus/ctl
echo 'chans 1'    > /n/opus/ctl
echo 'frame_ms 20' > /n/opus/ctl
echo 'bitrate 24000' > /n/opus/ctl

# Pipe
audiotone -r 48000 -c 1 /n/opus/enc      # writes encoded frames
```

The opus-aware voice scripts (`voice/listen-opus`, `voice/dial-opus`,
`voice/test-tone-opus`) follow the same shape as the PCM ones with an
extra two cats per direction for the encode / decode hops.

## Where the work lives

| Ticket | Status | What |
|---|---|---|
| INFR-185 | done | v0 PCM voice, macOS backend, voice/{listen,dial,test-tone} |
| INFR-186 | done | iOS audio backend, AVAudioSession `.voiceChat` |
| INFR-187 | done | `/dev/opus` codec device + opus pipeline scripts |
| INFR-188 | done | Android shares the SDL3 audio backend |
| INFR-189 | done | Local-from-macOS Android APK build |
| INFR-190 | done | iOS mic permission prompt threading |
| INFR-194 | done | SDL3 queue cap (kills minutes-of-drift) |
| INFR-195 | done | SDL audio init + listen-block prewarm (Phone→Mac plays) |
| INFR-197 | open | Buffer / sample-rate tuning to remove grit |
| INFR-198 | open | Phone ↔ phone direct (no Mac in the loop) |
| INFR-199 | open | Mac CLI listener mic capture (TCC bundle) |
| INFR-191 | open | Shell backspace glitch on Samsung (blocked typing) |
