# ARM64 JIT - Solution Options Analysis

**Date:** 2026-01-18
**Problem:** C code corrupts X19-X22 because Apple clang doesn't support `-ffixed-xNN` on macOS

## Three Proposed Solutions

### Solution 1: Use Caller-Saved Registers (X9-X15)

**Approach:** Change JIT register allocation from callee-saved (X19-X22) to caller-saved (X9-X15)

**Changes Required:**
```c
// Current (BROKEN on macOS):
#define RFP   X19    // Dis Frame Pointer
#define RMP   X20    // Module Pointer
#define RREG  X21    // Pointer to REG struct
#define RM    X22    // Cached R.M

// Proposed:
#define RFP   X9     // Dis Frame Pointer
#define RMP   X10    // Module Pointer
#define RREG  X11    // Pointer to REG struct
#define RM    X12    // Cached R.M
```

**Pros:**
- ✅ **Most portable** - works on ALL platforms (macOS, Linux, BSD)
- ✅ **No compiler flag requirements** - no `-ffixed-xNN` needed
- ✅ **Clean solution** - registers are meant to be caller-saved
- ✅ **Matches ARM64 ABI** - X9-X15 are scratch/temporary registers
- ✅ **Relatively small code change** - just update #defines and recompile
- ✅ **No runtime overhead** - no extra save/restore instructions

**Cons:**
- ⚠️ Caller-saved means JIT must save them before calling C functions
- ⚠️ Need to audit all `BLR` calls to ensure proper save/restore
- ⚠️ Slightly more instructions around C callbacks
- ⚠️ Less "permanent" storage (but that's the design intent)

**Implementation Effort:** Low (1-2 hours)
- Change 4 #define lines
- Verify all macro functions save/restore before BLR
- Test thoroughly

**Risk:** Low - well-defined approach, follows ARM64 ABI

---

### Solution 2: Save/Restore X19-X22 Around C Calls

**Approach:** Keep current register allocation but wrap every C function call with save/restore

**Changes Required:**
```c
// Before every BLR to C functions:
emit(STP_PRE(X19, X20, SP, -32));  // Save to stack
emit(STP(X21, X22, SP, 16));

// ... BLR to C function ...

emit(LDP(X21, X22, SP, 16));       // Restore from stack
emit(LDP_POST(X19, X20, SP, 32));
```

**Pros:**
- ✅ Keeps current register allocation (X19-X22)
- ✅ Works on macOS without compiler flag support
- ✅ Explicit control over register preservation
- ✅ Easy to verify correctness (check each BLR site)

**Cons:**
- ❌ **Runtime overhead** - 4 extra instructions per C callback
- ❌ **Many code sites** - punt(), macfrp(), macmcal(), macfram(), macmfra(), macret()
- ❌ **Easy to miss** - future code changes could forget to save/restore
- ❌ **Stack manipulation** - more complex sp management
- ❌ **Violates ABI** - callee-saved registers shouldn't need this

**Implementation Effort:** Medium (3-4 hours)
- Add STP/LDP around ~10-15 BLR sites
- Verify stack offset calculations
- Test edge cases (nested calls, exceptions)

**Risk:** Medium - easy to miss a site, stack corruption if offsets wrong

---

### Solution 3: Use Homebrew GCC

**Approach:** Switch from Apple clang to GCC from Homebrew which properly supports `-ffixed-xNN`

**Changes Required:**
```bash
# Install GCC
brew install gcc

# Update mkfiles to use gcc-13 instead of cc
CC = gcc-13 -c -arch arm64
CFLAGS = ... -ffixed-x19 -ffixed-x20 -ffixed-x21 -ffixed-x22
```

**Pros:**
- ✅ **No code changes** - just compiler flags
- ✅ **Proven approach** - works on Linux, should work here
- ✅ **No runtime overhead** - compiler handles it
- ✅ **Clean separation** - JIT and C code independent

**Cons:**
- ❌ **External dependency** - requires Homebrew and GCC installation
- ❌ **Build complexity** - users must install GCC
- ❌ **Toolchain mismatch** - mixing Apple SDK with GCC can cause issues
- ❌ **Compatibility unknown** - GCC + macOS + ARM64 less tested than clang
- ❌ **Framework linking** - GCC may have issues with `-framework` flags
- ❌ **Not portable** - breaks standard macOS build workflow

**Implementation Effort:** Medium-High (4-6 hours)
- Install and test GCC
- Update all mkfiles
- Fix any GCC-specific compatibility issues
- Test across different macOS versions

**Risk:** High - unknown toolchain issues, framework linking problems

---

## Recommendation

**Solution 1 (Caller-Saved Registers)** is the clear winner:

1. **Portable** - works everywhere, no platform-specific hacks
2. **Low risk** - well-defined, follows ARM64 ABI conventions
3. **Fast implementation** - mostly just changing #defines
4. **No dependencies** - works with stock Apple clang
5. **Maintainable** - future developers will understand it

The slight overhead of saving/restoring around C calls is negligible compared to the simplicity and portability benefits.

### Implementation Plan for Solution 1:

1. Change register allocation in comp-arm64.c:
   - RFP: X19 → X9
   - RMP: X20 → X10
   - RREG: X21 → X11
   - RM: X22 → X12

2. Update preamble() to not save/restore X9-X12 (they're caller-saved)

3. Add save/restore around BLR in:
   - punt() - before calling interpreter functions
   - macfrp() - before rdestroy()
   - macmcal(), macfram(), macmfra() - before rmcall/rmfram
   - macret() - before destroy callbacks

4. Test with all programs (calc, echo, cat, sh, benchmark)

**Estimated time:** 2-3 hours including testing
**Success probability:** 95%+

---

*Analysis by: Claude Sonnet 4.5*
*Date: 2026-01-18*
