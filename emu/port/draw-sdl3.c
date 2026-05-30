/*
 * SDL3 GUI Backend for Infernode
 *
 * This module provides cross-platform GUI via SDL3.
 * It is completely self-contained and can be removed
 * without impacting Infernode core.
 *
 * Platforms: macOS (Metal), Linux (Vulkan/OpenGL), Windows (D3D12)
 *
 * Function signatures match stubs-headless.c for drop-in replacement.
 *
 * RENDERING ARCHITECTURE (Performance Critical)
 * =============================================
 *
 * Infernode's draw system calls flushmemscreen() frequently during rendering
 * (100-1000+ times per frame for text-heavy operations like directory
 * listings or text selection). The naive implementation would call
 * SDL_UpdateTexture() and SDL_RenderPresent() on each flush, but on macOS
 * this requires dispatch_sync() to the main thread for each call, creating
 * massive synchronization overhead (multi-second delays for simple operations).
 *
 * Solution: Batched Dirty Rectangle Accumulation
 *
 *   1. flushmemscreen() does NO synchronization - it only accumulates
 *      dirty rectangles into a bounding box (O(1), ~10 nanoseconds)
 *
 *   2. sdl3_mainloop() runs on the main thread at ~60Hz and performs:
 *      - Single SDL_UpdateTexture() with the accumulated dirty region
 *      - Single SDL_RenderPresent() per frame
 *
 * This reduces cross-thread synchronization from 1000s of dispatch_sync()
 * calls per frame to zero, while maintaining correct rendering.
 *
 * The tradeoff is ~16ms maximum latency from draw to display, which is
 * imperceptible and far better than the previous multi-second delays.
 */

#include "dat.h"
#include "fns.h"
#include "error.h"
#include "keyboard.h"
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>

#include <SDL3/SDL.h>

#ifdef __APPLE__
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <TargetConditionals.h>
#endif

/*
 * Touch platforms with an on-screen keyboard (iOS, Android). On these the
 * keyboard must be requested explicitly (setsoftkbd) so it appears only on
 * text-field focus. On desktop there is no soft keyboard and text input is
 * simply left enabled, so typing (SDL_EVENT_TEXT_INPUT) always works.
 */
#if (defined(__APPLE__) && TARGET_OS_IOS) || defined(__ANDROID__)
#define MOBILE_TOUCH 1
#else
#define MOBILE_TOUCH 0
#endif

/* External keyboard queue (from devcons.c) */
extern Queue *gkbdq;

/* SDL3 state - private to this module */
static SDL_Window *sdl_window = NULL;
static SDL_Renderer *sdl_renderer = NULL;
static SDL_Texture *sdl_texture = NULL;
static int sdl_width = 0;
static int sdl_height = 0;
/* Byte stride of a screen_data row. NOT sdl_width*4: Inferno's memimage
 * pads each scan line up to a whole number of ulong words (wordsperline),
 * so for an odd pixel width (e.g. iPhone 15 at 3x = 1179px) the real
 * stride is sdl_width*4 + 4. Using sdl_width*4 as the texture-upload pitch
 * then drifts every row by a pixel — the diagonal shear seen on iOS. On
 * even widths (macOS/Linux Retina 2x) this equals sdl_width*4, so it's a
 * no-op there. */
static int sdl_stride = 0;
static int sdl_running = 0;
static int sdl_initialized = 0;  /* Flag: SDL already initialized on main thread */

/* Mouse state */
static int mouse_x = 0;
static int mouse_y = 0;
static int mouse_buttons = 0;

/*
 * Event-based button state tracking.
 *
 * SDL_GetMouseState() returns the instantaneous button state at the time
 * of the call, NOT the state at the time a queued event was generated.
 * When a fast click produces both BUTTON_DOWN and BUTTON_UP events before
 * the event loop runs, SDL_GetMouseState() during BUTTON_DOWN processing
 * already shows the button released — the click is silently lost.
 *
 * This variable tracks button state from events: BUTTON_DOWN sets bits,
 * BUTTON_UP clears them, mirroring how the X11 backend (win-x11a.c)
 * derives state from the event structure.
 */
static Uint32 sdl_button_state = 0;

/* HiDPI state — pixel-per-logical-point ratio used to map SDL event
 * coordinates (logical) to pixel-space coordinates the renderer/
 * window_to_texture_coords logic operates in.
 *
 * Earlier this was SDL_GetWindowDisplayScale (the *display density*
 * factor, e.g. 2.8125 on a 388 dpi Android phone). On platforms where
 * SDL3 reports event coordinates already in pixels (Android in
 * particular), using density-as-multiplier produced nonsense: a tap
 * at 540×711 logical was converted to 1520×2000 pixels, far outside
 * the 1080×2116 canvas, and every touch landed in or past the right/
 * bottom edge.
 *
 * Compute it as the actual GetWindowSizeInPixels / GetWindowSize
 * ratio in init_hidpi and on every WINDOW_PIXEL_SIZE_CHANGED:
 *   - Android logical == pixels → 1.0 (no multiplier needed)
 *   - Linux 150% HiDPI: 1.5
 *   - macOS Retina: 2.0
 * Universal correctness, no platform branches.
 */
static float display_scale = 1.0f;

/* Shutdown request flag - can be set from any thread */
static volatile int sdl_quit_requested = 0;

/*
 * Touch / multi-finger gesture state.  INFR-121.
 *
 * Touchscreen SDL_VIDEO platforms (Android, iOS) send SDL_EVENT_FINGER_*
 * for every touch and ALSO synthesise SDL_EVENT_MOUSE_* for the first
 * finger by default — single-finger touches keep working as clicks/drags
 * through the existing mouse path unchanged.  Here we track the active
 * finger set and turn TWO-FINGER drags into scroll-wheel events, the
 * conventional mobile gesture for "scroll content".  Lands once in
 * shared code, benefits iOS + Android + (any touch-capable) desktop.
 *
 *   one finger:   existing mouse semantics (select, drag)
 *   two fingers:  swipe → wheel ticks (buttons 8/16/32/64)
 *
 * Multi-finger gesture starts when finger #2 lands; ends when finger
 * count drops below 2.  While in gesture, mouse motion is suppressed
 * (SDL keeps synthesising mouse motion from the first finger even
 * while the second is down, which would otherwise fight the scroll).
 */
#define TOUCH_MAX_FINGERS	10
/* 50 physical pixels ≈ a finger's width swipe per wheel tick.  On a 450dpi
 * screen that's ~3mm — flick-sensitive without being twitchy.  Each
 * mousetrack(8/16) call is one wheel tick (3-5 lines in most wm apps),
 * so a 500px swipe ≈ 10 ticks ≈ half a screen.  Tune if needed. */
#define TOUCH_SCROLL_TICK_PX	50.0f
struct touch_finger {
	SDL_FingerID	id;
	float		last_x;	/* physical pixels (matches mouse path's space) */
	float		last_y;
};
static struct touch_finger touch_fingers[TOUCH_MAX_FINGERS];
static int touch_finger_count = 0;
static float touch_scroll_accum_x = 0.0f;
static float touch_scroll_accum_y = 0.0f;
static int touch_in_multi_gesture = 0;

