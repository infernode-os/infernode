# JIT-64bit Status Report
**Date:** 2026-01-18
**Platform:** macOS ARM64 (Apple Silicon)
**Status:** NOT WORKING - Requires Further Development

## Executive Summary

The ARM64 JIT-64bit implementation is currently **non-functional**. While the build system works correctly and the code compiles, the JIT crashes with segmentation faults when enabled (cflag > 0). The interpreter mode (cflag=0) works perfectly.

## What Works ✓

1. **Build System**
   - ✓ Compiles cleanly with headless build script
   - ✓ No SDL dependencies (correct for headless mode)
   - ✓ Generates Mach-O 64-bit ARM64 executable (1.0MB)
   - ✓ All source files compile without errors

2. **Interpreter Mode (cflag=0)**
   - ✓ ALL programs work correctly (calc, echo, cat, sh, benchmark)
   - ✓ Benchmark completes in 13.3 seconds
   - ✓ Produces correct results for all tests

3. **JIT Infrastructure**
   - ✓ Preamble code generation (entry point)
   - ✓ Two-pass compilation (sizing + code generation)
   - ✓ Literal pool management
   - ✓ Macro functions compile (macfrp, macret, maccase, etc.)
   - ✓ macOS MAP_JIT memory allocation works
   - ✓ Instruction encoding verified correct (ADD, LDR, STR, etc.)

## What's Broken ✗

**JIT Mode (cflag 1-9): ALL programs crash with segmentation fault**

### Crash Pattern
- Crashes consistently after 2-3 successful `mframe` (module frame) calls
- Corruption manifests as: `*R.s = R.s + 8` (pointer points to itself + 8 bytes)
- Register X20 (RMP - Module Pointer) contains incorrect value during execution

### Root Causes Identified

1. **Register Corruption During Execution**
   - RMP (X20) gets overwritten with stack address instead of module pointer
   - Preamble loads correct values initially
   - Something during JIT execution corrupts X20

2. **Missing RM Reloads** (FIXED)
   - RM (cached R.M) wasn't being reloaded after interpreter callbacks
   - Added reloads to: punt(), macmcal(), macmfra(), macfram(), macfrp()

3. **Missing Register Saves/Restores** (FIXED)
   - Preamble must save callee-saved registers X19-X22 (ARM64 AAPCS64 requirement)
   - Must restore before returning to interpreter/C code
   - Added STP_PRE/LDP_POST in preamble and macret

4. **Potential Lea+AIMM Bug** (REVERTED)
   - ARM32 has special handling for `Lea` with immediate operands
   - Attempted fix caused issues, reverted for now

## Fixes Applied

### libinterp/comp-arm64.c

1. **Line 1923-1924**: Re-enabled register saves in preamble
   ```c
   emit(STP_PRE(X19, X20, SP, -32));
   emit(STP(X21, X22, SP, 16));
   ```

2. **Line 1951**: Added R.M load to preamble
   ```c
   emit(LDR_UOFF(RM, RREG, O(REG, M)));
   ```

3. **Line 1084**: Added RM reload in punt() after interpreter calls
   ```c
   mem(Ldw, O(REG, M), RREG, RM);
   ```

4. **Lines 2005, 2163, 2219, 2238**: Added RM reloads to all macros
   - macfrp, macmcal, macfram, macmfra

5. **Lines 2095-2096, 2089-2090**: Re-enabled register restores in returns
   ```c
   emit(LDP(X21, X22, SP, 16));
   emit(LDP_POST(X19, X20, SP, 32));
   ```

### libinterp/xec.c

- Added comprehensive debug logging to mframe() (can be removed later)

## Current Investigation Status

### Verified Facts

