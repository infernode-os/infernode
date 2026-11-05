#include "lib9.h"
#include "draw.h"

static
int
unitsperline(Rectangle r, int d, int bitsperunit)
{
	if(d <= 0 || d > 32)
		abort();
	return ((vlong)r.max.x*d - ((vlong)r.min.x*d & -bitsperunit)
		+ bitsperunit - 1) / bitsperunit;
}

int
wordsperline(Rectangle r, int d)
{
	return unitsperline(r, d, 8*sizeof(ulong));
}

int
bytesperline(Rectangle r, int d)
{
	return unitsperline(r, d, 8);
}