/*
 * Long-press → context-menu (button-3) synthesis. INFR-163/160/162.
 *
 * A touchscreen produces no button-2/3, so the Plan 9 context menus across
 * the wm apps (and lucipres) are otherwise unreachable. A single finger held
 * roughly still past LONGPRESS_MS is promoted to a button-3 press at the
 * touch point: we drop the synthesised left button (so it isn't read as a
 * click/drag) and raise the right button, held until the finger lifts —
 * exactly the Plan 9 hold-to-show / release-to-select menu interaction.
 * Moving past the slop (a drag), a second finger (scroll), or an early lift
 * (a tap) all cancel it, leaving normal single-finger mouse semantics.
 * Shared path → fixes iOS and Android at once; button-3 is the standard
 * context-menu button, so wm.b's old button-2 menu is migrated to match.
 */
#define LONGPRESS_MS		500
#define LONGPRESS_SLOP_PX	16.0f
static int touch_lp_armed = 0;		/* a single-finger press may become a long-press */
static int touch_lp_fired = 0;		/* button-3 has been synthesised, awaiting lift */
static Uint64 touch_lp_down_ms = 0;	/* when the finger landed */
static float touch_lp_x0 = 0.0f;	/* landing point (physical px) for slop test */
static float touch_lp_y0 = 0.0f;

/*
 * Dirty rectangle accumulator for batched updates.
 *
 * CRITICAL PERFORMANCE FIX:
 * Previously, flushmemscreen() called dispatch_sync() for every tiny
 * texture update (100s of times per frame for text rendering), causing
 * massive synchronization overhead. Now flushmemscreen() just accumulates
 * dirty rectangles with NO synchronization, and the main loop does a
 * single dispatch_sync() per frame to upload all changes at once.
 */
static volatile int dirty_pending = 0;
static int dirty_min_x = 0, dirty_min_y = 0;
static int dirty_max_x = 0, dirty_max_y = 0;

/* Screen data pointer (set by attachscreen) */
static uchar *screen_data = NULL;

/*
 * Cross-thread window creation dispatch (non-Apple platforms).
 *
 * On Windows (and potentially Linux), SDL3 window/renderer creation
 * must happen on the main thread (the one that called SDL_Init).
 * The worker thread (running emuinit/wm) signals the main thread
 * to create the window, then waits for completion.
 */
#ifndef __APPLE__
static volatile int create_window_requested = 0;
static volatile int create_window_done = 0;
static volatile int create_window_result = 0;
#endif

/*
 * Destination rectangle for rendering texture to window.
 * Used to maintain aspect ratio and center content when
 * window size differs from texture size (e.g., full-screen).
 */
static SDL_FRect dest_rect = {0, 0, 0, 0};
static int window_width = 0;
static int window_height = 0;
/* Safe-area rect in physical pixels: the part of the window not covered by
 * the iOS status bar / Dynamic Island / home indicator. The Inferno screen
 * is sized to this and presented here, so the UI isn't occluded. On desktop
 * SDL_GetWindowSafeArea returns the whole window, so this equals the full
 * window and the behaviour is unchanged. */
static int safe_x = 0, safe_y = 0, safe_w = 0, safe_h = 0;

/*
 * Calculate destination rectangle for centered, aspect-ratio-preserving render.
 * This prevents stretching/distortion when window and texture sizes differ.
 */
static void
calc_dest_rect(void)
{
	float scale_x, scale_y, scale;
	float dest_w, dest_h;
	int aw = safe_w, ah = safe_h, ax = safe_x, ay = safe_y;

	/* Present into the safe area, not the full window, so the iOS status
	 * bar / home indicator don't occlude the UI. Fall back to the full
	 * window if the safe area isn't known yet. */
	if (aw <= 0 || ah <= 0) {
		aw = window_width; ah = window_height; ax = 0; ay = 0;
	}

	if (aw <= 0 || ah <= 0 || sdl_width <= 0 || sdl_height <= 0) {
		dest_rect.x = (float)ax;
		dest_rect.y = (float)ay;
		dest_rect.w = (float)sdl_width;
		dest_rect.h = (float)sdl_height;
		return;
	}

	/* Scale to fit the surface in the safe area, preserving aspect. */
	scale_x = (float)aw / (float)sdl_width;
	scale_y = (float)ah / (float)sdl_height;
	scale = (scale_x < scale_y) ? scale_x : scale_y;

	dest_w = (float)sdl_width * scale;
	dest_h = (float)sdl_height * scale;

	/* Centre within the safe area (offset by the safe-area origin). */
	dest_rect.x = (float)ax + ((float)aw - dest_w) / 2.0f;
	dest_rect.y = (float)ay + ((float)ah - dest_h) / 2.0f;
	dest_rect.w = dest_w;
	dest_rect.h = dest_h;
}

/*
 * Transform window mouse coordinates to texture coordinates.
 * Accounts for letterboxing offset and scaling.
 */
static void
window_to_texture_coords(float win_x, float win_y, int *tex_x, int *tex_y)
{
	float rel_x, rel_y;
	int x, y;

	if (dest_rect.w <= 0 || dest_rect.h <= 0) {
		/* Fallback - direct mapping */
		*tex_x = (int)win_x;
		*tex_y = (int)win_y;
		return;
	}

	/* Subtract letterbox offset to get position relative to rendered texture */
	rel_x = win_x - dest_rect.x;
	rel_y = win_y - dest_rect.y;

	/* Scale from rendered size to texture size */
	x = (int)(rel_x * (float)sdl_width / dest_rect.w);
	y = (int)(rel_y * (float)sdl_height / dest_rect.h);

	/* Clamp to texture bounds */
	if (x < 0) x = 0;
	if (y < 0) y = 0;
	if (x >= sdl_width) x = sdl_width - 1;
	if (y >= sdl_height) y = sdl_height - 1;

	*tex_x = x;
	*tex_y = y;
}

/*
 * Read physical pixel dimensions and display scale after window creation.
 * Updates sdl_width/sdl_height to physical pixels for crisp HiDPI rendering.
 * Must be called after sdl_window is created and before texture creation.
 */
static void update_text_input_area(void);

static void
init_hidpi(void)
{
	int win_w, win_h, pix_w, pix_h;

	SDL_GetWindowSize(sdl_window, &win_w, &win_h);
	SDL_GetWindowSizeInPixels(sdl_window, &pix_w, &pix_h);

	/* See the display_scale comment for why this is the right
	 * definition (it's the pixels-per-logical-point ratio, not the
	 * display density). */
	if (win_w > 0)
		display_scale = (float)pix_w / (float)win_w;
	else
		display_scale = 1.0f;

	window_width = pix_w;
	window_height = pix_h;

	/* Safe area (logical points) -> physical pixels. On iOS this excludes
	 * the status bar / Dynamic Island / home indicator; on desktop it is
	 * the whole window. The Inferno screen is sized to the safe area so
	 * the UI isn't drawn under those system regions. */
	{
		SDL_Rect safe;
		if (SDL_GetWindowSafeArea(sdl_window, &safe) && safe.w > 0 && safe.h > 0) {
			safe_x = (int)(safe.x * display_scale);
			safe_y = (int)(safe.y * display_scale);
			safe_w = (int)(safe.w * display_scale);
			safe_h = (int)(safe.h * display_scale);
		} else {
			safe_x = 0; safe_y = 0; safe_w = pix_w; safe_h = pix_h;
		}
	}

	sdl_width = safe_w;
	sdl_height = safe_h;
	calc_dest_rect();
	update_text_input_area();	/* window may have resized/rotated */
}

