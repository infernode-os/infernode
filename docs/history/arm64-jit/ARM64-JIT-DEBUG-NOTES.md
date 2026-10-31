# ARM64 JIT Debugging Notes

## Status: BROKEN - Under Active Development

The ARM64 JIT (comp-arm64.c) was initially committed with the claim it was tested and working, but this was incorrect. The JIT was never actually executed - settings caused the interpreter to run instead. When properly enabled with `-c1` or higher cflag values, the JIT crashes with segmentation faults.

## Environment
- **Platform**: macOS (Apple Silicon)
- **Architecture**: ARM64 (AArch64)
- **Build**: Successful (headless mode)
- **Test Date**: 2026-01-18

## Symptoms

### Primary Issue
**Crash in `mframe` function after several successful interpreter callbacks**

```
mframe: R.s=1024901a0 *R.s=1024901a8 ml=1024901a8 o=3
  ml->nlinks=320 &ml->nlinks=40
```

**Analysis:**
- R.s contains a valid stack address (0x1024901a0)
- The value stored at *R.s is `R.s + 8` (0x1024901a8) instead of a valid Modlink pointer
- This causes `ml->nlinks` to read garbage (320)
- Accessing `ml->links[3].frame` with corrupted ml causes segfault

### Test Results

| Test | cflag=0 (Interpreter) | cflag=1+ (JIT) |
|------|----------------------|----------------|
| calc.dis | ✓ Works (1+1=2) | ✗ Crashes |
| echo.dis | ✓ Works | ✗ Crashes |
| cat.dis | ✓ Works | ✗ Crashes |
| sh.dis | ✓ Works | ✗ Crashes |
| jitbench.dis | ✓ Works | ✗ Crashes |

**Pattern:** ALL programs crash in JIT mode after a few successful interpreter punts.

## Debugging Work Completed

### 1. Initial Investigation
- ✓ Build system works correctly
- ✓ Verified preamble code generation (register saves, &R loading)
- ✓ Verified punt mechanism works (successfully calls interpreter functions)
- ✓ Verified struct sizes: WORD=8, Modl=16, Modlink=72
- ✓ Verified struct offsets correct

### 2. Fixes Attempted

#### Register Save/Restore (PARTIAL FIX)
- **Problem**: ARM64 AAPCS64 requires callee-saved registers X19-X28 preserved
- **Attempted Fix**: Added STP_PRE/LDP_POST to save/restore X19-X22 in preamble
- **Result**: Still crashes (but this is required for correctness)
- **Status**: Commented out temporarily for debugging

#### R.M Cache Reload (PARTIAL FIX)
- **Problem**: RM (cached R.M) not reloaded after interpreter punts
- **Fix**: Added `mem(Ldw, O(REG, M), RREG, RM)` after punt calls
- **Result**: Still crashes but may have helped
- **Status**: KEPT - this is necessary

#### Preamble VM State Loading (FIX APPLIED)
- **Problem**: Original preamble didn't load R.M into RM register
- **Fix**: Added `emit(LDR_UOFF(RM, RREG, O(REG, M)))` to preamble
- **Result**: Still crashes but more state is correct
- **Status**: KEPT

### 3. Debug Output Added
- Preamble code dump showing all instructions
- Struct size verification (WORD, Modl, Modlink)
- REG struct offset verification
- mframe detailed logging showing R.s, *R.s, ml values
- punt SRCOP parameter logging

## Root Cause Analysis

### The Corrupted Pointer Problem

**Observation**: On the 3rd mframe call:
```
R.s = 0x1024901a0          (valid stack address)
*R.s = 0x1024901a8          (= R.s + 8, WRONG!)
```

**This pattern indicates:**
- Some JIT instruction is storing `(address + 8)` instead of loading the value at that address
- Most likely in a MOVMP, MOVW, or similar pointer move operation
- Could be a bug in `opwld()` or `opwst()` when handling indirect addressing

**Hypothesis**: When the JIT compiles an instruction to store a module pointer, it's computing the SOURCE ADDRESS instead of loading the value from that address, then adding 8 bytes incorrectly.

### Comparison Needed

The 32-bit ARM JIT (comp-arm.c) is known to work. Key differences to investigate:
1. How does ARM32 handle AIND (indirect) addressing?
2. Are there pointer size assumptions (32-bit vs 64-bit)?
3. How does ARM32's `opwld()` differ from ARM64's?

## Next Steps

1. **Systematic comparison with comp-arm.c**
   - Compare opwld, opwst, mid implementations line-by-line
   - Check for 32-bit vs 64-bit pointer handling differences
   - Verify indirect addressing logic

2. **Trace specific failing instruction**
   - Add instruction-level logging to identify WHICH instruction stores the bad pointer
   - Use cflag=5 with full disassembly
   - Compare with interpreter execution

3. **Memory operation audit**
   - Review all `mem()` calls for Lea operations
   - Check if indirect addressing is adding offsets incorrectly
   - Verify that Ldw loads 64-bit pointers, not 32-bit values

4. **Consider simpler test case**
   - Create minimal Dis program that just does module operations
   - Isolate the exact instruction sequence that fails

## Code Locations

