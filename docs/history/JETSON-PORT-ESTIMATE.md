# Porting to Jetson Orin AGX - Effort Estimate

**Target:** NVIDIA Jetson Orin AGX (ARM64, Linux, Ubuntu-based)
**Status:** ✅ **IMPLEMENTED** - See `docs/JETSON-PORT-PLAN.md` for details.

## TL;DR: **Linux ARM64 support is now included in infernode!**

The files have been added. See `build-linux-arm64.sh` for the build script.

---

## Original Estimate (For Reference)

## What We Have (Reusable)

### ✅ All the Hard 64-bit Work (DONE)

**These are architecture-specific, not OS-specific:**

1. **Pool quanta fix (127)** - Same on Linux ✓
2. **BHDRSIZE with uintptr** - Same on Linux ✓
3. **Module headers regenerated for 64-bit** - Same on Linux ✓
4. **WORD/IBY2WD definitions** - Same on Linux ✓
5. **Shell with exception handling** - Same on Linux ✓

**All 64-bit fixes apply directly to Jetson!**

### ✅ ARM64-Specific Code (Portable)

**These work on ANY ARM64 system:**

1. **libinterp/comp-arm64.c** - Compiler backend ✓
2. **libinterp/das-arm64.c** - Disassembler ✓
3. **lib9/getcallerpc-MacOSX-arm64.s** - May need rename but same code ✓
4. **emu/MacOSX/asm-arm64.s** - May work as-is or need minor tweaks ✓

**ARM64 assembly is the same across macOS and Linux.**

### ✅ Portable Code (Works Everywhere)

