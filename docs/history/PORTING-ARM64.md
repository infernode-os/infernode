# Inferno ARM64 64-bit Porting Notes

## Overview

This document tracks the porting effort to bring Inferno infernode to ARM64 macOS with full 64-bit Dis VM support (WORD=intptr, IBY2WD=sizeof(void*)).

## Architecture Pattern: "inferno64"

The porting approach uses:
- `WORD = intptr` (8 bytes on 64-bit)
- `IBY2WD = sizeof(void*)` (8 bytes on 64-bit)
- All pointer-sized values use 8 bytes instead of 4 bytes

## Critical Discovery: Module Header Generation Issue

### Root Cause of Pool Corruption

The "bad magic" pool corruption error was traced to auto-generated module headers containing **hardcoded 32-bit frame sizes and pointer maps**.

#### Example from libinterp/sysmod.h:
```c
typedef struct{char *name; long sig; void (*fn)(void*); int size; int np; uchar map[16];} Runtab;
Runtab Sysmodtab[]={
    "announce",0xb7c4ac0,Sys_announce,72,2,{0x0,0x80,},
    "bind",0x66326d91,Sys_bind,88,2,{0x0,0xc0,},
    "fwstat",0x50a6c7e0,Sys_fwstat,176,2,{0x0,0xf8,},
    ...
};
```

The `size` values (72, 88, 176) were computed for 32-bit WORD=4 bytes.
On 64-bit WORD=8, these frame sizes are incorrect, causing the garbage collector to use wrong pointer maps.

### How Module Headers Are Generated

From `libinterp/mkfile` lines 55-74:
```make
sysmod.h:D: $MODULES
	rm -f $target && limbo -t Sys -I$ROOT/module $ROOT/module/runt.m > $target

loadermod.h:D: $MODULES
	rm -f $target && limbo -t Loader -I$ROOT/module $ROOT/module/runt.m > $target
```

The `limbo` compiler with `-t ModuleName` flag generates Runtab structures.

From `limbo/stubs.c` modtab() function (lines 177-178):
```c
md = mkdesc(idoffsets(id->ty->ids, MaxTemp, MaxAlign), id->ty->ids);
print("%ld,%ld,%M,", md->size, md->nmap, md);
```

The frame sizes are computed by `mkdesc()` using the WORD size that limbo was **compiled with**.

### The Fix

**Sequence Required:**

1. **Rebuild limbo with 64-bit settings**
   - Ensure limbo is compiled with WORD=8 (intptr)
   - This makes limbo's `mkdesc()` compute 64-bit frame sizes

2. **Regenerate all module headers**
   - Run: `mk sysmod.h loadermod.h drawmod.h mathmod.h keyring.h ipintsmod.h cryptmod.h`
   - This creates new headers with correct 64-bit frame sizes and pointer maps

3. **Rebuild libinterp with new headers**
   - Run: `mk install` in libinterp

4. **Rebuild and test emulator**
   - Run: `mk install` in emu/MacOSX
   - Test execution

### Files Affected

Auto-generated module headers (must be regenerated for 64-bit):
- `libinterp/sysmod.h` - Sys module runtime table
- `libinterp/loadermod.h` - Loader module runtime table
- `libinterp/drawmod.h` - Draw module runtime table
- `libinterp/mathmod.h` - Math module runtime table
- `libinterp/keyring.h` - Keyring module runtime table
- `libinterp/ipintsmod.h` - IPints module runtime table
- `libinterp/cryptmod.h` - Crypt module runtime table
- `emu/MacOSX/srvm.h` - Srv module runtime table (platform-specific)

### Previous Fixes Applied

1. **Nil pointer crashes** - Added protective checks in:
   - `kstrcpy()` - Check for nil string before dereferencing
   - `error()` - Check for nil error string
   - `string2c()` - Check for nil String* before accessing data

2. **Structure layouts verified correct** on 64-bit:
   - `Bhdr` = 48 bytes (magic=8, size=8, union=32)
   - `Heap` = 32 bytes (color=4, padding=4, ref=8, t=8, hprof=8)
   - D2B offset = 16 bytes (offsetof(Bhdr, u.data))

### Error Message Context

The original error:
```
alloc:D2B(10042d0b0): pool main CORRUPT: bad magic at 100378960'4298609664(magic=100374fa0)
```

