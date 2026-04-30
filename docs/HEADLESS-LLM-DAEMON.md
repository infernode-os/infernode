# Headless InferNode: Mounting an LLM as a Filesystem

This tutorial walks through standing up a Linux server that exposes a
local LLM (running under Ollama) as a 9P filesystem, then mounting it
from another InferNode instance running on a different machine. By the
end, the remote machine treats the language model as a directory on
disk: it opens a session by reading one file, sends a prompt by writing
to another, and reads the response from the same file.

The host running InferNode in this tutorial can be any 64-bit Linux
system. It is not specific to NVIDIA Jetson; the daemon mechanics work
on amd64 and arm64 alike, including Jetson Orin AGX, Raspberry Pi 4 and
generic x86-64 servers. Where Jetson-specific paths or behaviour are
relevant, they are called out as such.

## The unusual idea

InferNode is a fork of Inferno OS, a small distributed operating system
descended from Plan 9 from Bell Labs. Inferno's central design choice
is that **every service is a filesystem**, accessed through a network
protocol called 9P. Process tables, network connections, the audio
device, the display, the clipboard — all expose themselves as files in
a hierarchy. A program reads or writes those files to interact with the
service behind them. Because 9P runs over any reliable byte stream
(Unix socket, TCP, TLS, encrypted aan tunnel), a service exposed
locally can be re-exported across the network and consumed by another
machine as if it were local.

This applies just as well to a language model. The InferNode component
`llmsrv` (`appl/cmd/llmsrv.b`) translates 9P file operations into HTTP
calls to an OpenAI-compatible chat-completions endpoint, and presents
the model as a synthetic filesystem under `/n/llm`. The protocol is
documented in [`doc/llm-mount.md`](../doc/llm-mount.md); the relevant
shape is:

```
/n/llm/
    new                    # read: allocate a session, returns its id
    {id}/
        ask                # write: prompt; read: response
        ctl                # write: session control (model, system prompt)
        tools              # write: tool definitions as JSON
        model              # read/write: model name for this session
        stream             # read: streaming response chunks
        usage              # read: token usage
```

A client speaking 9P does not have to know whether the server lives on
the same machine, on the next host on the LAN, or on a Jetson at the
end of a ZeroTier link. Mount the service and read and write files.
This tutorial sets up exactly that.

## Architecture

```
   Remote InferNode (client)               InferNode server (this host)
   ┌──────────────────────────┐            ┌────────────────────────────┐
   │  emu (Mac, Linux, ...)   │            │  emu, headless             │
   │                          │            │   ├─ llmsrv ── HTTP ──┐    │
   │  /n/llm  ◄─── 9P/TCP ────┼────────────┼─► /n/llm              │    │
   │                          │            │   └─ listen :5640     │    │
   │  Veltro / shell / xenith │            │                       ▼    │
   │  read/write /n/llm/*     │            │                ┌──────────┐│
   └──────────────────────────┘            │                │  Ollama  ││
                                           │                │ :11434   ││
                                           │                │ (model)  ││
                                           │                └──────────┘│
                                           └────────────────────────────┘
```

Three processes on the server, one network protocol on the wire:

1. **Ollama** runs on the host (outside InferNode) and serves the model
   over HTTP at `127.0.0.1:11434`.
2. **`llmsrv`** runs inside a headless InferNode emulator (`emu`),
   self-mounts `/n/llm` in the InferNode namespace, and translates 9P
   reads and writes against `/n/llm/*` into HTTP requests to Ollama.
3. **`listen`** runs in the same emulator, accepts inbound TCP on
   port 5640, and exports the InferNode namespace (specifically the
   subtree at `/n/llm`) over 9P.

Clients on other machines mount that exported subtree with `mount -A
'tcp!host!5640' /n/llm` (no auth) or via the `mount -k keyfile`
authenticated form.

## Prerequisites

- A 64-bit Linux server (amd64 or arm64). Tested on Ubuntu 22.04 and
  on Jetson Orin AGX running JetPack 6.
- A working network path from the client InferNode to the server on
  TCP port 5640 (LAN, ZeroTier, Tailscale, WireGuard, etc).
- A C toolchain (`build-essential`), `bison`, `make`, and `git`.
- Ollama installed and running. Installation:
  ```sh
  curl -fsSL https://ollama.com/install.sh | sh
  ```
  Confirm it is listening on `127.0.0.1:11434`:
  ```sh
  curl -sf http://127.0.0.1:11434/api/tags
  ```
