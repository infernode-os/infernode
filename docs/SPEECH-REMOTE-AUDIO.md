# Remote Speech: 9P Audio Composition

> **Scope.** This document covers *remoting* — putting the speech server on a
> different host from the audio device, exploiting Plan 9 namespace
> composition. For the architecture of `speech9p` itself (file tree, engines,
> data flow, agent integration), see
> [SPEECH-ARCHITECTURE.md](SPEECH-ARCHITECTURE.md).
>
> **Phase 2 pointer.** The Mac-local voice mode
> ([SPEECH-VOICE-ONLY-PHASE1.md](SPEECH-VOICE-ONLY-PHASE1.md)) is Phase 1 of
> the voice work; this remote-audio direction is the Phase 2 target (Mac as
> I/O terminal, Jetson or other host as inference engine), together with
> pluggable `.dis` speech-engine modules built on the `TTSEngine`/`STTEngine`
> and `Partial` interfaces in `module/speech.m`. The audio-routing side is
> now implemented: `speechshim9p` takes its playback and capture devices as
> namespace paths (`audiodev`, `capturedev`, `micmode device` — see
> SPEECH-ARCHITECTURE.md), so any 9P-imported audio device works like the
> local one. What remains manual is starting the services and exports on
> each host (launch scripts below).

## Current Design

`speech9p` presents the stable speech interface at `/n/speech` and consumes a
single **provider mount** (default `/n/speechshim`, served by `speechshim9p`)
for all streaming voice I/O — see the provider contract in
[SPEECH-ARCHITECTURE.md](SPEECH-ARCHITECTURE.md). Two properties make
remoting a pure composition exercise:

1. **The provider is a mount.** `echo 'provider /n/x' > /n/speech/ctl`
   points the whole voice pipeline (listen, wake, kokoro say, cancel) at any
   namespace serving the contract — local shim, parakeet export, or a mount
   from another Infernode instance across the network.
2. **The provider's audio I/O is namespace paths.** `speechshim9p` plays
   through `audiodev` (default `/dev/audio`) and, in `micmode device`,
   captures s16le PCM from `capturedev` (default: `audiodev`) and pumps it
   into the STT/wake helpers' stdin. An imported `/dev/audio` from another
   machine drops in with one ctl write — no `bind` required.

The default deployment assumes the user is physically at the machine running
the stack; the topologies below relocate the pieces.

---

## The Three Topologies

### 1. Everything local (default)

What `lib/lucifer/boot.sh` sets up: `speechshim9p` + `speech9p` on the local
machine, provider `/n/speechshim`, helpers (whisper.cpp stream, Kokoro,
openWakeWord) installed on the local host, `micmode helper` so the helper
CLIs grab the local microphone directly. A parakeet export mounted at
`/n/parakeet` is the same topology with a different provider value.

### 2. Remote processing, local microphone and speakers

The local machine is the I/O terminal; a beefier host (Jetson, second
Infernode instance) runs STT/TTS. Audio is forwarded from the local mic and
played on the local speakers, but everything stays a locally mounted
namespace.

```
Local terminal (mic + speakers)          Remote engine (helpers installed)
───────────────────────────────          ─────────────────────────────────
listen -A 'tcp!*!17010' export /dev ───► mount ... /n/term
                                         speechshim9p &
                                         listen -A 'tcp!*!17019' export /n/speechshim
mount -A 'tcp!<remote>!17019' /n/remotespeech ◄──┘
echo 'provider /n/remotespeech' > /n/speech/ctl
echo 'audiodev /n/term/audio' > /n/speech/ctl     # resolved in the REMOTE namespace
echo 'micmode device' > /n/speech/ctl
```

**Local — export the audio device, mount the remote provider:**
```sh
listen -A 'tcp!*!17010' export /dev &
mount -A 'tcp!<remote-ip>!17019' /n/remotespeech
echo 'provider /n/remotespeech' > /n/speech/ctl
```

**Remote — import the terminal's audio, serve the provider:**
```sh
mount -A 'tcp!<local-ip>!17010' /n/term
speechshim9p &
listen -A 'tcp!*!17019' export /n/speechshim &
```

