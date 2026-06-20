# 2026-06-20 — Linux emu returns exit status 137 on every clean shutdown

## Summary

On Linux, the emulator (`emu/Linux/o.emu`) exited with status **137**
(128 + SIGKILL) on *every* normal shutdown, even after a completely
successful run. The cause: `cleanexit()` in `emu/Linux/os.c` did
`kill(0, SIGKILL); exit(0);`. Because `libinit()` calls `setsid()`,
emu is its own process-group leader, so `kill(0, SIGKILL)` delivers
SIGKILL to the whole group — **including the calling thread** — and the
process dies by signal 9 before `exit(0)` is ever reached. The host
parent therefore always saw a process that was "killed by SIGKILL",
i.e. exit status 137.

This silently broke any caller that checks emu's exit code:

- `tests/host/mount_clone_walk_test.sh` failed (`rc=137`) even though the
  run printed its `OK` marker — it explicitly rejects any rc that is
  neither 0 nor 124 (timeout).
- `run-tests.sh`'s internal (emu) runner does `return $emu_status`, so a
  137 from the runner made the **entire internal test suite report FAIL**
  at the harness level even when every Limbo test passed.

The macOS port (`emu/MacOSX/os.c`) never had this bug — its `cleanexit()`
is just `exit(0)`, with no group kill.

## Symptoms

```
$ printf 'echo hi\n' > tmp_hi.sh
$ emu/Linux/o.emu -r$PWD sh /tmp_hi.sh ; echo "exit=$?"
fs: fsqid: top-bit dev: 0xfe00
hi
exit=137              # <- clean run, output correct, but 137
```

```
$ bash tests/host/mount_clone_walk_test.sh ; echo rc=$?
FAIL: emulator exited with rc=137
...
OK                    # <- the script DID complete
rc=1
```

Internal suite (`./run-tests.sh -i`): every test prints "passed", yet the
harness ends in `FAIL` because the runner emu returned 137.

## Root cause

`emu/Linux/os.c`:

```c
void
cleanexit(int x)
{
	USED(x);
	if(up->intwait){ up->intwait = 0; return; }
	if(dflag == 0) termrestore();
	kill(0, SIGKILL);   /* signals the whole process group, incl. self */
	exit(0);            /* never reached */
}
```

`kill(0, SIGKILL)` is correct only for the **clone-based** proc model
(`emu/Linux/os-clone.c`), where each Inferno proc is a separate host
*process* in the group and must be force-killed individually. The default
Linux build links `os.c` with `kproc-pthreads.o` — the **pthread** model,
where every Inferno proc is a thread sharing emu's single PID. There,
ending the process (the calling thread terminating the process) already
tears every proc down; the `kill(0, SIGKILL)` does nothing useful except
kill the main thread and corrupt the exit status.

`cleanexit()` is reached on the normal path via `dis.c`: when the Dis
scheduler run queue empties (`isched.head == nil`, i.e. the last proc has
exited) it calls `cleanexit(0)`. It is *also* installed as the `SIGINT`
and `SIGTERM` handler (`os.c`), so Ctrl-C and `kill`/`timeout` flow
through the same code.

## Fix

Replace `kill(0, SIGKILL); exit(0);` with `_exit(0);`
(`emu/Linux/os.c`).

- **No group kill.** The pthread model does not need it; dropping it lets
  the host observe a real exit status. This matches the macOS port.
- **`_exit()`, not `exit()`.** `cleanexit()` runs both from a signal
  handler and from arbitrary interp threads. `exit()` is not
  async-signal-safe and is unsafe to call while other pthreads hold the
  locks it needs to flush stdio / run `atexit` handlers. `_exit()` ends
  the whole process immediately with a clean status. emu prints via raw
  `write(2)`, so there are no buffered streams to lose.

Only `os.c` (pthread) is changed. `os-clone.c` legitimately needs the
group kill and is left alone (and is not part of the default build).

## Validation (Linux AMD64)

| Check | Before | After |
| --- | --- | --- |
| `emu sh -c 'echo hi'` exit code | 137 | **0** |
| `tests/host/mount_clone_walk_test.sh` | FAIL (rc=137) | **PASS** |
| `tests/host/jit_boot_test.sh` | PASS | PASS (unchanged, ~60s) |
| full Lucifer boot (29 lines, `lucifer: INIT`, 16 tools) | ✓ | ✓ identical |
| Ctrl-C / SIGTERM termination | → 137 | clean exit, no hang |
| `run-tests.sh -i` harness result | FAIL (137 propagated) | PASS |

Note: a *booted* emu (one that started background services such as
`msg9p`, `lucibridge`, `llmsrv`) stays alive by design — `isched` never
empties — so `jit_boot_test.sh` still runs to its `timeout` as it always
did; only the exit status delivered on that timeout's SIGTERM changed
(137 → clean).

## Why this matters / lessons

- A non-zero exit status on success makes emu unusable as a building
  block in any shell pipeline, `set -e` script, or CI step. Two of our
  own harnesses were already silently mis-reporting because of it.
- The `kill(0, …)` idiom is dangerous in a process-group leader: it
  always includes the caller, and if `setsid()` ever fails it would
  signal the *parent's* group instead. `_exit()` avoids both hazards.
- `os.c` and `os-clone.c` implement two different proc models; code
  copied between them (this `kill(0, SIGKILL)` looks lifted from the
  clone variant) needs review against the model actually linked.
