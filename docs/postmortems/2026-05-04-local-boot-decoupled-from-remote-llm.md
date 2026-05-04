# 2026-05-04 — Local InferNode boot wedged by remote LLM mount

## Summary

The macOS InferNode bundle hung after the user entered their secstore
password. Root cause turned out to be a violation of a system-wide
invariant: **a local InferNode startup must never block on the
availability or health of a remote InferNode.** Both `lib/sh/profile`
and `lib/lucifer/boot.sh` performed a foreground `mount -A
$llmdial /n/llm` and a `ftest -f /n/llm/new` probe of the resulting
mount. Either call can block forever if the remote 9P exporter
accepts the TCP connection but never services it (no protocol-level
timeout in 9P mount). Once the remote `serve-profile` on hephaestus
degraded into that state, every subsequent local boot wedged.

## Symptoms

- `/Applications/InferNode.app` opened, login screen appeared, password
  accepted, then the GUI hung indefinitely.
- Captured stdout via `open --stdout /tmp/infernode.out --stderr
  /tmp/infernode.err /Applications/InferNode.app` ended at:

  ```
  logon: secstore save-back enabled
  logon: /n/llm not mounted, starting llmsrv
  llmsrv: no API key in factotum or ANTHROPIC_API_KEY
  ```

  with no further boot output (no `tools9p` lines, no `lucifer: INIT`).
- Local emu process alive, two TCP connections in `ESTABLISHED` state
  to the remote exporter on `tcp!10.243.169.78!5640`. Server side had
  19 bytes (== exact size of a 9P TVERSION) sitting in the socket
  receive queue, never read by the exporter process.

## Investigation

Hypotheses were enumerated and tested rather than guessed:

- **H1** boot blocked on `ftest -f /n/llm/new` walking through a stale
  9P mount left by `profile`. A loopback test on hephaestus
  (`mount -A tcp!127.0.0.1!5640 /n/test; ls /n/test`) returned
  `clone failed`, confirming the live exporter could complete TCP
  handshake but not serve filesystem walks.
- **H2** boot blocked on the second `mount -A` inside boot.sh's
  if-block. Possible but downstream of H1.
- **H3..H9** later boot.sh steps (luciuisrv, tools9p, lucibridge,
  lucifer). Ruled out by per-step trace markers (see "Test
  infrastructure" below).

A clean restart of hephaestus's `serve-profile` (systemd brought it
back up automatically) made the desktop boot succeed once. Within
minutes the same exporter re-degraded into the same "TCP-ESTABLISHED,
TVERSION-unread" state — making this a recurrent server-side bug,
*not* something the local desktop should have to tolerate.

## Test infrastructure

`lib/lucifer/boot.sh` was instrumented with `echo BOOT-N >>
/tmp/inferno-trace.log` markers between each phase. `/tmp` inside
emu binds to `$HOME/tmp` on the host (via `bind -bc $home/tmp /tmp`
in profile), so the trace was readable from outside the emulator
without further tooling. Once the architectural fix was deployed,
the trace went BOOT-1 through BOOT-12 (lucifer is foreground; no
BOOT-13 expected while running), confirming desktop boot completed
even with hephaestus visibly degraded (TVERSION still unread on the
server side at the time of confirmation).

## Fix

Two changes, both in this commit:

1. `lib/sh/profile`: background the remote `mount -A` so the rest of
   profile (and therefore boot.sh) cannot wedge on it.
2. `lib/lucifer/boot.sh`: drop the `ftest -f /n/llm/new` probe entirely
   and run the whole LLM (re)start in a backgrounded subshell. The
   chat UI is responsible for handling "/n/llm not ready yet"
   gracefully — see `appl/wm/llmclient.b` and downstream.

Trace markers were left out of the committed version. Re-add them
locally if a future regression needs the same diagnostic.

## Things this commit does NOT fix

- The hephaestus exporter degradation. Hephaestus's `serve-profile`
  (`lib/sh/serve-profile`) still goes into the
  "accept-but-don't-read-TVERSION" state shortly after a `kill +
  systemd respawn`. Investigation continues separately — see
  `docs/postmortems/<TBD>` once tracked down. Likely candidates: a
  stuck `export /n/llm` worker spawned by `listen -sA`; a deadlock
  inside the spawned exporter when llmsrv-on-hephaestus's own
  `/n/llm` is in transition; or interaction with `mntgen`.

## Other things this incident exposed

- The macOS bundle's CDHash had been silently invalidated by another
  agent that swapped in patched `.dis` files (and a Safari-quarantine
  xattr on each one) on April 30. macOS `codesign --verify` reported
  `a sealed resource is missing or invalid`. Re-signing the bundle
  with the original `Developer ID Application: Synectify, Pte Ltd
  (TJ448C32Q3)` restored the seal. Locally rebuilding `o.emu` also
  required `install_name_tool -change
  /opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib
  @executable_path/libSDL3.0.dylib` so dyld wouldn't try to load
  Homebrew's differently-signed SDL3 under hardened runtime
  (library validation rejects mixed-team-ID dylibs). The release CI
  (`.github/workflows/release.yml`) does this via the canonical sign
  procedure; the local `build-macos-sdl3.sh` does not, and should.

## Lessons

1. **A distributed system is not allowed to wedge its local boot on a
   remote.** Any cross-host mount, dial, or stat must be
   backgroundable, timeout-bound, or both. This applies to *every*
   boot-time `mount -A`, not just the LLM one.
2. **9P has no transport-level timeout.** Don't rely on the protocol
   to fail; the kernel `connect(2)` gives you SYN-RTO timeouts but
   once the connection is `ESTABLISHED` you wait for the peer
   forever. Every 9P client codepath that boot depends on must be
   guarded.
3. **macOS bundle TCC grants are tied to the CDHash.** Editing files
   inside `Contents/Resources/` of a signed bundle invalidates the
   seal silently and revokes any prior Local-Network /
   Microphone / etc. grants. If you must hot-patch a bundle,
   re-sign it and expect to re-prompt. Don't drop Safari-quarantined
   files into a bundle — strip xattrs first.
4. **`open` and shell-exec are not equivalent on Sequoia.** Shell-
   launched binaries inside an `.app` inherit responsibility from the
   terminal, so TCC checks the terminal's grants, not the bundle's.
   Always launch via `open` for anything that needs bundle-level
   entitlements; use `open --stdout … --stderr …` to keep debug
   output.
