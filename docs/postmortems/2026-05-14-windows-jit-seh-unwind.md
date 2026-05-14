# 2026-05-14 — Windows JIT crash: SEH unwind across JIT frames

## Summary

On Windows AMD64 with the Dis JIT enabled (`emu -c1`), even the simplest
session — `o.emu.exe -c1 -r <bundle> sh -c "echo ok"` — crashed with
`STATUS_BAD_FUNCTION_TABLE` (`0xC00000FF`) somewhere inside the very
first `longjmp`/`error()` unwind. Disabling the JIT (`-c0`) ran clean.

Root cause: MSVC's x64 `longjmp` doesn't just restore registers — it
calls `RtlUnwind`, which walks every stack frame between the matching
`setjmp` and the `longjmp` call site, reading each frame's PE
function-table entry to run SEH `__finally` blocks and C++
destructors. JIT-generated code lives in dynamically-allocated
executable memory with **no** function-table entries. On recent ntdll
builds (10.0.26100+) the unwinder validates that lookup and raises
`STATUS_BAD_FUNCTION_TABLE` when it can't find one. Older ntdlls
silently tolerated the missing entry, which is why the JIT
"used to work" — the bug had been latent the whole time and Windows
Update lit the fuse.

Fix: zero `_JUMP_BUFFER.Frame` immediately after every `setjmp` in
emu. That's the Microsoft-documented hook that tells `longjmp` "just
restore the registers, don't walk the stack." Safe in this codebase
because emu is plain C — no SEH `__finally` blocks, no C++
destructors that need to run during the jump.

The fix is two lines of C in `Nt/amd64/include/emu.h`. JIT and
interpreter now exit cleanly on Windows.

Jira: **INFR-46** (this fix). Surfaced a separate downstream crash —
`0xC0000005` AV during the profile's `bind /usr/inferno/tmp` — tracked
as **INFR-69**.

## Symptoms

- Headless smoke test crashes immediately:
  ```
  PS> .\emu\Nt\o.emu.exe -c1 -r $bundle sh -c "echo ok"
  $LASTEXITCODE = -1073741569   (0xC00000FF)
  ```
- Application event log:
  ```
  Faulting application name: o.emu.exe
  Faulting module name:      ntdll.dll
  Exception code:            0xC00000FF
  Fault offset:              0x000000000000dd2f   (on 26100.8246)
  ```
- `-c0` (interpreter only) runs to completion every time.
- macOS and Linux builds at the same commit run clean.
- Reproduces on the current `master` AND on `refs/preserved/nervsystems/*`
  branches that demonstrably worked weeks earlier. **The code didn't
  change; ntdll did.**

## Investigation

This crash burned most of a day before we sat down with WinDbg. The
shape of the journey matters — future you will be tempted to repeat it.

### Dead ends, in order

1. **Misread the NTSTATUS.** I initially decoded `-1073741569` as
   `0xC000007B` (`STATUS_INVALID_IMAGE_FORMAT`) and started chasing
   DLL-loader theories. It's `0xC00000FF`
   (`STATUS_BAD_FUNCTION_TABLE`). Cost: a couple of hours and a
   credibility hit with the maintainer. PowerShell prints exit codes
   signed; always convert to hex (`'{0:X8}' -f ([uint32]([int64]$ec
   -band 0xFFFFFFFF))`) before pattern-matching.

2. **Reverted to W^X JIT discipline.** Hypothesis: the JIT pages
   weren't `PAGE_EXECUTE_READ`, the CPU faulted on execute, and ntdll
   was reporting it as a function-table miss. Reverting `segflush` to
   the strict W→X transition did not change the crash. W^X is
   correct hygiene but not the cause.

3. **Reverted PR #67 (control-plane split).** Hypothesis: a recent
   merge broke something in the kproc lifecycle that the JIT walked
   into. Same crash on the parent commit. Not the cause.