/* Keep the top pinned (don't slide) for the focused input; set when the
 * GUI requests the keyboard for a workspace text app. See setsoftkbd.
 * Written from the devcons worker thread, read on the main thread. */
static volatile int softkbd_keeptop = 0;

/* Explicit focused-widget rect in window POINTS, set by the GUI via
 * /dev/consctl "kbd rect x y w h" (see setsoftkbd_rect). When w*h > 0
 * this overrides the hard-coded top/bottom rect in
 * update_text_input_area — SDL slides the view so the *actual* widget
 * stays above the keyboard, regardless of where the cursor is or
 * whether keeptop is set. Cleared with "kbd rect 0 0 0 0". Plain ints
 * read by the main thread, written from the devcons worker thread;
 * the one-frame race is harmless. */
static volatile int softkbd_rect_x = 0;
static volatile int softkbd_rect_y = 0;
static volatile int softkbd_rect_w = 0;
static volatile int softkbd_rect_h = 0;

/*
 * iOS soft-keyboard avoidance via SDL_SetTextInputArea, which tells UIKit
 * where the caret is (window POINTS); SDL then slides the view up so that
 * rect stays above the keyboard. The rect is position-aware:
 *
 *   keeptop == 0 (chat input, at the very bottom): put the rect at the
 *     bottom so SDL slides the input up into view.
 *   keeptop == 1 (a workspace text app — editor/man/settings, which fill
 *     the upper area below the header): put the rect at the TOP. It's
 *     already above the keyboard, so SDL does NOT slide — the top stays
 *     pinned and a cursor near the top no longer scrolls off-screen. The
 *     keyboard simply overlays the lower part of the app.
 *
 * No-op on macOS/Linux (no soft keyboard).
 */
static void
update_text_input_area(void)
{
#if defined(__APPLE__) && TARGET_OS_IOS
	int win_w = 0, win_h = 0;
	SDL_Rect r;
	int ih;

	if (!sdl_window)
		return;
	SDL_GetWindowSize(sdl_window, &win_w, &win_h);	/* points */
	if (win_w <= 0 || win_h <= 0)
		return;
	if (softkbd_rect_w > 0 && softkbd_rect_h > 0) {
		/* Explicit focused-widget rect from the GUI (INFR-166).
		 * Clamp to the window so a slightly out-of-window value
		 * (rotated layout caught mid-update) doesn't make SDL
		 * round-trip a degenerate rect to UIKit. */
		r.x = softkbd_rect_x < 0 ? 0 : softkbd_rect_x;
		r.y = softkbd_rect_y < 0 ? 0 : softkbd_rect_y;
		r.w = softkbd_rect_w;
		r.h = softkbd_rect_h;
		if (r.x + r.w > win_w) r.w = win_w - r.x;
		if (r.y + r.h > win_h) r.h = win_h - r.y;
		if (r.w <= 0 || r.h <= 0)
			return;
	} else {
		ih = 56;				/* input row height, points */
		r.x = 0;
		r.w = win_w;
		r.h = ih;
		if (softkbd_keeptop)
			r.y = 0;			/* top — SDL won't need to slide */
		else
			r.y = win_h - ih;		/* bottom input row — SDL slides it up */
	}
	SDL_SetTextInputArea(sdl_window, &r, 0);
#endif
}

/*
 * Soft-keyboard control, driven from Limbo via /dev/consctl ("kbd on" /
 * "kbd off"). The keyboard must surface only while a text field is
 * focused — not on every tap — so text input is no longer started
 * unconditionally; the GUI requests it on focus and drops it on blur.
 *
 * setsoftkbd runs on an Inferno worker thread (the devcons write), but
 * SDL_StartTextInput/StopTextInput touch UIKit and MUST run on the main
 * thread — calling them here crashes on device. So setsoftkbd only sets
 * a desired-state flag; sdl3_mainloop (main thread) reconciles it. The
 * flag is a plain int written from one thread and read from another: the
 * only race is a one-frame delay, which is harmless.
 */
static volatile int softkbd_want = 0;	/* desired state (set from any thread) */
static int softkbd_applied = 0;		/* last state pushed to SDL (main thread) */

/*
 * on: 0 = hide, 1 = show (bottom input — slide to keep it above the
 * keyboard), 2 = show + keep the top pinned (workspace text app — don't
 * slide). Encoded in the int so the headless stubs and the signature
 * stay unchanged.
 */
void
setsoftkbd(int on)
{
#if MOBILE_TOUCH
	softkbd_want = on ? 1 : 0;
	softkbd_keeptop = (on == 2);
#else
	/* Desktop: text input stays enabled; nothing to toggle. */
	USED(on);
#endif
}

/*
 * Override the keyboard-avoidance rect with the focused widget's actual
 * bounds (window POINTS). Called from /dev/consctl "kbd rect x y w h"
 * (devcons.c) — Limbo helper is appl/lib/softkbd.b. When the rect is
 * non-empty it wins over the legacy keeptop hint; (0,0,0,0) clears
 * the override and the hard-coded top/bottom rect comes back into
 * play. apply_softkbd will re-push the area on the main thread.
 */
void
setsoftkbd_rect(int x, int y, int w, int h)
{
#if MOBILE_TOUCH
	softkbd_rect_x = x;
	softkbd_rect_y = y;
	softkbd_rect_w = (w > 0) ? w : 0;
	softkbd_rect_h = (h > 0) ? h : 0;
#else
	USED(x); USED(y); USED(w); USED(h);
#endif
}

/*
 * Apply a pending soft-keyboard request. MUST be called on the main
 * (SDL/UIKit) thread — sdl3_mainloop calls it each iteration.
 */
static void
apply_softkbd(void)
{
#if MOBILE_TOUCH
	static int applied_keeptop = 0;
	static int applied_rx = 0, applied_ry = 0, applied_rw = 0, applied_rh = 0;
	if (!sdl_window)
		return;
	if (softkbd_want != softkbd_applied) {
		softkbd_applied = softkbd_want;
		if (softkbd_applied) {
			SDL_StartTextInput(sdl_window);
			update_text_input_area();
		} else {
			SDL_StopTextInput(sdl_window);
		}
	} else if (softkbd_want &&
		   (softkbd_keeptop != applied_keeptop ||
		    softkbd_rect_x != applied_rx ||
		    softkbd_rect_y != applied_ry ||
		    softkbd_rect_w != applied_rw ||
		    softkbd_rect_h != applied_rh)) {
		/* keyboard already up but the mode or the focused-widget
		 * rect changed (focus moved between chat and a workspace
		 * app, or the cursor moved within the same app — INFR-166). */
		update_text_input_area();
	}
	applied_keeptop = softkbd_keeptop;
	applied_rx = softkbd_rect_x;
	applied_ry = softkbd_rect_y;
	applied_rw = softkbd_rect_w;
	applied_rh = softkbd_rect_h;
#endif
}

