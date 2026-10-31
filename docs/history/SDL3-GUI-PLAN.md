# SDL3 GUI Implementation Plan

**Branch**: `feature/sdl3-gui`
**Principle**: SDL3 is a **bolt-on module**. Core Inferno remains untouched.
**Goal**: Optional cross-platform GUI without polluting the codebase.

---

## Architecture

```
═══════════════════════════════════════════════════════════════════════
                     HEADLESS (Current - Unchanged)
═══════════════════════════════════════════════════════════════════════

    Limbo Apps
        ↓
    libdraw
        ↓
    devdraw.c ──→ Terminal I/O (stdin/stdout/stderr)

    • No GUI code compiled
    • No GUI dependencies
    • Exactly as it works now
    • Dennis Ritchie's code untouched

═══════════════════════════════════════════════════════════════════════
                     SDL3 (New - Optional Bolt-On)
═══════════════════════════════════════════════════════════════════════

    Limbo Apps
        ↓
    libdraw
        ↓
    devdraw.c ──→ [#ifdef GUI_SDL3] ──→ draw-sdl3.c ──→ SDL3
                                              ↓
                                         GPU Rendering
                                      (Metal/Vulkan/D3D)

    • SDL3 only when: mk GUIBACK=sdl3
    • Self-contained in draw-sdl3.c
    • Removable without breaking anything
    • Zero coupling to Inferno internals

═══════════════════════════════════════════════════════════════════════
```

---

## What Gets Modified (Minimal)

### Core Inferno: Touched Files

**Only ONE file gets modified:**

1. **`emu/port/devdraw.c`** - Add minimal `#ifdef` dispatch (see below)

**That's it.** No other Inferno source files are modified.

---

### New Files (SDL3 Module - Separate)

2. **`emu/port/draw-sdl3.c`** - Complete SDL3 implementation (NEW)
3. **`emu/port/draw-sdl3.h`** - Function prototypes (NEW)
4. **`emu/MacOSX/mkfile-gui-sdl3`** - SDL3 build config (NEW)
5. **`emu/Linux/mkfile-gui-sdl3`** - SDL3 build config (NEW)

These files can be **deleted** and everything still works.

---

## Implementation

### Phase 1: devdraw.c - Minimal Dispatch (1 day)

**Goal**: Add tiny hooks for SDL3, zero impact on headless

**File**: `emu/port/devdraw.c`

**Changes**: Add at the top of file:

```c
/*
 * Optional GUI backend dispatch
 * Headless (default): No GUI, terminal I/O only
 * SDL3 (optional): Cross-platform GUI via SDL3
 */

#ifdef GUI_SDL3
#include "draw-sdl3.h"
#endif
```

**Then modify each display function** with minimal dispatch:

```c
void
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
#ifdef GUI_SDL3
	sdl3_attachscreen(r, chan, depth, width, softscreen);
	return;
#endif

	/* Headless: no display */
	*r = Rect(0, 0, 0, 0);
	*softscreen = 0;
}

void
flushmemscreen(Rectangle r)
{
#ifdef GUI_SDL3
	sdl3_flushmemscreen(r);
#endif
	/* Headless: nothing to flush */
}

void
mousereader(void *unused)
{
#ifdef GUI_SDL3
	sdl3_mousereader(unused);
#else
	USED(unused);
#endif
}

void
keyboardreader(void *unused)
{
#ifdef GUI_SDL3
	sdl3_keyboardreader(unused);
#else
	USED(unused);
#endif
}

void
resizewindow(Rectangle r)
{
#ifdef GUI_SDL3
	sdl3_resizewindow(r);
#else
	USED(r);
#endif
}

void
setcursor(void)
{
#ifdef GUI_SDL3
	sdl3_setcursor();
#endif
}

void
closedisplay(void)
{
#ifdef GUI_SDL3
	sdl3_closedisplay();
#endif
}
```

**That's ALL that changes in devdraw.c.**

When `GUI_SDL3` is not defined (headless mode), this code compiles to stubs. Zero overhead.

---

### Phase 2: draw-sdl3.h - Interface (1 hour)

**File**: `emu/port/draw-sdl3.h` (NEW)

```c
#ifndef _DRAW_SDL3_H_
#define _DRAW_SDL3_H_

/*
 * SDL3 GUI backend for Inferno
 * Self-contained implementation, removable without impact
 */

void sdl3_attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen);
void sdl3_flushmemscreen(Rectangle r);
void sdl3_mousereader(void *unused);
void sdl3_keyboardreader(void *unused);
void sdl3_resizewindow(Rectangle r);
void sdl3_setcursor(void);
void sdl3_closedisplay(void);

#endif
```

