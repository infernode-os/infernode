# Changelog

All notable changes to InferNode are documented in this file.

## [Unreleased]

### Veltro

- **One agent harness, served as files.** The agent loop was written out
  twice, in `veltro` and `lucibridge`, and had drifted; it is now one
  program, `veltrosrv`, which serves a session as a directory at
  `/mnt/veltro`: `input`, `text` (the conversation, following a turn as it
  is generated), `log` (the trajectory), `status`, `approve` and `ctl`.
  The loop is `lucibridge`'s, the one the grinding tuned, moved in
  unchanged; its goldens pass through the new `lucibridge`, now a client
  that renders those files into Lucia. `veltro` is a client too, and
  Xenith gets `Agent`, a window on the agent for work on a project from
  the editor (`man 4 veltrosrv`, docs/VELTRO.md, docs/XEN.md).
- **Read-only tool calls run concurrently.** The tool calls of one model
  response run at once when all are read-only (reads, searches, `spawn`)
  and one at a time, in the model's order, when any mutates, so a write
  always precedes the read or compile that follows it. Every call has its
  own sixty-second bound.
- **The server restricts its own namespace before it serves**, with the
  grants it was started with, and mounts only in the client's namespace:
  the agent's tools cannot see `/mnt/veltro`, so it cannot approve or
  widen itself. Compaction is `llmsrv`'s alone.
- **Acme's and Xenith's commands ship.** Each editor binds its own command
  directory before `/dis` (`acme/dis`, `xenith/dis`: `win`, `adiff`, `Mail`,
  `Agent` and the rest), as upstream Inferno's acme does. Releases staged a
  fixed list of top-level directories that never included `acme/` or
  `xenith/`, so in a shipped tree neither editor could run its tag
  commands, and Acme had no colour schemes. Every release job stages both
  now, and the build manifest covers both command directories.
- `veltro` session names and logs were built with `string c` on a rune,
  which printed its number; fixed. `-y` answers the approval gate for
  scripts. `xen` starts the model service the way Lucifer's boot does,
  through `lib/lucifer/llmsrv.sh`, now one script for both.

### Xenith

- **Xenith ships as an app of its own**, alongside InferNode in every
  release: `Xenith.app` (a signed, notarized `xenith-<version>-macos-arm64.dmg`)
  and `Xenith.exe` (`xenith-<version>-windows-amd64.zip`), with their own
  icon. Each is the same emulator and runtime tree as InferNode, running
  Xenith alone as `tools/xen` does, and shares `~/.infernode` with it.
  `xen`, `xen.ps1` and both apps start through one script,
  `lib/xen/boot.sh` (docs/XEN.md). `xen.ps1` now starts the plumber and the
  model service, as `xen` does.

## [0.5.0] - 2026-09-28

InferNode runs on bare metal. This release adds a native kernel for the
Raspberry Pi 3B+, brought up on the hardware and soaked for 48 hours,
a port to 64-bit RISC-V, hosted and bare metal, and the fixes that work
found in the shared code: in the Dis VM, all three JITs and the hosted
emulator. It also makes the TLS client authenticate servers, which it
did not do before; see Security.

### Bare metal