/*
 * Create SDL renderer and streaming texture for the window.
 * Must be called on the main thread (Cocoa/Windows requirement)
 * and after init_hidpi() so sdl_width/sdl_height are physical pixels.
 * Returns 1 on success, 0 on failure.  Sets sdl_renderer and sdl_texture.
 */
static int
create_renderer_and_texture(void)
{
	sdl_renderer = SDL_CreateRenderer(sdl_window, NULL);
	if (!sdl_renderer)
		return 0;

	SDL_SetRenderVSync(sdl_renderer, 0);
	SDL_SetRenderLogicalPresentation(sdl_renderer, sdl_width, sdl_height,
		SDL_LOGICAL_PRESENTATION_DISABLED);

	sdl_texture = SDL_CreateTexture(
		sdl_renderer,
		SDL_PIXELFORMAT_XRGB8888,
		SDL_TEXTUREACCESS_STREAMING,
		sdl_width, sdl_height
	);
	if (!sdl_texture) {
		SDL_DestroyRenderer(sdl_renderer);
		sdl_renderer = NULL;
		return 0;
	}

	SDL_SetTextureScaleMode(sdl_texture, SDL_SCALEMODE_NEAREST);
	SDL_ShowWindow(sdl_window);
#if !MOBILE_TOUCH
	/* Desktop: no soft keyboard, so leave text input enabled — typing
	 * (SDL_EVENT_TEXT_INPUT) needs it. On mobile we deliberately do NOT
	 * start it here; the keyboard must appear only on text-field focus
	 * (the GUI calls setsoftkbd via /dev/consctl). */
	SDL_StartTextInput(sdl_window);
#endif
	update_text_input_area();
	return 1;
}

/*
 * Map raw SDL button state to Inferno button mask with modifier key emulation.
 * On macOS laptops without a three-button mouse:
 *   - Option + Left Click  = Button 2 (middle click)
 *   - Command + Left Click = Button 3 (right click)
 * This follows Plan 9 / Acme conventions.
 *
 * Takes the raw SDL button bitmask (from event-based tracking) rather than
 * polling SDL_GetMouseState(), which can miss fast clicks due to a race
 * between event queuing and state polling.
 */
static int
map_buttons(Uint32 state)
{
	int buttons = 0;
	SDL_Keymod mods = SDL_GetModState();

	/* Check for physical buttons */
	int left = (state & SDL_BUTTON_LMASK) ? 1 : 0;
	int middle = (state & SDL_BUTTON_MMASK) ? 1 : 0;
	int right = (state & SDL_BUTTON_RMASK) ? 1 : 0;

	/* Emulate button 2 (middle) with Option/Alt + Left Click */
	if (left && (mods & SDL_KMOD_ALT)) {
		buttons |= 2;  /* Button 2 */
	}
	/* Emulate button 3 (right) with Command/GUI + Left Click */
	else if (left && (mods & SDL_KMOD_GUI)) {
		buttons |= 4;  /* Button 3 */
	}
	/* Normal left click (no emulation) */
	else if (left) {
		buttons |= 1;  /* Button 1 */
	}

	/* Physical middle and right buttons always work */
	if (middle)
		buttons |= 2;
	if (right)
		buttons |= 4;

	return buttons;
}

/*
 * Update tracked button state from an SDL mouse button event.
 * Returns the SDL button mask bit for the event's button.
 */
static Uint32
button_event_mask(Uint8 button)
{
	switch (button) {
	case SDL_BUTTON_LEFT:   return SDL_BUTTON_LMASK;
	case SDL_BUTTON_MIDDLE: return SDL_BUTTON_MMASK;
	case SDL_BUTTON_RIGHT:  return SDL_BUTTON_RMASK;
	default:                return 0;
	}
}

/* Forward declarations */
static void sdl_atexit_handler(void);
void sdl_shutdown(void);

/*
 * Find an active finger by SDL_FingerID. Returns -1 if not tracked.
 * INFR-121.
 */
static int
touch_finger_index(SDL_FingerID id)
{
	int i;
	for (i = 0; i < touch_finger_count; i++)
		if (touch_fingers[i].id == id)
			return i;
	return -1;
}

/*
 * Remove an active finger from the tracked set, compacting the array.
 * INFR-121.
 */
static void
touch_finger_remove_at(int idx)
{
	int j;
	if (idx < 0 || idx >= touch_finger_count)
		return;
	for (j = idx; j < touch_finger_count - 1; j++)
		touch_fingers[j] = touch_fingers[j + 1];
	touch_finger_count--;
}

/*
 * Convert SDL_TouchFingerEvent normalised coords (0..1 relative to the
 * window's logical size) to physical-pixel coords matching the rest of
 * the mouse path. On Android logical == pixels so display_scale is 1.0
 * and the multiplication is a no-op. INFR-121.
 */
static void
touch_finger_to_pixels(const SDL_TouchFingerEvent *ev, float *px, float *py)
{
	int lw = 0, lh = 0;
	SDL_GetWindowSize(sdl_window, &lw, &lh);
	if (lw <= 0 && display_scale > 0.0f) lw = (int)(window_width / display_scale);
	if (lh <= 0 && display_scale > 0.0f) lh = (int)(window_height / display_scale);
	*px = ev->x * (float)lw * display_scale;
	*py = ev->y * (float)lh * display_scale;
}

/*
 * Pre-initialize SDL3 on main thread
 * Called from main() before threading starts
 */
int
sdl3_preinit(void)
{
	const char *driver;

	/*
	 * On Android, single-finger touches do not generate SDL_MOUSE_*
	 * events by default — they only fire SDL_FINGER_* events. emu's
	 * event pump (sdl3_mainloop) handles SDL_MOUSE_*, so without this
	 * hint a tap on the phone produces FINGER events that go nowhere
	 * and the user sees their tap ignored. Setting this hint before
	 * SDL_Init tells SDL3 to also synthesise mouse events from
	 * touches — left-click on tap, drag-as-motion — which is exactly
	 * the Plan 9-style mouse semantics emu expects.
	 *
	 * Set on all platforms (no-op where touches aren't a thing) so
	 * touchscreen laptops behave the same way.
	 */
	SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "1");

	/*
	 * Initialize SDL3 on the main thread.
	 * On macOS, this must happen before any Cocoa window operations.
	 * We use the native driver (Cocoa on macOS) for real GUI.
	 */
	if (!SDL_Init(SDL_INIT_VIDEO)) {
		fprint(2, "sdl3_preinit: SDL_Init failed: %s\n", SDL_GetError());
		return 0;
	}

	/* Set app metadata for macOS menu bar and About dialog */
	SDL_SetAppMetadata("InferNode", "1.0", "systems.nerv.infernode");
	SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_CREATOR_STRING, "NERV Systems");
	SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_COPYRIGHT_STRING, "Copyright 2026 NERV Systems. MIT License.");
	SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_URL_STRING, "https://github.com/NERVsystems/infernode");
	SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_TYPE_STRING, "Operating System");

	driver = SDL_GetCurrentVideoDriver();
	/* SDL init succeeded */

	/* Register cleanup handler to ensure window closes on exit */
	atexit(sdl_atexit_handler);

	sdl_initialized = 1;
	return 1;
}