- A clone of the InferNode repository:
  ```sh
  git clone https://github.com/infernode-os/infernode.git
  cd infernode
  ./hooks/install.sh           # installs post-merge bytecode-rebuild hook
  ```

The post-merge hook is recommended even if you do not plan to develop
against the repo; it prevents the most common class of post-pull
breakage when `.m` interface files change upstream and the shipped
`dis/*.dis` bytecode goes out of sync with the local source.

## Step 1: Build InferNode for the server

The server runs `emu`, the InferNode emulator. Build it for your host
architecture:

```sh
# arm64 (Jetson, Pi 4, ARM workstations):
./build-linux-arm64.sh headless

# amd64 (most servers):
./build-linux-amd64.sh headless
```

The `headless` argument selects a build that does not link SDL3 and
does not require a display server. The resulting emulator is at
`emu/Linux/o.emu`. A first build typically takes 5–10 minutes.

Verify the binary is present:

```sh
ls -l emu/Linux/o.emu
```

## Step 2: Pull a model

Any Ollama model that supports the OpenAI-compatible chat-completions
shape will work. Tool-capable models are recommended if you intend to
drive the service from Veltro (the InferNode agent harness), since
Veltro relies on function-calling. As of this writing, the following
are reasonable choices:

| Model | Approx. size at q4 | Notes |
|---|---|---|
| `mistral-nemo` | 7 GB | 12B parameters, 128 K context |
| `ministral-3:14b` | 9 GB | Mistral 3 dense, vision and tool use |
| `mistral-small3.2:24b` | 14 GB | improved function-calling per Mistral release notes |
| `qwen2.5:14b` | 8 GB | reliable tool use, well-tested |
| `llama3.1:8b` | 5 GB | small footprint, broad familiarity |

Pull one (the rest of the tutorial assumes `mistral-small3.2:24b`):

```sh
ollama pull mistral-small3.2:24b
```

On a Jetson Orin AGX with 64 GB unified memory, models up to about 30 B
parameters at 4-bit quantisation fit comfortably with room for the
emulator and the inference KV cache. On a server with only the
GPU's dedicated VRAM, choose accordingly.

## Step 3: Configure the LLM backend

InferNode's LLM client reads its backend configuration from
`~/.infernode/lib/ndb/llm` on the host. The file is bind-mounted into
the InferNode namespace as `/lib/ndb/llm` at startup.

Create or edit it to point at the local Ollama instance:

```sh
mkdir -p ~/.infernode/lib/ndb
cat > ~/.infernode/lib/ndb/llm <<'EOF'
mode=local
backend=openai
url=http://localhost:11434/v1
model=mistral-small3.2:24b
dial=
EOF
```

The fields:

- `mode` — `local` runs `llmsrv` against an HTTP endpoint on this host.
  (`remote` would mount someone else's `/n/llm` instead, which is what
  the *client* machine in this tutorial will use.)
- `backend` — `openai` selects the OpenAI-compatible chat-completions
  protocol. `api` would select Anthropic's native API.
- `url` — the Ollama endpoint. `/v1` is required: it is the
  OpenAI-compatible prefix, not the native Ollama API.
- `model` — the default model for new sessions. Clients can override
  per-session by writing to `/n/llm/{id}/model`.
- `dial` — only used when `mode=remote`. Leave empty here.

## Step 4: Run the daemon ad-hoc

Two scripts in the repository wire the daemon together:

- `lib/sh/serve-profile` — a stripped-down InferNode `rc` profile that
  starts only what is needed for the LLM gateway: networking,
  connection server, the LLM config bind-mount, `llmsrv`, and the 9P
  network exporter. It deliberately omits the desktop machinery (`auth/secstored`,
  `auth/factotum`, theme bindings, Veltro overlays) that the default
  desktop profile loads.
- `serve-llm.sh` — a host-side bash wrapper that locates Ollama on
  `PATH`, pre-flights the Ollama API, and execs `emu` against the lean
  profile. It is the entry point the systemd unit will call.

Start it ad-hoc to verify everything works before installing the unit:

```sh
./serve-llm.sh
```

You should see the wrapper announce itself, then a couple of lines of
emulator startup, then output of the form:

