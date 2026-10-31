#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "memlayer.h"

/*
 * The lines joining vert as one anti-aliased stroke (aadrawlines): the
 * ends as line's, the joins round, and no seam or doubled coverage
 * where one segment meets the next.
 */
void
mempoly(Memimage *dst, Point *vert, int nvert, int end0, int end1, int radius, Memimage *src, Point sp, int op)
{
	Aapoly poly;

	if(nvert < 2 || radius < 0)
		return;
	aapolyinit(&poly);
	aadrawlines(&poly, vert, nvert, radius, end0, end1);
	memaadraw(dst, &poly, ~0, src, subpt(sp, vert[0]), op);
	aapolyfree(&poly);
}