/*
 * atexit handler - ensures SDL cleanup happens on program exit
 */
static void
sdl_atexit_handler(void)
{
	sdl_shutdown();
}

/*
 * Initialize SDL3 and create window
 * Returns pointer to screen buffer
 */
uchar*
attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen)
{
	/* SDL3 should already be initialized from main thread */
	/* attachscreen called from worker thread */
	if (!sdl_initialized)
		return nil;

	/* Get screen dimensions from globals */
	sdl_width = Xsize;
	sdl_height = Ysize;

	/*
	 * Create window, read HiDPI info, then create renderer + texture.
	 * On macOS, window/renderer ops must happen on the main thread (Cocoa).
	 * On Linux/Windows, we signal the main thread which does it all.
	 */
#ifdef __APPLE__
	dispatch_sync(dispatch_get_main_queue(), ^{
		sdl_window = SDL_CreateWindow(
			"InferNode",
			sdl_width, sdl_height,
			/* HIGH_PIXEL_DENSITY: without it iOS gives a 1x (logical)
			 * backing, so the screen is ~393px not ~1179px and the
			 * mobile fonts render ~3x too large (≈8 chars/line). With
			 * it, GetWindowSizeInPixels reports real Retina pixels and
			 * the UI is properly sized + crisp. */
			/* HIGH_PIXEL_DENSITY is iOS-only. On macOS/Linux it makes
		 * the Inferno surface report physical Retina pixels, so
		 * 14-pt fonts render at 14 physical pixels on a 2x display
		 * (half-size). The mobile boot rebinds 14->32/48 to
		 * compensate; desktop boots don't, so desktop UI ends up
		 * tiny. Limiting the flag to iOS preserves the iOS fix
		 * (a5f38e48) without bleeding small fonts to desktop. */
		SDL_WINDOW_RESIZABLE
#if defined(__APPLE__) && TARGET_OS_IOS
		| SDL_WINDOW_HIGH_PIXEL_DENSITY
#endif
		);
	});
	if (!sdl_window)
		return nil;

	init_hidpi();

	dispatch_sync(dispatch_get_main_queue(), ^{
		create_renderer_and_texture();
	});
	if (!sdl_renderer || !sdl_texture) {
		dispatch_sync(dispatch_get_main_queue(), ^{
			if (sdl_renderer) SDL_DestroyRenderer(sdl_renderer);
			SDL_DestroyWindow(sdl_window);
		});
		sdl_renderer = NULL;
		sdl_window = NULL;
		return nil;
	}
#else
	/*
	 * Signal main thread to create window + renderer + texture.
	 * The main loop calls init_hidpi() between window and renderer
	 * creation so the texture gets the correct physical pixel size.
	 */
	create_window_requested = 1;
	create_window_done = 0;
	create_window_result = 0;

	while (!create_window_done)
		SDL_Delay(1);

	if (!create_window_result) {
		fprint(2, "draw-sdl3: main thread window creation failed\n");
		return nil;
	}
#endif

	sdl_running = 1;

	/* Row stride must match Inferno's memimage layout (wordsperline),
	 * not sdl_width*4 — see the sdl_stride comment. */
	sdl_stride = wordsperline(Rect(0, 0, sdl_width, sdl_height), 32) * sizeof(ulong);

	/* Allocate screen buffer at the padded stride. */
	screen_data = malloc(sdl_stride * sdl_height);
	if (!screen_data) {
		SDL_DestroyTexture(sdl_texture);
		SDL_DestroyRenderer(sdl_renderer);
		SDL_DestroyWindow(sdl_window);
		return nil;
	}

	/* Initialize buffer to white (Infernode default) */
	memset(screen_data, 0xFF, sdl_stride * sdl_height);

	/* Return screen parameters to Infernode */
	*r = Rect(0, 0, sdl_width, sdl_height);
	*chan = XRGB32;
	*d = 32;
	/*
	 * width is in 'ulong' words per row, not bytes.
	 * On 64-bit systems sizeof(ulong)=8, so we use wordsperline()
	 * which correctly calculates based on word size.
	 */
	*width = wordsperline(*r, *d);
	*softscreen = 1;

	return screen_data;
}

/*
 * Flush dirty rectangle to screen
 *
 * CRITICAL PERFORMANCE FIX:
 * This function NO LONGER calls dispatch_sync or SDL_UpdateTexture.
 * It only accumulates dirty rectangles into a bounding box.
 * The actual texture upload happens in sdl3_mainloop() once per frame.
 *
 * Previously, this function was called 100s of times per frame during
 * text rendering, each call doing a blocking dispatch_sync to the main
 * thread. This caused massive latency (seconds for directory listings).
 *
 * Now: flushmemscreen() is O(1) with no synchronization.
 * The main loop batches all updates into a single GPU upload per frame.
 */
void
flushmemscreen(Rectangle r)
{
	if (!sdl_running || !screen_data)
		return;

	/*
	 * Clamp dirty rectangle to screen bounds.
	 */
	if (r.min.x < 0) r.min.x = 0;
	if (r.min.y < 0) r.min.y = 0;
	if (r.max.x > sdl_width) r.max.x = sdl_width;
	if (r.max.y > sdl_height) r.max.y = sdl_height;

	/* Skip if rectangle is empty or invalid */
	if (r.min.x >= r.max.x || r.min.y >= r.max.y)
		return;

	/*
	 * Accumulate into bounding box of all dirty regions.
	 * No locking needed - single writer (Infernode), single reader (main loop).
	 */
	if (!dirty_pending) {
		dirty_min_x = r.min.x;
		dirty_min_y = r.min.y;
		dirty_max_x = r.max.x;
		dirty_max_y = r.max.y;
		dirty_pending = 1;
	} else {
		/* Expand bounding box */
		if (r.min.x < dirty_min_x) dirty_min_x = r.min.x;
		if (r.min.y < dirty_min_y) dirty_min_y = r.min.y;
		if (r.max.x > dirty_max_x) dirty_max_x = r.max.x;
		if (r.max.y > dirty_max_y) dirty_max_y = r.max.y;
	}
}

/* sdl_pollevents() removed — all event handling is in sdl3_mainloop() */

/*
 * Set mouse pointer position
 * Coordinates from Infernode are in texture space; we convert to window space.
 */
void
setpointer(int x, int y)
{
	float win_x, win_y;

	if (!sdl_running)
		return;

	/*
	 * Convert from texture coordinates to window coordinates.
	 * This is the inverse of window_to_texture_coords.
	 */
	if (dest_rect.w > 0 && dest_rect.h > 0 && sdl_width > 0 && sdl_height > 0) {
		/* Scale from texture size to rendered size, then add offset */
		win_x = (float)x * dest_rect.w / (float)sdl_width + dest_rect.x;
		win_y = (float)y * dest_rect.h / (float)sdl_height + dest_rect.y;
	} else {
		/* Fallback - use display_scale */
		win_x = (float)x / display_scale;
		win_y = (float)y / display_scale;
	}

	SDL_WarpMouseInWindow(sdl_window, win_x, win_y);
	mouse_x = x;
	mouse_y = y;
}