4. **Wrote `RtlInstallFunctionTableCallback` framework
   (`emu/Nt/jit-unwind.c`).** Hypothesis: register a dynamic
   function-table callback for every JIT-allocated region so the
   unwinder can find a `RUNTIME_FUNCTION` / `UNWIND_INFO` pair. Got it
   to register all 20 JIT regions cleanly. **Still crashed.** The
   unwinder was reaching code that wasn't covered, or the synthetic
   `UNWIND_INFO` we generated (leaf, then 6×`PUSH_NONVOL`) didn't
   describe the JIT's actual prologue. Either way: not the right
   layer.

5. **"The JIT used to work — find the regression."** I went looking
   for a code regression for several rounds. The maintainer was
   right that earlier builds worked; I was wrong to assume that
   meant the bug was in our code. An Explore-agent sweep of the
   preserved branches established the crash is environmental: every
   historic branch we tried crashes the same way on 26100.8246.

### What actually worked

Installed WinDbg via `winget install 9PGJGD53TN86 --source msstore`,
wrote `tests/host/windows-jit-cdb-script.txt` to set a first-chance
break on `c00000ff`, and re-ran the repro under cdb. The stack at
break-point told the whole story:

```
ntdll!RtlVirtualUnwind+0x...
ntdll!RtlUnwindEx+0x...
ntdll!_C_specific_handler+...
...
o.emu!longjmp+...
o.emu!nexterror+...            ← Inferno error path
o.emu!mountfree+...            ← unwinding kproc namespace
[ ? frame with no module ]      ← a JIT page
o.emu!destroy+...
```

The `[ ? frame with no module ]` line is the JIT page being walked.
`RtlUnwind` can't find a PE function-table entry for that RIP and
raises `STATUS_BAD_FUNCTION_TABLE`. Once that frame is visible in
the trace, the fix becomes obvious: don't walk the stack at all.

### The fix