Simple. Just function prototypes.

---

### Phase 3: draw-sdl3.c - Full Implementation (5-7 days)

**File**: `emu/port/draw-sdl3.c` (NEW - ~800 lines)

This file is **completely self-contained**. All SDL3 logic lives here.

```c
/*
 * SDL3 GUI Backend for Inferno
 *
 * This module provides cross-platform GUI via SDL3.
 * It is completely self-contained and can be removed
 * without impacting Inferno core.
 *
 * Platforms: macOS (Metal), Linux (Vulkan), Windows (D3D)
 */

#include "dat.h"
#include "fns.h"
#include "error.h"
#include "keyboard.h"

#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>

/* SDL3 globals - private to this module */
static SDL_Window *sdl_window = NULL;
static SDL_Renderer *sdl_renderer = NULL;
static SDL_Texture *sdl_texture = NULL;
static int sdl_width = 0;
static int sdl_height = 0;
static int sdl_running = 0;

/*
 * Initialize display and create window
 */
void
sdl3_attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) < 0) {
		fprint(2, "SDL_Init failed: %s\n", SDL_GetError());
		error("cannot initialize SDL3");
	}

	sdl_width = Xsize;   /* Use Inferno's configured size */
	sdl_height = Ysize;

	/* Create window */
	sdl_window = SDL_CreateWindow(
		"Inferno",
		sdl_width, sdl_height,
		SDL_WINDOW_RESIZABLE
	);

	if (!sdl_window) {
		fprint(2, "SDL_CreateWindow failed: %s\n", SDL_GetError());
		SDL_Quit();
		error("cannot create window");
	}

	/* Create GPU renderer */
	sdl_renderer = SDL_CreateRenderer(sdl_window, NULL);
	if (!sdl_renderer) {
		fprint(2, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
		SDL_DestroyWindow(sdl_window);
		SDL_Quit();
		error("cannot create renderer");
	}

	/* High-DPI support (Retina on macOS) */
	float scale = SDL_GetWindowDisplayScale(sdl_window);
	SDL_SetRenderScale(sdl_renderer, scale, scale);

	/* Create texture for pixel buffer */
	sdl_texture = SDL_CreateTexture(
		sdl_renderer,
		SDL_PIXELFORMAT_ARGB8888,
		SDL_TEXTUREACCESS_STREAMING,
		sdl_width, sdl_height
	);

	if (!sdl_texture) {
		fprint(2, "SDL_CreateTexture failed: %s\n", SDL_GetError());
		SDL_DestroyRenderer(sdl_renderer);
		SDL_DestroyWindow(sdl_window);
		SDL_Quit();
		error("cannot create texture");
	}

	SDL_ShowWindow(sdl_window);
	sdl_running = 1;

	/* Tell Inferno about the display */
	*r = Rect(0, 0, sdl_width, sdl_height);
	*chan = RGBA32;
	*depth = 32;
	*width = sdl_width * 4;
	*softscreen = 1;
}

/*
 * Flush pixel buffer to screen
 */
void
sdl3_flushmemscreen(Rectangle r)
{
	if (!sdl_running || !gscreen)
		return;

	/* Upload pixels to GPU */
	SDL_UpdateTexture(sdl_texture, NULL, gscreen->data->base, sdl_width * 4);

	/* Render to window */
	SDL_RenderClear(sdl_renderer);
	SDL_RenderTexture(sdl_renderer, sdl_texture, NULL, NULL);
	SDL_RenderPresent(sdl_renderer);
}

/*
 * Mouse event reader (runs in thread)
 */
void
sdl3_mousereader(void *unused)
{
	SDL_Event event;
	int buttons;

	USED(unused);

	while (sdl_running) {
		while (SDL_PollEvent(&event)) {
			switch (event.type) {
			case SDL_EVENT_QUIT:
				cleanexit(0);
				break;

			case SDL_EVENT_MOUSE_MOTION:
			case SDL_EVENT_MOUSE_BUTTON_DOWN:
			case SDL_EVENT_MOUSE_BUTTON_UP:
				/* Convert SDL buttons to Inferno format */
				buttons = 0;
				if (SDL_GetMouseState(NULL, NULL) & SDL_BUTTON_LMASK)
					buttons |= 1;
				if (SDL_GetMouseState(NULL, NULL) & SDL_BUTTON_MMASK)
					buttons |= 2;
				if (SDL_GetMouseState(NULL, NULL) & SDL_BUTTON_RMASK)
					buttons |= 4;

				absmousetrack(
					(int)event.button.x,
					(int)event.button.y,
					buttons,
					nsec()
				);
				break;

			case SDL_EVENT_MOUSE_WHEEL:
				/* Scroll wheel */
				if (event.wheel.y > 0)
					buttons = 8;   /* scroll up */
				else if (event.wheel.y < 0)
					buttons = 16;  /* scroll down */
				absmousetrack(0, 0, buttons, nsec());
				break;

			case SDL_EVENT_WINDOW_RESIZED:
				sdl_width = event.window.data1;
				sdl_height = event.window.data2;

				/* Recreate texture at new size */
				if (sdl_texture)
					SDL_DestroyTexture(sdl_texture);

				sdl_texture = SDL_CreateTexture(
					sdl_renderer,
					SDL_PIXELFORMAT_ARGB8888,
					SDL_TEXTUREACCESS_STREAMING,
					sdl_width, sdl_height
				);

				/* Notify Inferno */
				resizewindow(Rect(0, 0, sdl_width, sdl_height));
				break;
			}
		}
		SDL_Delay(10);  /* Don't busy-wait */
	}
}

/*
 * Keyboard event reader (runs in thread)
 */
void
sdl3_keyboardreader(void *unused)
{
	SDL_Event event;
	int key;

	USED(unused);

	while (sdl_running) {
		SDL_WaitEvent(&event);

		if (event.type == SDL_EVENT_KEY_DOWN) {
			/* Map SDL keys to Inferno keycodes */
			switch (event.key.scancode) {
			case SDL_SCANCODE_ESCAPE:   key = 27; break;
			case SDL_SCANCODE_RETURN:   key = '\n'; break;
			case SDL_SCANCODE_TAB:      key = '\t'; break;
			case SDL_SCANCODE_BACKSPACE: key = '\b'; break;
			case SDL_SCANCODE_DELETE:   key = 0x7F; break;
			case SDL_SCANCODE_UP:       key = Kup; break;
			case SDL_SCANCODE_DOWN:     key = Kdown; break;
			case SDL_SCANCODE_LEFT:     key = Kleft; break;
			case SDL_SCANCODE_RIGHT:    key = Kright; break;
			case SDL_SCANCODE_HOME:     key = Khome; break;
			case SDL_SCANCODE_END:      key = Kend; break;
			case SDL_SCANCODE_PAGEUP:   key = Kpgup; break;
			case SDL_SCANCODE_PAGEDOWN: key = Kpgdown; break;
			default:
				key = event.key.key;
				break;
			}

			keystroke(key);
		}
	}
}

/*
 * Window resize (handled in event loop)
 */
void
sdl3_resizewindow(Rectangle r)
{
	USED(r);
	/* SDL handles this automatically */
}

/*
 * Set cursor (stub for now)
 */
void
sdl3_setcursor(void)
{
	/* Use default cursor */
}

/*
 * Shutdown
 */
void
sdl3_closedisplay(void)
{
	sdl_running = 0;

	if (sdl_texture) {
		SDL_DestroyTexture(sdl_texture);
		sdl_texture = NULL;
	}

	if (sdl_renderer) {
		SDL_DestroyRenderer(sdl_renderer);
		sdl_renderer = NULL;
	}

	if (sdl_window) {
		SDL_DestroyWindow(sdl_window);
		sdl_window = NULL;
	}

	SDL_Quit();
}
```