/*
 * Draw cursor (Infernode's software cursor).
 * Convert Inferno cursor bitmap to SDL3 cursor.
 *
 * Inferno cursor data layout (1-bpp, MSB-first):
 *   First h*bpl bytes: "clr" bits (white pixels)
 *   Next  h*bpl bytes: "set" bits (black pixels)
 *
 * SDL3 cursor semantics (data, mask):
 *   (1,1)=black  (0,1)=white  (0,0)=transparent  (1,0)=inverted
 *
 * Mapping: data = set bits, mask = set | clr bits.
 */
enum { MaxCursorSize = 32 };

void
drawcursor(Drawcursor *c)
{
	static SDL_Cursor *sdl_cursor = NULL;
	uchar data[MaxCursorSize * MaxCursorSize / 8];
	uchar mask[MaxCursorSize * MaxCursorSize / 8];
	uchar *bc, *bs;
	int i, j, h, w, bpl, stride;

	if (c->data == nil) {
		/* Reset to default cursor */
		if (sdl_cursor) {
			SDL_DestroyCursor(sdl_cursor);
			sdl_cursor = NULL;
		}
		SDL_SetCursor(NULL);
		return;
	}

	h = (c->maxy - c->miny) / 2;	/* bounds include image + mask */
	if (h > MaxCursorSize)
		h = MaxCursorSize;
	bpl = bytesperline(Rect(c->minx, c->miny, c->maxx, c->maxy), 1);
	w = bpl;
	if (w > MaxCursorSize / 8)
		w = MaxCursorSize / 8;

	memset(data, 0, sizeof(data));
	memset(mask, 0, sizeof(mask));

	stride = MaxCursorSize / 8;
	bc = c->data;
	bs = c->data + h * bpl;
	for (i = 0; i < h; i++) {
		for (j = 0; j < w; j++) {
			data[i * stride + j] = bs[j];
			mask[i * stride + j] = bs[j] | bc[j];
		}
		bs += bpl;
		bc += bpl;
	}

	if (sdl_cursor) {
		SDL_DestroyCursor(sdl_cursor);
		sdl_cursor = NULL;
	}

	sdl_cursor = SDL_CreateCursor(data, mask,
		MaxCursorSize, MaxCursorSize, -c->hotx, -c->hoty);
	if (sdl_cursor)
		SDL_SetCursor(sdl_cursor);
}

/*
 * Read clipboard/snarf buffer
 */
char*
clipread(void)
{
	if (!sdl_running)
		return nil;

	if (!SDL_HasClipboardText())
		return nil;

	char *text = SDL_GetClipboardText();
	if (!text)
		return nil;

	/* Copy to Infernode-managed memory */
	char *result = strdup(text);
	SDL_free(text);

	return result;
}

/*
 * Write to clipboard/snarf buffer
 */
int
clipwrite(char *buf)
{
	if (!sdl_running)
		return 0;

	if (!SDL_SetClipboardText(buf))
		return 0;

	return strlen(buf);
}

/*
 * Shutdown SDL3
 * On macOS, window operations must happen on the main thread.
 */
void
sdl_shutdown(void)
{
	sdl_running = 0;

	if (screen_data) {
		free(screen_data);
		screen_data = NULL;
	}

#ifdef __APPLE__
	/*
	 * SDL/Cocoa cleanup must happen on the main thread.
	 *
	 * If we're already on the main thread (e.g., called from sdl3_mainloop
	 * via cleanexit), execute cleanup directly. Otherwise use dispatch_sync.
	 * Using dispatch_sync when already on the main queue causes a deadlock.
	 */
	if (sdl_window) {
		if (pthread_main_np()) {
			/* Already on main thread - cleanup directly */
			SDL_HideWindow(sdl_window);

			if (sdl_texture) {
				SDL_DestroyTexture(sdl_texture);
				sdl_texture = NULL;
			}

			if (sdl_renderer) {
				SDL_DestroyRenderer(sdl_renderer);
				sdl_renderer = NULL;
			}

			SDL_DestroyWindow(sdl_window);
			sdl_window = NULL;

			SDL_Quit();
		} else {
			/* Not on main thread - dispatch to it */
			dispatch_sync(dispatch_get_main_queue(), ^{
				if (sdl_window)
					SDL_HideWindow(sdl_window);

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
			});
		}
	}
#else
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
#endif
}

/*
 * Handle cross-thread window creation request.
 * The worker thread sets create_window_requested when it needs
 * a window (via attachscreen). We create it here on the main thread.
 */
#ifndef __APPLE__
static void
handle_window_creation(void)
{
	if (!create_window_requested || create_window_done)
		return;

	sdl_window = SDL_CreateWindow(
		"InferNode",
		sdl_width, sdl_height,
		/* HIGH_PIXEL_DENSITY is iOS-only. On macOS/Linux it makes
		 * the Inferno surface report physical Retina pixels, so
		 * 14-pt fonts render at 14 physical pixels on a 2x display
		 * (half-size). The mobile boot rebinds 14->32/48 to
		 * compensate; desktop boots don't, so desktop UI ends up
		 * tiny. Limiting the flag to iOS preserves the iOS fix
		 * (a5f38e48) without bleeding small fonts to desktop. */
		SDL_WINDOW_RESIZABLE
#if defined(__APPLE__) && TARGET_OS_IOS
		| SDL_WINDOW_HIGH_PIXEL_DENSITY
#endif
	);
	if (!sdl_window) {
		fprint(2, "draw-sdl3: SDL_CreateWindow failed: %s\n", SDL_GetError());
		create_window_result = 0;
	} else {
		init_hidpi();
		if (!create_renderer_and_texture()) {
			fprint(2, "draw-sdl3: renderer/texture creation failed: %s\n",
				SDL_GetError());
			SDL_DestroyWindow(sdl_window);
			sdl_window = NULL;
			create_window_result = 0;
		} else {
			create_window_result = 1;
		}
	}
	create_window_done = 1;
	create_window_requested = 0;
}
#endif

/*
 * Upload accumulated dirty region to GPU and present.
 * Called at ~60Hz from the main loop.  Returns the new last_refresh time,
 * or the old value if no present was needed.
 */
static Uint64
update_and_present(Uint64 now, Uint64 last_refresh)
{
	if (!sdl_running || !sdl_renderer || !sdl_texture || !screen_data)
		return last_refresh;

	if (!dirty_pending && (now - last_refresh <= 250))
		return last_refresh;

	if (dirty_pending) {
		SDL_Rect dirty;
		uchar *src;
		int pitch;

		dirty.x = dirty_min_x;
		dirty.y = dirty_min_y;
		dirty.w = dirty_max_x - dirty_min_x;
		dirty.h = dirty_max_y - dirty_min_y;

		pitch = sdl_stride;
		src = screen_data + (dirty_min_y * pitch) + (dirty_min_x * 4);

		SDL_UpdateTexture(sdl_texture, &dirty, src, pitch);
		dirty_pending = 0;
	}

	SDL_SetRenderDrawColor(sdl_renderer, 0, 0, 0, 255);
	SDL_RenderClear(sdl_renderer);
	SDL_RenderTexture(sdl_renderer, sdl_texture, NULL, &dest_rect);
	SDL_RenderPresent(sdl_renderer);
	return now;
}

