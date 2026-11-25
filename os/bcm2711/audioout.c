/*
 * A BCM2711 board's outputs: the jack, #A (os/bcm/audiopwm.c). The Pi 4's
 * HDMI audio, its own blocks behind the BCM2711's HDMI PHY, is #1216's
 * second phase.
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

extern Audioout audiopwmout;

Audioout*
audioout(int n)
{
	static Audioout *pi4[] = { &audiopwmout, nil };
	Audioout **l;
	int i;

	l = pi4;
	if(n < 0)
		return nil;
	for(i = 0; i < n; i++)
		if(l[i] == nil)
			return nil;
	return l[n];
}