**This is the entire SDL3 implementation.** Self-contained. Can be deleted.

---

### Phase 4: Build System (1 day)

**Goal**: Conditional compilation that keeps GUI out of headless

#### File: `emu/MacOSX/mkfile-gui-sdl3` (NEW)

```makefile
# SDL3 GUI backend for macOS
# Only included when GUIBACK=sdl3

GUISRC=\
	../port/draw-sdl3.$O\

SDL3_CFLAGS=`sdl3-config --cflags`
SDL3_LIBS=`sdl3-config --libs` -lSDL3_ttf

GUIFLAGS=-DGUI_SDL3 $SDL3_CFLAGS
GUILIBS=$SDL3_LIBS
```

#### File: `emu/MacOSX/mkfile-gui-headless` (NEW)

```makefile
# Headless (no GUI) - default
# Zero GUI code, zero dependencies

GUISRC=
GUIFLAGS=
GUILIBS=
```

#### Modify: `emu/MacOSX/mkfile`

Add near top (after GUIBACK=headless line):

```makefile
# Include GUI-specific configuration
<mkfile-gui-$GUIBACK
```

Modify OBJ list:

```makefile
OBJ=\
	asm-$OBJTYPE.$O\
	os.$O\
	$GUISRC\              # GUI source (if any)
	devdraw.$O\
	# ... rest unchanged ...
```

Modify devdraw compilation:

```makefile
../port/devdraw.$O: ../port/devdraw.c
	$CC $CFLAGS $GUIFLAGS ../port/devdraw.c
```

