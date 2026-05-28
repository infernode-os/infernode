# Hellaphone — InferNode on a Phone

*Phase 0: Termux on Android.*

The goal of the hellaphone effort is to run InferNode — the Dis VM, the
ARM64 JIT, 9P, and the Veltro agent harness — on a stock mobile phone.
This document walks through getting the **Phase 0 proof of life** up on
real Android hardware via Termux.

If you are looking for the bigger picture, see `INFR-107` and
`emu/Android/README.md`.

## Why Termux for Phase 0

Termux is a Linux-like userspace that runs as a normal Android app. It
ships `clang`, `mk`-able C, ARM64 hardware, and a POSIX-ish filesystem.
That is enough to bootstrap `mk`, build `limbo`, build `o.emu`, and run
Dis bytecode — without writing any NDK or JNI code first. If this
doesn't work, no amount of NDK plumbing will save us, so we want to
learn that here.

Phase 1 introduces a real `emu/Android/` target with NDK toolchain and
a proper Android app shell. Phase 0's job is to de-risk that work.

## Prerequisites

* An ARM64 Android device (modern Android phones are all aarch64).
* **Termux from F-Droid** (recommended) or the modern Play Store
  build (`googleplay.2025.10.05` or later, `targetSdk=36`). The older
  Play Store Termux was frozen on an old Android API for years and
  could not `pkg install` reliably; Termux re-released a modern build
  in October 2025 that works for Phase 0. F-Droid remains the
  default channel for the wider Termux community.
  F-Droid: <https://f-droid.org/en/packages/com.termux/>.
* ~2 GB of free storage for the source tree and build outputs.
* A few hundred MB of RAM headroom while building.

## Installing Termux

Termux is on the F-Droid app store, not the Play Store's default catalog
(see prereqs note above for the Play Store caveat). Two ways:

* **From the phone browser.** Go to
  <https://f-droid.org/en/packages/com.termux/>, download the `.apk`,
  tap to install. Android will ask you to allow "Install unknown apps"
  for the browser; grant it.
* **Via adb from a host machine.** Faster if you already have a USB
  cable plugged in:

  ```sh
  # On the host (Linux/macOS with adb installed)
  curl -fL --proto '=https' -o F-Droid.apk https://f-droid.org/F-Droid.apk
  adb install F-Droid.apk
  # Then open F-Droid on the phone, search "Termux", install.
  ```

  On a Samsung device running One UI you may need to disable Auto Blocker
  (Settings → Security and privacy → Auto Blocker) to sideload.

Modern Samsung devices (and most other vendor skins) ship with Auto
Blocker on by default — install F-Droid first, the Auto Blocker prompt
will let you make an exception.

## One-time Termux setup

Inside the Termux shell:

```sh
pkg update
pkg install -y clang make binutils pkg-config which perl git byacc
termux-setup-storage   # grant the "Files" permission prompt — needed
                       # for the daemon recipe later to expose /sdcard
```

`byacc` is required for the limbo compiler grammar (`limbo.y`); without
it the build dies with `yacc: not found` after the C libraries finish.

If you want to clone over SSH or run the host-driven workflow below,
also `pkg install openssh`. HTTPS clone works out of the box.

### Keep the device awake during the build

The Phase 0 build runs for several minutes. Android's Doze and Samsung
One UI's background-app management can suspend Termux while the screen
is off, stalling or killing the build. Before kicking off a long build,
acquire a wake-lock:

```sh
termux-wake-lock
```

Release it after the build finishes (or just close Termux):

```sh
termux-wake-unlock
```

If you are driving the build over `adb` + `ssh` from a host machine
(see the section below), the wake-lock is mandatory — otherwise the
device sleeps and the ssh session stalls.

### Driving the build from a host machine (adb + ssh)

Typing a 5–15 minute build on a phone keyboard is painful. If you
have the phone plugged in via USB with `adb` working, this is the
canonical workflow:

```sh
# --- on the host, once ---
# Generate a key pair for the phone (no passphrase).
ssh-keygen -t ed25519 -f ~/.ssh/infernode-phone -N "" -C "infernode-phone"

# Push the public key to the phone's shared storage.
adb push ~/.ssh/infernode-phone.pub /sdcard/Download/

# --- on the phone, once ---
# Inside Termux:
pkg install -y openssh
termux-wake-lock
termux-setup-storage   # answer the "Files" prompt
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat ~/storage/downloads/infernode-phone.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sshd                   # listens on 8022 by default
whoami                 # note the username, e.g. u0_a330

# --- back on the host ---
adb forward tcp:8022 tcp:8022
# Now host:8022 -> phone-Termux:8022.
ssh -i ~/.ssh/infernode-phone -p 8022 u0_a330@localhost
```

