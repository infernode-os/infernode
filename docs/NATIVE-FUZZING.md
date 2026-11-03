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

## The chaos build

Faults a kernel meets seldom, made often. Build the kernel with
`EXTRACFLAGS=-DCHAOS` (os/port/chaos.c) and it has `/dev/chaos`:

```
echo 'malloc 3000' > /dev/chaos   one malloc, mallocz or realloc in 3000 refused
echo 'sleep 300' > /dev/chaos     a Prog's system call's sleep interrupted, as a kill does
echo 'lock 1000' > /dev/chaos     a spin lock's holder delayed a few microseconds
echo 'yield 1000' > /dev/chaos    a proc releasing a spin lock preempted
echo 'vms 0xe' > /dev/chaos       only in Dis VMs 1-3 (bit 31: the kernel's own procs)
echo off > /dev/chaos
cat /dev/chaos                    each site's rate and how often it fired
```

`tools/nativefuzz -C malloc=3000,sleep=300,lock=1000,yield=1000 -K
tmp/bmC/virt-kernel.img` turns them on in VMs 1-3 and the kernel's procs
while sysfuzz runs, VM 0 (the console's shell) spared, and off before the
shell is checked. A chaos run fails only on a crash, QEMU exiting, no
boot, or a shell that does not answer once chaos is off: Progs dying of
what is injected, sysfuzz among them, is expected.

A refused allocation is not far-fetched: the hosted emulator's pools are
anyone's to size (`-pmain=`), and set too small they are run out of for
real. `tools/sysfuzz -P="-pmain=2m"` does that to the emulator.

## When it stops

The console's debug keys work when nothing else does. Type Ctrl-T twice,
then:

| key | shows |
|-----|-------|
| `p` | every kernel process: state, what it sleeps on, the last qlock it took |
| `k` | the kernel stack of each process not running (frame-pointer walk from its saved label) |
| `d` | every VM's Progs: pid, VM, state, group, a kill pending, module |
| `m` | the memory pools |
| `a` | the timed sleepers: the alarm list's lock, each sleeper and when it is due, each core's ticks |

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

- **#640's lock loop**, `lock loop ... held by pc 0x0` on a Chan's
  reference in `fdtochan`: `lock()` raised the holder to `PriLock` only
  after its test-and-set won. A proc preempted in between held the lock
  at its own priority, kept to its core (`samecore`); the spinner, at
  `PriLock` because it held the fd table's lock, yielded only to itself,
  and after a hundred million spins the machine panicked. pc 0 and the
  Proc named were the previous holder's, left by its `unlock`. The raise
  now comes before the test-and-set (`canlock` too); `lockloop` says who
  took the lock last, what it is doing, and its stack. Reproduced on two
  of eight seeds of one `-icount 2` machine before, none of eight after.
- **A kill hung the killer**: `killprog` destroys a Prog blocked on a
  channel there and then, in the killer's thread, and a close among its
  closes on a server that never answers (a 9P clunk) did not return. The
  killer marks itself (`up->killing`) while it destroys, and the mount
  driver sends that clunk without waiting for it. Kill stays synchronous:
  ventisrv, for one, kills its helpers and goes on as if they were gone.
- **A killed Prog stuck in a 9P call**: interrupted, it sent a flush and
  waited for the flush's answer for good. A killed Prog still sends the
  flush, and a killed Prog's clunk or remove is still sent, but each is
  waited for at most a second (a watchdog kproc interrupts it, `Mwatch`
  in devmnt): a server that answers in time is told everything as before
  (a killed listener's announce is still taken down), and one that does
  not leaves the call orphaned, on the mount's queue holding its tag, so
  the tag is not reused while the server may still answer, freed by
  whoever reads that answer. Progs left behind after a run fell from
  10-40 a VM to 1-12.
- **Exiting Progs used up the kernel's processes**: a Prog exiting of
  itself, not killed, waited in its exit for each clunk without end. On
  servers that never answer, such Progs held their kprocs until there
  were none, and exportfs could start no slave (`no procs`, seed 408 on
  an `-icount 0` machine). An exit's clunk is now waited for five
  seconds at most (`Mntexitms`; a kill's, one), long enough for a
  server that acts on the clunk, a ctl file's, to answer first.
- **exportfs held a request behind its own name space**: a slave adopting
  the next request's name space and fd table closed the ones it had,
  before serving the request; a close that waited on a server reached
  through this export waited on itself. The old ones are closed after the
  reply.
- **An exiting Prog waiting on itself**: `delprog` closed the name space
  before the fd table, so a Prog holding the far end of a pipe it had
  mounted waited in its own exit for a clunk only its fd table's close
  could answer. The fd table goes first. (That once seemed to break
  `auditprov_test`; the cause was an emu left running from an earlier
  test, holding the test's Venti port.)

Test: `kill_deadserver_test` (a server that never answers a read, a
clunk or a flush; the killer and the killed both get away within 5s, a
Prog exiting of itself within 10s).

Found by the chaos build and by `tools/sysfuzz -P` (refused memory):

- **The JITs' calls of a builtin** ran it with R.PC whatever was last
  punted and the builtin's frame as R.FP: an exception the builtin raised
  inside a handler block (an array bounds error from `utfbytes`, out of
  memory, an interrupted call) was matched with the builtin's frame, the
  block's locals "zeroed" in it, and the caller resumed on it. Reachable
  with plenty of memory (`jit_builtinexc_test`); seen as destroy of nil
  and as compiled code running with a nil frame pointer (`mframe`).
- **MacFRAM** (a frame that needs a new stack segment) raised out of
  memory with R.PC stale: the same wrong handler.
- **spawn** made the Prog runnable, then could not allocate its stack,
  and left it to run with none.
- **compile** raised out of memory from inside the compile lock, which
  was never let go: every later module load waited, holding its VM, and
  the console's VM stopped. A failure partway also left the module's links
  pointing at freed code.
- **Channels**: `alt` left its Prog queued on the first channels when
  queuing it on a later one failed (the collector later woke it, freed);
  `isend`/`irecv` took the Prog off the run queue before queuing it (its
  exception handled with another Prog current); a new channel whose queue
  heads could not be allocated kept the freed pointers.
- A kproc's Prog (`addprog`), a first Prog from `#X` (`newprog`), a
  mount's queue (`mntversion`, which also called qopen holding a spin
  lock), an IP conversation's queues (`Fsprotoclone`): each panicked or
  kept a nil.
- `killgrp` killed nothing when it could not allocate its list of pids:
  under memory pressure a group could not be killed.
- The emulator's `smalloc` panicked after ten seconds without memory, and
  `kstrdup`, `kproc`, `addprog` at once; they wait, as the native kernel's
  do, the pool named once on the console, a kill interrupting the wait.

## Open

- Orphaned calls whose server never answers keep their tag and their
  Mntrpc until the mount goes: one tag of 64K a call, which a long soak
  against a stuck server could use up.
- A main pool far too small for what is run (emu `-pmain=2m` under
  sysfuzz) still brings every Prog, the one that would kill the others
  among them, to wait for memory nothing frees: a standstill with the
  pool named, not a crash. And with hundreds of procs blocked, the host
  can refuse emu another thread's stack (glibc's assertion in
  `pthread_create`).
- Hosted sysfuzz, rarely (seeds 704 with `-d`, 904 without): heartbeats
  stop with no watchdog report and nothing found under gdb on a rerun.

## Reading a run under -icount

`-icount` gives every instruction a fixed slice of the machine's time
and runs every core on one host thread: under `-icount 0` a run takes
many times its seconds. nativefuzz waits while the heartbeats go on (a
minute without one is a hang) rather than for a fixed time; a "hang" on
an `-icount` machine from before that was the machine being slow.

On one core, nativefuzz gives `-icount` `sleep=on`. With `sleep=off`
QEMU (8.2) jumps the clock to the next deadline whenever every core is
idle, and with a single core, idling as it should in `wfi`, it then never
runs its main loop again: no serial input reaches the guest and the
QEMU monitor does not answer either. Every one-core `-icount` seed hung
at the prompt that way; it was never the kernel.