/*
 * Handle SDL_EVENT_TEXT_INPUT.
 * Decodes UTF-8 text to Unicode codepoints and sends to keyboard queue.
 * Skips control characters (handled by Ctrl+letter in KEY_DOWN).
 */
static void
handle_text_input(const char *text)
{
	Rune r;
	int n;

	if ((uchar)text[0] < 0x20 && text[0] != '\t')
		return;

	while (*text) {
		n = chartorune(&r, (char*)text);	/* chartorune doesn't modify text; Plan 9 API lacks const */
		if (r == Runeerror) {
			text++;
			continue;
		}
		gkbdputc(gkbdq, r);
		text += n;
	}
}

/*
 * Handle SDL_EVENT_KEY_DOWN.
 * Maps special keys and Ctrl+letter to Plan 9 key codes.
 * Printable characters are handled by TEXT_INPUT, not here.
 */
static void
handle_key_down(SDL_Event *event)
{
	int key = 0;
	SDL_Keymod mods = event->key.mod;
	SDL_Keycode kc = event->key.key;

	/* Ctrl+letter or Cmd+letter -> control character (^A=1, ^H=8, etc.)
	 * Cmd (GUI mod) is mapped so macOS Cmd+C/X/V work as copy/cut/paste */
	if ((mods & (SDL_KMOD_CTRL | SDL_KMOD_GUI)) && kc >= 'a' && kc <= 'z')
		key = kc - 'a' + 1;

	/* Special/non-printable keys only */
	if (key == 0)
	switch (event->key.scancode) {
	case SDL_SCANCODE_ESCAPE:   key = 27; break;
	case SDL_SCANCODE_RETURN:   key = '\n'; break;
	case SDL_SCANCODE_KP_ENTER: key = '\n'; break;
	case SDL_SCANCODE_TAB:      key = '\t'; break;
	case SDL_SCANCODE_BACKSPACE: key = '\b'; break;
	case SDL_SCANCODE_DELETE:   key = 0x7F; break;
	case SDL_SCANCODE_UP:       key = Up; break;
	case SDL_SCANCODE_DOWN:     key = Down; break;
	case SDL_SCANCODE_LEFT:     key = Left; break;
	case SDL_SCANCODE_RIGHT:    key = Right; break;
	case SDL_SCANCODE_HOME:     key = Home; break;
	case SDL_SCANCODE_END:      key = End; break;
	case SDL_SCANCODE_PAGEUP:   key = Pgup; break;
	case SDL_SCANCODE_PAGEDOWN: key = Pgdown; break;
	case SDL_SCANCODE_INSERT:   key = Ins; break;
	case SDL_SCANCODE_F1:       key = KF|1; break;
	case SDL_SCANCODE_F2:       key = KF|2; break;
	case SDL_SCANCODE_F3:       key = KF|3; break;
	case SDL_SCANCODE_F4:       key = KF|4; break;
	case SDL_SCANCODE_F5:       key = KF|5; break;
	case SDL_SCANCODE_F6:       key = KF|6; break;
	case SDL_SCANCODE_F7:       key = KF|7; break;
	case SDL_SCANCODE_F8:       key = KF|8; break;
	case SDL_SCANCODE_F9:       key = KF|9; break;
	case SDL_SCANCODE_F10:      key = KF|10; break;
	case SDL_SCANCODE_F11:      key = KF|11; break;
	case SDL_SCANCODE_F12:      key = KF|12; break;
	default:
		break;
	}

	if (key != 0)
		gkbdputc(gkbdq, key);
}

/*
 * Main thread event loop for SDL3/Cocoa
 * This function runs on the TRUE main thread and never returns
 * Worker threads communicate via dispatch_sync()
 */
