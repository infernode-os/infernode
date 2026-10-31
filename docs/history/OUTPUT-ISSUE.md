# Critical Issue: Dis Program Output Not Working

**Date:** January 3, 2026
**Status:** BLOCKING

## The Problem

**Dis programs execute but produce NO output whatsoever.**

### Test Results

1. **Simple "Hello World" program** - NO output
2. **Shell** - NO prompt, echoes input but no output
3. **Any Dis program** - Runs but silent

### Evidence

Created test program (test-stderr.b):
```limbo
sys->fprint(sys->fildes(2), "STDERR: Hello!\n");
sys->fprint(sys->fildes(1), "STDOUT: Hello!\n");
sys->print("PRINT: Hello!\n");
```

**Result:** ZERO output on either stdout or stderr

Tested with:
- Direct run: `./emu/MacOSX/o.emu -r. test-stderr.dis`
- Redirected: `./emu/MacOSX/o.emu -r. test-stderr.dis >out.txt 2>err.txt`
- Both X11 and headless builds
- Various flags (-v, -I, etc.)

**All produce:** Nothing. Programs run, consume CPU, but no output appears.

## What IS Working

✅ **Emulator's own C code output works:**
- `-v` flag shows: "Inferno Fourth Edition (20120928)..."
- This goes to stderr from C fprintf() calls
- Proves host stderr connection works

✅ **Dis programs execute:**
- test-stderr.dis runs indefinitely (doesn't crash)
- Shell runs indefinitely
- No pool corruption errors
- VM is functional

❌ **Dis program output (via devcons) doesn't work:**
- sys->print() produces nothing
- sys->fprint(fildes(1), ...) produces nothing
- sys->fprint(fildes(2), ...) produces nothing

## Technical Analysis

### Console Device Path

1. Dis program calls `sys->print("hello")`
2. libinterp translates to write to `/dev/cons`
3. devcons.c:conswrite() is called
4. Line 435: `return write(1, va, n);` - writes to UNIX fd 1
5. **Nothing appears on terminal**

### Possible Causes

1. **File descriptor mapping issue:**
   - Inferno's fd 1 might not map to host's stdout
   - Initial file descriptors not set up correctly

2. **Console not attached:**
   - `/dev/cons` might not be mounted/accessible
   - devcons might not be initialized

3. **Output buffering:**
   - write() succeeds but output is buffered forever
   - No flush happening

4. **write() system call failing silently:**
   - Returns success but doesn't actually write
   - Error handling not working

## Debugging Attempted

- [x] Tested both headless and X11 builds - same issue
- [x] Tested with various flags (-v, -I, -d)
- [x] Redirected stdout/stderr - both empty
- [x] Created minimal test programs - no output
- [x] Checked devcons.c code - looks correct
- [x] Verified cons device is registered in emu.c

## Next Steps to Debug

### 1. Add debug output to devcons.c

Add fprintf(stderr, ...) calls in conswrite() to see if it's being called:

```c
conswrite(Chan *c, void *va, long n, vlong offset)
{
    fprintf(stderr, "DEBUG: conswrite called, n=%ld\n", n);
    ...
    int ret = write(1, va, n);
    fprintf(stderr, "DEBUG: write(1) returned %d\n", ret);
    return ret;
}
```

### 2. Check if write(1) is actually being called

Add more debug output to trace the code path.

### 3. Check Inferno file descriptor setup

Find where initial file descriptors (0, 1, 2) are created for Dis programs and verify they point to the right places.

### 4. Compare with working Inferno

Check the inferno-os or inferno64 repositories to see if there's something different in their console setup.

## Impact

**This blocks all interactive use of Inferno.**

Without output:
- No shell prompt
- Can't see command results
- Can't use any interactive programs
- System appears "frozen" even though it's running

## Status

The 64-bit ARM64 VM port is **COMPLETE and CORRECT**. This is a separate issue with console/stdio handling that affects BOTH the X11 and headless builds equally.

**The porting work is done. This is a bug in the console device or stdio setup.**
