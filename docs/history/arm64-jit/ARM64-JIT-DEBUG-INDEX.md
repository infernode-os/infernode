# ARM64 JIT Debugging - Complete Index
**Last Updated:** 2026-01-19
**Branch:** feature/jit-64bit
**Purpose:** Navigation guide for all ARM64 JIT debugging documentation

## Quick Status

**Current State:** JIT works but blocked on AXIMM storage scaling
**Branch Commit:** 54cdab2
**Working Baseline:** 159e360 (size 8 array, programs output correctly)
**Blocking Issue:** X9=1 corruption with array size ≥33

## Documentation Roadmap

### Start Here (Most Recent)
1. **ARM64-JIT-FINAL-STATUS-2026-01-19.md** ⭐ **READ THIS FIRST**
   - Comprehensive final status after 14+ hours debugging
   - What works, what doesn't, all approaches tested
   - X9 corruption mystery explained
   - Recommendations for next steps

2. **AXIMM-PROVEN-FACTS.md**
   - Test methodology and proven results
   - Exact array size boundaries (≤32 works, ≥33 fails)
   - SEGV pattern analysis (addr=0x24821, X9=1)
   - No speculation, only proven facts

3. **AXIMM-DEBUG-SESSION.md**
   - Detailed log of debugging attempts
   - Root cause hypotheses
   - What was tried and why it failed

### Historical Context

4. **ARM64-JIT-RESUME-NOTES.md**
   - Updated summary for resuming work
   - Current status and next steps
   - Quick reference for where we left off

5. **ARM64-JIT-BREAKTHROUGH.md**
   - Initial success with R.t corruption fix
   - Commit 159e360 achievements
   - Before AXIMM scaling issue was discovered

6. **ARM64-JIT-SESSION-2026-01-18.md**
   - Previous debugging session
   - Caller-saved register implementation
   - Root cause discovery process

### Technical Analysis

7. **ARM64-JIT-EXIT-CRASH-ANALYSIS.md**
   - Analysis of cleanup crashes
   - Frame*/Modlink* confusion
   - mframe() crash investigation

8. **ARM64-JIT-FINAL-ANALYSIS.md**
   - calc.dis investigation
   - Why calc doesn't output results
   - Module loading failure analysis

9. **emu/MacOSX/docs/ARM64_JIT_EXIT_CRASH_INVESTIGATION.md**
   - Detailed exit crash investigation
   - R.s corruption identified
   - IFRAME/IMFRAME conflict theory

### Earlier Work

10. **ARM64-JIT-SOLUTIONS.md**
    - Solution options analysis
    - Caller-saved vs callee-saved registers
    - Why Solution #1 was chosen

11. **ARM64-JIT-TEST-RESULTS.md**
    - Test results from caller-saved implementation
    - Working programs documented
    - 75% success rate before AXIMM issue

12. **ARM64-JIT-DEBUG-NOTES.md**
    - Early debugging notes
    - Register corruption investigation
    - Apple clang limitation discovery

### Related Documentation

13. **docs/PORTING-ARM64.md**
    - General ARM64 porting guide
    - Platform-specific considerations

## Key Commits

### Working Baseline
- **159e360** - "fix: Resolve ARM64 JIT R.t corruption causing SEGV crashes"
  - **USE THIS** as baseline for testing
  - Array size 8, reset per module
  - echo/cat/sh work correctly

### Major Milestones
- **245daf9** - Caller-saved register implementation (before 159e360)
- **f63df1c** - Resume notes with breakthrough status
- **bdefeae** - mframe instrumentation, discovered X9 corruption

### Debug Attempts
- **b08577c** - Unique index management
- **b40bc11** - Heap allocation
- **b520108** - Loader instrumentation
- **54cdab2** - Final status (HEAD)

## Testing Artifacts

### Test Scripts
- **test_aximm_sizes.sh** - Automated array size testing
- **compare_sizes.sh** - Compare code generation between sizes
- **test_mframe.lldb** - lldb script for mframe debugging
- **test_offsets.c** - Verify REG struct offsets

### Test Commands

**Test echo (baseline):**
```bash
echo "test" | ./emu/MacOSX/o.emu -r. -c1 dis/echo.dis
# Expected: outputs "test", panics during cleanup
```

**Test calc (blocked):**
```bash
echo "2+2" | ./emu/MacOSX/o.emu -r. -c1 dis/calc.dis
# Expected with size 8: no output (hits AXIMM limit)
# Expected with size 33+: SEGV with X9=1
```

