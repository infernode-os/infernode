#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

void
_assert(char *s)
{
	fprint(2, "FAIL: draw clipping assertion: %s\n", s);
	exits("assert");
}

int
main(void)
{
	Memimage src, mask;
	Rectangle dr, clip, r, sr, mr;
	Point sp, mp;

	memset(&src, 0, sizeof src);
	memset(&mask, 0, sizeof mask);
	dr = Rect(0, 0, 100, 100);
	clip = Rect(10, 20, 30, 40);
	r = Rect(0, 0, 50, 50);
	src.r = src.clipr = Rect(0, 0, 100, 100);
	mask.r = mask.clipr = Rect(0, 0, 100, 100);
	sp = mp = ZP;
	if(!_drawclip(&dr, &clip, &r, &src, &sp, &mask, &mp, &sr, &mr)){
		fprint(2, "FAIL: explicit clip rejected a valid draw\n");
		return 1;
	}
	if(!eqrect(dr, Rect(0, 0, 100, 100)) || !eqrect(clip, Rect(10, 20, 30, 40))){
		fprint(2, "FAIL: explicit clipping mutated shared image geometry\n");
		return 1;
	}
	if(!eqrect(r, clip)){
		fprint(2, "FAIL: explicit clipping produced the wrong destination\n");
		return 1;
	}
	print("PASS: layered draw clipping uses immutable geometry\n");
	return 0;
}