```
serve-llm: 2026-04-30T17:17:49+07:00 emu=... root=... profile=/lib/sh/serve-profile
fs: fsqid: top-bit dev: 0xb301
<- Tmsg.Version(65535,8216,"9P2000")
-> Rmsg.Version(65535,8216,"9P2000")
<- Tmsg.Attach(1,55,4294967295,"pdfinn","")
-> Rmsg.Attach(1,Qid(16r0,0,16r80))
```

Those last four lines are llmsrv's internal self-mount of `/n/llm`,
debug-logged because the lean profile starts llmsrv with `-D`. The
process is now waiting for inbound 9P connections on port 5640.

In another shell, confirm the listener:

```sh
ss -ltnp | grep 5640
```

Output should resemble:

```
LISTEN 0  256  *:5640  *:*  users:(("o.emu",pid=...,fd=...))
```

A protocol-level handshake check (does not require a second InferNode):

```sh
python3 -c '
import socket, struct
s = socket.create_connection(("127.0.0.1", 5640), timeout=3)
ver = b"9P2000"
msg = struct.pack("<IBHI", 0, 100, 0xFFFF, 8192) + struct.pack("<H", len(ver)) + ver
msg = struct.pack("<I", len(msg)) + msg[4:]
s.send(msg)
hdr = s.recv(7)
sz, typ, tag = struct.unpack("<IBH", hdr)
rest = s.recv(sz - 7)
if typ == 101:
    msize = struct.unpack("<I", rest[:4])[0]
    vlen  = struct.unpack("<H", rest[4:6])[0]
    print("Rversion:", "msize=", msize, "version=", rest[6:6+vlen].decode())
'
```

Expected output:

```
Rversion: msize= 8192 version= 9P2000
```

Anything else means the listener is not speaking 9P. Stop the daemon
with Ctrl-C; we will install systemd next.

## Step 5: Install as a systemd user service

Create `~/.config/systemd/user/infernode-llm.service`. Replace
`/path/to/infernode` with the absolute path to your repo clone:

```ini
[Unit]
Description=InferNode headless LLM 9P gateway (llmsrv via emu)
Documentation=file:///path/to/infernode/doc/llm-mount.md
After=ollama.service network-online.target
Requires=ollama.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/path/to/infernode
ExecStart=/path/to/infernode/serve-llm.sh
Restart=always
RestartSec=10
KillMode=mixed
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=infernode-llm

[Install]
WantedBy=default.target
```

A few notes on the unit:

- It is a **user service** (`--user`), not a system service. The
  service inherits the user's environment, including any model storage
  configured via `OLLAMA_MODELS`. If you need it to run as a different
  user, install under that user's `~/.config/systemd/user/` instead.
- `KillMode=mixed` sends `SIGTERM` to the main `emu` process and
  `SIGKILL` to its descendants. This is appropriate because `emu`'s
  child processes are kernel-level threads of the InferNode runtime,
  not POSIX processes that run their own cleanup.
- `Restart=always` covers both crashes and clean exits. `RestartSec=10`
  spreads out restart storms if Ollama is also restarting.

Reload, enable, start:

```sh
systemctl --user daemon-reload
systemctl --user enable infernode-llm.service
systemctl --user start  infernode-llm.service
```

Verify:

```sh
systemctl --user status infernode-llm.service --no-pager
ss -ltnp | grep 5640
journalctl --user -u infernode-llm -n 50 --no-pager
```

Make the service start at boot **without** an active login session,
which user services do not do by default:

```sh
sudo loginctl enable-linger "$USER"
```

The service now survives reboots, console logouts, and Ollama
restarts (it will reconnect when Ollama returns).

## Step 6: Connect from a remote InferNode

On the client machine — a Mac, another Linux box, anywhere InferNode
runs — there are two ways to mount the server's `/n/llm`.

### Through the Settings application

Launch InferNode and open the Settings app from the wm panel. Under
**LLM Service**, choose **Mode: Remote (9P)**. In the **Dial address**
field enter:

```
tcp!server-hostname-or-ip!5640
```

The Settings dialer accepts a raw `host:port` form as a convenience
and normalises it to `tcp!host!port` on apply (see `module/dialnorm.m`
and `tests/dialnorm_test.b` for the exact rules). Click **Apply** to
persist the configuration, then restart InferNode for the mount to
take effect — the mount must happen at profile-load time so it is
visible to all child processes that fork the namespace.

### From the InferNode shell

Equivalent direct command, run from the InferNode shell after start:

