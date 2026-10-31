# ARM64 64-bit Inferno Porting - Lessons Learned

**Purpose:** Document all pitfalls, solutions, and debugging techniques for future porters

## Critical 64-bit Fixes (In Order of Discovery)

### 1. WORD and IBY2WD Definitions

**Issue:** Original code used fixed 32-bit sizes
**Fix:** Change to architecture-specific types
```c
// include/interp.h
typedef intptr   WORD;    // Was: typedef int WORD;
typedef uintptr  UWORD;   // Was: typedef unsigned int UWORD;

// include/isa.h
IBY2WD = sizeof(void*),   // Dynamic: 4 on 32-bit, 8 on 64-bit
```

**Why:** WORD must match pointer size for Dis VM stack operations

### 2. Module Header Generation

**Issue:** Auto-generated *mod.h files had hardcoded 32-bit frame sizes
**Root Cause:** limbo compiler itself was compiled with 32-bit values
**Solution:**
```bash
# 1. Rebuild limbo with 64-bit headers
cd limbo
ROOT="$PWD/.." PATH="$PWD/../MacOSX/arm64/bin:$PATH" ../MacOSX/arm64/bin/mk clean
ROOT="$PWD/.." PATH="$PWD/../MacOSX/arm64/bin:$PATH" ../MacOSX/arm64/bin/mk install

# 2. Regenerate ALL module headers
cd libinterp
rm -f *.h
ROOT="$PWD/.." PATH="$PWD/../MacOSX/arm64/bin:$PATH" ../MacOSX/arm64/bin/mk \
  runt.h sysmod.h loadermod.h drawmod.h mathmod.h keyring.h ipintsmod.h cryptmod.h

# 3. Regenerate platform-specific headers
cd ../emu/MacOSX
ROOT="../.." ../../MacOSX/arm64/bin/limbo -t Srv -I../../module ../../module/srvrunt.b > srvm.h
```

**Lesson:** Generated files must be regenerated after changing build tools!

**Symptom if wrong:** Pool corruption "bad magic" errors, GC crashes

### 3. BHDRSIZE Calculation

**Issue:** Used wrong calculation for pool block header size
**Wrong:** `sizeof(Bhdr) + sizeof(Btail)` = 64 bytes (counts user data as overhead!)
**Correct:** `((uintptr)(((Bhdr*)0)->u.data) + sizeof(Btail))` = 24 bytes

```c
// include/pool.h
#define BHDRSIZE ((uintptr)(((Bhdr*)0)->u.data)+sizeof(Btail))
```

**Why:** The Bhdr.u.data field IS the user data, not overhead. Only count header up to data field plus footer.

**Lesson:** Use `uintptr` not `int` for pointer arithmetic casts on 64-bit!

**Symptom if wrong:** Use-after-free errors, D2B() finding freed blocks (MAGIC_F)

### 4. Pool Quanta (THE CRITICAL FIX)

**Issue:** Pool allocator quanta was 31 (for 32-bit)
**Fix:** Must be 127 for 64-bit

```c
// emu/port/alloc.c
{ "main",  0, 32*1024*1024, 127, 512*1024, 0, 31*1024*1024 },  // Was: 31
{ "heap",  1, 32*1024*1024, 127, 512*1024, 0, 31*1024*1024 },  // Was: 31
{ "image", 2, 64*1024*1024+256, 127, 4*1024*1024, 1, 63*1024*1024 },  // Was: 31
```

**Why:** With 64-bit pointers (8 bytes):
- Free block structure needs: 5 pointers + allocpc/reallocpc = 5*8 + 2*8 = 56 bytes
- Plus overhead ≈ 64 bytes minimum
- Quanta must be 2^q - 1, so 127 (2^7-1)

**Lesson:** Quanta controls minimum allocation size. Too small = headers overwrite data!

**Symptom if wrong:**
- Programs execute but produce NO output
- Pool corruption after bytecode execution starts
- VM appears to work but programs silently fail

**This was the final blocker** - without this fix, Dis programs loaded and executed bytecode but all output vanished because blocks were corrupted.

## Common Pitfalls

### Pitfall 1: Declaring Success Too Early

