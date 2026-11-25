# Threat model: remote sessions (cpu, rcpu, rimport)

What this machine lends another when a program runs there on its behalf,
who might abuse it, and what each restriction is for. A restriction not
traced to a threat here should not exist; a threat here with no control
is a gap, listed as one.

Status: **draft for decision** (2026-11-25). Each claim about present
behaviour is marked **tested** (with the test) or **not tested**.

## 1. Scope

| Command | This machine is | The other machine is | What crosses |
|-|-|-|-|
| `cpu(1)` | the *viewer*: it dials and lends its devices | an InferNode *node* (`auxi/rstyxd`) | this machine's `/dev`, or the tree given with `-e` |
| `rcpu(1)` | the *client* | a 9front cpu server | rcpu's own tree at `/mnt/term` |
| `rimport(1)` | the client | a 9front file server | nothing of this machine's; it only mounts |

Out of scope: the authentication protocols themselves (keyring certificates
and devssl for `cpu`, [AUTHENTICATION.md](AUTHENTICATION.md); dp9ik and its
TLS for `rcpu`, [9FRONT.md](9FRONT.md)); what a node protects of itself from
a caller ([REMOTE-DESKTOP.md](REMOTE-DESKTOP.md) §6, `cpu_boundary_test`);
programs on this machine (trusted, as in Plan 9; agents are confined by
their own name spaces, a separate model).

## 2. Assets on this machine

| | Asset | Why it matters |
|-|-|-|
| A1 | What other windows show | documents, mail, an agent's output, secrets on screen |
| A2 | Input meant for other programs | keystrokes, passwords among them; the pointer |
| A3 | The integrity of what the user sees and clicks | a forged dialog over a real window gets a password or a click |
| A4 | Credentials | factotum's keys, keyring certificates, secstore, the wallet |
| A5 | Files | home, the host's files through `/n/local` |
| A6 | Control of this machine | `/dev/sysctl` (halt), the host process's own stdin/stdout/stderr, devices (audio, camera), `kprint`, memory statistics |
| A7 | The snarf buffer | whatever was last copied: often a password |
| A8 | Availability | the screen, CPU and memory |

## 3. Adversaries

| | Adversary | Notes |
|-|-|-|
| E1 | On the network between the two | Handled by authentication and encryption, not here. |
| E2 | **The other machine, and whoever controls it**: its administrator, malware on it, someone with its card (a Pi in a cupboard) | The case this document is about. |
| E3 | **A program the user runs there that is hostile or compromised** (an untrusted binary, a program fed hostile input, an agent's tool) | Within a session, the same reach as E2. |
| E4 | Programs on this machine | Trusted; out of scope. |

**The premise.** Plan 9 and 9front trust the cpu server as much as the
terminal: it is your own account, usually your own machine, and their `cpu`
and `rcpu` give it the terminal's whole name space (files, factotum, the
window's devices, `/dev/screen`, rio's `wsys`). InferNode's premise is
**secure by default**: the other machine is trusted to run what it is asked
to, and is lent what that needs and no more. A node is often a smaller,
less tended, more exposed machine than the one with the screen, and its
compromise should not become this machine's. Anything broader is the
user's explicit choice (an `-e` tree, a flag), never a default.

## 4. Threats and controls

| | Threat (by E2/E3) | Assets | `cpu` today (default) | `rcpu` (#1278) |
|-|-|-|-|-|
| T1 | Read what other windows show | A1 | **Open.** `/dev/screen` copied whole; `/dev/draw` lists the viewer's clients (**tested**, two emulators, 2026-11-25) | Closed: draw scope (no `screen`, own image 0, own names) (**tested**, `drawscope_test`, `dp9ik_live_test`) |
| T2 | Draw over other windows (forge a dialog) | A3 | **Open**: the unscoped draw device and its names (not tested directly; same device as T1) | Closed: draw scope (**tested**) |
| T3 | Read keystrokes meant for other programs | A2 | **Open**: a node's read of `/dev/keyboard` got keys the viewer's user typed, competing with the window manager (**tested**) | Closed: only the session window's keys are served (**tested**, live test) |
| T4 | Inject input | A2, A3 | **Open**: `/dev/kbdin` write accepted (**tested**; what the keys reach not tested) | Closed: not served |
| T5 | Use credentials | A4 | Closed unless `-e` names them (`cpu_boundary_test`) | Closed: not served |
| T6 | Read or write files | A5 | Closed unless `-e` (`cpu_boundary_test`) | Closed except this machine's fonts, read-only (**tested**, write and remove refused) |
| T7 | Control this machine | A6 | **Open**: `halt` written to `/dev/sysctl` stopped the viewer (**tested**); writes to `/dev/hoststdout` reach the viewer's host terminal, so escape sequences too (**tested**) | Closed: not served |
| T8 | Read the snarf buffer | A7 | **Open**: read (**tested**) | **Open by design**: `dev/snarf` is served so copy and paste work, as rio serves it to 9front's rcpu |
| T9 | Exhaust the screen, CPU or memory | A8 | Not controlled | Not controlled beyond the scope's 4096 limit and one window at a time |
| T10 | Exploit a bug in what parses its messages (the draw device; on the native kernel, in the kernel) | all | Open to the extent of the bugs | Same. The warp's own were found and fixed under ASan/UBSan (#1282); `drawwarp_fuzz_test` in CI |

## 5. Not protected, by design

- What the user sends on purpose: what they type into the session's own
  window, the files they pass with `-e`, what they paste.
- The correctness of what the other machine computes or shows in its own
  window.
- Traffic analysis: who talks to whom, when, how much.
- E4: programs on this machine.

## 6. Decisions this asks for

1. **`cpu`'s default `/dev`.** T1-T4, T7 and T8 are open in a default
   session, which `REMOTE-DESKTOP.md` describes as delegating "devices, not
   credentials". Proposed: lend a node only the devices a session uses
   (the console; the draw device, scoped unless the viewer is a dedicated
   screen with nothing else on it; the pointer and keyboard only then), and
   never `sysctl`, `kbdin`, `host*`, `kprint`, `memory` or the snarf buffer
   unless the user grants them. The documented uses (whole desktop, single
   windows with `-e`) keep working.
2. **`rcpu` and the 9front way.** 9front's `rcpu` lends the whole name
   space. Ours lends its own tree (§4). Whether 9front's breadth should be
   available as an explicit opt-in is open.
3. **T8 for `rcpu`.** Keep `dev/snarf` (copy and paste work, as on 9front),
   or make it opt-in.

## 7. Compatibility rule

No change made for another system's sake may widen what InferNode exposes
when that system is not in use. Of the 9front work: `rcpu`, `rimport`,
`tlspsk(2)`, `rconnect(2)` and factotum's `dp9ik` do nothing unless run or
given a `dp9ik` key; the draw device's `w` message and its scopes are
reachable by every program that draws, so each is tested as such
(`drawwarp_test`, `drawwarp_fuzz_test`, `drawscope_test`).