- **A native kernel** (`os/`): Inferno's kernel structure, `os/port` and
  `os/ip` shared, `os/arm64` for the architecture, `os/bcm` and
  `os/bcm2837` for the Raspberry Pi 3B+. It boots to the Lucifer desktop
  from the SD card: USB keyboard and mouse, HDMI, the card as a
  filesystem (`dossrv`), the audio jack as `/dev/audio` (#636) with a
  low-latency mode (#653), GPIO pins as files with edge events and
  interrupt timestamps (#651), Wi-Fi (WPA2 and DHCP), Bluetooth (`bt9p`:
  HCI, L2CAP, SDP, RFCOMM, HID), and the on-board Ethernet.
- **Ethernet at 160 Mbit/s in and 148 out** on the 3B+'s LAN7515 behind
  its USB 2 controller, from 7-32 before (#633): a bulk IN kept armed
  across NAKs, a cross-core race on the controller's interrupt mask, a
  cache invalidate after receive DMA, 802.3x pause frames, and
  receiver-side selective acknowledgement (RFC 2018) in the TCP stack.
  One data path, in the kernel; the earlier 9P path is gone.
- **The cores at their rated clock** (#691). The firmware leaves the
  ARM cores at its 600 MHz idle clock for the OS to raise, and nothing
  asked; every soak, battery and benchmark before this ran at 600 MHz.
  They now run at 1400.
- **Two more machines under QEMU**: the `virt` machine (#656, #657) and
  the Raspberry Pi 4 (#662-#666). The Pi 4 port has never run on a
  board and says so; both are built and booted in CI.
- **Drivers for the Pi 4, tested where QEMU can test them** (#705): PCI
  and the Pi 4's PCIe bridge, xHCI with hot-plug, MSI, GICv3, USB disks
  (`diskusb`), isochronous USB output, and GENET Ethernet, all from
  9front. On `virt` they run; the Pi 4's own hardware has never run
  them. A QEMU DWC2 bug that looked like ours (#664) is patched in the
  QEMU that CI builds.
- **64-bit RISC-V** (#718): `emu` on riscv64 Linux with a new Dis JIT
  (`libinterp/comp-riscv64.c`), and a native kernel (`os/riscv64`) for
  QEMU's RISC-V `virt` machine (`os/riscvvirt`, to the graphical logon
  on a ramfb screen) and the PolarFire SoC of the BeagleV-Fire and
  Icicle Kit (`os/mpfs`: SD card, Ethernet, entropy, and a `boot.scr`
  for U-Boot). The virtio drivers and framebuffer console are now shared
  across the kernels. Everything RISC-V has run under QEMU only;
  `os/riscv64/README.md` has the first-boot checklist for the board.
- **A lock loop found by the soak, and fixed** (#681, #682): `tsleep()`
  took the timer-sleep lock with interrupts on while the USB driver spun
  for it with them off; a holder preempted at the wrong instant pinned
  the spinner's core for ever. Reproduced in 40-125 s under a sleep
  storm, then 48 hours clean. Also from the board: a process preempted
  between two uses of a register resumed on another core (#622), the
  JIT's module-pointer sentinel taken for code (#635), type code never
  freed on module unload (#641), the entropy source padding a short
  read with zeros (#658), a software cursor that left a second arrow
  behind (#654), and "clone failed" now says why (#650).
- **More from the board, after the soak**: every Limbo `real` formatted
  as garbage, and loading a map that wrote positions with `%.6f` wedged
  the VM, because `snprint`/`sprint` were built without FP and a
  variadic double travels in a vector register (#715); the 100-slot
  process table filled in an ordinary GUI session and hung everything
  on "no procs", now scaled from RAM and capped at 1000 (#716); a
  program's own mount point under the read-only `/mnt` did not exist,
  now generated by `mntgen` (#714); a full Ethernet transmit queue
  wedged IP instead of dropping (#692); a `chdir` in a sibling process
  could free `dot` under `pctl(NEWNS)` (#640); and `dossrv` glued a
  failed create's orphan long-name slots onto the next file's name
  (#673).

### Dis VM and JITs

- **A Limbo `int` is 32 bits on a 64-bit word**, in the interpreter and
  both JITs. `16r7FFFFFFF + 1` was positive, a `-1` assembled from bytes
  did not compare equal to `-1`, and shifts did not sign-extend; every
  int result is now stored sign-extended, and a string converted to an
  int saturates at the int's own range (#683) instead of carrying a
  64-bit `long` into the slot.
- **Hosted arm64 no longer leaks every type's compiled code** (#646,
  #649): about 52 KB per command run, 52 MB per thousand, now zero. The
  amd64 JIT stored `movw` results sign-extended and truncated 64-bit
  words; fixed and verified on x86-64. Hosted amd64 now also reuses a
  freed type's compiled code instead of growing its slab by about
  1.5 KB per command (#706).
- **A compiled module's code is no longer unmapped under its own
  return** (#718), on every JIT. When a module's last reference went
  while a call into it was running, as a server does with modules it
  unloads, the return punted to `OP(ret)`, which unloaded and unmapped
  the module and then returned into unmapped memory.
- **arm64 JIT returns within a module inline** (#689), as amd64 does,
  instead of punting to the interpreter's `OP(ret)`: recursive code is
  2-6x faster on the 3B+ (jitbench v2 7,354 to 2,607 ms).
- **The arm64 JIT hands off to the interpreter for a callee that is
  not compiled** (#687). A compiled module calling an interpreted one
  -- the JIT switched off at run time, or a module built with `limbo
  -C` -- branched into the callee's bytecode as if it were code: a
  kernel panic on the board, a fault in the hosted emulator. Found by
  the JIT benchmark's interpreter runs on the 3B+; amd64 was already
  right. A regression test runs both directions, hosted and on the
  Pi 3 kernel under QEMU.
- `memfs`: a read past the end of a file returns nothing instead of
  killing the server (found by the soak, #641).
- A Prog whose module is not linked yet has `R.M` nil, not only `H`;
  the #635 diagnostics read through it, which faulted the first Dis
  program on the RISC-V kernel (#718).

### Security

- **The TLS client authenticates servers, and fails closed** (#693).
  Any one of these let a network attacker impersonate any HTTPS server
  to programs using `tls` or `webclient`: X.509 chains did not have to
  reach a trust anchor (a self-signed certificate verified against
  itself, and an unknown issuer was accepted); TLS 1.3 did not require
  Certificate and CertificateVerify; TLS 1.2 skipped the
  ServerKeyExchange signature when absent or not RSA; the hostname check
  soft-failed when an extension did not parse; and PKCS#1 v1.5 was
  verified by suffix match. A connection that cannot be authenticated
  is now refused.

### Other fixes

- `awk`: `$0` is kept verbatim (it was rebuilt with OFS, losing tabs),
  `NF = n` no longer clobbers `$1`, regex literals understand `\t`,
  `\n` and `\r`, and `break`/`continue` work in loops (#694).
- `lucitheme`: a colour whose red channel is `>= 0x80` is no longer
  taken for a parse failure, so light themes such as Halo apply to the
  desktop's own chrome (#717).

### Tests

- `tests/host/baremetal_test.sh` across the three arm64 machines under
  QEMU, and `tests/host/baremetal_riscv64_test.sh` for RISC-V, run by CI
  on every change; hosted riscv64 is built and tested under
  `qemu-riscv64`.
- `tests/acceptance/`: batteries run from a Linux tester against a
  board -- Ethernet after RFC 2544, Bluetooth after the SIG PTS cases,
  GPIO on a loopback jig, and the card's contents against the build --
  with the soak and bench tools beside them.
- `tests/intsem_test.b` pins the 32-bit int semantics under both
  engines; `tests/host/arm64_jit_typecode_leak_test.sh` pins the leak.
- `tests/jit_unload_test.b` reproduces the unmapped-return crash
  deterministically; `tests/jit_fault_test.b` covers faults raised from
  compiled code; `tests/host/dossrv_lfn_test.sh` covers long names.

### Documentation

- `docs/BAREMETAL-PORTING-LESSONS.md`, written for any port; the
  bare-metal manual and board contract; `os/bcm2837/README.md`, the
  port's working notes; man pages for the native devices, `osinit(8)`
  and `mkcard(10.1)`. 9front is credited for the drivers taken from it.
- The JIT benchmarks on bare metal, at 1400 MHz and against the hosted
  emulator on the same board (#690, #696, #712); what the firmware
  leaves for the OS in the porting lessons (#697); `os/riscv64/README.md`
  and `os/bcm2711/README.md` for the boards not yet run.

### Known limitations

- At gigabit, a 60 KB IP burst overruns the LAN7515's 12 KB FIFO unless
  the switch honours pause; it passes at 100 Mb/s (#633).
- Empty hub ports report phantom attaches under load (#644): noisy on
  the console, harmless.
- The Pi 4 and RISC-V ports are QEMU-only.

### The soak

The 48-hour soak ran on the 2026-09-23 Pi 3 kernel (09-21 13:13 to
09-23 13:59: 0 panics, 0 reboots, 290/290 inbound pushes at a mean
144.7 Mbit/s, batteries passed twice, no memory growth unaccounted for).
The kernel in this release is not byte-identical to it: #691, #705,
#707, #714, #715, #716 and #718 all change it. Each ran on the board
or under QEMU as its PR records; the full 48 hours was not re-run on
this build.

### Release artifacts

The hosted archives, as before; there is no riscv64 archive yet. The
release job does not build a bare-metal kernel or card image; build them from the tag with
`tests/host/baremetal_test.sh` (see the bare-metal manual).

## [0.4.1] - 2026-09-17

Security patch release. Three containment fixes from the external
escape-room campaign (`infernode-os/infernode-escape-room`), found after 0.4.0
was cut, and a wallet change that operators need to know about.

### Security

- **Tool metadata sealed before `/tmp`** — `tools9p` restricted
  `/tmp/veltro/.ns` after the worker's `/tmp` had already been replaced, which
  recreated `/tmp/.veltro-ns` inside the model-visible view. A single `list`
  showed the shadow tree, and concurrent calls exposed live worker directory
  names. The 0.4.0 entry for #600 said the shadow tree was no longer visible;
  through `tools9p` it still was. Shadow-backed restriction now completes
  before the final `/tmp` replacement, and model-facing calls wait for the
  trusted startup manifest probe (#619, INFR-470).
- **Tool workers get a fresh environment group** — Inferno lets a process name
  its own `#e` device even under `NODEVS`, so a worker that inherited the
  launcher's environment could read it by spelling `/env` as `#e`,
  bypassing the narrowed view. Every tool worker now starts with `NEWENV` and
  carries only `VELTRO_SESSION` (#618, INFR-480).
- **9P directory stat entries bounded** — `statcheck` advanced by an untrusted
  string length without checking it against the bytes returned, so a malformed
  directory entry could read past its buffer and fault the emulator. Each
  entry is now validated against the remaining span before any field is
  decoded, with an ASan/UBSan guard-page regression (#617, INFR-479).

### Wallet

- **Agent payments are proposal-only** — trusted approval is mandatory for
  every `pay` and x402 authorization. **`requireapproval off` is now
  rejected**: it turned the same agent-visible files into immediate spending
  without changing the agent's namespace or its `nsaudit` report.
  `requireapproval on` is accepted as a no-op. `wallet` and `payfetch` are
  classified as `proposes_payment`, and the caller-asserted `walletbudget`
  audit metadata is removed; any future direct-spend authority fails closed
  without capability-bound enforcement evidence (#627, INFR-488).
- `nsaudit` models `/mnt/msg/draft` as an immutable proposal rather than a
  durable mutation, and the messaging profile grants a real `write` tool
  (#625).

### Build & CI

- Runtime namespace residue under the repo root and host-tool Python bytecode
  are ignored (#611).
- OSSF Scorecard reads branch protection with the default token instead of an
  expired PAT (#607).
- GitHub Sponsors enabled (#628). Dependency bumps (#590, #612, #613).

## [0.4.0] - 2026-09-12

### Runtime tree & build

- **`dis/` is a build product and is no longer tracked** — compiled Dis
  bytecode is untracked, exactly like `emu/*/o.emu`. A fresh clone builds its
  runtime in about 20 seconds, and `hooks/install.sh` installs a `post-merge`
  rebuild. What the build must *produce* is tracked instead, as
  `tools/dis-manifest.txt`, gated by `tools/verify-dis-build.sh` in CI and in
  every release job. Tracking the bytecode had let the tree drift from the
  source that produced it in every way it could: `appl/cmd/git` had not
  compiled since 2026-07-02, `dis/acme.dis` shipped font paths the source
  abandoned five months earlier, 45 modules shipped that no mkfile ever
  compiled, and programs shipped whose sources had been deleted. Releases
  still ship a runnable tree — the packaging job builds it before staging
  (#559).
- **Go-on-Dis removed** — the experimental Go-to-Dis work is gone from the
  tree (#566).
- `mk emuinstall` repaired on a clean clone (#507). Android builds target
  API 36 (Android 16) for Play compliance (#581).

### Agent provenance & audit (INFR-355)

- **Trajectory sealing** — the Veltro agent stack seals its full trajectory
  (prompts, LLM output, tool calls, capability grants, namespace-restriction
  manifests) into the tamper-evident audit chain; bulky payloads are
  content-addressed into a `ventisrv(8)` store with the SHA-256 pin sealed
  under the chain (`auditprov(2)`) (#508).

### Persistence

- **Whole-`/usr` durability** — all of `/usr` is bound from the durable
  overlay; system updates never touch user state. `newuser(8)` creates
  accounts from the skeleton; `snapd(8)` takes daily deduplicated venti
  snapshots of `/usr` (one text line per snapshot: timestamp + `vac:` score,
  restorable with `vacfs(4)`). Settings gains Auditing and Snapshots panels
  (#511).

### Wallet

- **Out of experimental** — the Ethereum wallet is production-supported:
  budgets hard-capped on every path, trusted approval on payments, agents
  see proposal files only (#512, with the raw signing surface removed in
  #488 and proposal validation in #487).

### LLM backends

- **codex-gate** — OpenAI models served through the ChatGPT Codex CLI on the
  host's own subscription login, as a sibling of claude-gate: an
  OpenAI-compatible localhost gateway on `:11436`, `backend=codex` in ndb, a
  "Codex CLI" choice in the Settings LLM panel, and `llmctl set|health codex`.
  The tool bridge is prompt-level (`codex exec --output-schema`) rather than
  MCP, so the gate is stateless — see `docs/CODEX-GATE.md`.
- **First-run wizard offers the CLI gateways** — "Claude CLI" and "Codex CLI"
  join "Remote API" / "Local model" / "Remote 9P" in the first-run LLM setup
  dialogue, so a user who already pays for one of those subscriptions isn't
  steered to paste an API key. Desktop dialogue buttons now wrap onto further
  rows instead of silently dropping the ones that don't fit on one line.
- **codex-gate hardening** — the OAuth gateway uses backend defaults instead
  of forwarding llmsrv's Anthropic default model to an OpenAI-compatible
  backend, and requires a verified ChatGPT login before reporting readiness
  (#529). The gateway is pinned and the CLI's native shell disabled, so Codex
  requests Veltro tools rather than inspecting the gateway filesystem (#539).
  Quota control is returned to callers (#597), and transient model-capacity
  failures are classified as structured retryable errors instead of assistant
  content — the classifier deliberately narrow, so model prose cannot
  authenticate a retry (#603).

### GUI & video

- **Live video panes** — vid9p live-feed ring, Matrix video panes, colour
  fixes; trfs fd-handling fixes (#510).

### Security

Namespace hardening continued through a sustained internal red-team campaign.
This cycle the mounts and the pathname stack themselves were the focus, rather
than the control grammars above them.

- **Read-only mounts genuinely attenuate** — a new `MREADONLY` mount flag
  attenuates Veltro's code, library, metadata, and source views. The
  restriction survives rebinds and 9P exports, writable protocol filters stay
  distinct, and intentional nested writable mounts are retained. This closes a
  campaign path that overwrote `sh.dis`, and a remote-export laundering
  regression (#586, INFR-453).
- **Mount boundaries survive parent walks** — completing the Fourth Edition
  pathname-stack port in the emulator: final-element mount crossings performed
  by `open` are recorded, the child slot is discarded before undoing a parent
  mount, and reference ownership is preserved across `Cname` copy-on-write.
  The private `.veltro-ns` shadow tree is no longer visible (#600, INFR-470).
- **A namespace traversal escape closed**, with delegation evidence hardened
  in the same pass (#537).
- **Runtime profiles are materialized and audited** rather than assembled ad
  hoc, and campaign-only runtime hooks and duplicate profiles are gone from
  the product path (#591, #592, #596, #598 — INFR-456, INFR-466).
- **No hidden audit fallback during namespace construction** — by the time
  `restrictns` emits its audit record, `/mnt` has already been narrowed, so
  reaching for a hidden or stale 9P audit mount could block construction
  outright. The fallback is refused there rather than attempted (#593,
  INFR-459).
- **Copy-on-write overlays keyed by path** — a delegated agent holding a
  writable grant could create a file that `list` and `read` saw but `exec`
  reported absent at the same absolute path, because the overlay directory was
  keyed by a path's position in the invocation list rather than by the path.
  The capability is now composable across tools (#571, INFR-435).
- **Campaign metadata fails closed** — `NODEVS` and wallet-budget
  declarations are validated semantically, and their validity is reported in
  `nsaudit` machine output (#580 — INFR-440, INFR-441, INFR-442).
- **A stalled tool call can no longer silence the audit trail** — a hung 9P
  tool request blocked lucibridge's activity loop indefinitely, so `toolres`
  and `agentdone` records were never written. The existing 60-second Veltro
  tool bound now applies there too (#599).
- **Truthful grantable tool catalogue** — delegation planning context is
  derived from the live `tools9p` budget instead of a hand-maintained persona
  list, preserving namespace attenuation (#544, INFR-393).
- Further fixes: delegated message draft writes preserved (#546), concurrent
  task provisioning made atomic (#547), delayed tasks kept observable (#542,
  INFR-362).
- Earlier in the cycle, ~40 further namespace-hardening fixes: control-grammar
  tightening (wallet #499, wiki #500, msg #496), path-delimiter rejection
  across write/editor/wiki (#493–#495), luciuisrv control metadata (#502),
  matrix composition grants (#501), provisioning validation (#503),
  failed-tool-mutation reporting (#505).

### Emulator, JIT & shell reliability

- **JIT `typecom` slab exhaustion** — scratch overflow and incorrect rollover
  of an exhausted slab, both under sustained load (#561, #570, INFR-421).
- **Linux memory faults report PC and symbol** rather than an address alone
  (#558), and `devfs` directory reads can no longer fault on an
  uninitialised `Fsinfo` (#557).
- **The pthread process leader stays alive**, so a Linux emulator no longer
  strands children when the leader exits (#582), plus further Linux
  concurrency fixes (#602, INFR-601).
- `sh` raises instead of panicking when the wait file is unavailable (#572,
  INFR-436). `llmsrv` cancels flushed async replies safely (#541).

### Testing & compliance

- **The escape-room harness moved out of the product tree**, with a CI
  ring-fence that fails the release stage if harness material reappears in it
  (#585).
- Source-aware `nsaudit` campaign (#555) and dynamic red-team qualification
  (#562). Grind fixes: evidence preserved on scorer errors (#569),
  qualification effects required (#567), scenario canary post-state preserved
  (#545), fail-closed on live child tasks (#543), dynamic child activities
  reconciled (#548), campaigns resume after quota pauses (#576, INFR-437).
- Compliance evidence scorecard re-rolled and stale AU residuals corrected
  (#532). Rooted capability delegation proposed for review (#535).

## [0.3.6] - 2026-07-20

- **claude-gate** — Anthropic models served through the Claude Code CLI as an
  LLM backend, with Settings LLM-panel fixes (#440); factotum API-key
  provisioning generalized beyond one vendor (#321 lineage) and tools read
  secrets from factotum — no plaintext key files (#322).
- **Video over 9P end to end** — Matrix player, Tk design-system engine work
  (#453); click-target alignment and Tk-button picker (#454).
- **Agent-facing module discovery** — man pages, `whatis` index, and a Veltro
  tool for Matrix module discovery (#408).
- **Branding** — themed login screen (#448) and About box / desktop title
  from data files (#450).
- **Shell fix** — initialise before `waitfd()` in `Context.new`; rebuild
  stale `sh.m` consumers (#455).
- Continued namespace hardening (#410–#443): fixed-service namespaces
  reserved (#418, #419), app-IPC grant scoping (#417–#424), manifest hiding
  (#414), MCP tool-name/schema validation (#397, #471 lineage), exec
  write-containment (#374).

## [0.3.5] - 2026-07-13

The bulk of a sustained agent-security campaign (~60 PRs), plus the audit
hardening pass.

- **Audit-log hardening** — strict verification (`-k` makes signatures
  mandatory), off-host anchoring (`-a`), self-driving signed checkpoint
  cadence, fail-closed emitters (#389); checkpoint signing moved into
  factotum (ML-DSA-87) so `auditfs` never holds the key (INFR-356).
- **nsaudit as a CI gate** — namespace-configuration audit runs on every PR
  against committed fixtures (#391), with the internal configuration audit
  tool underneath (#310).
- **mcpdeny** — drop named MCP tools from a child's grant (INFR-258, #369).
- **Failed-attempt lockout** — AC-7/FIA_AFL.1 in `secstored`; compliance
  docs reorganized into an evidence register (#368, #373).
- **Tk reintegration** — libtk built for macOS release jobs (#409).
- Dozens of grant-model fixes: raw service grants denied (factotum #462,
  auditfs #465, gpu #467, video #461, calendar #463, key registry #469,
  llmctl #464), delegated control paths blocked (#392–#394), egress
  flagging for MCP mounts and LLM paths (#395, #396), namespace grant
  delimiter/descendant rejection (#386, #406, #426), mail-send grants
  flagged (#383).

## [0.3.4] - 2026-07-02

- **Send is a capability** — `/mnt/msg` send split from read; authorise-to-send
  with one-shot approval for replies (INFR-367, #337, #343).
- **Per-invocation attenuation** — each tool call runs in a namespace
  containing only the invoked tool (#338).
- **Workspace isolation** — activity workspaces and child capabilities
  isolated (#342); delegated task metadata isolated (#340).
- **Charon SSRF** — private-network fetches blocked (#344).

## [0.3.3] - 2026-06-30

- **Headless macOS arm64 release artifact** (#335).
- Confused-deputy fixes: editor paths (#333), browser local files (#334);
  agent write-capability enforcement (#331).

## [0.3.2] - 2026-06-30

- **`/mnt` by capability only** — mounts are granted, never inherited by
  existence (INFR-366, #329).
- **Delegation reliability** — lost-task race in parallel delegation fixed
  (INFR-362, #320); task agents auto-start reliably, low agentic
  temperature (#317).
- **Fail closed** — namespace setup errors abort the agent (#319); auth
  transport algorithm policy enforced (#318), noncanonical frames rejected
  (#315), client identity preserved after `listen` (#313).

## [0.3.1] - 2026-06-29

Security-hardening point release, with cross-platform YubiKey/FIDO2 second-factor
authentication.

### Second-factor auth (`/dev/2fa`)

- **Cross-platform FIDO2** — the `#F` (`/dev/2fa`) device, previously macOS-only,
  is now built into the Linux and Windows emulators, and into headless Linux
  builds (#305, #307).
- **YubiKey 2FA fixes** — namespace ACL enforcement, Dis-parser hardening,
  Windows Hello (winhello) integration, and clearer error surfacing (#309).
- **Enrollment persistence** — `~/.infernode` overlays are persisted so a
  YubiKey 2FA enrollment survives an emulator restart (#311).

### Cryptography & Dis VM hardening

- **SHA-384 auth-cert hashing** for ML-DSA-87 signing (CNSA 2.0) (#304).
- **Dis parser hardening** — guard the Dis bytecode parser against malformed
  modules and pointer corruption (#306), with additional module-parse
  hardening in `libinterp` (#302).

### Security

- **Pre-authentication bounds** — pre-auth handshake work is time- and
  concurrency-bounded (#312).
- **Transport** — remove weak transport algorithms and close devfs races (#301).
- **Memory safety** — resolve CodeQL memory-safety findings (#300).
- **Internal configuration audit** added (#310).

### Release engineering

- Fix FIDO2 packaging in the release pipeline: the Windows `vcpkg` port is
  `libfido2` (not `fido2`) and that install step is now genuinely best-effort;
  the macOS GUI/headless emulators link `libfido2` and `opus` reliably even when
  `pkg-config` cannot resolve Homebrew's keg-only `openssl@3`.

## [0.3.0] - 2026-06-28

### Breaking & behavior changes

- **Namespace move `/n/*` → `/mnt/*`** — `mail9p` (`/mnt/mail`), `calendar9p`
  (`/mnt/cal`), and `msg9p` (`/mnt/msg`). Scripts, shell profiles, or configs
  referencing the old `/n/` paths must be updated.
- **CNSA 2.0 strict mode** (opt-in via `/env/cnsamode`, off by default) —
  ML-KEM-768 → ML-KEM-1024 and ed25519 → ML-DSA-87 for the native STS
  handshake, TLS, and the auth-domain CA. No silent downgrade; enabling it
  requires upgrading all nodes in a fleet together.
- **2FA accounts** (opt-in) — a YubiKey-enrolled account cannot be unlocked by
  a password alone; it requires the hardware key (touch, and a FIDO PIN at
  AAL3) or the recovery passphrase. Legacy password-only accounts are unchanged.

### Highlights

- **YubiKey-gated secstore login** with UV/AAL3, backup key, and a Settings GUI
  Security panel.
- **Hybrid TLS** — `SecP384r1MLKEM1024` CNSA hybrid key exchange, with P-384
  (secp384r1) ECDH primitives and Keyring builtins.
- **Tamper-evident audit log** (`/mnt/audit`) with factotum-held ML-DSA-87
  signing and a compliance evidence program.
- **Pre-auth hardening** — time-bounded handshakes with a per-listener
  concurrent-auth cap; weak/malformed v2 DH shares are rejected
  (INFR-321/322/323).
- **Veltro agent** — research agent and launchable personas, deterministic
  intent classifier for persona routing, agent-loop read-cache, and per-session
  model override (`veltro -m <model>`).
- **SBOM** — CI-verifiable SPDX SBOM generated and shipped with releases.

## [0.2] - 2026-05-11

### Windows AMD64 release

First official Windows AMD64 distribution. Feature parity with macOS and Linux
modulo the items called out under "Known limitations" below.

- **Windows JIT compiler** — AMD64 JIT with 5.7× speedup (181/181 correctness tests pass).
- **Host filesystem mounting** — Drive letters mounted at `/n/C`, `/n/D`, etc. via the `#U` device; `~/.infernode` overlay for persistent user state.
- **Secstore + factotum** — Encrypted key persistence with PAK authentication; Lucifer login screen unlocks it interactively.
- **SDL3 GUI** — Lucia, Xenith, and the window manager render with D3D acceleration.
- **Bundled-app UX** — `InferNode.exe` is a Windows-subsystem launcher that double-clicks to a full-screen Lucifer session (uses screen-resolution sizing on launch).
- **CSPRNG** — Secure random via `BCryptGenRandom` (replaces the POSIX `/dev/urandom` path).
- **Build system** — Complete MSVC build via `build-windows-amd64.ps1` (libs + headless emu), `build-windows-sdl3.ps1` (GUI emu), and `emu/Nt/build-launcher.ps1`. Crypto libraries (secp256k1, keccak256, securezero) fully linked.
- **Cross-platform unification** — Windows launcher invokes the same `/lib/lucifer/boot.sh` as macOS and Linux; legacy `dis/lucifer-start.sh` and `Lucia.bat` removed.
- **Dev bundle** — `build-dev-bundle.ps1` mirrors the macOS `build-dev-bundle.sh` for local packaging tests without going through CI.
- **CI/CD** — Windows AMD64 build and test job runs alongside macOS/Linux on every PR; release job produces a signed bundle on tag push.

### Known limitations on Windows

- **JIT GUI race** (latent) — Some long-running JIT GUI sessions can crash with `STATUS_BAD_FUNCTION_TABLE` because the JIT does not yet register Windows SEH unwind data for its executable pages. Mitigation in place; proper fix tracked in INFR-46.
- **MSIX packaging** — Deferred to a follow-up release (INFR-48). For 0.2 the artefact is a portable zip.
- **Stdio-redirected boot** — `o.emu.exe` started with `Start-Process -RedirectStandardOutput` crashes in the secstore PAK dial step. Interactive double-click is unaffected. Tracked in INFR-50; matters mainly for headless smoke tests.

### Platforms

| Platform | Architecture | GUI | JIT |
|----------|-------------|-----|-----|
| macOS | ARM64 (Apple Silicon) | SDL3 | 9.6x |
| Linux | AMD64 | Headless / SDL3 | 14.2x |
| Linux | ARM64 | Headless / SDL3 | 8.3x |
| Windows | AMD64 | SDL3 | 5.7x |

## [0.1] - 2026-04-09

First public release of InferNode, a 64-bit fork of Inferno OS for AI agents.

### Highlights

- **Veltro AI Agent** — built-in conversational agent with tool use, delegation,
  and namespace-isolated sub-agents
- **Capability-based namespace isolation** — each agent sees only explicitly
  granted resources; formally verified with TLA+, SPIN, and CBMC
- **Post-quantum cryptography** — preliminary ML-KEM (FIPS 203) and ML-DSA
  (FIPS 204) implementations
- **ARM64 JIT compiler** — native JIT for Apple Silicon and Linux ARM64
  (e.g. NVIDIA Jetson)
- **Xenith text environment** — Acme-inspired editor with markdown, PDF,
  image, and Mermaid rendering
- **Lucifer GUI** — presentation zone with app hosting, tab management, and
  context/namespace browser
- **Secstore persistence** — encrypted key storage with PAK authentication
- **Ollama/OpenAI-compatible backend** — local LLM support alongside
  Anthropic API
- **9P everywhere** — LLM, speech, tools, wallet, and UI all exposed as
  9P filesystems

### Platforms

| Platform | Architecture | GUI |
|----------|-------------|-----|
| macOS | ARM64 (Apple Silicon) | SDL3 |
| Linux | AMD64 | Headless (SDL3 optional via build script) |
| Linux | ARM64 | Headless (SDL3 optional via build script) |

### Known Issues

- Secstore key loading can intermittently fail on cold boot due to trfs
  cache timing; a warmup workaround is in place
- Models that do not support tool use (e.g. llama2) return empty responses;
  use a tool-capable model (llama3.2, qwen2.5, mistral, etc.)
- The presentation rendering architecture is tightly coupled to the lucipres
  window; a refactor to a separate wmclient app is planned (see
  docs/TODO-LUCIPRES-ARCHITECTURE.md)
