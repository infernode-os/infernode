#include <lib9.h>

/*
 * The block is tagged with strdup's caller, not with strdup, as Plan 9's
 * libc tags it: /dev/memtags named every string as strdup's, so a soak
 * that kept thousands more of them (a Pi Zero 2 W, 2051 to 5379 in 11 h)
 * could not say whose they were.
 */
char*
strdup(char *s)
{
	char *os;

	os = malloc(strlen(s) + 1);
	if(os == 0)
		return 0;
	setmalloctag(os, (ulong)(uintptr)__builtin_return_address(0));
	return strcpy(os, s);
}
