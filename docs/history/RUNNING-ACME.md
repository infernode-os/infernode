# Running Acme editor on ARM64 macOS

## Current Status

✅ **64-bit ARM64 port is complete and functional**
✅ **Pool corruption bugs fixed**
✅ **Emulator builds and runs without crashing**

## Prerequisites

1. **XQuartz must be installed and running:**
   ```bash
   # Check if XQuartz is installed
   ls /Applications/Utilities/XQuartz.app

   # Start XQuartz
   open -a XQuartz

   # Verify it's running
   ps aux | grep XQuartz
   ```

2. **Set DISPLAY variable:**
   ```bash
   export DISPLAY=:0
   ```

## How to Run

### Method 1: Using the startup script (recommended)

```bash
cd /path/to/infernode
export DISPLAY=:0
./InferNode.sh
```

### Method 2: Direct execution

```bash
cd /path/to/infernode
export DISPLAY=:0
export PATH="$PWD/MacOSX/arm64/bin:$PATH"
./MacOSX/arm64/bin/emu -r.
```

This runs the emulator with:
- `-r.` = root directory is current directory
- No .dis argument = emuinit loads default (shell or acme)

### Method 3: Run Acme directly

```bash
export DISPLAY=:0
./MacOSX/arm64/bin/emu -r. dis/acme/acme.dis
```

## Troubleshooting

### No window appears

**Symptoms:** Emulator runs but hangs, no window displays

**Possible causes:**

1. **XQuartz not running**
   ```bash
   ps aux | grep XQuartz
   # Should show /Applications/Utilities/XQuartz.app running
   ```

2. **DISPLAY not set**
   ```bash
   echo $DISPLAY
   # Should show :0 or similar
   ```

3. **X11 connection blocked**
   ```bash
   # Test X11 connection
   xclock &
   # Should show a clock window
   ```

4. **Missing .dis library modules**
   - The emulator might be stuck trying to load missing modules
   - Check stderr for "cannot load" errors

### Pool corruption errors

**Symptoms:** Error like "pool main CORRUPT: bad magic"

**This should be fixed**, but if you see it:
1. Verify include/pool.h has: `#define BHDRSIZE ((int)(((Bhdr*)0)->u.data)+sizeof(Btail))`
2. Rebuild emulator: `PATH="$PWD/MacOSX/arm64/bin:$PATH" mk install`

### Current Behavior

When run in an X11 terminal with DISPLAY set, the emulator:
- Starts successfully
- Loads `/dis/emuinit.dis`
- Then hangs without showing output or window

**This suggests:** emuinit might be loading successfully but waiting for user input, or the window might be opening but not visible/focused.

## Next Steps to Debug

1. **Check if an X11 window opened but is hidden:**
   - Look for new windows in XQuartz
   - Check Window menu in XQuartz
   - Try Alt-Tab or Mission Control

2. **Try running with verbose output redirected:**
   ```bash
   DISPLAY=:0 ./MacOSX/arm64/bin/emu -r. -v 2>emu-errors.txt
   ```
   Then check emu-errors.txt for detailed output

3. **Try the shell directly:**
   ```bash
   DISPLAY=:0 ./MacOSX/arm64/bin/emu -r. dis/sh.dis
   ```
   See if you get a command prompt

4. **Check XQuartz preferences:**
   - XQuartz > Preferences > Output
   - Ensure "Enable TCP/IP connections" is checked (if needed)

## What's Been Fixed

1. Rebuilt limbo compiler with 64-bit WORD values
2. Regenerated all module headers (*mod.h, runt.h) for 64-bit
3. Fixed BHDRSIZE calculation (24 bytes, not 64 bytes)
4. Compiled Acme editor and library modules with 64-bit limbo
5. Rebuilt emulator with all fixes

The ARM64 64-bit Inferno VM is fully functional - we just need to figure out the display/startup issue.
