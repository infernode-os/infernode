# Fuzzing the native kernel

`tools/sysfuzz` grinds the hosted emulator's C with random system calls
(see CLAUDE.md). The native kernel (`os/`) has the same device and
name-space code and more besides: a Dis VM per core (`#X`, #944), its own
scheduler, locks and memory. `tools/nativefuzz` runs the same fuzzer
there, under QEMU, in every VM at once; the same commands typed at a
board's serial console run it on the hardware.

## What runs

`tests/sysfuzz.b` with `-d DIR`: the native kernel has no `#U`, and its
`#/` has neither `/nvfs` nor `/fd`, so the fuzzer's root is a directory
it makes under `DIR` (the kernel's memory file system, `/tmp`), exported
from a copy of its name space and mounted on `/`, with each device bound
on a directory there. Everything a worker does goes through `exportfs`,
`devmnt` and memfs as well as the device it is aimed at.

Each VM runs its own sysfuzz with its own seed. VM 0 runs it in the
background, so the shell still answers.

## Under QEMU

Build the kernel once (it carries `dis/` as built when it was made, so
rebuild it after a `mk install`):

```sh
export ROOT=$PWD PATH=$PWD/Linux/amd64/bin:$PATH
BAREMETAL_BUILD_ONLY=1 BAREMETAL_PLATFORMS=virt BAREMETAL_BUILD_DIR=$PWD/tmp/bm \
    ./tests/host/baremetal_test.sh
```

Then:

```sh
tools/nativefuzz -n 20 -k          # 20 seeds, keep going after a failure
tools/nativefuzz -n 1 -s 7 -v      # seed 7 again, with sysfuzz's epochs shown
tools/nativefuzz -m max,4,3,2048,2 # a fixed machine: cpu,smp,gic,memMB,icount
```

Each seed picks a machine: the core (cortex-a53, a57, a72, `max`), one to
four cores (so one to four VMs), GICv2 or v3, memory, and either
multi-threaded TCG or `-icount` with a shift (one host thread, the cores
interleaved in a fixed order: other timings, and fewer of them). Failures
are kept in `tmp/nativefuzz/fail/SEED/` (`console`, `machine`, `why`);
passes in `tmp/nativefuzz/pass/`.

A run fails on a panic or the kernel's own complaints (lock loop, double
sleep, a corrupt pool, an unhandled exception), on QEMU exiting, on a
sysfuzz whose check at the end fails (`wedged`), on not every sysfuzz
finishing (`hang`), on the shell not answering afterwards (`dead`), and on
Progs left in VMs 1-3 (`leaked`).

## On the board

Put the tree's `dis/` on the card (`tools/mkcard.py`, as
`tests/host/baremetal_test.sh` does, or copy it into the card's `dis/`),
boot, and at the serial console:

```
vm 1 /dis/tests/sysfuzz.dis -s 11 -t 600 -e 5 -p 6 -d /tmp
vm 2 /dis/tests/sysfuzz.dis -s 12 -t 600 -e 5 -p 6 -d /tmp
vm 3 /dis/tests/sysfuzz.dis -s 13 -t 600 -e 5 -p 6 -d /tmp
{/dis/tests/sysfuzz.dis -s 10 -t 600 -e 5 -p 6 -d /tmp; echo VM0END} &
```

Each prints `hb SECONDS OPS` every second and `sysfuzz: done` at the end
(`sysfuzz: wedged: ...` if the kernel stopped answering). Then `vm` should
show no Progs left in VMs 1-3.

## When it stops

The console's debug keys work when nothing else does. Type Ctrl-T twice,
then:

| key | shows |
|-----|-------|
| `p` | every kernel process: state, what it sleeps on, the last qlock it took |
| `k` | the kernel stack of each process not running (frame-pointer walk from its saved label) |
| `d` | every VM's Progs: pid, VM, state, group, a kill pending, module |
| `m` | the memory pools |

`k` prints addresses; turn them into functions with the kernel's ELF
(`BAREMETAL_BUILD_DIR` keeps `virt-kernel.elf`, `bcm2837-kernel.elf`, ...):

```sh
llvm-addr2line -f -e tmp/bm/virt-kernel.elf 0x400b9368 ...
```

A panic's own `trace:` line takes the same treatment. If the shell still
answers, `cat /prog/N/stack` gives a Prog's Dis stack; map its pcs with the
module's `.sbl` (compile with `limbo -g`).

## What it has found

- Styx and Ninep refused any Twstat whose stat is 256 bytes or more (the
  count's high byte shifted as a byte), and counted runes past U+FFFF as
  three bytes: a long or emoji name killed the reader of any styxlib
  server, memfs on `/tmp` among them, and every client hung.
- memfs: offsets past 2^31 indexed its block table negative; a read of a
  hole (blocks never written) sliced nil; a Readerror left it waiting for
  ever.
- devprog: listings made in the reader's buffer added snprint's -1 (no
  room) to their count and wrote before the buffer (`fd`, `ns`, `stack`,
  heap reads): a kernel panic natively, heap corruption in emu. `stack`
  of a Prog with no module walked H. Natively, `fd` read another core's
  fd table unlocked, and `ns` kept a Mount past its lock.
- `cmount`/`cunmount` freed mounts, a 9P clunk, under the Mhead and name
  space locks, while devprog read those locks holding the VM: a VM frozen
  when the clunk's server was in it.
- `/env` opened ORCLOSE and closed by Limbo's collector faulted (no
  environment in the collector's kproc) and emu exited.
- emu's `/dev/scancode` open unlocked the wrong lock on its error path.
- A union directory's read holds its mount point's lock across a 9P read;
  a mount on that point waits for it holding the name space's lock; and
  devprog's `fd` and `ns` took the name space's lock holding the VM. A
  server not answering stopped the VM for good. devprog now takes only
  references under the VM (the name space, a copy of the fd table) and
  locks with it let go.
- Native `delprog` closed a Prog's fd table and name space while it was
  still listed, and devprog read them as they were freed (emu had been
  fixed, INFR-373).
- Native kills were lost when they came while the Prog's kproc ran the
  kernel between sleeps (emu kept them as `intpend`); the Prog then slept
  on, unkillable, in whatever it called next.
- memfs: an offset of 2^63-1 passed its range check (the sum overflowed).

## Open

- `delprog` closes a Prog's name space before its fd table: a Prog
  holding the far end of a pipe it mounted waits in its own exit for a
  clunk that only its fd table's close could answer. Closing the fds
  first fixes that and breaks `auditprov_test` (ventisrv), so the order
  stands until that dependence is understood.
- A kill runs the dead Prog's closes in the killer's thread (`killprog`
  → `delprog`): a close on a server that never answers hangs the
  killer.
- An interrupted 9P call waits for its flush's reply, uninterruptibly.
  Progs killed while in calls to servers that are themselves stuck the
  same way (an epoch of sysfuzz's workers, serving each other through
  pipes whose ends their fd tables hold) never finish dying.
  nativefuzz notes them on the pass line (`-L` fails on them).
- `lock loop ... held by pc 0x0` on a Chan's reference in `fdtochan`,
  once, under `-icount 5` (seed 100, cortex-a57, three cores, GICv3).
  pc 0 is also what a holder preempted inside `unlock` leaves, so this
  may be starvation under one-thread TCG rather than a freed Chan.
