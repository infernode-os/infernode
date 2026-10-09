# SDL3 Implementation - Resume Here

**Last Updated**: 2026-01-14
**Branch**: `feature/sdl3-gui`
**Next Session**: Start here to continue SDL3 work

---

## Quick Status

**SDL3 Backend**: 95% complete
**Blocker**: Inferno Display.allocate() doesn't connect to SDL window
**Time to fix**: 1-2 hours

---

## What You'll See When You Resume

### Working:
```bash
./build-macos-sdl3.sh
./emu/MacOSX/o.emu -r. /dis/test-sdl3
```

**Result**:
- SDL window opens ✓
- Window is white (blank)
- Console shows: "Display.allocate succeeded! Drawing red rectangle..."
- But: No rectangles visible (Display disconnected from SDL)

### The Problem in One Sentence

**Inferno programs create a Display successfully, but it's not connected to our SDL window, so their drawing goes nowhere.**

---

## Exact Next Steps

### Step 1: Add Logging to devdraw.c (5 minutes)

**File**: `emu/port/devdraw.c`
**Line**: ~867 (search for "screendata.bdata = attachscreen")

**Add**:
```c
int
initscreenimage(void)
{
    fprint(2, "devdraw: initscreenimage() CALLED\n");  // ADD THIS

    Rectangle r;
    if(screenimage != nil)
        return 1;

    memimageinit();
    screendata.base = nil;

    fprint(2, "devdraw: Calling attachscreen()...\n");  // ADD THIS
    screendata.bdata = attachscreen(&r, &chan, &depth, &width, &sdraw.softscreen);
    fprint(2, "devdraw: attachscreen returned %p\n", screendata.bdata);  // ADD THIS

    if(screendata.bdata == nil)
        return 0;
    // ... rest of function
}
```

**Rebuild and test**: See if initscreenimage is called when test-sdl3 runs.

### Step 2: Check When initscreenimage is Called (10 minutes)

**File**: `emu/port/devdraw.c`
**Search for**: "initscreenimage()"

**Find**:
- Who calls it?
- Under what conditions?
- Does it get called for Display.allocate(nil)?

**Commands**:
```bash
grep -n "initscreenimage" emu/port/devdraw.c
```

### Step 3: Compare with Working X11 (15 minutes)

**If X11 emu exists**:
```bash
# Run with X11
./MacOSX/arm64/bin/emu -r. /dis/test-sdl3
# Check if it shows rectangles

# If it works, compare:
# - Does X11 call attachscreen differently?
# - Does X11 version have different devdraw.c?
```

### Step 4: Check libdraw Display Creation (20 minutes)

**Files**: `libdraw/init.c`, `libdraw/alloc.c`

**Look for**:
- How `Display.allocate()` works
- Does it open `/dev/draw`?
- What parameters control screen connection?

**Search**:
```bash
grep -rn "initdisplay\|gengetwindow\|getwindow" libdraw/
```

### Step 5: Try Different Test Approach (10 minutes)

**Modify**: `appl/test-sdl3.b`

**Try opening /dev/draw explicitly**:
```limbo
init(ctxt: ref Draw->Context, nil: list of string)
{
    sys = load Sys Sys->PATH;
    draw = load Draw Draw->PATH;

    # Try explicit /dev/draw connection
    drawfd := sys->open("/dev/draw/new", Sys->ORDWR);
    if (drawfd == nil) {
        sys->fprint(sys->fildes(2), "Cannot open /dev/draw/new: %r\n");
        return;
    }

    # Use this fd to create display?
    # (check Draw module API for how to use fd)
}
```

### Step 6: Study Working GUI App (15 minutes)

**Check**: `appl/wm/wm.b`

**Find**:
- How does wm initialize display?
- Does it do something special that test-sdl3 doesn't?
- Copy that initialization pattern

**Search**:
```bash
grep -A20 "init(" appl/wm/wm.b | head -40
```

---

## Critical Files for Next Session

### To Modify:
1. `emu/port/devdraw.c` - Add logging to initscreenimage
2. `appl/test-sdl3.b` - Try different Display init
3. Possibly: `libdraw/init.c` - If Display.allocate needs changes

### To Reference:
1. `docs/SDL3-IMPLEMENTATION-STATUS.md` - Full status (this file)
2. `docs/SDL3-SUCCESS.md` - What we achieved
3. `emu/port/draw-sdl3.c` - SDL3 backend (working)

### To Run:
```bash
# Build
./build-macos-sdl3.sh

# Test (shows problem)
./emu/MacOSX/o.emu -r. /dis/test-sdl3

# Look for in output:
# - "initscreenimage() CALLED" (if our logging added)
# - "attachscreen() called" (means connection working)
```

---

## The Last Thing We Learned

**Our hardcoded test pattern works**:
- Buffer filled with gray: ✓ Displays
- Red/Green/Blue squares: ✓ All display correctly
- Colors perfect (XRGB8888 format)

**This proves**:
- SDL3 rendering: ✓ Working
- Texture upload: ✓ Working
- Color format: ✓ Correct

**But programs' drawing doesn't appear**:
- `display.image.draw()` called (no error)
- But buffer stays white
- Means: They're drawing to different buffer than our SDL buffer

---

## Expected Solution

**Likely**: Programs need to be told to use `/dev/draw` explicitly, OR there's a setup step in devdraw.c that creates screenimage from our buffer.

**Check**: Does screenimage get created? Does it use our buffer?

**Fix**: Make sure `allocmemimaged()` in devdraw.c uses the buffer returned by our `attachscreen()`.

---

## Time Invested

- SDL3 implementation: 8 hours
- Threading architecture: 3 hours
- Pixel format debugging: 2 hours
- Display connection investigation: 1 hour
- **Total**: ~14 hours

**Remaining**: 1-2 hours to connect Display to SDL

---

## Pickup Checklist

When resuming work:

1. ☐ Read this document (SDL3-RESUME-HERE.md)
2. ☐ Read SDL3-IMPLEMENTATION-STATUS.md for details
3. ☐ Build: `./build-macos-sdl3.sh`
4. ☐ Test: `./emu/MacOSX/o.emu -r. /dis/test-sdl3`
5. ☐ Verify: Window opens (white screen = expected)
6. ☐ Start: Add logging to devdraw.c per Step 1 above
7. ☐ Debug: Follow steps 1-6 systematically

**Goal**: See colored rectangles from test-sdl3 in SDL window.
**Success**: Red and green rectangles visible = Display connected!

---

## Branch Status

```bash
git branch --show-current
# Should show: feature/sdl3-gui

git log --oneline -5
# Should show latest commits

git status
# Should show clean (after this commit)
```

---

Ready to resume SDL3 work from this point.
