# Remote Speech: 9P Audio Composition

> **Scope.** This document covers *remoting* — putting the speech server on a
> different host from the audio device, exploiting Plan 9 namespace
> composition. For the architecture of `speech9p` itself (file tree, engines,
> data flow, agent integration), see
> [SPEECH-ARCHITECTURE.md](SPEECH-ARCHITECTURE.md).

## Current Design

`speech9p` presents TTS/STT as a 9P filesystem at `/n/speech`:

```
/n/speech/
├── ctl      rw  engine, voice, lang config
├── say      rw  write text → synthesized audio plays
├── hear     rw  write "start" → read transcription back
└── voices   r   list available voices
```

The current implementation assumes the user is **physically at the machine running
`speech9p`**. TTS output goes to the local `/dev/audio`; STT records from the local
`/dev/audio`. This is a coherent, reasonable deployment: macOS with `say`, or a Jetson
with espeak/piper/whisper, used as the user's workstation.

---

## The Plan 9 Extension: Transparent Remote Audio

Because `speech9p` only ever touches its local namespace, audio I/O can be transparently
remoted by composing namespaces before the server starts — no changes to `speech9p` itself.

### Architecture

```
GUI machine (Mac)                   Headless machine (Jetson)
─────────────────                   ─────────────────────────
/dev/audio  ──── exported via 9P ──► /dev/audio  (bound from Mac)
                                     speech9p    (uses /dev/audio transparently)
                                     /n/speech   ── exported via 9P ──►  /n/speech
                                                                          (mounted on Mac)
Lucifer GUI ──── writes to /n/speech/say ──────────────────────────────────────────►
◄──────────────── audio plays on Mac speakers ◄──────── PCM written to /dev/audio ──
```

### Commands

**Mac — export audio device (add to Lucifer launch script):**
```sh
listen -A 'tcp!*!17010' export /dev &
```

**Jetson — import Mac audio, start speech9p, export it (Jetson launch script):**
```sh
mount -A 'tcp!<mac-ip>!17010' /n/macaudio
bind /n/macaudio/audio /dev/audio
speech9p -e cmd &
listen -A 'tcp!*!17019' export /n/speech &
```

**Mac — mount remote speech service:**
```sh
mount -A 'tcp!<jetson-ip>!17019' /n/speech
```

Or via the Lucifer catalog: add an entry with `dial=tcp!hephaestus!17019` and click `[+]`.

### Why It Works

`speech9p` calls `open("/dev/audio")` and `write()`. Those are ordinary namespace
lookups. After `bind /n/macaudio/audio /dev/audio`, those calls transparently hit the
Mac's audio hardware over 9P. `speech9p` never knows or cares. This is standard Plan 9
namespace composition — location transparency falls out of the model rather than being
bolted on as a special case.

---

### Choosing the local input device: `#A/audiodev`

The emulator opened whatever the host called the default input device. That
default is not always a microphone: a virtual device installed by another
application can hold it, and such a device produces no samples unless that
application is running. Capture then opens, every sample is zero, and no layer
reports a fault. A silent device and a silent room look identical, and finding
out which it was meant leaving InferNode for a host tool.

`#A/audiodev` makes both the choice and the verdict visible. Read it to
enumerate the devices the host offers and see which is selected:

```
; bind -a '#A' /dev
; cat /dev/audiodev
in selected default
in device 'Built-in Microphone'
in device 'USB Audio Device'
out selected default
out device 'Built-in Output'
capture idle
```

Write `in <name>` or `out <name>` to select one. Names are quoted in the
readback because they contain spaces, and the readback's own forms —
`in device '<name>'` and `in selected '<name>'` — are accepted on write
as well, so a line from the read can be written straight back. `in
default` returns to following the host default. An unknown name is
refused rather than ignored. Selection takes effect at once: a stream
that is already open is reopened on the new device.

