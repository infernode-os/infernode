/*
 * cursorshim.c — LD_PRELOAD shim for tests/host/wm_cursor_test.sh.
 * Logs each cursor change emu makes through SDL, with the cursor's
 * mask bits counted (which cursor it is) and whether the call came on
 * the main thread, the only one SDL allows it on.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <pthread.h>
#include <SDL3/SDL.h>

static pthread_t mainthread;

__attribute__((constructor)) static void
shiminit(void)
{
	mainthread = pthread_self();
}

static const char*
thread(void)
{
	return pthread_equal(pthread_self(), mainthread) ? "main" : "other";
}

SDL_Cursor*
SDL_CreateCursor(const Uint8 *data, const Uint8 *mask, int w, int h, int hotx, int hoty)
{
	static SDL_Cursor *(*real)(const Uint8*, const Uint8*, int, int, int, int);
	SDL_Cursor *c;
	int i, n;

	if(real == NULL)
		real = (SDL_Cursor *(*)(const Uint8*, const Uint8*, int, int, int, int))dlsym(RTLD_NEXT, "SDL_CreateCursor");
	c = real(data, mask, w, h, hotx, hoty);
	n = 0;
	for(i = 0; i < w*h/8; i++)
		n += __builtin_popcount(mask[i]);
	fprintf(stderr, "C create %d %s\n", n, thread());
	return c;
}

bool
SDL_SetCursor(SDL_Cursor *c)
{
	static bool (*real)(SDL_Cursor*);

	if(real == NULL)
		real = (bool (*)(SDL_Cursor*))dlsym(RTLD_NEXT, "SDL_SetCursor");
	fprintf(stderr, "C set %s\n", thread());
	return real(c);
}

void
SDL_DestroyCursor(SDL_Cursor *c)
{
	static void (*real)(SDL_Cursor*);

	if(real == NULL)
		real = (void (*)(SDL_Cursor*))dlsym(RTLD_NEXT, "SDL_DestroyCursor");
	fprintf(stderr, "C destroy %s\n", thread());
	real(c);
}