The magic value `0x100374fa0` is a pointer address (not a valid magic constant like `MAGIC_A` or `MAGIC_F`), indicating memory corruption caused by incorrect pointer map interpretation during garbage collection.

## Build Status

- [x] ARM64 architecture support added
- [x] 64-bit WORD size configured
- [x] Nil pointer crashes fixed
- [x] Structure layouts verified
- [x] Root cause identified (module headers)
- [x] Limbo rebuilt for 64-bit (MaxTemp=64, IBY2WD=8)
- [x] Module headers regenerated (all *mod.h files)
- [x] Emulator rebuilt with new 64-bit headers
- [x] BHDRSIZE calculation bug fixed
- [x] **Acme editor running successfully!** ✅
- [x] Built-in Limbo compiler (appl/cmd/limbo/) updated for 64-bit

## Status Update

### Completed (Latest Session)

1. **Rebuilt limbo compiler** with 64-bit settings
   - Verified MaxTemp=64, IBY2WD=8, NREG=5
   - limbo now generates correct 64-bit frame sizes

2. **Regenerated ALL module headers** (critical step!)
   - emu/MacOSX/srvm.h (frame sizes: 32→64, 40→72, 40→72, 40→80)
   - libinterp/runt.h (ADT structure definitions)
   - libinterp/sysmod.h, loadermod.h, drawmod.h, mathmod.h, keyring.h, ipintsmod.h, cryptmod.h

   To regenerate these headers:
   ```bash
   cd libinterp
   rm -f *.h
   ROOT="$PWD/.." PATH="$PWD/../MacOSX/arm64/bin:$PATH" ../MacOSX/arm64/bin/mk \
     runt.h sysmod.h loadermod.h drawmod.h mathmod.h keyring.h ipintsmod.h cryptmod.h
   ```

3. **Rebuilt and tested**
   - libinterp rebuilt from clean state
   - Emulator rebuilt from clean state
   - Emulator now runs WITHOUT pool corruption errors! ✅

### Critical BHDRSIZE Bug Fix

The final blocker was an incorrect BHDRSIZE calculation:

**WRONG:**
```c
#define BHDRSIZE (sizeof(Bhdr)+sizeof(Btail))  // = 56+8 = 64 bytes
```

**CORRECT:**
```c
#define BHDRSIZE ((int)(((Bhdr*)0)->u.data)+sizeof(Btail))  // = 16+8 = 24 bytes
```

The Bhdr.u.data field IS the user data, not overhead. The incorrect 64-byte value broke all pool block traversal, causing D2B() to find freed blocks (MAGIC_F) instead of allocated blocks (MAGIC_A).

## How to Run Acme editor

### Prerequisites

**XQuartz (X11 for macOS) must be running:**

```bash
# Start XQuartz (one-time per session)
open -a XQuartz

# Wait a few seconds for it to start, then...
```

### Running Acme

From the infernode directory:

```bash
export PATH="$PWD/MacOSX/arm64/bin:$PATH"
export DISPLAY=:0
./emu/MacOSX/o.emu -r. dis/acme/acme.dis
```

**Note:** The current build uses X11 graphics (win-x11a.c). Native macOS graphics (Cocoa/AppKit) would require porting from the deprecated Carbon API in `emu/MacOSX/win.c`.

### Remaining Tasks

1. Test all Acme functionality thoroughly
2. Compile remaining Limbo standard library modules
3. Consider merging additional utilities from inferno-os
4. Performance testing and optimization

## References

### Source Repositories

- **infernode** (this fork): Intended for extensive modifications, not backward compatible
- **InferNode**: https://github.com/caerwynj/InferNode - Original Acme editor (32-bit)
- **inferno64**: https://github.com/caerwynj/inferno64 - Incomplete 64-bit Inferno port (ARM64 explicitly incomplete, but may have useful patterns)
- **inferno-os**: https://github.com/inferno-os/inferno-os - Full Inferno distribution (complete source)

### Code References

- Bhdr structure: `include/pool.h`
- Heap structure: `include/interp.h`
- Type/dtype: `libinterp/heap.c`
- Module generation: `limbo/stubs.c` modtab()
- Build rules: `libinterp/mkfile`
