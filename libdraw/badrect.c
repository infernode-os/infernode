#include "lib9.h"
#include "draw.h"

/*
 * Keep image geometry inside the range in which unitsperline(), Memimage.zero
 * and byteaddr() can do their offset arithmetic.  Use vlong for the
 * validation itself: the host compilers do not provide Plan 9 C's wrapping
 * signed arithmetic.
 */
int
badrect(Rectangle r)
{
	vlong x, y, pixels, zy0, zy1;

	x = (vlong)r.max.x - r.min.x;
	y = (vlong)r.max.y - r.min.y;
	if(x <= 0 || y <= 0)
		return 1;
	if(r.min.x < -(1<<25) || r.min.x >= (1<<25) ||
	   r.max.x < -(1<<25) || r.max.x >= (1<<25))
		return 1;
	pixels = x*y;
	if(pixels > 0xFFFFFFFFULL)
		return 1;
	zy0 = x*r.min.y;
	zy1 = x*r.max.y;
	/* Memimage.zero is a vlong: an image far down its coordinates is
	 * fine, so long as the offset stays well inside it. */
	if(zy0 < -((vlong)1<<32) || zy0 >= ((vlong)1<<32) ||
	   zy1 < -((vlong)1<<32) || zy1 >= ((vlong)1<<32))
		return 1;
	return 0;
}
