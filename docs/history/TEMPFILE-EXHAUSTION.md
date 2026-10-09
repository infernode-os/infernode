# Temp File Slot Exhaustion Bug

## TL;DR

If acme or xenith fails with:
```
acme: can't create temp file file does not exist: file does not exist
```

**The fix is:**
```bash
# Check which PIDs are exhausted
./tests/test-tempfile-slots.sh

# Remove exhausted slots (example for PID 1)
rm tmp/*1.pdfiacme
rm tmp/*1.pdfixenith
```

---

## The Bug

### Symptoms

1. **Standalone xenith fails completely** - exits immediately with temp file error
2. **First Acme from wm menu fails** - shows white window, error in console
3. **Subsequent Acme launches work** - no error, normal operation
4. **Standalone acme works** - depending on which PID it gets

### Root Cause

The `tempfile()` function in `appl/acme/disk.b` and `appl/xenith/disk.b` creates temporary files with a limited naming scheme:

```limbo
buf := sys->sprint("/tmp/X%d.%.4sacme", sys->pctl(0, nil), utils->getuser());
for(i:='A'; i<='Z'; i++){
    buf[5] = i;
    (ok, nil) := sys->stat(buf);
    if(ok == 0)      // file exists, skip
        continue;
    fd := sys->create(buf, Sys->ORDWR|Sys->ORCLOSE|Sys->OEXCL, 8r600);
    if(fd != nil)
        return fd;
}
return nil;  // ALL 26 SLOTS EXHAUSTED - FAILURE
```

The filename pattern is: `/tmp/{A-Z}{pid}.{user}{app}`
- Letters A-Z provide 26 slots per process ID
- `{pid}` is the Inferno process ID (NOT the host OS PID)
- `{user}` is first 4 characters of username (e.g., "pdfi" for "pdfinn")
- `{app}` is "acme" or "xenith"

**When all 26 slots for a given PID are used, `tempfile()` returns nil and the application fails.**

### Why Files Accumulate

The `ORCLOSE` flag should auto-delete files when closed, but files persist because:

1. **Crashes/forced termination** - file descriptors not properly closed
2. **Killed processes** - `kill` doesn't trigger ORCLOSE cleanup
3. **Abnormal exits** - exceptions, panics, etc.

Over time, slots accumulate until exhausted.

### Why Different PIDs Get Exhausted

- **PID 1**: Standalone applications (xenith, acme run directly)
- **PID 18**: First application spawned from wm menu
- **Other PIDs**: Subsequent spawns, different execution paths

---

## The Debugging Journey

### What Made This Hard to Debug

1. **Misleading error message** - "file does not exist" sounds like /tmp directory is missing
2. **Inconsistent behavior** - worked sometimes, failed others
3. **Red herrings**:
   - Namespace binding issues (FORKNS)
   - Profile script race conditions (mntgen/trfs)
   - Module loading paths
   - Permission issues

### Wrong Hypotheses Explored

1. **"/tmp not bound in namespace"** - Wrong. /tmp existed and was accessible.
2. **"Profile race condition"** - Partially right for different issue, but not this one.
3. **"FORKNS losing /tmp binding"** - Wrong. Namespace was fine.
4. **"Xenith vs Acme code difference"** - Wrong. Code is identical.

### How We Found the Real Cause

1. Noticed xenith temp files existed from previous sessions (proving /tmp worked before)
2. Counted temp files per PID:
   ```
   26 files with PID 1 for xenith - ALL SLOTS EXHAUSTED
   26 files with PID 18 for acme - ALL SLOTS EXHAUSTED
   ```
3. Realized the "file does not exist" error was from `sys->create()` failing after the A-Z loop exhausted

### The Key Insight

The second Acme worked because it got a **different PID** (not 18), which had available slots.

---

## The Fix

### Immediate Fix

Remove exhausted temp files:
```bash
rm tmp/*1.pdfixenith   # For standalone xenith (PID 1)
rm tmp/*18.pdfiacme    # For wm-spawned acme (PID 18)
```

### Regression Test

Run the slot exhaustion test:
```bash
./tests/test-tempfile-slots.sh
```

This test:
- Counts slots per PID for both acme and xenith
- FAILS if any PID has 26/26 slots (exhausted)
- WARNS if any PID has 20+/26 slots (getting full)
- Should be run before releases and when debugging temp file issues

### Profile Fix (Separate Issue)

The profile was also fixed to be synchronous (unrelated to slot exhaustion):
```diff
- mount -ac {mntgen} /n &
- trfs '#U*' /n/local &
- sleep 1
+ mount -ac {mntgen} /n
+ trfs '#U*' /n/local >[2] /dev/null
```

This approach eliminates race conditions.

---

## Prevention

### Short-term

1. Run `./tests/test-tempfile-slots.sh` periodically
2. Clean up tmp/ directory when slots get full
3. Add test to CI/pre-commit hooks

### Long-term Options

1. **Cleanup on startup** - Add to profile or emuinit
2. **Expand character range** - Use A-Z, a-z, 0-9 (62 slots)
3. **Use timestamp in filename** - Avoid PID collision entirely
4. **Proper ORCLOSE handling** - Investigate why it's not working

---

## Files Involved

| File | Purpose |
|------|---------|
| `appl/acme/disk.b` | Acme's tempfile() implementation |
| `appl/xenith/disk.b` | Xenith's tempfile() implementation |
| `tmp/` | Inferno temp directory (in root filesystem) |
| `lib/sh/profile` | Shell initialization (fixed separately) |
| `tests/test-tempfile-slots.sh` | Regression test |

---

## Lessons Learned

1. **Check the obvious first** - Count existing files before assuming directory issues
2. **"File does not exist" is ambiguous** - Can mean parent dir missing OR create() failed
3. **Consistent vs inconsistent failures** - Often points to resource exhaustion
4. **PID-based naming has limits** - 26 slots is not enough for long-running systems
5. **ORCLOSE is not reliable** - Don't depend on it for cleanup

---

## Related Issues

- SDL3 HiDPI fixes (separate)
- Full-screen letterboxing (separate)
- Exit crash / dispatch_sync deadlock (separate)

---

*Document created: 2026-01-16*
*Last debugging session: ~2 hours of wrong hypotheses before finding root cause*