Modify linking:

```makefile
$O.emu: $OBJ $CONF.$O $LIBFILES
	$LD $LDFLAGS -o $target $OBJ $CONF.$O $LIBFILES $SYSLIBS $GUILIBS
```

**Same changes for `emu/Linux/mkfile`**

---

### Phase 5: Testing (3-4 days)

#### Test 1: Headless Build (MUST work as before)

```bash
cd emu/MacOSX
mk clean
mk GUIBACK=headless

# Verify zero SDL code
nm o.emu | grep -i sdl   # Should be empty

# Verify it runs
./o.emu -r../..
; ls
; echo hello
; rm '#p/8' /fd/0  # terminate
```

**Result**: Must work exactly as current version.

#### Test 2: SDL3 Build

```bash
# Install SDL3 first
brew install sdl3 sdl3_ttf

mk clean
mk GUIBACK=sdl3

# Verify SDL is linked
nm o.emu | grep -i sdl   # Should show SDL symbols

# Run GUI apps
./o.emu -r../.. wm/colors   # Color picker
./o.emu -r../.. acme        # Editor
```

**Result**: GUI window should appear, rendering should work.

#### Test 3: Both Builds Side-by-Side

```bash
# Build headless
mk clean
mk GUIBACK=headless
mv o.emu o.emu-headless

# Build SDL3
mk clean
mk GUIBACK=sdl3
mv o.emu o.emu-sdl3

# Compare sizes
ls -lh o.emu-*
# headless: ~1.0 MB
# sdl3:     ~1.2 MB

# Both should work
./o.emu-headless -r../..    # Terminal
./o.emu-sdl3 -r../.. acme   # GUI
```

#### Test Matrix

| Platform | Headless | SDL3 | Status |
|----------|----------|------|--------|
| macOS ARM64 | ✓ | ✓ | Primary |
| Linux ARM64 | ✓ | ✓ | Jetson |
| Linux x86_64 | ✓ | ✓ | Server |

---

### Phase 6: Documentation (1 day)

Create **`docs/SDL3-GUI.md`**:

```markdown
# SDL3 GUI for InferNode

## Overview

InferNode supports an optional SDL3 GUI backend for visual applications
like Acme and the window manager. The GUI is **completely optional** and
adds zero overhead to headless builds.

## Headless Mode (Default)

Default build is headless (terminal I/O only):

```bash
mk GUIBACK=headless   # or just: mk
./o.emu -r../..
```

Zero GUI code. Zero dependencies. Works in SSH, containers, servers.

## SDL3 Mode (Optional)

To enable GUI:

### Install SDL3

**macOS:**
```bash
brew install sdl3 sdl3_ttf
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt install libsdl3-dev libsdl3-ttf-dev
```

### Build with GUI

```bash
mk GUIBACK=sdl3
./o.emu -r../.. acme
```

### Features

- GPU-accelerated rendering (Metal on macOS, Vulkan on Linux)
- High-DPI support (Retina displays)
- Cross-platform (macOS, Linux, Windows)
- Self-contained module

## Architecture

SDL3 is a bolt-on module. Core Inferno is unchanged.

Files:
- `emu/port/draw-sdl3.c` - SDL3 implementation (can be deleted)
- `emu/port/draw-sdl3.h` - Interface
- `emu/port/devdraw.c` - Minimal dispatch via `#ifdef GUI_SDL3`

Everything else untouched.
```

Update **`README.md`** with SDL3 build instructions.

---

## Timeline

| Phase | Task | Duration |
|-------|------|----------|
| 1 | devdraw.c dispatch | 1 day |
| 2 | draw-sdl3.h interface | 1 hour |
| 3 | draw-sdl3.c implementation | 5-7 days |
| 4 | Build system | 1 day |
| 5 | Testing | 3-4 days |
| 6 | Documentation | 1 day |
| **Total** | | **11-15 days** |

**Realistic with buffer: 3 weeks**

---

## Success Criteria

### Must Have:
- ✅ Headless build unchanged (zero GUI code)
- ✅ SDL3 as removable module
- ✅ Acme works with SDL3
- ✅ Window manager works
- ✅ Mouse and keyboard functional

### Verification:
- ✅ `nm o.emu | grep SDL` empty for headless
- ✅ Headless binary ~1.0 MB (unchanged)
- ✅ Can delete draw-sdl3.c and still build headless
- ✅ Core Inferno files pristine

---

## The Sacred Principle

**Inferno core remains untouched.**

SDL3 is a guest. It can be removed without breaking anything.
Dennis Ritchie's work remains pure.

---

Ready to implement when approved.