From that ssh session you have a real terminal into Termux — clone,
build, smoke-test, all from your host keyboard. To clean up:

```sh
adb forward --remove tcp:8022      # on host
termux-wake-unlock                 # on phone (or just close Termux)
```

## Build

```sh
cd ~
git clone https://github.com/infernode-os/infernode.git
cd infernode
./build-android-termux.sh         # headless build (recommended)
```

The script:

1. Confirms it is running on Termux (`uname -o` reports `Android`).
2. Bootstraps `mk` using `clang`, then uses `mk` for everything else.
3. Builds the core C libraries, the `limbo` compiler, the emulator
   (`o.emu`, headless), and the Limbo applications (commands, shell,
   Veltro tools).
4. Drops outputs into `Linux/arm64/bin/` and `emu/Linux/o.emu`.

The `Linux/` prefix is on purpose for Phase 0 — see
`emu/Android/README.md` for why.

Expect the first run to take 5–15 minutes depending on the device. The
bootstrap of `mk` is the slowest single step.

## Smoke test

From the same Termux shell:

```sh
./emu/Linux/o.emu -c1 -r$PWD sh -l
```

You should land in an Inferno shell prompt (`;` by default). Try:

```
; cat /dev/sysname
; echo hello from inferno on a phone
; ls /appl
```

If that works, **Phase 0 is done.** You have InferNode running on a
phone. Capture the output, attach it to `INFR-107`, and we move on.

## Running as a daemon — 9P export over TCP

The interactive smoke test is fine for a one-off check, but the more
interesting use case is running `o.emu` as a background daemon that
exports an Inferno namespace over 9P/Styx — so a desktop, laptop, or
another phone can mount the handset's filesystem (or anything else
visible to Termux) and pipe data through Inferno.

This is exactly the same `listen + exportfs` pattern that other
InferNodes use; the only Termux-specific part is the wake-lock and
the `-r` rooting decision.

### Minimal recipe

Run inside Termux on the phone:

```sh
termux-wake-lock
termux-setup-storage     # grant the "Files" prompt if you have not

cd ~/infernode

# (Optional) Expose host paths outside the build tree by symlinking
# them into the -r root. `#U` is confined to the -r directory, so
# anything you want visible has to be reachable from there. The
# symlinks below give you access to /sdcard and your Termux $HOME.
ln -sfn /sdcard ./sdcard
ln -sfn /data/data/com.termux/files/home ./termux-home

# Write the Inferno-side script the daemon will run.
cat > ./serve9p.b <<'EOF'
mkdir /n
mkdir /n/host
mkdir /n/sdcard
mkdir /n/home

# `#U` is the host-OS filesystem device, confined to the `-r` root.
# First, mount the whole tree at /n/host so we can navigate into it.
bind -ac '#U' /n/host

# Then re-bind the interesting subtrees to their idiomatic /n/ paths.
# The symlinks added above (./sdcard, ./termux-home) let us reach
# host paths outside the -r sandbox.
bind -ac /n/host/sdcard      /n/sdcard
bind -ac /n/host/termux-home /n/home

# /n/sdcard now serves Android's shared storage (subject to Termux's
# storage permission). /n/home serves your Termux $HOME. /n/host
# stays available for the whole -r tree if you want it.

listen -A 'tcp!*!17564' {exportfs -r /} &
# Keep the kernel alive — `listen` is in the background, and
# without something blocking in the foreground the shell would
# exit and emu with it.
wait
EOF

# Launch the daemon. nohup detaches it from the Termux session so
# it survives terminal close; stdout/stderr go to a log file.
nohup ./emu/Linux/o.emu -c1 -r"$PWD" /dis/sh.dis serve9p.b \
  > emu-daemon.log 2>&1 &