1. **Preamble encoding is CORRECT**
   - Instruction [7]: `f9400ab3` = LDR X19, [X21, #16] ✓ (loads R.FP)
   - Instruction [8]: `f94006b4` = LDR X20, [X21, #8] ✓ (loads R.MP)
   - Instruction [9]: `f9401ab6` = LDR X22, [X21, #48] ✓ (loads R.M)

2. **REG struct offsets are CORRECT**
   - O(REG, PC) = 0, O(REG, MP) = 8, O(REG, FP) = 16, O(REG, M) = 48

3. **Register reloads happen**
   - After every macro that calls interpreter
   - Values are correct in R struct

4. **Corruption pattern**
   - R.MP value (in R struct) is CORRECT: `100844cb0`
   - RMP value (in X20 register) is WRONG: contains stack address `~1007a0fe0`
   - When opwld computes `320(mp)`, it uses corrupted X20: `stack_addr + 320`
   - Result: R.s points to stack instead of module data

### Unresolved Mystery

**How does X20 get corrupted?**

Possibilities:
1. Stack overflow corrupting saved registers at [SP+16]
2. Generated code accidentally using X20 as scratch register
3. Incorrect stack pointer management in macros
4. ABI violation in interpreter callbacks
5. Missing memory barrier or cache coherency issue

## Test Results Log

```
Test: calc.dis with "1+1"
Mode: cflag=0 (interpreter)
Result: ✓ PASS - outputs "2"

Test: calc.dis with "1+1"
Mode: cflag=1 (JIT)
Result: ✗ FAIL - Segmentation violation after 2-3 mframe calls

Test: jitbench.dis
Mode: cflag=0 (interpreter)
Result: ✓ PASS - 13,283ms, all tests pass

Test: jitbench.dis
Mode: cflag=1 (JIT)
Result: ✗ FAIL - Segmentation violation

Test: echo.dis, cat.dis, sh.dis
Mode: cflag=0
Result: ✓ ALL PASS

Test: echo.dis, cat.dis, sh.dis
Mode: cflag=1
Result: ✗ ALL FAIL - same segfault pattern
```

## Detailed Error Analysis

### Third mframe Call Debug Output
```
JIT punt: R.s=1007a81a0 *R.s=1007a81a8 R.m=1006d0a40 R.t=3
mframe: R.s=1007a81a0 *R.s=1007a81a8 ml=1007a81a8 o=3
  R.MP=100844cb0 R.M=100844c30 R.M->MP=100844cb0
  R.s-R.MP=-641808 ml->nlinks=320 (garbage)
```

**Analysis:**
- Instruction source: `320(mp)` (should be RMP+320)
- Expected R.s: `100844cb0 + 320 = 100844dd0`
- Actual R.s: `1007a81a0` (stack address!)
- Implies RMP (X20) = `1007a81a0 - 320 = 1007a0fe0` (stack address)

### Instruction Sequence Leading to Crash
```
107: mframe 320(mp), $4, 216(fp)   ✓ Works
108-110: Various frame operations        ✓ Work
111: mcall 216(fp), $4, 320(mp)     ✓ Works, reloads RMP
112-114: More operations                 ✓ Work
115: mframe 320(mp), $3, 216(fp)   ✗ CRASHES - X20 corrupted
```

## Comparison with ARM32 JIT

The 32-bit ARM JIT (comp-arm.c) is known to work. Key structural differences:

1. ARM32 uses unified `opx()` function for operand handling
2. ARM64 split into `opwld()` and `opwst()`
3. ARM32 has different register allocation (R4-R7 vs X19-X22)
4. ARM32 uses different calling convention (AAPCS32 vs AAPCS64)

## Next Steps for Resolution

### Immediate Actions Needed

1. **Verify stack integrity**
   - Check if macro functions are corrupting stack beyond SP+24
   - Verify SP is correctly maintained across all operations
   - Add stack canary values to detect corruption

2. **Audit X20 usage**
   - Search all code generation for accidental X20 writes
   - Verify no generated instruction uses X20 as destination except reloads
   - Check if RTA or RCON accidentally map to X20

3. **Compare with working implementation**
   - Test if ARM32 JIT works on a 32-bit system
   - Port working patterns from ARM32 more carefully
   - Consider if ARM64 needs different approach

4. **Add comprehensive register checking**
   - After every macro call, verify X19-X22 contain expected values
   - Add assertions that X20 == R.MP
   - Log any discrepancies immediately

### Long-term Considerations

1. **Consider fresh rewrite**
   - Current port may have subtle architectural misunderstandings
   - Could benefit from ground-up ARM64-native design

2. **Formal verification**
   - Add unit tests for individual opwld/opwst cases
   - Test each instruction type in isolation
   - Build test harness for JIT code generation

3. **Alternative approach**
   - Consider LLVM JIT backend
   - Or simpler "threaded code" approach vs full native JIT

## Files Modified

- `libinterp/comp-arm64.c` - Multiple fixes, still broken
- `libinterp/xec.c` - Debug logging added
- `ARM64-JIT-DEBUG-NOTES.md` - Detailed debugging log
- `JIT-64BIT-STATUS.md` - This file

## Performance Baseline

With interpreter (cflag=0):
- Native C benchmark: 107ms
- Dis interpreter: 13,283ms
- Slowdown: 124x vs native C

Expected with working JIT (based on other architectures):
- JIT execution: ~500-2000ms estimated
- Speedup: 6-26x vs interpreter

## Conclusion

The ARM64 JIT implementation has core functionality in place but suffers from register corruption during execution.

**ROOT CAUSE (Evening Discovery):** C code corrupts X19-X22 because Apple clang doesn't support `-ffixed-xNN` flags for macOS targets, despite listing them in `--help`. The flags work on Linux/GCC but fail on macOS with "unsupported option for target arm64-apple-darwin".

**Current recommendation:** Use cflag=0 (interpreter mode) for production. JIT requires either:
1. Using caller-saved registers (X9-X15) instead of X19-X22
2. Save/restore X19-X22 around all C function calls
3. Switch to Homebrew GCC which supports `-ffixed-xNN` properly

---

*Investigation conducted by: Claude Sonnet 4.5 (1M context)*
*Date: 2026-01-18*