```sh
echo 'in Built-in Microphone' > /dev/audiodev
# a line from the read, written back verbatim:
line=`{grep '^in device' /dev/audiodev | sed 1q}
echo $line > /dev/audiodev
```

A launcher that already knows the right device can set it before the
emulator starts, which matters when the voice stack opens capture
during startup — before anything could write `#A/audiodev`. The
environment variables `INFERNODE_AUDIO_IN` and `INFERNODE_AUDIO_OUT`
take a device name each and preselect the input and output device;
an unknown name is not validated at startup but warned about and
fallen back to the system default at open time.

The last line is the diagnostic. `capture active` means the device produced at
least one non-zero sample. `capture silent` means it delivered data and all of
it was zero. `capture idle` means it delivered nothing. It describes the most
recent capture rather than only a live one, so it can be read after a recording
finishes. A capture that stays silent for two seconds also prints a one-time
warning to stderr.

`capture silent` has more than one cause — a virtual device with nothing behind
it, or microphone authorization the host has not granted. The file does not say
which, but it distinguishes all of them from a quiet room, which is what the
caller could not do before.

Backends without device enumeration report `unsupported`, and the emulator
follows the host default as it did before.

## Current GUI / Veltro Limitations (Future Work)

The final step — mounting the remote speech service — is **already supported** by the
catalog `[+]` button (`mountresource()` calls `sys->dial()` + `sys->mount()`). A catalog
entry with the Jetson's address handles it.

The **audio bridge** (the prerequisite) is **not supported** by any current GUI or agent
pathway:

| Step | Manual? | GUI? | Veltro? |
|------|---------|------|---------|
| `listen export /dev` on Mac | yes (launch script) | ✗ | ✗ |
| `mount` Mac audio on Jetson | yes (launch script) | ✗ | ✗ |
| `bind /n/macaudio/audio /dev/audio` | yes | ✗ | ✗ |
| `speech9p &` on Jetson | yes (launch script) | ✗ | ✗ |
| `listen export /n/speech` on Jetson | yes (launch script) | ✗ | ✗ |
| Mount remote speech on Mac | via catalog `[+]` | ✓ | ✗ |

### What Would Enable Full GUI/Agent Control

1. **`bind` tool** — a Veltro tool that calls `sys->bind(src, dst, flags)` in the *main*
   namespace (not the restricted agent namespace). Currently `exec` runs in a restricted
   namespace whose changes don't propagate back to Lucifer.

2. **`rcmd` / `ssh` tool** — to start services on the remote machine from Veltro. Without
   this, Veltro cannot set up the Jetson side at all.

3. **Catalog multi-step connect** — extend the catalog entry format to support a sequence
   of setup actions (dial, mount, bind, spawn) rather than a single dial+mount. A
   "Speech on Jetson" catalog entry could encode the full setup and execute it on `[+]`.

4. **Mount path for catalog entries** — `mountresource()` currently mounts to
   `/tmp/veltro/mnt/<slug>`. Speech tools expect `/n/speech`. Either allow catalog entries
   to specify a target path, or make speech tools check the catalog mount location.

### Recommended Approach (When Implementing)

Option A — **Launch script automation** (low effort, sufficient for now):
Bake the audio bridge into the Jetson's Lucifer launch command alongside `tools9p` and
`lucibridge`. Add the Mac `listen export /dev` to its launch command. The catalog entry
handles the final user-facing mount.

Option B — **Catalog multi-step connect** (proper GUI solution):
Extend `CatalogEntry` with a `setup: list of string` field. Each entry is a command
(`listen`, `mount`, `bind`, `exec`) run in sequence on `[+]`. The catalog file format
gains a `setup=` attribute. `mountresource()` runs the setup sequence before the final
mount. This generalises beyond speech to any multi-step remote service.

Option C — **`rcmd` tool + `bind` tool** (Veltro-native solution):
Give the agent the tools it needs. `rcmd host cmd` runs a command on a remote Inferno
instance via authenticated 9P exec. `bind src dst` performs `sys->bind()` in the main
namespace. Then Veltro can set up the full pipeline autonomously once it knows the
remote host address.
