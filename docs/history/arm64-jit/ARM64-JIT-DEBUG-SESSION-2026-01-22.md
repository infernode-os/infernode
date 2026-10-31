# ARM64 JIT Debugging Session - 2026-01-22

## Overview

This document captures the debugging session for the ARM64 JIT compiler crash on Linux ARM64 (Jetson AGX Orin). The goal is to enable someone to pick up where we left off.

## Environment

- **Platform**: Linux ARM64 (Jetson AGX Orin)
- **Kernel**: 5.15.148-tegra
- **Branch**: `feature/arm64-jit`
- **Previous work**: JIT was developed on macOS ARM64, this session is porting to Linux

## Problem Description

### Symptom
When running any Dis program with JIT enabled (`-c1` or higher), the program output is correct but the system crashes during Emuinit module cleanup:

```
hello world
[Emuinit] Broken: "sys: segmentation violation addr=0x24821"
```

### Key Observations
1. **Program output is correct** - "hello world" prints successfully
2. **Crash happens after main program completes** - in Emuinit cleanup
3. **Same crash on both macOS and Linux** - same address 0x24821
4. **Without JIT (-c0), everything works** - confirmed this session
5. **Crash address**: 0x24821 = 0x24809 + 24, where 24 is `offsetof(Type, size)`

### Interpretation
The value 0x24809 is being used as a `Type*` pointer when it should be a valid heap address (like 0xffff80891a20). When the code tries to access `t->size`, it crashes.

## Fixes Applied This Session

### 1. Platform Detection in mkconfig
**File**: `mkconfig`
**Problem**: Hardcoded to `SYSHOST=MacOSX`
**Fix**: Auto-detect platform using uname:
```sh
SYSHOST=`{sh -c 'case $(uname -s) in Darwin) echo MacOSX;; *) uname -s;; esac'}
```
**Status**: Committed (73988cc3)

### 2. Linux Executable Memory Allocation
**File**: `libinterp/comp-arm64.c`
**Problem**: Non-Apple code paths used `malloc()` which doesn't provide executable memory
**Fix**: Changed to `mmap()` with `PROT_EXEC` at three locations:
- `preamble()` - comvec allocation
- `typecom()` - type initializer/destroyer code
- `compile()` - main JIT code buffer

**Status**: Committed (35825e39)

### 3. Literal Pool Size Counting
**File**: `libinterp/comp-arm64.c`, function `literal()`
**Problem**: `nlit++` only counted 1 slot, but 64-bit values need 2 u32int slots
**Fix**: Changed to `nlit += 2`
**Status**: Applied (uncommitted)

### 4. Memory Cleanup (munmap vs free)
**File**: `libinterp/comp-arm64.c`, function `compile()` bad: label
**Problem**: Linux now uses mmap, but cleanup used `free(base)`
**Fix**: Changed to `munmap(base, (n + nlit) * sizeof(*code))`
**Status**: Applied (uncommitted)

### 5. Cache Flush Coverage
**File**: `libinterp/comp-arm64.c`, end of `compile()`
**Problem**: `segflush()` only covered code area, not literal pool
**Fix**: Extended to `segflush(base, (n + nlit) * sizeof(*base))`
**Status**: Applied (uncommitted)

## What We Learned

### 1. IFRAME Instructions Are Punted
All IFRAME (module frame allocation) instructions in Emuinit use indirect addressing, not immediate:
```
IMFRAME: src add=0x41 UXSRC=0x0 s.ind=320 add&ARM=0x40 reg=0 d.ind=96
```
- `UXSRC=0x0` means source is NOT `SRC(AIMM)` (which would be 0x10)
- Therefore, ALL IFRAME instructions are punted to the interpreter via `punt()`

### 2. AXIMM Mode Uses literal() Function
When punt() handles AXIMM mode (third operand addressing), it calls:
```c
case AXIMM:
    literal((short)i->reg, O(REG, m));
    break;
