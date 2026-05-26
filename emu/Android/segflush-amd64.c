/*
 * Cache flush for x86_64 Linux
 *
 * x86_64 has hardware cache coherency, so no explicit flush needed.
 * This is a no-op like on 386.
 */

#include "dat.h"

int
segflush(void *a, ulong n)
{
	USED(a);
	USED(n);
	return 0;
}
