---
name: compose-first
description: Before writing any new program, service, tool, driver, daemon, module or kernel/emulator code in InferNode, or adding a dependency — find out whether existing name spaces, commands and modules already do the job, decide where any new code must run, and surface trade-offs to the user. Use whenever asked to build, add, make, implement or port something new, before any code is written.
---

# Compose before you write

The reasoning is in [docs/DESIGN-PRINCIPLES.md](../../../docs/DESIGN-PRINCIPLES.md):
"Compose before you write", "Where the code runs" and "Dependencies are a
decision". This is the procedure. Do it before opening an editor.

## 1. Look before you build

Agents miss compositions because they do not know the pieces exist. Look:

- `man/1` (commands), `man/4` (file servers), `man/2` and `module/`
  (modules), `appl/lib/`.
- "What the system already gives you" in DESIGN-PRINCIPLES.md: audit,
  provenance, durability under `/usr`, factotum/secstore, the wallet.
- `ns` in a running system: what is already mounted where.

Then state the job as a name space: what must be reachable, from where,
under what name.

## 2. Work down the ladder; stop at the first rung that does the job

1. **Name spaces.** `mount`, `bind`, `export`/`listen`, `import`, `cpu`,
   `rcmd`, `post`. A VPN is the far end's `/net` mounted and bound over
   `/net` (early in boot for the whole system; `bind '#I' /n/localnet`
   first, so the far end can be mounted again over `/net`, by address,
   if it goes away). Sound elsewhere is the far end's `/dev` bound in.
2. **Tools.** Pipelines, the shell's modules (`sh-std`, `sh-regex`,
   `sh-expr`), `sh-file2chan` for a script that serves a file, the host's
   programs through `os`. For a simple job the answer is the commands; no
   new software.
3. **Modules.** If code is needed, most of it is calls to existing
   modules (`bufio`, `styxservers`, `nametree`, `imgload`, `layers`,
   `nmea`, `jpeg`, `keyring`, ...).
4. **Build the composition, measure it** against the stated requirement
   (throughput, latency, clients, target machine). For each shortfall:
   first a better composition (more reads in flight, an encoder beside a
   feed), and only then the one missing mechanism, served as files so the
   rest stays composed.

New software needs a composition built or shown impossible, failing a
stated requirement a better composition cannot meet. "Cleaner as one
program" and "I didn't know it could" are not reasons.

The real exceptions are few: the host's own processes (in hosted
InferNode they do not use its `/net`), and a far end that does not speak
9P. Name the requirement the composition cannot meet; most claimed
exceptions are a bind made too late or in the wrong name space.

## 3. If something must be written, decide where it runs

Safest first:

1. **Limbo** — the default; security-relevant logic, anything that must
   run native and on phones, small open protocols. Measure under `-c1`
   before calling it slow.
2. **A host service over 9P**, local or remote — host hardware, large
   foreign libraries, vendor SDKs, heavy compute (llmsrv's backends,
   `tools/trtsrv`). The InferNode side is an adapter: a mount, the file
   contract, a man page. Treat it as an untrusted 9P server:
   authenticated mount, narrow grants, answers validated.
3. **A builtin module in C** — a measured hot loop that must run where
   there is no host. It runs with the kernel's authority; every argument
   hostile, edges tested.
4. **A kernel or emulator device** — last resort: hardware, or a platform
   API only the emulator's process can call. Drivers in Limbo first. An
   emulator device is kernel code; binding in a local host service beats
   building one in.

## 4. Dependencies: ask, never decide

Any new third-party library, crate or package, in the tree or in a host
service kept in the tree, is the maintainer's decision. Stop and ask
(an outside contributor opens an issue first) with: the alternatives
tried (composition, existing module, out-of-tree host service, rewrite),
whether it ships or is linked into emu or the kernel, how it is pinned
(exact version plus lock file or hash), and why it is worth the risk
(maintenance, use, history, reach, removal). A tested rewrite against
the original's answers is often the safer choice. Never port GPL code.

## 5. Surface the trade-offs

Decide what the rules settle (`/mnt` vs `/n`, text not JSON). Do not
decide tensions: whether a shortfall justifies new code, whether an
exception holds, host service vs builtin module (isolation vs
portability), any dependency. Put them to the user: the options, what
each costs, your recommendation.

## 6. Then, and only then

- Rungs 1–3: show the commands. No proposal needed.
- New software: a proposal issue (`.github/ISSUE_TEMPLATE/service_proposal.md`)
  starting with the composition tried and where it fell short, then the
  namespace sketch. For a 9P server, continue with the `ninep-server`
  skill; for emulator C, `emu-dev`.
