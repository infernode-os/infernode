#include "lib9.h"
#include "draw.h"
#include "tk.h"

#define RGB(R,G,B) (((ulong)(R)<<24)|((G)<<16)|((B)<<8)|(0xff))

/*
 * Default Tk colour palette.
 *
 * This is the brutalist "Brimstone" theme that InferNode's native widget
 * toolkit established: a near-black flat surface, a single warm accent,
 * and hard 1px borders rather than 3D bevels.  Every Tk widget inherits
 * these through its TkEnv unless an app overrides a specific colour, so
 * making the engine default match the house style means apps get the
 * right look with no per-widget colour options.
 *
 * Keep these in sync with lucitheme's Brimstone defaults
 * (appl/lib/lucitheme.b).  At runtime the palette can be re-pointed at
 * the active lucitheme so live theme switching keeps working; these
 * values are the fallback used before any theme is pushed and whenever a
 * key is absent.
 *
 * "Flat" is achieved by giving the light/dark relief shades a fixed
 * border colour instead of computed highlights: a raised/sunken widget
 * then renders as a uniform hard frame, not a bevel.
 */
enum
{
	clBg		= 0x080808,	/* bg      — near-black surface       */
	clBorder	= 0x131313,	/* border  — hard 1px frame           */
	clActive	= 0x1E1E1E,	/* hover/pressed background           */
	clText		= 0xCCCCCC,	/* text    — primary foreground       */
	clAccent	= 0xE8553A,	/* accent  — selection, indicators    */
	clDim		= 0x444444	/* dim     — disabled foreground      */
};

#define HEXRGB(v)	RGB(((v)>>16)&0xff, ((v)>>8)&0xff, (v)&0xff)

typedef struct Coltab Coltab;
struct Coltab {
	int	c;
	ulong rgba;
	int shade;
};

static Coltab coltab[] =
{
	TkCbackgnd,
		HEXRGB(clBg),
		TkSameshade,
	TkCbackgndlght,			/* flat: border colour, not a highlight */
		HEXRGB(clBorder),
		TkSameshade,
	TkCbackgnddark,			/* flat: border colour, not a shadow    */
		HEXRGB(clBorder),
		TkSameshade,
	TkCactivebgnd,
		HEXRGB(clActive),
		TkSameshade,
	TkCactivebgndlght,
		HEXRGB(clBorder),
		TkSameshade,
	TkCactivebgnddark,
		HEXRGB(clBorder),
		TkSameshade,
	TkCactivefgnd,
		HEXRGB(clText),
		TkSameshade,
	TkCforegnd,
		HEXRGB(clText),
		TkSameshade,
	TkCselect,			/* check/radio indicator = accent       */
		HEXRGB(clAccent),
		TkSameshade,
	TkCselectbgnd,			/* selection background = accent        */
		HEXRGB(clAccent),
		TkSameshade,
	TkCselectbgndlght,
		HEXRGB(clAccent),
		TkSameshade,
	TkCselectbgnddark,
		HEXRGB(clAccent),
		TkSameshade,
	TkCselectfgnd,			/* text on accent selection = surface   */
		HEXRGB(clBg),
		TkSameshade,
	TkCdisablefgnd,
		HEXRGB(clDim),
		TkSameshade,
	TkChighlightfgnd,		/* keyboard-focus highlight = accent    */
		HEXRGB(clAccent),
		TkSameshade,
	TkCtransparent,
		DTransparent,
		TkSameshade,
	-1,
};

void
tksetenvcolours(TkEnv *env)
{
	Coltab *c;

	c = &coltab[0];
	while(c->c != -1) {
		env->colors[c->c] = tkrgbashade(c->rgba, c->shade);
		env->set |= (1<<c->c);
		c++;
	}
}