**Mistake:** Saying "port is complete" when emulator builds without crashing
**Reality:** Must test actual interaction - shell prompt, command execution, I/O
**Lesson:** "Builds and doesn't crash" ≠ "works correctly"

### Pitfall 2: Not Investigating Working Implementations

**Mistake:** Trying to debug blindly without checking working code
**Solution:** Compare with inferno64 and inferno-os repositories
**Result:** Found critical quanta fix in inferno64's alloc.c

**Key resources:**
- https://github.com/caerwynj/inferno64 - Working 64-bit port
- https://github.com/inferno-os/inferno-os - Standard Inferno

### Pitfall 3: Assuming Error Messages Are Literal

**Example:** "illegal dis instruction" error
**Assumed:** Bad opcode in bytecode
**Reality:** Missing module dependency (readdir.dis)
**Lesson:** Trace the actual failure, don't just read error messages

### Pitfall 4: Missing Generated File Dependencies

**Issue:** libinterp/*mod.h files looked "up to date" but were 32-bit
**Problem:** mk doesn't know they need regeneration when limbo changes
**Solution:** Explicitly delete and regenerate ALL auto-generated headers
**Affected files:**
- libinterp/runt.h
- libinterp/sysmod.h, loadermod.h, drawmod.h, mathmod.h
- libinterp/keyring.h, ipintsmod.h, cryptmod.h
- emu/*/srvm.h

### Pitfall 5: Console Output Appears Broken

**Symptom:** No stdout/stderr from Dis programs
**First thought:** Console device broken
**Reality:** Pool corruption preventing programs from executing properly
**Lesson:** Seemingly unrelated systems (memory allocator) can cause unexpected symptoms (no output)

## Debugging Techniques That Worked

### 1. Strategic Debug Output

Add `fprint(2, "DEBUG: ...")` at key points:
- Module loading (load.c)
- VM initialization (dis.c:disinit)
- Execution (dis.c:vmachine)
- Console write (devcons.c:conswrite)
- System calls (inferno.c:Sys_print)

**Why fprint(2, ...) not printf():**
- fprint writes to stderr (fd 2)
- Works even when Dis program stdout is broken
- Survives through all code paths

### 2. Comparison with Working Code

When stuck, fetch and diff against working implementations:
```bash
curl -s https://raw.githubusercontent.com/caerwynj/inferno64/master/emu/port/alloc.c > /tmp/inferno64-alloc.c
diff emu/port/alloc.c /tmp/inferno64-alloc.c | head -100
```

### 3. Test Programs

Create minimal test cases:
```limbo
implement Test;
include "sys.m";
    sys: Sys;
include "draw.m";

Test: module { init: fn(ctxt: ref Draw->Context, args: list of string); };

init(ctxt: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    sys->print("Hello from Inferno!\n");
}
```

Compile and test:
```bash
./MacOSX/arm64/bin/limbo -I./module -gw test.b
./emu/MacOSX/o.emu -r. test.dis
```

### 4. Incremental Testing

Don't assume everything works - test each layer:
1. Does emulator start? ✓
2. Does it load emuinit.dis? ✓
3. Does emuinit execute? ✓
4. Does console output work? ✓
5. Does shell load? ✓
6. Does shell show prompt? ✓
7. Do commands execute? ✓
8. Do commands produce output? ✓

Each YES required specific fixes!

## Build Process Gotchas

### PATH Requirements

The build needs `ndate` utility:
```bash
PATH="$PWD/MacOSX/arm64/bin:/bin:/usr/bin" mk install
```

Without ndate, emu.c compilation fails with "KERNDATE: expected expression"

### Module Compilation Order