echo "daemon pid: $!  (logs in $PWD/emu-daemon.log)"
```

The daemon now listens on TCP port 17564 and serves a 9P/Styx export
of the entire Inferno namespace. The interesting subtrees, in the
order you'll usually want them:

| Inferno path | Backing |
|---|---|
| `/n/sdcard` | Android shared storage (`/sdcard`, the symlink target) |
| `/n/home`   | Your Termux `$HOME` (`/data/data/com.termux/files/home`) |
| `/n/host`   | The whole `-r` root (`~/infernode/`); includes both of the above plus the build tree |
| `/dis`, `/appl`, `/dev`, … | Inferno's own namespace |

Add more subtrees by symlinking into the `-r` root and adding the
matching `bind` line in `serve9p.b`. Why a re-bind rather than a
direct `bind '#U/sdcard' /n/sdcard`? — this build's `#U` does not
accept a subpath in the attach spec; the rebind-from-`/n/host` form
is the portable pattern.

Stop it with `pkill -x o.emu`.

### Reachability from a client

The phone needs to be reachable from your client. Three common
setups:

* **Plugged in via USB** — use `adb reverse` to expose the phone's
  listening port on the client:

  ```sh
  adb reverse tcp:17564 tcp:17564
  ```

  Then on the client, `127.0.0.1:17564` reaches the phone.

* **Same WiFi as the client.** Just use the phone's WiFi IP. Find
  it with `ifconfig wlan0` inside Termux, or read it off Android's
  WiFi settings.

* **Cellular / VPN.** Works the same way as long as your client has
  a route to the phone's IP; usually requires a personal VPN
  (Tailscale, WireGuard) since carrier NATs block inbound TCP.

### Mounting from a Linux client

Two reasonable client choices:

```sh
# 9pfuse (lightweight, FUSE-based)
9pfuse 'tcp!127.0.0.1!17564' /mnt/phone
ls /mnt/phone/n/host
ls /mnt/phone/n/host/sdcard      # if storage permission was granted

# Or v9fs in the kernel:
mount -t 9p -o trans=tcp,port=17564 127.0.0.1 /mnt/phone
```

`umount /mnt/phone` (or `fusermount -u` for 9pfuse) when done.

### Mounting from another Inferno

From inside any other InferNode (host laptop, Jetson, whatever):

```
; mount 'tcp!127.0.0.1!17564' /n/phone
; ls /n/phone/n/host
```

### What the security boundary actually is

* **`#U` is confined to the `-r` root.** Inferno's host-OS device
  cannot see paths above the directory passed to `emu -r`. This is
  a deliberate sandbox. Use symlinks pointing into the `-r` root
  (as in the recipe above) to widen the surface deliberately, one
  path at a time.

* **There is no authentication on the listener as written.** Anyone
  who can TCP-connect to the port reads (and writes — `exportfs` is
  read-write by default) the exported namespace. For a dev machine
  on a private network this is usually fine. For anything else,
  wrap the listener in TLS and require a client cert:

  ```
  # Inferno-side — pseudo, requires factotum + cert setup
  listen -A -s 'tcp!*!17564' tls {... exportfs -r /n/host}
  ```

  And mount client-side via `mount -A 'tls!host!port'`.

* **Termux's own permission boundary still applies.** Even if you
  mount everything from your client, you can only read paths Termux
  can read. `/sdcard` works after `termux-setup-storage`; other
  apps' private data dirs do not, and there is no root-only path
  visible to Termux without root.

### Persistent daemon (autostart)

For a daemon that survives reboots and Android's Doze killer, use
`termux-services`:

```sh
pkg install -y termux-services
mkdir -p $PREFIX/var/service/inferno9p/log
cat > $PREFIX/var/service/inferno9p/run <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
cd /data/data/com.termux/files/home/infernode
exec ./emu/Linux/o.emu -c1 -r"$PWD" /dis/sh.dis serve9p.b
EOF
chmod +x $PREFIX/var/service/inferno9p/run
ln -sf $PREFIX/share/termux-services/svlogger \
       $PREFIX/var/service/inferno9p/log/run
sv-enable inferno9p
```

Optionally `pkg install termux-boot` and add a wake-lock acquisition
to `~/.termux/boot/0-wake-lock` so the service comes up on boot:

```sh
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/0-wake-lock <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
EOF
chmod +x ~/.termux/boot/0-wake-lock
```

### What works (Phase 0) / what doesn't

