---
name: emu-dev
description: Write C code for the emulator (emu) correctly — the kproc kill path and blocking rules, CONF/mkdevlist device wiring, the incumbent-driver rule, and driver/policy layering. Use when adding or modifying emu devices, host drivers, or anything under emu/<Platform>/ or emu/port/.
---

# Writing emulator C code

The `limbo-dev` skill covers *building* this layer (platform scripts,
C-library rebuild order); this one covers writing it. The porting
history is in `docs/LESSONS-LEARNED.md`; read the incumbent code before
any of it.

## Blocking: the kill path only interrupts syscalls

Inferno kills a hosted proc via `oshostintr()` — on macOS,
`pthread_kill(SIGUSR1)` (`emu/MacOSX/os.c:413`); the signal handler
makes blocking *syscalls* return `EINTR`. It does **nothing** to a
`pthread_cond_wait`, a mutex wait, or any other in-process blocking: the
wait resumes as if nothing happened. A driver that parks in a condvar
wait is unkillable from inside Inferno.

Rules, each learned from a real deadlock:

- **Host blocking goes inside `osenter()`/`osleave()`** so the proc is
  in the right state to be interrupted and the kill is delivered as
  `EINTR`. `emu/FreeBSD/audio.c` is the exemplar — every blocking read
  and write is wrapped.
- **Prefer the emu `Rendez`** (`emu/port/dat.h`) for waits the Inferno
  side must be able to break; it participates in the proc model.
- **Never hold a `QLock` across a blocking wait.** The waiter blocks
  with the lock held, the closer blocks on the lock, and the device is
  wedged until the emulator dies. Take the lock, update state, release,
  *then* wait.
- Design for the hostile posture first: the device that never delivers
  (mic permission denied, disconnected hardware) is the case your
  blocking model must survive.

## A driver not named in the CONF is dead code

Devices are wired by the platform CONF file (e.g. `emu/MacOSX/emu`):
each line names the device and its source files (`audio audio-sdl3`),
and `mkdevlist` generates the device table, `$DEVS`, and `$LIBS` from
it at build time. Consequences:

- Adding a `.c` file without a CONF entry ships dead code — and if its
  link flags or tests land anyway, the tree carries live assertions
  about a driver that never runs. **Wire the CONF in the same PR or
  don't ship the driver**; its SYSLIBS additions and driver-specific
  test assertions go with it, both ways.
- One platform, one driver per device. If you must replace an
  incumbent, flip the CONF in the same PR and delete or explicitly
  fence the loser — the tree does not carry two rival drivers for one
  device.

## The incumbent rule

Before writing a rival to an existing driver, read the incumbent —
especially its header comments — for the regressions it already fixed.
Those fixes are behavioral contracts (drain-on-close semantics, ctl
verbs callers already write, buffer-size negotiation), and a rewrite
that silently re-loses them is a regression factory. You own not
re-losing them: name each inherited fix in your PR description and say
where your version preserves it.

## Drivers deliver events; policy lives in the window system

No keyboard chords, gesture recognition, or UI bindings in a device
driver or the portable SDL3 layer — a chord swallowed at the driver
level is swallowed for every platform, every layout, and every hosted
app (modifier masks like `SDL_KMOD_ALT` include right-Alt, which is
AltGr on European layouts). Deliver the raw events; implement bindings
in the window manager, where focus, layout, and app context exist.
Matching smell row in `docs/DESIGN-PRINCIPLES.md`.

## Hygiene

- C here is Plan 9/Inferno style: tabs, K&R, match the surrounding
  file — not a generic modern house style.
- Error paths release what they acquired: a partial device-start that
  leaks its queues or locks turns the *next* open into the deadlock.
- After changing `libinterp/`, `libsec/`, or keyring C, rebuild those
  libraries before relinking emu (`limbo-dev` skill has the order) —
  a stale archive looks exactly like a VM bug.
