# Inferno Shell Not Executing - Investigation Summary

**Date:** January 3, 2026

## Current Situation

✅ **Headless 64-bit Inferno emulator works perfectly**
- Binary: `emu/MacOSX/o.emu`
- No crashes, no pool corruption
- Runs from any terminal

❌ **Shell loads but doesn't execute commands**
- Echoes input but never runs anything
- No prompt displayed
- No errors reported

## Research Findings

### How Inferno Should Work

According to official Inferno documentation:

1. **Default startup** ([Inferno EMU manual](https://vitanuova.com/inferno/man/1/emu.html)):
   - Run: `emu -r /path/to/inferno`
   - emuinit loads and runs: `sh -l` (login shell)
   - Shell executes `/lib/sh/profile`
   - **Should show prompt**: typically a semicolon `;`

2. **Text mode operation** ([Inferno Shell](https://powerman.name/doc/Inferno/sh_en)):
   - sh CAN run in text mode: "bare shell with no graphical environment, just 'emu' running inside a VT100"
   - Draw module can be loaded but not used for graphics

3. **Shell profile** ([InferNode startup](https://groups.google.com/g/InferNode/c/DNi8a_Y43yU)):
   - When `-l` flag used, shell runs `/lib/sh/profile`
   - Profile sets up filesystem mounts, environment
   - Then runs user profile `$home/lib/profile`

### What We Have

✅ **All components compiled for 64-bit:**
- dis/emuinit.dis
- dis/sh.dis
- dis/sh/*.dis (12 builtins including std.dis)
- dis/lib/*.dis (10+ library modules)
- dis/{mntgen,trfs,os,cat,mkdir,cp,bind,mount,ftest,cd}.dis
- lib/sh/profile exists

✅ **Emulator runs correctly:**
- Loads emuinit successfully
- No pool corruption
- Runs indefinitely without crashing

## Theories

### Theory 1: Missing Library Modules

The shell might be failing to load required modules silently. Missing:
- More modules in dis/lib/
- Possible dependencies we haven't compiled

**Test:** Compile ALL appl/lib/*.b files

### Theory 2: stdin/stdout Not Connected Properly

The shell might be reading/writing to the wrong file descriptors in headless mode.

**Evidence:**
- Shell echoes input (so stdin works)
- But no output from commands (maybe stdout blocked?)

### Theory 3: Profile Script Blocking

The `/lib/sh/profile` script tries to:
- Mount filesystems (`mntgen`, `trfs`)
- Access host filesystem via `#U` device
- Run host commands via `os`

One of these might be blocking or failing.

**Test:** Create a minimal profile that just echoes something

### Theory 4: Terminal Mode Issue

According to docs, sh expects "VT100" terminal. Maybe it needs:
- TERM environment variable set
- Proper terminal control characters
- rlwrap or similar for line editing

## Debugging Steps

### Step 1: Test with minimal profile

```bash
# Rename current profile
mv lib/sh/profile lib/sh/profile.orig

# Create minimal test profile
cat > lib/sh/profile <<'EOF'
#!/dis/sh.dis
load std
echo 'Profile loaded!'
echo 'Type commands:'
EOF

# Test
./emu/MacOSX/o.emu -r.
```

### Step 2: Compile ALL library modules

The shell likely needs more modules we haven't compiled yet.

```bash
cd appl/lib
for f in *.b; do
  ../../MacOSX/arm64/bin/limbo -I../../module -gw "$f"
done
cp *.dis ../../dis/lib/
```

### Step 3: Check emuinit behavior

Modify emuinit to add debug output showing what it's doing.

### Step 4: Try running shell directly bypassing emuinit

```bash
# See if shell can run at all
./emu/MacOSX/o.emu -r. -d /dis/sh.dis
```

The `-d` flag might bypass emuinit.

## Comparison with Working Systems

According to [Using Inferno OS on Linux](https://bluishcoder.co.nz/2014/12/31/using-inferno-os-on-linux.html), when you run emu correctly, you should immediately see:

```
$ emu
; pwd
/usr/you
; ls
lib     tmp
;
```

We're not seeing the `;` prompt at all, which suggests the shell isn't reaching its interactive read-eval-print loop.

## Next Actions

1. Create a minimal test profile to isolate the issue
2. Compile all remaining library modules
3. Add debug output to emuinit to see where it's blocking
4. Check if there's a simpler test program (not shell) that can verify the VM is executing Dis bytecode correctly

## Technical Details

**What's working:**
- 64-bit Dis VM executes bytecode
- Modules load (no "can't load" errors)
- stdin reads (echoes work)

**What's NOT working:**
- Command execution
- Prompt display
- Interactive loop

This suggests the shell code path reaches the input reading part but never gets to the command execution/output part.

---

**Sources:**
- [Inferno EMU manual](https://vitanuova.com/inferno/man/1/emu.html)
- [The Inferno Shell](https://www.vitanuova.com/inferno/papers/sh.html)
- [Inferno Shell guide](https://powerman.name/doc/Inferno/sh_en)
- [InferNode startup customization](https://groups.google.com/g/InferNode/c/DNi8a_Y43yU)
- [Using Inferno OS on Linux](https://bluishcoder.co.nz/2014/12/31/using-inferno-os-on-linux.html)