| Capability | State |
|---|---|
| Build `o.emu` on Termux/arm64 | ✓ |
| Dis VM, 9P, namespace, Limbo bytecode | ✓ |
| ARM64 JIT (`-c1`) | ✓ (~3× faster than `-c0`) |
| TCP / TLS / live network handshakes | ✓ |
| Veltro agent harness | ✓ |
| `listen` + `exportfs` over TCP | ✓ |
| Mounting host paths via `#U` | ✓ (confined to `-r` root) |
| GUI (Lucia / Xenith / SDL3) | ✗ (Phase 1) |
| On-device LLM via `/n/llm` | ✗ (Phase 1) |
| Standalone APK (no Termux dependency) | ✗ (Phase 1) |
| x86 / x86_64 Android emulator (AVD) | ✗ (would need a separate cross-build) |

## Troubleshooting

**`clang: command not found`** — you missed `pkg install clang`, or the
Termux PATH is broken. Open a fresh Termux session.

**`/bin/sh: not found`** during the build — your Termux is unusual.
The build script picks up `sh` via `command -v sh`; if that fails,
export `SHELL=$(command -v sh)` before running.

**`fatal error: 'sys/foo.h' file not found`** — Bionic does not ship
every Linux header. Note the missing header, capture the offending
compile command, and file it against `INFR-107`. This is the kind of
signal Phase 0 exists to surface; it tells us what `emu/Android/` will
actually have to wrap in Phase 1.

**Build hangs or OOMs partway through** — Android may be killing
Termux for memory pressure. Close other apps; if the device is very
old, try a `headless` build only and skip the Limbo applications step.

**SDL3 build fails** — Phase 0 defaults to headless. Do not try the
SDL3 path on Termux yet; Phase 1 will sort the display backend.

**`ls /n/host/sdcard: permission denied`** when running the daemon —
you have not granted Termux storage access. Run `termux-setup-storage`
on the phone (or in Termux Settings → Apps → Termux → Permissions →
Files), then restart the daemon. The `#U` mount itself succeeded;
this is Termux's own permission boundary, not InferNode's.

**The 9P listener accepts connections but mounting hangs** — almost
always a wake-lock issue. Android put Termux to sleep mid-handshake.
`termux-wake-lock` before starting the daemon, and confirm with
`pgrep -af o.emu` from another Termux session that the process is
still running.

## What this is NOT

* It is not an Android app. There is no APK, no Activity, no
  notification — Termux just runs the binary in a terminal app. Phase
  1 produces an actual installable app.
* It is not on-device inference. `/n/llm` is not wired to anything
  useful on the phone yet; that retarget happens in Phase 1.
* It is not GUI. No Lucia, no Xenith on the phone yet. Headless only.

## Android app-sandbox seccomp restrictions

