/*
 * nokeyboard.m -- iOS's own keyboard never on the screen.
 *
 * InferNode types with a keyboard of its own (wm/osk), so the system's
 * is never wanted: it covers the screen, slides the view, and fights the
 * GUI for focus.  SDL_HINT_ENABLE_SCREEN_KEYBOARD "0" (set before
 * SDL_Init, draw-sdl3.c) keeps SDL from asking for it, but on iOS
 * starting text input makes SDL's hidden text field (SDLUITextField, made
 * with the window and kept for its life) the first responder, and UIKit
 * shows its keyboard for a first responder whenever no hardware keyboard
 * is attached.  draw-sdl3.c starts text input only while one is; this is
 * the second lock, for the moment between a keyboard going and SDL
 * saying so, and for a keyboard SDL does not know of: the field's input
 * view is an empty one, so UIKit has no keyboard to show for it, and a
 * hardware keyboard still types into it.  The shortcut bar an iPad
 * shows over a hardware keyboard goes too.
 *
 * Main thread only (UIKit): draw-sdl3.c calls it there, before and after
 * every SDL_StartTextInput.
 */
#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>

void	ios_nosystemkeyboard(SDL_Window *w);

static void
quieten(UIView *v)
{
	for (UIView *s in v.subviews) {
		if ([s isKindOfClass:[UITextField class]]) {
			UITextField *t = (UITextField *)s;
			if (t.inputView == nil || t.inputView.frame.size.height != 0) {
				t.inputView = [[UIView alloc] initWithFrame:CGRectZero];
				t.inputAccessoryView = nil;
				t.inputAssistantItem.leadingBarButtonGroups = @[];
				t.inputAssistantItem.trailingBarButtonGroups = @[];
				if (t.isFirstResponder)
					[t reloadInputViews];
			}
		}
		quieten(s);
	}
}

void
ios_nosystemkeyboard(SDL_Window *w)
{
	UIWindow *uw;

	if (w == NULL)
		return;
	uw = (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(w),
		SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	if (uw != nil)
		quieten(uw);
}