**Audio routing (writable from the local side — `speech9p` forwards these
keys to the provider's `ctl`):**
```sh
echo 'audiodev /n/term/audio' > /n/speech/ctl
echo 'micmode device' > /n/speech/ctl
```

Now the remote shim synthesizes and recognizes, but reads its PCM from —
and plays it back to — the terminal's audio device over 9P. Note the
`audiodev` value is a path in the *remote* shim's namespace.

### 3. Remote capture device (e.g. Infernode on an Android phone)

The phone contributes only its microphone; processing and playback stay
wherever topology 1 or 2 put them.

**Phone — export the device tree:**
```sh
listen -A 'tcp!*!17010' export /dev &
```

**Processing host (local machine in topology 1, remote engine in topology 2)
— import the phone's audio and use it for capture only:**
```sh
mount -A 'tcp!<phone-ip>!17010' /n/phone
echo 'capturedev /n/phone/audio' > /n/speech/ctl
echo 'micmode device' > /n/speech/ctl
```

`capturedev` overrides capture without touching playback: the wake word and
speech come from the phone's mic while TTS still plays through `audiodev`
(the local speakers, or wherever topology 2 pointed it). Write
`capturedev default` to fall back to `audiodev` again.

### Why It Works

The shim calls `open()` and `read()`/`write()` on the paths it was given.
Those are ordinary namespace lookups: after a 9P import, they transparently
hit the other machine's audio hardware. This is standard Plan 9 namespace
composition — location transparency falls out of the model rather than
being bolted on as a special case. The provider contract adds the same
property one level up: the entire speech engine is itself just a mount.

---

## Current GUI / Veltro Limitations (Future Work)

The final step — mounting the remote speech service — is **already supported** by the
catalog `[+]` button (`mountresource()` calls `sys->dial()` + `sys->mount()`). A catalog
entry with the Jetson's address handles it. The audio routing itself is now plain ctl
writes (`audiodev`, `capturedev`, `micmode` — no `bind` step remains), so once the
mounts exist, any shell or agent that can write `/n/speech/ctl` can rewire the audio
path.

What is still **not supported** by any GUI or agent pathway is the setup on the other
hosts:

| Step | Manual? | GUI? | Veltro? |
|------|---------|------|---------|
| `listen export /dev` on the mic/speaker host | yes (launch script) | ✗ | ✗ |
| `mount` terminal/phone audio on the engine host | yes (launch script) | ✗ | ✗ |
| `speechshim9p &` + export on the engine host | yes (launch script) | ✗ | ✗ |
| Mount remote provider locally | via catalog `[+]` | ✓ | ✗ |
| `provider` / `audiodev` / `capturedev` / `micmode` ctl writes | yes (one-liners) | ✗ | ✓ (shell tool) |

### What Would Enable Full GUI/Agent Control

1. **`rcmd` / `ssh` tool** — to start services on the remote machine from Veltro. Without
   this, Veltro cannot set up the engine-host side at all.

2. **Catalog multi-step connect** — extend the catalog entry format to support a sequence
   of setup actions (dial, mount, ctl writes, spawn) rather than a single dial+mount. A
   "Speech on Jetson" catalog entry could encode the full setup — including the
   `provider` and audio-routing ctl writes — and execute it on `[+]`.

3. **Mount path for catalog entries** — `mountresource()` currently mounts to
   `/tmp/veltro/mnt/<slug>`. Since the provider mount point is itself a ctl value
   (`provider <path>`), this is a one-write fixup rather than a blocker.

### Recommended Approach (When Implementing)

Option A — **Launch script automation** (low effort, sufficient for now):
Bake the exports and mounts into each host's launch command alongside `tools9p` and
`lucibridge`, and the ctl writes into the local boot script. The catalog entry handles
the final user-facing mount.

Option B — **Catalog multi-step connect** (proper GUI solution):
Extend `CatalogEntry` with a `setup: list of string` field. Each entry is a command
(`listen`, `mount`, `echo ... > ctl`, `exec`) run in sequence on `[+]`. The catalog
file format gains a `setup=` attribute. `mountresource()` runs the setup sequence
before the final mount. This generalises beyond speech to any multi-step remote service.

Option C — **`rcmd` tool** (Veltro-native solution):
Give the agent the tool it needs: `rcmd host cmd` runs a command on a remote Inferno
instance via authenticated 9P exec. The local half is already covered — the shell tool
can perform the mounts and ctl writes. Then Veltro can set up the full pipeline
autonomously once it knows the remote host address.