```
This stores the immediate value (type index like 0, 1, 2, 3) in the literal pool and writes its address to `R.m`.

### 3. Interpreter's mframe() Function
The interpreter (`xec.c:mframe()`) reads:
```c
ml = *(Modlink**)R.s;   // Modlink pointer from R.s
o = W(m);               // Type index from *R.m
t = ml->links[o].frame; // Type* from links array
nsp = R.SP + t->size;   // CRASH HERE if t is garbage
```
If R.m points to wrong location, `o` is garbage, and `ml->links[o].frame` returns invalid Type*.

### 4. Type Pointers Are Valid During Compilation
Debug output shows all Type pointers are valid 48-bit addresses during both passes:
```
IFRAME pass0: type[8]=ffffa0011720 (size=224)
IFRAME pass1: type[8]=ffffa0011720 (size=224)
```
The pointers are identical between passes, ruling out pass inconsistency.

### 5. Literal Pool Values Are Being Set
The `literal()` function is called with correct values:
```
literal: imm=0 roff=88 litpool=ffffa02fc940
literal: imm=1 roff=88 litpool=ffffa02fc958
literal: imm=2 roff=88 litpool=ffffa02fc968
```
- `imm` = type index (0, 1, 2, 3, etc.) - looks correct
- `roff=88` = O(REG, m) offset - correct
- `litpool` = address where value will be stored - looks valid

### 6. flushcon() Patching Appears Correct
The literal pool addresses are being stored via con() and patched by flushcon():
```
flushcon: i=0 LDR@ffffa02fa014 -> const@ffffa02fbd4c disp=7480 val=ffffa02fc938
flushcon: i=3 LDR@ffffa02fa05c -> const@ffffa02fbd64 disp=7432 val=ffffa02fc940
```
Displacements look reasonable (7000-8000 bytes).

## Current Hypothesis

The crash involves the interpreter reading a garbage type index from R.m. Possible causes:

### Hypothesis A: Literal Pool Address Mismatch
The `literal()` function uses `con((uvlong)litpool, RTA, 0)` to load the litpool address. In pass 0, litpool points to a static placeholder array. In pass 1, it points to `base + n`. If these different addresses cause different code generation paths, there could be a size mismatch.

**Counter-evidence**: No phase error is reported, suggesting code sizes match.

### Hypothesis B: Runtime Address Calculation Error
The LDR_LIT instruction loads an address from the inline constant pool (via flushcon), then that address should point to the litpool area where the actual value is stored. If the flushcon patch computes wrong offset, wrong address is loaded.

**Counter-evidence**: flushcon debug output shows reasonable displacements.

### Hypothesis C: Value Not Written to Literal Pool
In pass 1, `literal()` writes:
```c
*litpool++ = (u32int)(imm);
*litpool++ = (u32int)(imm >> 32);
```
If this doesn't execute or writes to wrong location, the value at R.m would be garbage.

**Needs investigation**: Add debug to verify values are actually written.

### Hypothesis D: Stale Cache
Even though we call `segflush()`, the cache invalidation might not cover the literal pool properly, causing CPU to read stale data.

**Counter-evidence**: Extended segflush to cover literal pool area.

### Hypothesis E: Multiple Constant Pools Interfering
Each `literal()` call:
1. Adds litpool address to rcon.table (inline constant pool)
2. Writes actual value to litpool area

If there's interaction or ordering issue between these two pools, addresses could be wrong.

## Key Files and Line Numbers

### libinterp/comp-arm64.c
- `literal()`: Lines 703-720 - Stores value in literal pool
- `con()`: Lines 721-785 - Loads constants into registers
- `flushcon()`: Lines 642-682 - Patches LDR_LIT and emits constants
- `punt()`: Lines 1030-1137 - Handles punted instructions
- `IMFRAME case`: Lines 1529-1534 - Always punts to interpreter
- `compile()`: Lines 2493-2690 - Main compilation function

### libinterp/xec.c
- `mframe()`: Lines 355-390 - Interpreter's module frame allocation

### include/interp.h
- `struct REG`: Lines 216-233 - Register structure (R.m at offset 88)
- `struct Type`: Lines 204-214 - Type structure (size at offset 24)
- `struct Modl`: Lines 300-304 - Module link entry (frame field)

## Debug Output Added

The following debug prints were added (cflag > 1 or > 2):

1. **Module compilation start**:
   ```c
   print("[JIT] Compiling module '%s' (size=%d, ntype=%d, ml=%p)\n", ...);
   ```

2. **IFRAME processing**:
   ```c
   print("IFRAME pass%d: type[%d]=%p (size=%d)\n", ...);
   ```

3. **literal() calls**:
   ```c
   print("literal: imm=%lld roff=%d litpool=%p\n", ...);
   ```

4. **con() literal pool usage**:
   ```c
   print("con: using literal pool for val=%llx (opt=%d)\n", ...);
   ```

5. **flushcon() patching**:
   ```c
   print("flushcon: i=%d LDR@%p -> const@%p disp=%lld val=%llx\n", ...);
   ```

6. **typecom() validation**:
   ```c
   if((uvlong)t < 0x100000)
       print("[JIT] typecom: INVALID Type* %p\n", t);
   ```

## Suggested Next Steps

### 1. Verify Literal Pool Values at Runtime
Add debug code to dump the actual bytes in the literal pool after compilation:
```c
print("litpool contents at %p:\n", base + n);
for(i = 0; i < nlit; i += 2) {
    uvlong val = *(uvlong*)(base + n + i);
    print("  [%d]: %llx\n", i/2, val);
}
```

### 2. Add Runtime Trace in mframe()
Modify `xec.c:mframe()` to print what it reads:
```c
print("mframe: R.m=%p *R.m=%lld ml=%p\n", R.m, W(m), ml);
```

### 3. Check con() Code Size Consistency
Verify that con() generates same code size in pass 0 and pass 1 for litpool addresses:
```c
int start_code = code - base;
con((uvlong)litpool, RTA, 0);
int end_code = code - base;
print("con generated %d words\n", end_code - start_code);
```

### 4. Examine Generated Code
Disassemble the actual ARM64 instructions around an AXIMM punt to verify:
- LDR loads correct litpool address
- STR stores to correct R.m offset
- Values in constant pool are correct

### 5. Compare with Working JIT Backend
The ARM32 (`comp-arm.c`) and other backends handle AXIMM similarly. Compare their literal pool implementation to find differences.

## Test Commands

```bash
# Build
cd libinterp && ROOT="$PWD/.." PATH="$PWD/../Linux/arm64/bin:/usr/bin:/bin" mk install
cd ../emu/Linux && rm -f o.emu && OBJTYPE=arm64 ROOT="..." mk o.emu

# Test without JIT (should work)
echo "hello" | ./emu/Linux/o.emu -r. -c0 dis/echo.dis

# Test with JIT (crashes)
echo "hello" | ./emu/Linux/o.emu -r. -c1 dis/echo.dis

# Test with debug output
echo "hello" | timeout 5 ./emu/Linux/o.emu -r. -c3 dis/echo.dis 2>&1 | grep -E "IFRAME|literal|flushcon"
```

## Files Modified (Uncommitted)

```
libinterp/comp-arm64.c  - Multiple debug prints and fixes
emu/Linux/mkfile        - Removed X11 dependencies for headless build
```

## Conclusion

The ARM64 JIT on Linux builds and partially works. Simple programs like echo.dis produce correct output but crash during Emuinit cleanup. The crash involves accessing `Type.size` from an invalid Type pointer (0x24809 instead of a valid heap address).

The root cause appears to be in how the literal pool interacts with the interpreter's mframe() function. The literal() function stores type indices in the literal pool and their addresses in R.m. At runtime, something causes R.m to point to wrong data, resulting in garbage type index and invalid Type pointer.

Key insight: The value 0x24809 (149513 decimal) is suspiciously small for a pointer but could be a valid-ish type index if there's severe memory corruption.
