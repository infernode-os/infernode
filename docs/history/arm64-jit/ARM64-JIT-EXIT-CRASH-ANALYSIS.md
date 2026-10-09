# ARM64 JIT Exit Crash Analysis
**Date:** 2026-01-18 Final
**Status:** Core JIT works, exit crash remains

## Current Situation

**JIT Functionality:** ✅ WORKING
- Programs execute correctly
- Output is produced correctly
- echo, cat, sh all functional

**Exit Behavior:** ❌ CRASH
- All programs crash when exiting
- Crash happens AFTER correct output
- Two distinct crash patterns observed

## Crash Pattern Analysis

### Crash 1: addr=0x58 (offset 88)
```
SEGV: addr=58 code=2
PC=<C code> X9=<valid ptr> X10=<valid ptr> X11=&R X12=<valid ptr>
```
- Registers are VALID at this crash
- Offset 88 = R.m (middle operand) in REG struct
- Crash from dereferencing bad `t` pointer in mframe()
- This is a separate bug (bad function arguments), not register corruption

### Crash 2: addr=0x120 (offset 288)
```
SEGV: addr=120 code=2
PC=<C code> X9=<ptr> X10=0-2 X11=3 X12=0
```
- X10-X12 contain small integers (0-3) instead of pointers
- This IS register corruption
- Crash in C code trying to use corrupted registers

## Investigation Attempts

### Attempt 1: Save/Restore X9-X12 in Preamble (Stack)
**Tried:** STP/LDP to stack at preamble entry/exit
**Result:** FAILED - stack pointer management issues, conflicts with JIT's stack usage

### Attempt 2: Save to R.st/R.dt
**Tried:** Store X9-X10 in R.st, R.dt temporary fields
**Result:** FAILED - R.st/R.dt actively used by JIT for other purposes

### Attempt 3: Wrap puntdebug() Call
**Tried:** Added STP/LDP around debug print function
**Result:** No improvement - crashes persist

## Root Cause Hypothesis

The exit crash with X10=0-2, X11=3, X12=0 suggests:

1. **C code uses X9-X12 as locals** (perfectly legal for caller-saved regs)
2. **JIT modifies X9-X12** (also legal - they're scratch registers)
3. **When returning from JIT to C, X9-X12 have JIT values**
4. **C code continues using X9-X12 as if they still had C values**
5. **C code dereferences what it thinks is a pointer but is actually integer 0-3**
6. **Crash!**

## Why This Is Hard

**ARM64 ABI Conflict:**
- Per ABI: X9-X15 are caller-saved = caller must save if needed
- Our usage: JIT uses X9-X12 persistently throughout execution
- The problem: JIT execution spans MULTIPLE C function calls
  - C calls comvec() (JIT entry)
  - JIT calls C functions (mframe, etc.)
  - Those C functions return to JIT
  - JIT continues with X9-X12
  - Eventually JIT returns to original C caller
  - Original C caller's X9-X12 are now corrupted

## Why Solution #1 Works for Execution

The save/restore around BLR (JIT→C calls) works because:
- JIT saves X9-X12 before calling C
- C code can use X9-X12 freely
- JIT restores X9-X12 after C returns
- JIT continues with correct values

But it FAILS for exit because:
- When JIT returns to C via comvec() exit
- C code resumes with JIT's X9-X12 values
- C code expects its own X9-X12 values
- Crash!

## Potential Solutions

### Option A: Make comvec() Preserve X9-X12
Save X9-X12 in preamble to a SAFE location (not R.st/R.dt which are used).
Need to find unused storage or allocate dedicated save area.

### Option B: Ensure C Code Doesn't Use X9-X12 After comvec()
Modify xec.c to not rely on X9-X12 after calling comvec().
But with -O optimization, compiler decides register usage.

### Option C: Accept Exit Crash as Known Limitation
Document that JIT works but programs can't exit cleanly.
Acceptable for batch/service mode where clean exit isn't critical.

### Option D: Use Different Registers
Try X13-X15 instead of X9-X12 (though they're also caller-saved).
Or use X19-X22 WITH manual save/restore everywhere (heavyweight).

## Current Recommendation

Given that:
- Core JIT functionality IS working
- Programs produce correct output
- Only exit/cleanup crashes
- Multiple fix attempts haven't succeeded

**Recommend:** Document as known limitation, proceed with benchmarking to
prove JIT performance benefits. Fix exit crash as follow-up task.

Alternative: Spend more time investigating Option A (find safe storage for
caller's X9-X12 during preamble).

---

*Analysis by: Claude Sonnet 4.5*
*Status: Partial success - JIT works, exit buggy*
*Time spent on exit crash: 2+ hours*