**Wrong:** Compile programs first, libraries later
**Right:**
1. Build system (mk, limbo, etc.)
2. Build C libraries (lib9, libinterp, etc.)
3. Build Limbo libraries (appl/lib/*.b → dis/lib/*.dis)
4. Build applications (appl/cmd/*.b → dis/*.dis)

**Why:** Applications load library modules - libraries must exist first!

### Headless vs X11 Build

**For console/text mode:**
- Use `mkfile-g` configuration
- Creates `emu-g` binary
- No graphics dependencies
- Requires graphics stubs (stubs-headless.c)
- Add CoreFoundation/IOKit frameworks for serial device

**For graphics mode:**
- Use standard `mkfile`
- Requires X11/XQuartz on macOS
- Carbon deprecated - needs X11 backend (win-x11a.c)

## Memory/Pointer Issues Specific to 64-bit

### Size Types

Change these from `ulong` to `uintptr`:
- Pool sizes (maxsize, cursize, arenasize)
- Memory counters (nalloc, nfree)
- Any value representing memory addresses or sizes

### Pointer Arithmetic

Always cast offsets to `uintptr`, not `int`:
```c
// WRONG:
#define OFFSET ((int)(((Struct*)0)->field))

// RIGHT:
#define OFFSET ((uintptr)(((Struct*)0)->field))
```

### Structure Alignment

64-bit pointers require 8-byte alignment:
- Check `__builtin_offsetof()` results
- Verify structure padding
- Ensure `STRUCTALIGN = sizeof(intptr)`

## Testing Checklist

After making changes, test:

1. **Build succeeds:** `mk install` completes
2. **Emulator starts:** `./emu/MacOSX/o.emu -r.` runs
3. **Test program outputs:** Simple print test shows output
4. **Shell prompt appears:** See `;`
5. **Commands execute:** pwd, date, cat work
6. **File operations work:** ls, mkdir, rm work
7. **No pool corruption:** Run for several minutes without crashes
8. **Modules load:** Dependencies resolve correctly

## Common Error Messages and Real Causes

| Error Message | Likely Real Cause |
|---------------|-------------------|
| "pool main CORRUPT: bad magic" | BHDRSIZE wrong OR quanta too small |
| "illegal dis instruction" | Missing library module dependency |
| No output from Dis programs | Pool quanta too small (31 instead of 127) |
| Program loads but hangs | Graphics module blocking in headless mode |
| "cannot load module" | Module not compiled for 64-bit |

## File Checklist for 64-bit Port

Must modify:
- [x] include/interp.h (WORD/UWORD types)
- [x] include/isa.h (IBY2WD definition)
- [x] include/pool.h (BHDRSIZE)
- [x] emu/port/alloc.c (quanta values)
- [x] All libinterp/*mod.h (regenerate!)
- [x] Platform srvm.h files (regenerate!)

Must create for ARM64:
- [x] emu/MacOSX/asm-arm64.s
- [x] lib9/getcallerpc-MacOSX-arm64.s
- [x] libinterp/comp-arm64.c
- [x] libinterp/das-arm64.c
- [x] mkfiles/mkfile-MacOSX-arm64

For headless mode, also:
- [x] emu/MacOSX/stubs-headless.c
- [x] emu/MacOSX/mkfile-g (update frameworks)

## Resources

### Source Repositories
- **inferno64:** https://github.com/caerwynj/inferno64 - Working 64-bit (amd64, arm64 in progress)
- **inferno-os:** https://github.com/inferno-os/inferno-os - Standard Inferno
- **InferNode:** https://github.com/caerwynj/InferNode - Acme standalone

### Key Commits in inferno64
- "change memory pointers to uintptr" (Jul 2021) - Critical 64-bit fix
- "changes for arm64 on rpi5" (Nov 2024) - ARM64 specific
- "wrap malloc" (Aug 2024) - Memory management

### Documentation
- Inferno Shell: https://www.vitanuova.com/inferno/papers/sh.html
- EMU manual: https://vitanuova.com/inferno/man/1/emu.html
- QIO system: https://inferno-os.org/inferno/man/10/qio.html

## Timeline of This Port

1. **Initial build** - Got emulator to compile for ARM64
2. **Nil pointer crashes** - Fixed kstrcpy, error(), string2c protections
3. **Pool corruption #1** - Fixed BHDRSIZE calculation
4. **Module headers** - Discovered 32-bit generated headers, rebuilt limbo, regenerated all
5. **Headless build** - Created graphics stubs for console-only mode
6. **Pool corruption #2** - Fixed BHDRSIZE to use uintptr
7. **No output mystery** - Programs ran but silent - quanta was too small
8. **BREAKTHROUGH** - Changed quanta 31→127, everything works!
9. **Missing modules** - ls failed until readdir.dis compiled
10. **Built-in compiler** - appl/cmd/limbo/ also needed IBY2WD=8 fix

**Total: 24 commits over ~6 hours of debugging**

## Key Insights

### "It compiles" ≠ "It works"
- Emulator built and ran without crashing early on
- But programs produced no output due to subtle memory corruption
- **Lesson:** Must test actual functionality, not just startup

### Follow the working code
- Hours spent debugging blindly
- User suggested checking inferno64
- Found critical quanta fix in minutes
- **Lesson:** Check working implementations first!

### Memory corruption has surprising symptoms
- Expected: Crashes, segfaults
- Reality: Programs execute but silently fail, no output
- **Lesson:** Corruption can be subtle - trace actual behavior

### Generated files are dangerous
- *mod.h files looked fine but were 32-bit
- mk didn't know they needed regeneration
- **Lesson:** Explicitly regenerate all generated files after toolchain changes

### There are TWO Limbo compilers
- **Native compiler** (`limbo/` - C code) runs on host, used for bootstrap
- **Built-in compiler** (`appl/cmd/limbo/` - Limbo code) runs inside emulator
- Both have IBY2WD constants that need updating for 64-bit
- The built-in compiler also needed ecom.b case→if-else fix (IBY2WD==IBY2LG==8)
- **Lesson:** Don't forget self-hosted tools need the same fixes

## Red Flags to Watch For

🚩 **"Everything builds but nothing outputs"** → Check pool quanta
🚩 **"Pool corruption after execution starts"** → Check quanta or BHDRSIZE
🚩 **"illegal dis instruction"** → Missing module dependency
🚩 **"Program hangs after loading"** → Graphics/Draw module blocking
🚩 **"Pool corruption with pointer addresses as magic"** → Bad type maps (module headers)
🚩 **"Pool corruption with MAGIC_F"** → BHDRSIZE wrong (use-after-free)

## Verification Steps

To verify a 64-bit port is correct:

```bash
# 1. Check WORD size
printf '#include "interp.h"\n#include <stdio.h>\nint main(){printf("WORD=%%zu\\n",sizeof(WORD));return 0;}\n' > /tmp/test.c
cc -I./include /tmp/test.c && ./a.out
# Should print: WORD=8

# 2. Check IBY2WD
printf '#include "isa.h"\n#include <stdio.h>\nenum {TEST=IBY2WD};\nint main(){printf("IBY2WD=%%d\\n",TEST);return 0;}\n' > /tmp/test.c
cc -I./include /tmp/test.c && ./a.out
# Should print: IBY2WD=8

# 3. Check BHDRSIZE
printf '#include "pool.h"\n#include <stdio.h>\nint main(){printf("BHDRSIZE=%%zu\\n",BHDRSIZE);return 0;}\n' > /tmp/test.c
cc -I./include /tmp/test.c && ./a.out
# Should print: BHDRSIZE=24

# 4. Check quanta
grep "quanta" emu/port/alloc.c
# Should show: 127, 127, 127

# 5. Test output
echo 'sys->print("test\n");' in a Dis program
# Should print: test
```

## For Future Porters

If porting to another 64-bit architecture (RISC-V, ARM64 on other OS, etc.):

1. **Start with inferno64 as base**, not InferNode or standard inferno-os
2. **Check ALL these files** for 32-bit assumptions:
   - Memory size types (ulong → uintptr)
   - Pointer casts (int → uintptr)
   - Pool quanta (must be 127)
   - Generated headers (must regenerate)
3. **Create minimal test programs** before assuming shell works
4. **Compare every modified file** with inferno64 version
5. **Document every fix** - you'll forget why you did it!

## Success Criteria

Port is complete when:
- ✅ Shell shows `;` prompt
- ✅ Commands execute and produce output
- ✅ File operations work (ls, cat, mkdir)
- ✅ System calls work (date, ps)
- ✅ No crashes after extended use (10+ minutes)
- ✅ No pool corruption errors
- ✅ Modules load correctly

Not just:
- ❌ Emulator compiles
- ❌ Emulator starts
- ❌ No immediate crash

---

**Written during the first successful ARM64 64-bit Inferno port**
**Date:** January 3, 2026
