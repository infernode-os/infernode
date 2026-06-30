#include "lib9.h"
#include "kernel.h"
#include "draw.h"
#include "tk.h"

#define RGB(R,G,B) (((ulong)(R)<<24)|((G)<<16)|((B)<<8)|(0xff))
#define HEXRGB(v)	RGB(((v)>>16)&0xff, ((v)>>8)&0xff, (v)&0xff)

/*
 * Default Tk colour palette.
 *
 * The palette is sourced from the *active lucitheme* — the same flat
 * key/value files lucitheme reads (/lib/lucifer/theme/current names the
 * theme; /lib/lucifer/theme/<name> holds its colours).  This is what
 * lets the whole Tk toolkit follow the selected theme: Brimstone (dark)
 * or Halo (light) or any user theme, with no per-widget colour options.
 * Every Tk widget inherits these through its TkEnv unless an app
 * overrides a specific colour.
 *
 * If the theme files cannot be read (absent namespace, custom embeddings
 * of the toolkit), the built-in Brimstone constants below are the
 * fallback, and any individual key missing from a theme file falls back
 * to its Brimstone value too.
 *
 * Independent of *which* theme is active, the look is flat 2D: the
 * light/dark relief shades are pinned to the one border colour instead
 * of computed highlights, so a raised/sunken widget renders as a uniform
 * hard frame, never a bevel.  That structure lives here; only the source
 * colours change per theme.
 */
enum
{
	clBg		= 0x080808,	/* bg      — surface                  */
	clBorder	= 0x131313,	/* border  — hard 1px frame           */
	clActive	= 0x1E1E1E,	/* hover/pressed background           */
	clText		= 0xCCCCCC,	/* text    — primary foreground       */
	clAccent	= 0xE8553A,	/* accent  — selection, indicators    */
	clDim		= 0x444444	/* dim     — disabled foreground      */
};

/* Palette field indices (order matches Palette below). */
enum
{
	PBg, PBorder, PActive, PText, PAccent, PDim,
	NPAL,
	PTransparent = -2	/* special: DTransparent, not a theme colour */
};

typedef struct Palette Palette;
struct Palette
{
	ulong	v[NPAL];	/* 0xRRGGBB per field                 */
};

typedef struct Coltab Coltab;
struct Coltab {
	int	c;	/* TkC* palette slot                          */
	int	f;	/* palette field index, or PTransparent       */
};

/*
 * Which lucitheme key feeds each palette field.  "active" (hover/pressed
 * background) maps to the theme's menuhilit, which is the hover surface
 * in both shipped themes; everything else maps to the obvious key.
 */
static char *palkey[NPAL] = {
	"bg",		/* PBg     */
	"border",	/* PBorder */
	"menuhilit",	/* PActive */
	"text",		/* PText   */
	"accent",	/* PAccent */
	"dim",		/* PDim    */
};

static ulong paldflt[NPAL] = {
	clBg, clBorder, clActive, clText, clAccent, clDim,
};

static Coltab coltab[] =
{
	TkCbackgnd,		PBg,
	TkCbackgndlght,		PBorder,	/* flat: border, not a highlight */
	TkCbackgnddark,		PBorder,	/* flat: border, not a shadow    */
	TkCactivebgnd,		PActive,
	TkCactivebgndlght,	PBorder,
	TkCactivebgnddark,	PBorder,
	TkCactivefgnd,		PText,
	TkCforegnd,		PText,
	TkCselect,		PAccent,	/* check/radio indicator = accent */
	TkCselectbgnd,		PAccent,	/* selection background = accent  */
	TkCselectbgndlght,	PAccent,
	TkCselectbgnddark,	PAccent,
	TkCselectfgnd,		PBg,		/* text on accent selection = bg  */
	TkCdisablefgnd,		PDim,
	TkChighlightfgnd,	PAccent,	/* keyboard-focus highlight       */
	TkCtransparent,		PTransparent,
	-1,	0,
};

/*
 * Read a small namespace file whole into buf (NUL-terminated).  Returns
 * the byte count, or -1 if it could not be read.  Uses the same
 * namespace-aware primitives the font loader uses one call earlier in
 * tknewenv, so it is safe in this context.
 */