Phase 1c+ (APK path) runs InferNode under the Android app sandbox.
The OS installs a seccomp-bpf filter that blocks a list of syscalls
that desktop Linux freely allows. Calling a blocked syscall raises
`SIGSYS` and kills the calling thread on the spot — there is no
errno path to handle this; the process is just gone (or the thread
disappears, depending on the filter's action).

InferNode's emu has historically targeted desktop Linux and calls
some of these syscalls in places `os(1)` traditionally expects.
Each one needs an `#ifndef __BIONIC__` gate in `emu/Android/` or
it'll crash on Android.

Known disallowed syscalls and where they bit us:

| syscall (arm64 #) | site | symptom | fix |
|---|---|---|---|
| `setgid` (#144) | `emu/Android/cmd.c` `childproc()` after fork in `os(1)` | SIGSYS kills `SDLThread`; profile's `os sh -c '...'` calls silently fail; `$ghome`/`$infhome` stay empty; boot stalls on dead overlay binds. **INFR-114.** | gated behind `#ifndef __BIONIC__` (commit `1b136db8`). |
| `setuid` | same site | same | same gate |

The app process is already pinned to its package uid by the OS
sandbox before any of our code runs — privilege drop in `childproc`
is neither possible nor necessary. Inferno-side `$user` is
independent of the host uid so the user-facing semantics are
unchanged.

**Regression test.** `tools/check-android-syscalls.sh` lints
`emu/Android/*.c` for unguarded calls to any function on the
blocklist. It runs in CI (`.github/workflows/android-apk.yml`)
before the cross-compile, so a PR that re-introduces a forbidden
call fails fast. Extend the blocklist in that script when a new
SIGSYS lands on a device.

When adding new code that goes through fork+exec or any privileged
operation, sanity-check the syscall against the device's actual
policy:

```
adb shell cat /system/etc/seccomp_policy/app.policy 2>/dev/null
```

## Testing iOS telephony on a real device (Ba'al recipe)

The iOS simulator returns `canSendText == NO` and has no `tel:` handler,
so the only place outbound SMS / dial / CallKit observation can be
exercised end-to-end is a real iPhone with a SIM. Ba'al (the test
device in the project memory entries — iPhone 17 Pro Max running iOS
26.4.2 with Developer Mode ON) is the canonical target. The recipe
below works against any iPhone that has been provisioned for the
`os.infernode.ios` profile (cert `Apple Development: p.d.finn@gmail.com`,
team `9Z8Z334UUU`).

### Build + install on device

```sh
IOSSDK=iphoneos ./build-ios-app.sh --gui
```

The script signs with the auto-detected provisioning profile, installs
via `devicectl`, and launches. First-run keyring / writable-root setup
happens automatically. After a moment Lucifer comes up with the
Context / Workspace / Chat accordion.

### What you should see in stderr at boot

`devicectl` captures stderr to the system log; mirror it locally with:

```sh
xcrun devicectl device process launch \
    --device <UDID> os.infernode.ios --console
```

Expected lines, in order:

```
phone: bridge=iOS (MessageUI + CallKit observation wired — INFR-181)
phone: CXCallObserver installed
msg9p: registered source 'sms' from /dis/veltro/sources/sms.dis
```

If `CXCallObserver installed` is missing, the main-queue dispatch in
`phonebridge_init` lost the race with UIKit init — open a console
attach and trigger any UI redraw to give the runloop a tick.

### Outbound SMS (`/phone/sms`)

From the Inferno shell (open Workspace → shell, or via lucibridge if
you have an LLM configured):

```
; echo 'send +447700900100 testing from inferno' > /phone/sms
```

Expected behaviour:

1. `MFMessageComposeViewController` slides up over the app, pre-filled
   with the recipient and body
2. User taps Send (or Cancel)
3. Stderr logs `phone: iOS sms compose sheet up for +447700900100`
4. On Send tap, a real cellular SMS goes out via the carrier

If `canSendText` returns false (no SIM, iPad without cellular), the
write to `/phone/sms` fails with the error
`device cannot send SMS (no cellular / simulator)` — `%r` from the
shell will surface it.

### Outbound dial (`/phone/phone`)

```
; echo 'dial +447700900100' > /phone/phone
```

Expected behaviour:

1. Stderr logs `phone: iOS dial openURL tel:+447700900100 ok`
2. iOS shows its own call-confirmation dialog ("Call +447700900100?")
3. User taps Call
4. Cellular call is placed; CallKit fires the observer

### CallKit observation (`/phone/phone` reads)

While the call is active or transitioning, every state change pushes
a record into the bridge ring. A parallel reader drains them:

```
; cat /phone/phone
dialing - 2026-05-28T14:30:00Z
connected - 2026-05-28T14:30:05Z
disconnected - 2026-05-28T14:31:12Z
```

The remote number ("-") is hidden by CallKit for cellular calls —
this is an OS policy, not something we can route around.

### msg9p plumbing

Once `register sms` has fired in boot, the source is watching
`/phone/sms` reads. iOS's `phonebridge_recv_sms` returns `-1` (no
inbox API), so on iOS this watcher idles. To exercise it without
inbound SMS:

```
; echo 'send sms +447700900100' > /n/msg/ctl
< body line here
```

That routes through `msg9p`'s `send` verb to the sms MsgSrc's
`send(Message)` and produces the same `/phone/sms` write as the
direct test above.

### What the simulator CAN test

* `phonebridge_init` runs without crashing
* `CXCallObserver installed` reaches the log
* `msg9p: registered source 'sms'` reaches the log
* A write to `/phone/sms` returns the `canSendText` error cleanly
* A write to `dial` triggers an `openURL: tel:` log line (the call
  confirmation dialog is suppressed by the simulator)
* `cat /phone/status` returns the expected single-line bridge state

Everything beyond that needs Ba'al.

## References

* `emu/Android/README.md` — what eventually lives in that directory.
* `build-android-termux.sh` — the Phase 0 build driver.
* `build-linux-arm64.sh` — the Linux ARM64 driver we piggyback on.
* `INFR-107` — Phase 0 tracking epic.
* `INFR-114` — APK boot speed (closed; setgid seccomp was the cause).
* `INFR-181` — iOS phonebridge MessageUI + dial + CallKit observation.
* `INFR-182` — Android telephony wiring (other session's scope).