void
sdl3_mainloop(void)
{
	SDL_Event event;
	static Uint64 last_refresh = 0;
	Uint64 now;

	/* mainloop running on main thread */

	/* Event loop - processes SDL events and sends to Infernode */
	for(;;) {
#ifndef __APPLE__
		handle_window_creation();
#endif

		now = SDL_GetTicks();
		last_refresh = update_and_present(now, last_refresh);

		/* Apply any pending soft-keyboard request on the main thread
		 * (setsoftkbd, called from a worker thread, only set a flag). */
		apply_softkbd();

		/*
		 * Long-press fire: a single finger held still past the threshold
		 * becomes a button-3 (context-menu) press. Checked here each loop
		 * because a stationary finger emits no further SDL events.
		 */
		if (touch_lp_armed && !touch_lp_fired && touch_finger_count == 1 &&
		    !touch_in_multi_gesture &&
		    now - touch_lp_down_ms >= LONGPRESS_MS) {
			sdl_button_state = SDL_BUTTON_RMASK;	/* drop synth left, raise right */
			mousetrack(map_buttons(sdl_button_state), mouse_x, mouse_y, 0);
			touch_lp_fired = 1;
			touch_lp_armed = 0;
		}

		/* Poll for events (non-blocking) */
		while (SDL_PollEvent(&event)) {
			switch (event.type) {
			case SDL_EVENT_QUIT:
				cleanexit(0);
				break;

			case SDL_EVENT_MOUSE_MOTION:
				/* SDL event coords are in window logical points;
				 * display_scale converts to pixels (1.0 on Android,
				 * where logical == pixels). */
				window_to_texture_coords(event.motion.x * display_scale, event.motion.y * display_scale, &mouse_x, &mouse_y);
				mousetrack(map_buttons(sdl_button_state), mouse_x, mouse_y, 0);
				break;

			case SDL_EVENT_MOUSE_BUTTON_DOWN:
			case SDL_EVENT_MOUSE_BUTTON_UP:
				{
					Uint32 mask = button_event_mask(event.button.button);
					if (event.type == SDL_EVENT_MOUSE_BUTTON_DOWN) {
						sdl_button_state |= mask;
						/*
						 * Re-assert text input on a press ONLY while a
						 * text field is focused (softkbd_want, set by the
						 * GUI via setsoftkbd). A system gesture (back,
						 * swipe-down, a permission dialog) can dismiss
						 * the IME and SDL won't restore it; re-asserting
						 * on the next tap brings it back. When no field
						 * is focused this is skipped, so a tap no longer
						 * pops the keyboard. (On desktop, no IME.) This
						 * runs on the main thread, so the SDL call is safe.
						 */
						if (softkbd_want)
							SDL_StartTextInput(sdl_window);
					} else
						sdl_button_state &= ~mask;

					window_to_texture_coords(event.button.x * display_scale, event.button.y * display_scale, &mouse_x, &mouse_y);
					mousetrack(map_buttons(sdl_button_state), mouse_x, mouse_y, 0);
				}
				break;

			case SDL_EVENT_MOUSE_WHEEL: {
				/* Shift+scroll converts vertical to horizontal */
				float wx2 = event.wheel.x;
				float wy2 = event.wheel.y;
				if ((SDL_GetModState() & SDL_KMOD_SHIFT) && wy2 != 0 && wx2 == 0) {
					wx2 = wy2;
					wy2 = 0;
				}
				if (wy2 > 0)
					mousetrack(8, mouse_x, mouse_y, 0);   /* scroll up */
				else if (wy2 < 0)
					mousetrack(16, mouse_x, mouse_y, 0);  /* scroll down */
				if (wx2 > 0)
					mousetrack(64, mouse_x, mouse_y, 0);  /* scroll right */
				else if (wx2 < 0)
					mousetrack(32, mouse_x, mouse_y, 0);  /* scroll left */
				break;
			}

			/*
			 * INFR-121: two-finger swipe → scroll-wheel synthesis.
			 * Track active fingers; when two or more are down, route
			 * finger motion into wheel-tick events so every wm app
			 * scrolls without per-app changes.  Single-finger touches
			 * continue to flow through SDL's synthesised mouse events
			 * (SDL_HINT_TOUCH_MOUSE_EVENTS=1, set in sdl3_preinit).
			 */
			case SDL_EVENT_FINGER_DOWN: {
				float px, py;
				touch_finger_to_pixels(&event.tfinger, &px, &py);
				if (touch_finger_count < TOUCH_MAX_FINGERS) {
					touch_fingers[touch_finger_count].id = event.tfinger.fingerID;
					touch_fingers[touch_finger_count].last_x = px;
					touch_fingers[touch_finger_count].last_y = py;
					touch_finger_count++;
				}
				if (touch_finger_count == 1) {
					/* Arm a possible long-press for this single finger. */
					touch_lp_armed = 1;
					touch_lp_fired = 0;
					touch_lp_down_ms = now;
					touch_lp_x0 = px;
					touch_lp_y0 = py;
				} else {
					/* >1 finger: not a context-menu long-press. */
					touch_lp_armed = 0;
				}
				if (touch_finger_count == 2) {
					/*
					 * Entering two-finger gesture.  Release any
					 * synthesised mouse button so we don't leave a
					 * click-drag in flight under the scroll; reset
					 * the scroll accumulators so a slow-drag-then-
					 * second-finger doesn't immediately flush a tick.
					 */
					if (sdl_button_state) {
						sdl_button_state = 0;
						mousetrack(0, mouse_x, mouse_y, 0);
					}
					touch_scroll_accum_x = 0.0f;
					touch_scroll_accum_y = 0.0f;
					touch_in_multi_gesture = 1;
				}
				break;
			}

			case SDL_EVENT_FINGER_UP: {
				int idx = touch_finger_index(event.tfinger.fingerID);
				touch_finger_remove_at(idx);
				if (touch_finger_count < 2)
					touch_in_multi_gesture = 0;
				/*
				 * Finger lifted. If a long-press had promoted to
				 * button-3, release it now (→ menu select/dismiss).
				 * SDL's own MOUSE_BUTTON_UP only clears the left mask,
				 * so the right button must be cleared here.
				 */
				if (touch_lp_fired) {
					sdl_button_state &= ~SDL_BUTTON_RMASK;
					mousetrack(map_buttons(sdl_button_state), mouse_x, mouse_y, 0);
					touch_lp_fired = 0;
				}
				touch_lp_armed = 0;
				break;
			}

			case SDL_EVENT_FINGER_MOTION: {
				int idx = touch_finger_index(event.tfinger.fingerID);
				float px, py, dx, dy;
				if (idx < 0)
					break;
				touch_finger_to_pixels(&event.tfinger, &px, &py);
				dx = px - touch_fingers[idx].last_x;
				dy = py - touch_fingers[idx].last_y;
				touch_fingers[idx].last_x = px;
				touch_fingers[idx].last_y = py;
				/*
				 * Moved past the slop from the landing point → this is a
				 * drag, not a long-press: cancel the armed context menu
				 * (but only before it fires; once button-3 is down the
				 * finger may move to highlight menu items).
				 */
				if (touch_lp_armed && !touch_lp_fired) {
					float mdx = px - touch_lp_x0;
					float mdy = py - touch_lp_y0;
					if (mdx * mdx + mdy * mdy > LONGPRESS_SLOP_PX * LONGPRESS_SLOP_PX)
						touch_lp_armed = 0;
				}
				if (!touch_in_multi_gesture)
					break;
				touch_scroll_accum_x += dx;
				touch_scroll_accum_y += dy;
				/*
				 * Natural scroll direction: drag finger UP (dy < 0)
				 * means user wants to see content BELOW (viewport
				 * moves down) → wheel "scroll down" = button 16.
				 * Drag finger DOWN (dy > 0) → "scroll up" = button 8.
				 * Same for horizontal.
				 */
				while (touch_scroll_accum_y <= -TOUCH_SCROLL_TICK_PX) {
					mousetrack(16, mouse_x, mouse_y, 0);
					touch_scroll_accum_y += TOUCH_SCROLL_TICK_PX;
				}
				while (touch_scroll_accum_y >= TOUCH_SCROLL_TICK_PX) {
					mousetrack(8, mouse_x, mouse_y, 0);
					touch_scroll_accum_y -= TOUCH_SCROLL_TICK_PX;
				}
				while (touch_scroll_accum_x <= -TOUCH_SCROLL_TICK_PX) {
					mousetrack(32, mouse_x, mouse_y, 0);
					touch_scroll_accum_x += TOUCH_SCROLL_TICK_PX;
				}
				while (touch_scroll_accum_x >= TOUCH_SCROLL_TICK_PX) {
					mousetrack(64, mouse_x, mouse_y, 0);
					touch_scroll_accum_x -= TOUCH_SCROLL_TICK_PX;
				}
				break;
			}

			case SDL_EVENT_TEXT_INPUT:
				handle_text_input(event.text.text);
				break;

			case SDL_EVENT_KEY_DOWN:
				handle_key_down(&event);
				break;

			case SDL_EVENT_KEY_UP:
				if (event.key.scancode == SDL_SCANCODE_LALT ||
				    event.key.scancode == SDL_SCANCODE_RALT) {
					gkbdputc(gkbdq, Latin);
				}
				break;

			case SDL_EVENT_WINDOW_RESIZED:
			case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
				{
					int pix_w;
					int pix_h;

					/*
					 * Window size changed (e.g., full-screen toggle).
					 * Recalculate dest rect for centered letterbox rendering.
					 * Use physical pixel dimensions to match renderer coordinate space.
					 * Texture/buffer size stays fixed at init dimensions.
					 */
					SDL_GetWindowSizeInPixels(sdl_window, &pix_w, &pix_h);
					window_width = pix_w;
					window_height = pix_h;
					/* See display_scale comment: pixel/logical
					 * ratio, not density. */
					{
						int log_w = 0, log_h = 0;
						SDL_GetWindowSize(sdl_window, &log_w, &log_h);
						if (log_w > 0)
							display_scale = (float)pix_w / (float)log_w;
						else
							display_scale = 1.0f;
					}
					calc_dest_rect();
				}
				break;
			}
		}

		/* Brief sleep to avoid busy-wait */
		SDL_Delay(16);  /* ~60Hz */
	}

	/* Never reached */
}
