/*
 * A BCM2837 board's outputs (#1216): a 3B+ or 3A+ has the jack, #A, and
 * HDMI, #A1 (os/bcm/audiopwm.c, os/bcm/audiohdmi.c); a Zero 2 W has no
 * jack, and HDMI is its #A.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "board.h"
#include "../port/error.h"
#include "../port/audio.h"

extern Audioout audiopwmout, audiohdmiout;

Audioout*
audioout(int n)
{
	static Audioout *zero[] = { &audiohdmiout, nil };	/* no jack: GPIO 40 and 41 are the camera's and the radio's */
	static Audioout *pi3[] = { &audiopwmout, &audiohdmiout, nil };
	Audioout **l;
	int i;

	l = boardtype() == Btzero2w? zero : pi3;
	if(n < 0)
		return nil;
	for(i = 0; i < n; i++)
		if(l[i] == nil)
			return nil;
	return l[n];
}