```sh
mount -A 'tcp!server.example.net!5640' /n/llm
```

`-A` selects unauthenticated 9P. For authenticated 9P over an Inferno
keyring, see the **Hardening** section below.

## Step 7: Verify end-to-end

From the InferNode shell on the client, run:

```sh
ls /n/llm
```

You should see at minimum a `new` file. Open a session and chat:

```sh
id=`{cat /n/llm/new}
echo $id
echo 'In one sentence, what is Plan 9 from Bell Labs?' > /n/llm/$id/ask
cat /n/llm/$id/ask
```

The first send is slow on a cold model (Ollama loads weights into
GPU memory; expect 10–60 seconds depending on model size and disk
speed). Subsequent sends in the same session are fast.

Switch model per-session without restarting the daemon:

```sh
echo mistral-nemo > /n/llm/$id/model
echo 'And in one sentence, what is Inferno?' > /n/llm/$id/ask
cat /n/llm/$id/ask
```

Veltro, xenith, and any other InferNode-native tool that consumes
`/n/llm` will work transparently against the remote model.

## Operational reference

```sh
# State
systemctl --user status infernode-llm

# Restart (e.g. after editing ~/.infernode/lib/ndb/llm)
systemctl --user restart infernode-llm

# Stop
systemctl --user stop infernode-llm

# Live logs
journalctl --user -u infernode-llm -f

# Configuration
${EDITOR:-vi} ~/.infernode/lib/ndb/llm
systemctl --user restart infernode-llm

# Verify Ollama is reachable from the host
curl -s http://127.0.0.1:11434/api/tags | jq '.models[].name'

