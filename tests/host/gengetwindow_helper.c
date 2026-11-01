#include "lib9.h"
#include "draw.h"
#include "kernel.h"

static int scenario;
static int reads;
static int opens;
static int closes;
static int oldimagefrees;
static int oldscreenimagefrees;
static int oldscreenfrees;
static int namedcalls;
static int allocsawdiscarded;
static Image **windowp;
static Image oldwindow;
static Image oldscreenimage;
static Image rootimage;
static Image newimage;
static Image newwindow;
static Screen oldscreen;
static Screen newscreen;

void
_assert(char *s)
{
	fprint(2, "FAIL: assertion: %s\n", s);
	exits("assertion");
}

Rectangle
insetrect(Rectangle r, int n)
{
	r.min.x += n;
	r.min.y += n;
	r.max.x -= n;
	r.max.y -= n;
	return r;
}

int
libopen(char *name, int mode)
{
	(void)name;
	(void)mode;
	opens++;
	return 7;
}

int
libread(int fd, void *v, int n)
{
	char *name;

	(void)fd;
	(void)n;
	if(scenario == 1)
		return 0;
	name = reads++ == 0 ? "old" : "new";
	strcpy(v, name);
	return strlen(name);
}

int
libclose(int fd)
{
	(void)fd;
	closes++;
	return 0;
}

int
_freeimage1(Image *i)
{
	if(i == &oldwindow)
		oldimagefrees++;
	return 1;
}

int
freeimage(Image *i)
{
	if(i == &oldscreenimage)
		oldscreenimagefrees++;
	return 1;
}

int
freescreen(Screen *s)
{
	if(s == &oldscreen)
		oldscreenfrees++;
	return 1;
}

Image*
namedimage(Display *d, char *name)
{
	(void)d;
	namedcalls++;
	if(*windowp != nil)
		allocsawdiscarded++;
	if(strcmp(name, "old") == 0)
		return nil;
	return &newimage;
}

Screen*
allocscreen(Image *image, Image *fill, int public)
{
	(void)fill;
	(void)public;
	newscreen.image = image;
	return &newscreen;
}

Image*
_allocwindow(Image *i, Screen *s, Rectangle r, int ref, ulong val)
{
	(void)r;
	(void)ref;
	(void)val;
	if(i != nil || s != &newscreen)
		allocsawdiscarded++;
	return &newwindow;
}

static int
check(int ok, char *what)
{
	if(ok)
		return 0;
	fprint(2, "FAIL: %s\n", what);
	return 1;
}

int
main(void)
{
	Display display;
	Image *window;
	Screen *screen;
	int failed;

	memset(&display, 0, sizeof display);
	memset(&oldwindow, 0, sizeof oldwindow);
	memset(&oldscreenimage, 0, sizeof oldscreenimage);
	memset(&rootimage, 0, sizeof rootimage);
	memset(&newimage, 0, sizeof newimage);
	memset(&newwindow, 0, sizeof newwindow);
	memset(&oldscreen, 0, sizeof oldscreen);
	memset(&newscreen, 0, sizeof newscreen);
	rootimage.chan = newimage.chan = newwindow.chan = GREY8;
	display.image = &rootimage;
	display.white = &rootimage;
	oldscreen.image = &oldscreenimage;
	window = &oldwindow;
	screen = &oldscreen;
	windowp = &window;

	failed = 0;
	failed += check(gengetwindow(&display, "/dev/winname", &window, &screen, Refnone) == 1,
		"window reattach failed after the name changed");
	failed += check(opens == 2 && reads == 2 && closes == 2,
		"window name was not reopened and closed on retry");
	failed += check(namedcalls == 2,
		"named image attach was not retried exactly once");
	failed += check(oldimagefrees == 1 && oldscreenimagefrees == 1 && oldscreenfrees == 1,
		"old window resources were not released exactly once");
	failed += check(allocsawdiscarded == 0,
		"reattach reused the discarded window image");
	failed += check(window == &newwindow && screen == &newscreen,
		"reattach did not install the new window and screen");

	scenario = 1;
	opens = closes = 0;
	window = nil;
	screen = nil;
	failed += check(gengetwindow(&display, "/dev/winname", &window, &screen, Refnone) == 1,
		"failed winname read did not fall back to the display image");
	failed += check(opens == 1 && closes == 1,
		"failed winname read leaked its descriptor");
	failed += check(window == &rootimage,
		"failed winname read selected the wrong fallback image");

	if(failed != 0)
		return 1;
	print("PASS: gengetwindow resize race and descriptor cleanup\n");
	return 0;
}