static int
readsmall(char *name, char *buf, int nbuf)
{
	int fd, n;

	fd = libopen(name, OREAD);
	if(fd < 0)
		return -1;
	n = libreadn(fd, buf, nbuf-1);
	libclose(fd);
	if(n < 0)
		return -1;
	buf[n] = 0;
	return n;
}

static int
hexbyte(char *p)
{
	int hi, lo;

	hi = *p++;
	if(hi >= '0' && hi <= '9') hi -= '0';
	else if(hi >= 'a' && hi <= 'f') hi -= 'a'-10;
	else if(hi >= 'A' && hi <= 'F') hi -= 'A'-10;
	else return -1;
	lo = *p;
	if(lo >= '0' && lo <= '9') lo -= '0';
	else if(lo >= 'a' && lo <= 'f') lo -= 'a'-10;
	else if(lo >= 'A' && lo <= 'F') lo -= 'A'-10;
	else return -1;
	return (hi<<4)|lo;
}

/*
 * Parse "key RRGGBB" lines from a lucitheme file.  For each palette field
 * whose key is present, overwrite pal->v[field].  Lines beginning with
 * '#', blank lines, and unrecognised keys are ignored.
 */
static void
parsetheme(char *buf, Palette *pal)
{
	char *p, *e, *k, *v;
	int i, r, g, b;

	p = buf;
	while(*p) {
		/* isolate the line [p, e) */
		e = p;
		while(*e && *e != '\n')
			e++;
		/* skip leading space */
		k = p;
		while(k < e && (*k == ' ' || *k == '\t'))
			k++;
		if(k < e && *k != '#') {
			/* key token */
			v = k;
			while(v < e && *v != ' ' && *v != '\t')
				v++;
			/* split key/value */
			if(v < e) {
				char *ke = v;
				while(v < e && (*v == ' ' || *v == '\t'))
					v++;
				if(v + 6 <= e) {
					r = hexbyte(v);
					g = hexbyte(v+2);
					b = hexbyte(v+4);
					if(r >= 0 && g >= 0 && b >= 0) {
						int klen = ke - k;
						for(i = 0; i < NPAL; i++) {
							if(strlen(palkey[i]) == klen
							&& strncmp(k, palkey[i], klen) == 0) {
								pal->v[i] = ((ulong)r<<16)|(g<<8)|b;
								break;
							}
						}
					}
				}
			}
		}
		if(*e == 0)
			break;
		p = e + 1;
	}
}

/*
 * Resolve the active palette.  Cached on the contents of
 * /lib/lucifer/theme/current so the common case (many envs, one theme)
 * costs one tiny read; a theme switch (current changes) triggers a
 * reparse, so live switching keeps working for toplevels created after.
 */
static void
loadpalette(Palette *pal)
{
	static char cached[64];		/* last theme name parsed        */
	static Palette cachepal;
	static int haveinit;
	char cur[64], path[128], buf[4096];
	int n, i;

	if(readsmall("/lib/lucifer/theme/current", cur, sizeof cur) < 0)
		cur[0] = 0;
	/* trim trailing whitespace/newline from the name */
	for(n = strlen(cur); n > 0; n--) {
		int c = cur[n-1];
		if(c == '\n' || c == '\r' || c == ' ' || c == '\t')
			cur[n-1] = 0;
		else
			break;
	}

	if(haveinit && strcmp(cur, cached) == 0) {
		*pal = cachepal;
		return;
	}

	/* start from Brimstone fallbacks, then overlay the theme file */
	for(i = 0; i < NPAL; i++)
		pal->v[i] = paldflt[i];

	if(cur[0]) {
		snprint(path, sizeof path, "/lib/lucifer/theme/%s", cur);
		if(readsmall(path, buf, sizeof buf) >= 0)
			parsetheme(buf, pal);
	}

	strncpy(cached, cur, sizeof cached - 1);
	cached[sizeof cached - 1] = 0;
	cachepal = *pal;
	haveinit = 1;
}

void
tksetenvcolours(TkEnv *env)
{
	Palette pal;
	Coltab *c;
	ulong rgba;

	loadpalette(&pal);

	for(c = &coltab[0]; c->c != -1; c++) {
		if(c->f == PTransparent)
			rgba = DTransparent;
		else
			rgba = HEXRGB(pal.v[c->f]);
		env->colors[c->c] = tkrgbashade(rgba, TkSameshade);
		env->set |= (1<<c->c);
	}
}