### Key Files
- `libinterp/comp-arm64.c` - ARM64 JIT compiler (2500+ lines)
- `libinterp/comp-arm.c` - ARM32 JIT (working reference)
- `libinterp/xec.c` - Interpreter including mframe() at line 355
- `include/interp.h` - REG, Modlink, Modl struct definitions

### Critical Functions
- `opwld()` (comp-arm64.c:868) - Load source operand
- `opwst()` (comp-arm64.c:908) - Store destination operand
- `mem()` (comp-arm64.c:748) - Memory operations (Lea, Ldw, Stw)
- `punt()` (comp-arm64.c:969) - Call interpreter for complex ops
- `preamble()` (comp-arm64.c:1850) - JIT entry point

### Addressing Modes (isa.h)
```
AFP   = 0x01  (Frame Pointer relative)
AMP   = 0x02  (Module Pointer relative)
AIMM  = 0x02  (Immediate)
AIND  = 0x04  (Indirect)
AMASK = 0x07

SRC(x) = x << 3
DST(x) = x << 0
UXSRC(x) = x & (AMASK << 3) = x & 0x38
```

### REG Struct Offsets (64-bit)
```
O(REG, PC) = 0
O(REG, MP) = 8
O(REG, FP) = 16
O(REG, SP) = 24
O(REG, M) = 48
O(REG, xpc) = 64
O(REG, s) = 72
O(REG, d) = 80
O(REG, m) = 88
O(REG, t) = 96
```

## Technical Details

### Preamble Code (10 words)
```assembly
a9be53f3    STP X19, X20, [SP, #-32]!  (save registers, commented out)
a9015bf5    STP X21, X22, [SP, #16]     (save registers, commented out)
d2813c15    MOVZ X21, #0x09e0           (load &R bits 0-15)
f2a062f5    MOVK X21, #0x0317, LSL#16   (load &R bits 16-31)
f2c00035    MOVK X21, #0x0001, LSL#32   (load &R bits 32-47)
f2e00015    MOVK X21, #0x0000, LSL#48   (load &R bits 48-63)
f90022be    STR X30, [X21, #64]         (save LR to R.xpc)
f9400ab3    LDR X19, [X21, #16]         (load R.FP -> X19/RFP)
f94006b4    LDR X20, [X21, #8]          (load R.MP -> X20/RMP)
f9401ab6    LDR X22, [X21, #48]         (load R.M -> X22/RM)
f94002a0    LDR X0, [X21, #0]           (load R.PC -> X0)
d61f0000    BR X0                       (jump to compiled code)
```

### Confirmed Working
- Preamble correctly loads &R, saves LR, loads VM state
- Punt mechanism successfully calls interpreter
- Interpreter functions (mframe, etc.) execute when called
- First 2 mframe calls receive CORRECT pointers
- RM reload after punts (attempted fix)

### Still Broken
- 3rd mframe call receives corrupted pointer (*R.s = R.s + 8)
- This suggests JIT is storing wrong value somewhere
- Likely in a MOVMP, MOVW, or frame setup instruction

## References

### Verified Constants
- sizeof(WORD) = 8 (pointer-sized, correct for 64-bit)
- sizeof(Modl) = 16 (2 pointers)
- sizeof(Modlink) = 72
- sizeof(Frame) = 32 (4 pointers)
- sizeof(Heap) = 32 (verified via offsetof)

### Working Comparison
- Native C benchmark: 107ms
- Interpreter (cflag=0): 13,283ms total, ALL programs work
- JIT (cflag=1+): Crashes before completion

## Open Questions

1. Is there a test case known to work on the 32-bit ARM JIT we can use as reference?
2. Are there any 64-bit JIT implementations for other architectures that work?
3. Is there existing test infrastructure or formal verification for JIT?

## Recent Changes
- 2026-01-18 Evening: **ROOT CAUSE IDENTIFIED** - C compiler uses X19-X22 as scratch registers
  - lldb debugging showed X22 = &cflag instead of R.M at crash
  - X19/X20 contain garbage values (0x40, 0x3) when called from JIT
  - Apple clang does NOT support `-ffixed-xNN` for arm64-apple-darwin target
  - Flag exists in `clang --help` but errors with "unsupported option for target"
  - Verified via standalone tests that LDR/STR/preamble encoding is 100% correct
  - Problem is C functions corrupt JIT registers during callbacks
- 2026-01-18: Identified corrupted pointer bug, added debug output
- 2026-01-18: Attempted register save/restore fix (not root cause)
- 2026-01-18: Added RM reload after punts (helpful but not sufficient)
- 2026-01-17: Initial ARM64 JIT commit (**INCORRECT - claimed working but untested**)

## Critical Discovery: Apple Clang Limitation

The `-ffixed-x19`, `-ffixed-x20`, `-ffixed-x21`, `-ffixed-x22` compiler flags are listed in `clang --help` and work on Linux/GCC, but **fail on macOS** with:
```
clang: error: unsupported option '-ffixed-x19' for target 'arm64-apple-darwin24.5.0'
```

This means all C code in libinterp and emu freely uses X19-X22, corrupting the JIT VM state.

---

*Last Updated: 2026-01-18 Evening by Claude Sonnet 4.5*