# What is currently loaded in Ollama
curl -s http://127.0.0.1:11434/api/ps | jq
```

## Pitfalls

The following are the most common ways this setup fails. Each was hit
during development; the fixes are upstream.

### "I entered an IP and port, and nothing connects"

The InferNode dial syntax is `tcp!host!port`, not `host:port`. The
Settings application will normalise `host:port` to the dial form
on apply (commit `6364113a`); older versions or direct `mount`
commands need the dial form spelled out:

```sh
mount -A 'tcp!10.0.0.5!5640' /n/llm     # correct
mount -A 10.0.0.5:5640 /n/llm           # silently fails
```

### "The first-run wizard only offers API key or local Ollama"

Older builds collapsed two orthogonal axes — *mode* (Local vs Remote)
and *backend* (Anthropic API vs Ollama-compatible) — into a single
two-button wizard, hiding the Remote 9P mode. Pull current `master` and
the wizard offers three peer choices (commit `fc61af13`). If you
cannot pull, you can write the Remote configuration directly:

```sh
cat > ~/.infernode/lib/ndb/llm <<'EOF'
mode=remote
backend=
url=
model=
dial=tcp!server.example.net!5640
EOF
```

### "Chat returned one response, then nothing"

Two distinct failure modes have produced this symptom:

1. **VRAM exhaustion.** Some models default to very large context
   windows (Mistral 3, for example, advertises 256 K). Ollama allocates
   KV cache for the full window when it loads the model. On a 24 GB
   GPU, a 14 B model at full Mistral 3 context can occupy 48 GB and
   start swapping mid-conversation. Pin the context window with a
   smaller value via the model file (`/n/llm/{id}/ctl`) or by setting
   `OLLAMA_NUM_CTX` for the Ollama service.
2. **Tool-call retry exhaustion.** When the consumer is Veltro, a
   model that emits malformed `tool_calls` blocks the agent loop after
   N consecutive failures. Switch the session to a model with stronger
   function-calling discipline (`mistral-small3.2`, `qwen2.5:14b`).

### "post-merge: mk not found"

The post-merge hook rebuilds InferNode bytecode for `.b` files that
changed in a pull, using a native `mk` it expects to find under
`Linux/$ARCH/bin/mk`. If you have not built the native InferNode
toolchain on this Linux host (it is built on macOS by default), the
hook prints the warning and skips. For the daemon this is harmless —
it runs the shipped `dis/*.dis` bytecode, which travels with the repo.
For local development on Linux, build the native toolchain via
`./makemk.sh` followed by `mk install` from the repo root.

### "The model doesn't load — I deleted it as cleanup"

Ollama's model store is content-addressable, but model *names* are
manifest-level and removing one removes the named entry. If you have a
service unit pinned to a model and you delete that model, the service
will stall at first inference. Either re-pull the model or update the
service config (`~/.infernode/lib/ndb/llm`) and restart.

## Hardening

The defaults in this tutorial trade away security for ease of setup.
Before exposing the service beyond a trusted network, address each of
the following.

### Authentication

`listen -A` and `mount -A` bypass authentication. Anyone who can reach
the TCP port can open sessions. For trusted networks (LAN, ZeroTier,
Tailscale) this is often acceptable; for the open internet it is not.

To enable Inferno keyring authentication:

1. Generate a keyfile on the server: see `appl/cmd/auth/` for the
   relevant tooling (`changelogin`, `getauthinfo`).
2. Distribute the public component to authorised clients.
3. In `lib/sh/serve-profile`, replace
   ```
   listen -sA 'tcp!*!5640' {export /n/llm}
   ```
   with
   ```
   listen -s -k /usr/$user/keyring/default 'tcp!*!5640' {export /n/llm}
   ```
4. On the client, `mount -k /usr/$user/keyring/default 'tcp!host!5640' /n/llm`.

The pattern is exercised by `tests/test-distributed.sh`, which sets up
two emulator instances communicating over authenticated, encrypted 9P.

### Network exposure

The default listener binds to all interfaces (`tcp!*!5640`). To
restrict to a specific interface — for example, only the ZeroTier
interface — change the listen address in `lib/sh/serve-profile`:

```
listen -sA 'tcp!10.243.169.78!5640' {export /n/llm}
```

Alternatively, leave the listener wide and rely on the host firewall
(`ufw`, `iptables`, `nftables`) to drop unsolicited connections.

### Secrets

Anthropic API keys and other secrets that `llmsrv` consumes are read
from `factotum`, InferNode's authentication agent. The lean
`serve-profile` does **not** start `factotum` — it is only needed when
the backend is `api` (Anthropic). If you switch the daemon to that
backend, add the factotum startup back into `serve-profile` and
provision keys via `secstored` or environment variables, as the
desktop profile does.

### Resource ceilings

`emu` uses a small, predictable amount of memory (about 12 MB
resident) — the model itself lives in Ollama, outside the InferNode
namespace. To prevent runaway resource use under abuse or accidents,
add cgroup limits to the unit file:

```ini
[Service]
MemoryMax=1G
TasksMax=200
```

Ollama's resource use is a separate question, addressed by Ollama's
own configuration (`OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL`).

## Going further

- **GPU services.** `appl/cmd/gpusrv.b` exposes TensorRT inference as a
  9P filesystem at `/mnt/gpu` using the same architectural pattern as
  `llmsrv`. It requires an `emu` rebuilt with `mkfile-gpu-1` (CUDA and
  TensorRT linked in). On Jetson hardware, JetPack already provides the
  needed libraries.
- **Server-side UI.** `appl/cmd/luciuisrv.b` serves the UI state of the
  Lucifer interface as a 9P filesystem at `/n/ui/`. Combined with
  `appl/cmd/lucibridge.b`, it allows the agent loop to run on the
  server while a Mac or other client acts as a thin renderer over the
  same 9P mount. Multiple renderers can attach to the same activity.
- **Speech.** `appl/veltro/speech9p.b` exposes TTS/STT under
  `/n/speech`. Useful for voice front-ends to a remote Veltro session.

Each of these can be added as a peer service in the same lean
`serve-profile`, exported either on `:5640` alongside `/n/llm` or on
its own listener for clean network-policy boundaries.

## References

- [`doc/llm-mount.md`](../doc/llm-mount.md) — the 9P filesystem layout
  exposed by `llmsrv`, including session control and tool-definition
  files.
- [`appl/cmd/llmsrv.b`](../appl/cmd/llmsrv.b) — the canonical
  implementation of the LLM 9P gateway in Limbo.
- [`module/dialnorm.m`](../module/dialnorm.m),
  [`appl/lib/dialnorm.b`](../appl/lib/dialnorm.b) — the dial-string
  normaliser shared across InferNode applications.
- [`tests/test-distributed.sh`](../tests/test-distributed.sh) — example
  of authenticated, encrypted 9P between two InferNode instances.
- [`docs/USER-MANUAL.md`](USER-MANUAL.md) — broader InferNode user
  guide, including namespace and device documentation.
- Plan 9 from Bell Labs, [9P protocol](http://man.cat-v.org/plan_9/5/0intro)
  — original protocol reference.
