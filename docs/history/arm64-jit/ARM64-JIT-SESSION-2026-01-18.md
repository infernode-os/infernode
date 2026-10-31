# ARM64 JIT Debugging Session Summary
**Date:** 2026-01-18 Evening
**Duration:** ~4 hours intensive debugging
**Status:** Root cause identified, fix implemented (pending testing)

## Session Overview

Continued debugging the ARM64 JIT that was crashing with segmentation faults. Through systematic debugging with lldb, signal handlers, and standalone tests, identified the definitive root cause and implemented a complete fix.

## Root Cause Discovery

### The Smoking Gun
Used lldb to examine registers at crash point in `mframe()`:
```
X19 = 0x10035daa0  (pointer, but wrong value)
X20 = 0x0000000004 (garbage!)
X21 = 0x1001c09e0  (correct - &R)
X22 = 0x1001bfe3c  (WRONG - this is &cflag, not R.M!)
```

**Conclusion:** C code was using X19-X22 as scratch registers, overwriting JIT's VM state.

### Apple Clang Limitation

The `-ffixed-x19` through `-ffixed-x22` compiler flags:
- ✅ Listed in `clang --help` for AArch64/RISC-V
- ✅ Work on Linux with GCC
- ❌ **Fail on macOS:** `error: unsupported option for target 'arm64-apple-darwin24.5.0'`

This is a macOS-specific limitation where Apple's clang doesn't implement these flags despite advertising them.

### Verification Process

Created standalone tests proving:
1. ✅ All preamble LDR/STR encodings are mathematically perfect
2. ✅ MOVZ/MOVK sequences correctly construct &R pointer
3. ✅ REG struct offsets are correct (PC=0, MP=8, FP=16, M=48)
4. ✅ MAP_JIT and basic LDR operations work correctly
5. ❌ C code corrupts X19-X22 when called from JIT

## Three Solution Options Analyzed

### Solution 1: Caller-Saved Registers ⭐ **CHOSEN**
- Change RFP/RMP/RREG/RM from X19-X22 to X9-X12
- Most portable, no compiler flags needed
- ~2-3 hours implementation
- **Implemented in commit 245daf9**

### Solution 2: Save/Restore Around C Calls
- Keep X19-X22, add STP/LDP around each BLR
- Runtime overhead, error-prone
- Rejected as inferior to Solution #1

### Solution 3: Use Homebrew GCC
- External dependency, toolchain risks
- Rejected as too complex and non-portable

## Implementation (Commit 245daf9)

### Register Allocation Changed
```c
// Old (callee-saved, broken on macOS):
#define RFP   X19
#define RMP   X20
#define RREG  X21
#define RM    X22

// New (caller-saved, works everywhere):
#define RFP   X9
#define RMP   X10
#define RREG  X11
#define RM    X12
```

### Code Changes

**1. Preamble (preamble):**
- Removed STP_PRE/STP saves (not needed for caller-saved)
- Updated comments to reflect new register allocation
- Kept load sequence (now loads into X9-X12)

**2. Punt Function (punt):**
- Added STP_PRE/LDP_POST around BLR to interpreter functions
- Saves X9-X12 before C call, restores after
- Removed old X19-X22 restore code

**3. Macro Functions:**
- **macfrp()**: Added save/restore around rdestroy()
- **macret()**: Added save/restore around 2x destroy() callbacks
- **macmcal()**: Added save/restore around rmcall()
- **macfram()**: Added save/restore around initializer() and extend()
- **macmfra()**: Added save/restore around rmfram()

All BLR calls to C functions now protected with:
```c
emit(STP_PRE(RFP, RMP, SP, -32));   // Save X9, X10
emit(STP(RREG, RM, SP, 16));        // Save X11, X12
emit(BLR(RA0));                     // Call C
emit(LDP(RREG, RM, SP, 16));        // Restore X11, X12
emit(LDP_POST(RFP, RMP, SP, 32));   // Restore X9, X10
```

## Testing Status

**Pending:** Build system needs library rebuilds before testing can proceed.

**Expected outcome:** JIT should work correctly since:
- C code can safely use X19-X22 (not reserved)
- JIT's X9-X12 are saved/restored around all C callbacks
- Follows proper ARM64 ABI conventions

## Files Modified

- `libinterp/comp-arm64.c` - Register allocation + save/restore logic
- `mkconfig` - Fixed to MacOSX/arm64 (was Linux/amd64)
- `ARM64-JIT-DEBUG-NOTES.md` - Updated with root cause
- `JIT-64BIT-STATUS.md` - Updated with solution options
- `ARM64-JIT-SOLUTIONS.md` - New file with detailed analysis

## Key Insights

1. **Apple clang advertises features it doesn't implement** - the `-ffixed` flags are in help but don't work
2. **Caller-saved is better anyway** - more portable, no special compiler requirements
3. **lldb register inspection was critical** - seeing X22=&cflag was the breakthrough
4. **User's skepticism was valuable** - caught assumption that JIT was working when it wasn't

## Next Steps

1. Rebuild all libraries with proper mkconfig settings
2. Test with calc, echo, cat, sh programs
3. Run jitbench to verify performance improvement
4. If successful, clean up debug code
5. Consider whether to rebase/amend commit c73af03

## Commits Created This Session

- `22789d0` - Root cause identification (Apple clang limitation)
- `afccd18` - Solution analysis document
- `245daf9` - Implementation of caller-saved register fix

---

*Session conducted by: Claude Sonnet 4.5 (1M context)*
*Total commits: 3*
*Lines changed: ~150*
*Root cause: Identified ✅*
*Fix: Implemented ✅*
*Tested: Pending build*