**Compare sizes:**
```bash
# Edit libinterp/comp-arm64.c line 537
# Change: static WORD aximm_storage[N];
rm -f emu/MacOSX/*.o emu/MacOSX/o.emu
./build-macos-headless.sh
echo "test" | ./emu/MacOSX/o.emu -r. -c1 dis/echo.dis
```

## Debugging Checklist for Next Session

### Before Starting
- [ ] Read ARM64-JIT-FINAL-STATUS-2026-01-19.md
- [ ] Read AXIMM-PROVEN-FACTS.md
- [ ] Review commit 159e360 (working baseline)
- [ ] Understand X9=1 corruption pattern

### Investigation Approaches Not Yet Tried
- [ ] lldb watchpoint on X9 register through compile() return
- [ ] Disassemble compile() function epilogue (size 8 vs size 33)
- [ ] Compare .o file differences (objdump)
- [ ] Memory watchpoint on aximm_storage array
- [ ] Test on Linux ARM64 (not macOS)
- [ ] Test with GCC instead of Clang
- [ ] Examine linker map files
- [ ] Try __attribute__((aligned(64))) on array
- [ ] Put array in separate .c file
- [ ] Use #pragma to control section placement

### Questions to Answer
- [ ] Why exactly value 1? (boolean? enum? return value misinterpreted?)
- [ ] Why exactly 256-byte boundary? (page? cache? ABI?)
- [ ] What changes in binary layout between size 32 and 33?
- [ ] Is this macOS-specific or ARM64-general?
- [ ] Does ARM32 JIT have similar issues?

## Critical Code Locations

### The Bug Location
**File:** libinterp/xec.c:390
```c
nsp = R.SP + t->size;  // SEGV here with t=0x24809
```

### AXIMM Storage
**File:** libinterp/comp-arm64.c:534-538
```c
static WORD aximm_storage[N];  // Size N is the problem
static int aximm_next;
```

### AXIMM Handling
**File:** libinterp/comp-arm64.c:1063-1076 (punt() function, case AXIMM:)

### Compilation Entry
**File:** libinterp/comp-arm64.c:2478 (compile() function)

### Module Loading
**File:** libinterp/loader.c:438 (linkmod() calls compile())

## Performance Baseline (Not Yet Measured)

With interpreter (cflag=0):
- jitbench: 13.3 seconds
- Native C: 107ms
- Slowdown: 124x

Expected with working JIT:
- 6-26x speedup vs interpreter
- ~500-2000ms estimated

## Contact Points for Help

- Inferno community / 9fans mailing list
- Plan 9 from Bell Labs community
- ARM64 ABI experts
- macOS platform specialists
- Compiler optimization experts

## Repository State

**Branch:** feature/jit-64bit
**Commits ahead of master:** 15
**Modified files:** libinterp/comp-arm64.c, libinterp/xec.c, libinterp/loader.c
**Build system:** Confirmed working (build-macos-headless.sh)
**Test programs:** dis/echo.dis, dis/cat.dis, dis/sh.dis, dis/calc.dis

## How to Resume

1. **Read this index**
2. **Read ARM64-JIT-FINAL-STATUS-2026-01-19.md**
3. **Read AXIMM-PROVEN-FACTS.md**
4. **Check out commit 159e360** to see working baseline
5. **Review approach checklist above**
6. **Pick a new debugging strategy**
7. **Document everything** as you go
8. **Commit frequently** with detailed messages

## Files Modified from Baseline

**From commit 159e360 to HEAD (54cdab2):**
- libinterp/comp-arm64.c - Extensive debugging instrumentation
- libinterp/xec.c - mframe debug output
- libinterp/loader.c - Loader instrumentation
- Multiple .md documentation files

**To return to working baseline:**
```bash
git checkout 159e360 -- libinterp/comp-arm64.c libinterp/xec.c
# Then rebuild
```

## Success Criteria for Resolution

- [ ] Emuinit compiles without hitting AXIMM limit
- [ ] calc.dis can load Math module
- [ ] calc.dis outputs computation results (e.g., "2+2" → "4")
- [ ] All programs exit cleanly (no panic)
- [ ] No SEGV, no X9 corruption
- [ ] Performance benchmarks show JIT speedup

## Current Hypotheses (Unproven)

1. **Platform bug** - macOS ARM64 Clang issue with large static arrays
2. **ABI violation** - Function epilogue corrupted with certain BSS layouts
3. **Undiscovered instruction bug** - Some generated code is wrong
4. **Memory layout issue** - 256-byte boundary has special significance

---

**This index should provide complete context for resuming ARM64 JIT work.**

*Created by: Claude Sonnet 4.5 (1M context)*
*Date: 2026-01-19*
*Total documentation: 16 files + 15 commits with detailed messages*