1. **All Limbo code** - Platform-independent
2. **emu/port/** - Portable emulator core
3. **libinterp/** (except platform assembly) - Portable
4. **All utilities and libraries** - Platform-independent

**~95% of the codebase is portable!**

## What inferno64 Already Has

### ✅ Linux/ARM64 Support Exists!

From inferno64 repository:
- `emu/Linux/mkfile-arm64` - Build configuration ✓
- `emu/Linux/arm-tas-v8.S` - ARM v8 atomic ops ✓
- Linux-specific `os.c` - System interface ✓

**inferno64 already has Linux/arm64!** (Though may not be fully tested)

## What Needs to Change

### Minimal Platform-Specific Work

**1. Build System (Easy)**
- Use `emu/Linux/mkfile-arm64` (already exists in inferno64)
- Adjust paths for Linux
- Set OBJTYPE=arm64, SYSTARG=Linux

**2. OS Interface (Small)**
- Use `emu/Linux/os.c` instead of `emu/MacOSX/os.c`
- Differences:
  - Header includes (Linux vs macOS)
  - System call wrappers
  - Process/thread management
  - File descriptors

**Estimate:** ~200 lines of code differences

**3. Device Drivers (Maybe)**
- Console device (devcons.c) - portable ✓
- Network (devip.c) - portable ✓
- Keyboard - might need adjustment for Linux terminal
- Serial - probably works

**4. Build Dependencies**
- Install X11 dev packages (if keeping X11 support)
- Or use headless (what we want anyway)

**5. Test and Verify**
- Same tests we ran on macOS
- Verify networking
- Check device access

## Estimated Effort

### Best Case: **1-2 hours**

If inferno64's Linux/arm64 works and we just:
1. Copy our 64-bit fixes to inferno64's Linux build
2. Use their Linux-specific os.c
3. Build and test

### Realistic Case: **4-6 hours**

Including:
1. Adapting build system
2. Merging our fixes with inferno64's Linux code
3. Testing all functionality
4. Fixing any platform quirks
5. Documentation

### Worst Case: **8-12 hours**

If we hit:
- Device driver issues
- Kernel interface problems
- Platform-specific bugs

## Strategy for Jetson Port

### Approach 1: Start from inferno64 (Recommended)

1. Clone inferno64
2. Apply our critical fixes:
   - Pool quanta 127
   - BHDRSIZE uintptr
   - inferno64 shell (they have it)
   - Module headers (regenerate)
3. Use their Linux/arm64 build
4. Test

**Advantage:** They've already solved Linux-specific issues

### Approach 2: Start from infernode

1. Copy infernode
2. Replace emu/MacOSX with emu/Linux (from inferno64)
3. Adapt mkfiles
4. Build

**Advantage:** We know our code works

## Comparison to This Port

### This Port (MacOSX ARM64)
- **Started from:** InferNode (32-bit, no ARM64)
- **Challenges:**
  - Discover all 64-bit issues
  - Fix pool quanta (took time to find)
  - Fix BHDRSIZE (subtle bug)
  - Regenerate module headers
  - Find shell exception handling bug
  - Fix backspace key
- **Time:** ~6-8 hours of debugging
- **Commits:** 72 documenting every discovery

### Jetson Port (Linux ARM64)
- **Starting from:** infernode (working 64-bit ARM64!)
- **Challenges:**
  - Port from macOS to Linux
  - Mostly system call differences
  - Already know all the 64-bit fixes
- **Time:** Estimated 2-6 hours
- **Commits:** Probably 5-10 (much less discovery)

## Key Differences: macOS vs Linux

### Similar (Easy to Port)

- ARM64 instruction set (identical)
- 64-bit pointer size (8 bytes on both)
- POSIX system calls (mostly compatible)
- Network stack (BSD sockets on both)
- File I/O (standard)

### Different (Need Adjustment)

**System Headers:**
- macOS: CoreFoundation, IOKit
- Linux: Standard Linux headers, no frameworks

**Process Management:**
- Different threading (pthread similar but details vary)
- Linux has different process model

**Device Access:**
- Console/terminal (different ioctl)
- Serial ports (naming conventions)

**Build System:**
- macOS: No separate package manager for dev tools
- Linux: Need X11 dev packages (libx11-dev, etc.)

## Jetson-Specific Considerations

### What Jetson Provides

- **ARM64 (same as Mac!)** - Our code should work ✓
- **Linux** - inferno64 has this ✓
- **Ubuntu base** - Standard environment ✓
- **NVIDIA GPU** - We don't use (headless) ✓

### What We Can Leverage

**Jetson advantages:**
- Standard Linux environment
- Good developer tools
- Active community
- Well-documented

**infernode advantages:**
- All 64-bit issues solved
- Headless mode working
- Clean error handling
- Complete test suite

## Porting Checklist

### Phase 1: Setup (30 min)
- [ ] Get inferno64 Linux/arm64 code
- [ ] Review their mkfile-arm64
- [ ] Check what they already have

### Phase 2: Integration (1-2 hours)
- [ ] Copy our critical fixes:
  - Pool quanta 127
  - BHDRSIZE uintptr cast
  - Shell (inferno64 version)
- [ ] Use their emu/Linux/os.c
- [ ] Copy our ARM64 assembly files
- [ ] Regenerate module headers

### Phase 3: Build (30 min - 2 hours)
- [ ] Set up build environment on Jetson
- [ ] Install dependencies
- [ ] Run makemk.sh
- [ ] mk install
- [ ] Fix any build errors

### Phase 4: Test (1-2 hours)
- [ ] Shell prompt appears ✓
- [ ] Commands work ✓
- [ ] Filesystem operations ✓
- [ ] Networking ✓
- [ ] Run our test suite

### Phase 5: Document (30 min - 1 hour)
- [ ] Document Jetson-specific notes
- [ ] Update build instructions
- [ ] Create verification tests

## Risk Assessment

### Low Risk (Probably Just Works)

- 64-bit arithmetic (same fixes)
- Memory management (same pool code)
- Limbo VM (portable)
- Utilities (all Limbo, portable)

### Medium Risk (May Need Tweaking)

- Console/keyboard handling (Linux terminal vs macOS)
- Serial devices (different device names)
- Build system paths

### Low Impact (We Don't Use)

- Graphics (we're headless)
- GUI (don't need)
- Platform-specific optimizations

## Confidence Level

**High confidence (80-90%) that:**
- Port will work with minimal changes
- Most code is directly reusable
- No major new issues to discover

**The hard work (64-bit) is DONE and portable.**

## Recommendation

**Proceed with confidence!**

1. **Start with inferno64** as base (they have Linux/arm64)
2. **Apply our fixes** (we know exactly what they are)
3. **Test systematically** (we have test suite)
4. **Should take 2-6 hours** vs the 6-8 hours this port took

## What We Learned Here Applies Directly

- Pool quanta must be 127 ✓
- BHDRSIZE must use uintptr ✓
- Module headers must be regenerated ✓
- Shell needs exception handling ✓
- Backspace needs fixing ✓

**All documented in docs/LESSONS-LEARNED.md!**

## Differences to Expect

**Linux vs macOS:**
- No CoreFoundation/IOKit (Linux doesn't have these)
- Different system calls (but similar)
- apt instead of brew
- /dev/tty* instead of /dev/cu.*

**Jetson-specific:**
- May have NVIDIA device files (can ignore)
- May have GPIO/hardware access (bonus if we want)
- Probably has better networking (datacenter-grade)

## Conclusion

**Estimated effort: 2-6 hours of focused work**

Compared to this port (6-8 hours), the Jetson port should be:
- ✅ Faster (know all the fixes)
- ✅ Easier (most code portable)
- ✅ Less risky (documented path)
- ✅ More straightforward (inferno64 has Linux/arm64)

**The hard discoveries are done. Jetson is mostly platform adaptation.**

---

**Confidence:** High
**Effort:** Low-Medium
**Timeline:** Could be done in a day
**Documentation:** This port serves as complete reference
