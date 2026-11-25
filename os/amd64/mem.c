/*
 * os/amd64/mem.c -- the memory and string routines a freestanding kernel
 * needs.
 *
 * There is no libc here, and clang lowers struct copies, array clears and
 * loop idioms to memcpy, memmove, memset, memcmp and strlen even under
 * -ffreestanding, so the kernel has to provide them.  They are byte
 * loops on purpose: nothing at this stage is worth an unrolled word copy,
 * and SSE is off.  os/port brings its own with the rest of the library.
 */

#include <stddef.h>

void*
memmove(void *d, const void *s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;

	if(dp < sp){
		while(n-- > 0)
			*dp++ = *sp++;
	}else if(dp > sp){
		dp += n;
		sp += n;
		while(n-- > 0)
			*--dp = *--sp;
	}
	return d;
}

void*
memcpy(void *d, const void *s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;

	while(n-- > 0)
		*dp++ = *sp++;
	return d;
}

void*
memset(void *d, int c, size_t n)
{
	unsigned char *dp = d;

	while(n-- > 0)
		*dp++ = (unsigned char)c;
	return d;
}

int
memcmp(const void *a, const void *b, size_t n)
{
	const unsigned char *ap = a, *bp = b;

	while(n-- > 0){
		if(*ap != *bp)
			return *ap - *bp;
		ap++;
		bp++;
	}
	return 0;
}

int
strcmp(const char *a, const char *b)
{
	while(*a != 0 && *a == *b){
		a++;
		b++;
	}
	return (unsigned char)*a - (unsigned char)*b;
}

size_t
strlen(const char *s)
{
	size_t n;

	for(n = 0; s[n] != 0; n++)
		;
	return n;
}