Microsoft documents that zeroing the first qword of the
`_JUMP_BUFFER` (the `Frame` field) tells `longjmp` to skip the SEH
walk and just restore registers. Used in production by Mono and
SpiderMonkey for the same reason. `setjmp` must remain a textual call
at the original call site (it's a compiler intrinsic), so we pass
its return value through a `__forceinline` helper that nulls Frame on
the first-time (zero-return) path and is a no-op on the longjmp
return:

```c
typedef jmp_buf osjmpbuf;

static __forceinline int
ossetjmp_no_seh(int rv, void *buf)
{
    if(rv == 0)
        *(unsigned __int64*)buf = 0;   /* _JUMP_BUFFER.Frame */
    return rv;
}
#define ossetjmp(buf)  ossetjmp_no_seh(setjmp(buf), (buf))
```

That's it. Two lines that route every emu `setjmp` through the helper,
and a long comment explaining why.

Why this is safe for emu specifically: emu is plain C, compiled
without `/EHsc` for the modules on the unwind path. There are no C++
destructors and no `__finally` blocks between `waserror()`'s `setjmp`
and the matching `nexterror()`'s `longjmp`. Skipping the SEH walk
skips nothing that needed to run.

## Test infrastructure

Two artifacts checked in alongside the fix so the next regression has
a sharp tool ready:

- `tests/host/windows-jit-crash-repro.ps1` — deterministic reproducer.
  Runs the minimal "load std + mntgen mount" sequence that JIT-compiles
  ~15 modules and triggers the SEH walk. Use `-ExpectPass` in CI to
  treat the crash as a regression; default mode treats the crash as
  expected and exits 0 so you can confirm "bug exists" on a fresh
  machine without it failing your shell.

- `tests/host/windows-jit-cdb-script.txt` — cdb script that sets a
  first-chance break on `0xC00000FF` (and AV as a fallback), dumps
  registers, stack, exception record, and `lmDvm ntdll` so the
  ntdll build number is captured. Re-run this any time the Windows
  JIT crashes again and the stack will tell you what to do.

## Verification

Post-fix, on the same Windows host that was crashing:

```
PS> .\emu\Nt\o.emu.exe -c1 -r $bundle sh -c "echo ok"
ok
$LASTEXITCODE = 0
```

`for i in 1..5` of the same command: 5/5 exit 0. JIT-compiled mntgen
mount: completes (daemon kproc holds emu alive; that's expected).

The fix also surfaced a previously-masked bug: with the SEH crash
out of the way, the profile now gets far enough that JIT-compiled
`ndb/cs` calls into `Srv_iph2a` (DNS lookup) and dies with
`0xC0000005`. Tracked and fixed under **INFR-69** — see below.

## INFR-69 — 32-bit-stale runtime headers committed in `emu/Nt/`

### Diagnosis

cdb caught the AV at `o_emu+0x3f741`, decoded via `o.emu.map` to
`string2c + 0x21`, called from `Srv_iph2a + 0xc6` — i.e.
`string2c(f->host)` with `rcx = 0`. A NULL `String*` reaching
`string2c` means either the caller passed nil, or the frame layout
seen by C disagrees with the frame layout the runtime allocated.

The latter. Both `emu/Nt/srv.h` and `emu/Nt/srvm.h` had been
generated long ago by a 32-bit `limbo` (`emu/Nt/mkfile` still says
`OBJTYPE=386`) and committed to the tree. They encode 32-bit WORDs:

```c
/* emu/Nt/srv.h, wrong: */
struct F_Srv_iph2a {
    WORD    regs[NREG-1];   /* 4 × 4 = 16 bytes on 32-bit (correct sz),
                               but WORD is intptr → 32 bytes on amd64 */
    List**  ret;
    uchar   temps[12];      /* 3 × WORD = 12 on 32-bit, should be 24 */
    String* host;
};
```

```c
/* emu/Nt/srvm.h, wrong: */
"iph2a", 0xaf4c19dd, Srv_iph2a, 40, 2, {0x0,0x80,},
                                /* frame size 40 = 32-bit, should be 72 */
```

The amd64 runtime allocates a **40-byte** frame (per `srvm.h`), then
the C code reads `f->host` at **offset 56** (per `srv.h`'s 64-bit-
laid-out struct: 32 + 8 + 12 + 4-pad = 56). That's 16 bytes past
the allocation, into whatever happens to be zero in adjacent heap —
hence `rcx=0` and the AV.

`emu/MacOSX/srv.h` and `emu/MacOSX/srvm.h` had the correct 64-bit
values (`temps[24]`, frame sizes 64/72/72/80) because the macOS
mkfile uses `OBJTYPE=amd64` and regenerates them every build.

### Fix

The Windows build scripts (`build-windows-amd64.ps1`,
`build-windows-sdl3.ps1`) didn't regenerate these headers — they
only regenerated `libinterp/runt.h` and friends. Added a
`limbo -a` / `limbo -t Srv` step in both scripts to regenerate
`emu/Nt/srv.h` and `emu/Nt/srvm.h` from `module/srvrunt.b` using
the freshly-built 64-bit `limbo.exe`, immediately before
compiling `emu/port/srv.c`. The committed copies are now byte-
identical to what fresh generation produces.

Verified: same `cdb` script that previously caught `AV_HIT` after
~20 `ModLoad` lines now runs past the DNS-resolution phase
(wshbth.dll, fwpuclnt.dll all loaded) without any first-chance
exception. `sh -l -c 'echo profile-ok; exit 0'` reaches and prints
`profile-ok`.

### Things that look right but do not fix `0xC0000005` here

- **"It crashes in DNS — must be a Windows networking issue."**
  Wrong layer. `Srv_iph2a` itself is fine; the bug is the JIT
  runtime giving it a too-small frame.

- **"Just add a NULL check in `string2c`."** Would paper over the
  AV but leave every other runtime function reading garbage from
  the frame. Fix the layout, not the symptom.

- **"Regenerate just `srv.h`."** Must regenerate `srvm.h` too —
  it has the frame-size value the JIT uses to allocate frames. They
  must be generated by the same limbo with the same target word size.

### Lessons (INFR-69 specific)

1. **Auto-generated headers must be regenerated, not committed.**
   Any header generated by a build tool needs a generation step in
   the active build script. If you commit a generated artefact and
   forget to update it, it ages out silently — and on Windows
   especially, where the only signal is "JIT crashes weeks later in
   a function you didn't touch."

2. **OBJTYPE mismatch between mkfile and actual target is invisible
   at build time.** `emu/Nt/mkfile` says `OBJTYPE=386` but the
   amd64 build script never reads that mkfile — it has its own
   notion of target. The two views of "what word size is this?"
   never crossed paths, so the stale 32-bit headers survived for
   years. If you keep `mkfile`s around alongside hand-rolled
   build scripts, mark the obsolete ones obsolete or delete them.

3. **Read the `.map` file.** When a Windows binary crashes without
   symbols, the linker `.map` is your friend. With image base and
   section RVAs you can resolve any `module+0xNNNN` to a function
   name in a one-line awk/perl script. Don't waste a cdb session
   on disassembly when `o.emu.map` tells you the function in five
   seconds.

## Things that look right but do not fix `0xC00000FF`

For future me, future them, future us. These all sound like the right
shape of fix and are wrong:

- **W^X (PAGE_READWRITE → PAGE_EXECUTE_READ).** Correct hygiene.
  Does not change the crash. The CPU isn't faulting; ntdll is.

- **`RtlAddFunctionTable` / `RtlInstallFunctionTableCallback`.** The
  right answer *if* you want SEH unwinding to actually work through
  JIT frames. We don't — we want it to stop walking. Registering
  function tables also requires generating accurate `UNWIND_INFO`
  for the JIT's real prologue and any non-leaf calls it makes, which
  is a project in itself.

- **Reverting recent merges.** The crash predates any recent change.
  Verified by running historic `refs/preserved/nervsystems/*`
  branches against current ntdll.

- **Switching `setjmp` → `_setjmp`.** MSVC's `_setjmp` still uses
  the SEH-aware longjmp on x64. The intrinsic name doesn't matter;
  the Frame field does.

## Lessons

1. **When you see a Windows NTSTATUS, convert to hex first, then
   look it up.** Decimal exit codes are a footgun and `[uint32]`
   chokes on negatives in PowerShell — go through `[int64]` first.
   Three hours of "INVALID_IMAGE_FORMAT" theorising could have been
   one minute of "BAD_FUNCTION_TABLE — oh, the unwinder."

2. **Reach for WinDbg sooner.** Once a Windows-specific crash makes
   it past the first hypothesis-test cycle, install cdb/WinDbg and
   set a first-chance break. The stack trace removes whole classes
   of speculation. We had the answer within ten minutes of
   `winget install 9PGJGD53TN86`.

3. **"It used to work" + "same code crashes now" = environmental.**
   Don't bisect your repo when Windows Update is the suspect. Try
   the preserved branches on the current OS image before assuming
   regression. Capture the ntdll build (`lmDvm ntdll`) on every
   Windows crash report.

4. **JITs on Windows x64 must engage with the SEH unwinder one way or
   the other.** Either register function tables (full engagement) or
   opt every `setjmp` out of the walk (this fix). There is no third
   option where ntdll politely ignores frames it doesn't recognise —
   that's the bug the 26100 hardening closed.

5. **Honest reporting beats fast reporting.** Several of the dead ends
   above came with confident "this is the fix" framing before the
   evidence supported it. The maintainer noticed every time. The
   working rule for this codebase, restated: claim a fix only when
   you have a verifying run that reproduces clean, and name the
   command you ran.

## Files touched

- `Nt/amd64/include/emu.h` — the actual fix (`ossetjmp_no_seh`).
- `tests/host/windows-jit-crash-repro.ps1` — reproducer.
- `tests/host/windows-jit-cdb-script.txt` — WinDbg/cdb diagnostic.
- `emu/Nt/jit-unwind.c`, `.h` — dead-end framework retained on the
  branch as reference for anyone who wants to attempt the
  full-engagement path later.

## References

- Microsoft Windows Internals 7th ed., chapter 8 (x64 exception
  dispatching, function tables, `RtlUnwindEx`).
- Microsoft Learn — `setjmp` x64 semantics, `_JUMP_BUFFER` layout.
- Mono runtime `mini-x86_64.c` — same Frame=0 workaround, same reason.
- SpiderMonkey `js/src/jit/x64/Trampoline-x64.cpp` — same.
- Jira INFR-46 (this fix), INFR-69 (downstream AV surfaced after fix).
