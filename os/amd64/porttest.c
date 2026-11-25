/*
 * os/amd64/porttest.c -- the os/port foundation at boot.
 *
 * Three things every later os/port file depends on: setlabel/gotolabel
 * (the error machinery and the scheduler), _tas (the spin locks), and
 * spl masking (everything that takes a lock).  Each is tested for what
 * it promises rather than merely called.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

static Label	lab;
static int	unwound;

static void
jumpback(void)
{
	unwound = 1;
	gotolabel(&lab);
	consprint("infernode/amd64: port: gotolabel returned\n");
}

/* setlabel returns 0; gotolabel makes it return 1, in this frame */
static int
labeltest(void)
{
	int r;

	unwound = 0;
	r = setlabel(&lab);
	if(r == 0)
		jumpback();
	return r == 1 && unwound == 1;
}

static int
tastest(void)
{
	ulong w;

	w = 0;
	if(_tas(&w) != 0 || w != 1)
		return 0;
	if(_tas(&w) != 1 || w != 1)
		return 0;
	w = 0;
	if(_tas(&w) != 0 || w != 1)
		return 0;
	w = 0;
	return 1;
}

static int
spltest(void)
{
	int s;

	/* make sure interrupts start on */
	s = splhi();
	splx(s | (1<<9));
	if(!islo())
		return 0;

	s = splhi();			/* saves IF=1, turns them off */
	if(islo()){
		splx(s);
		return 0;
	}
	splx(s);			/* restores IF=1 */
	if(!islo())
		return 0;

	/* leave them as the caller found them: off */
	(void)splhi();
	return 1;
}

void
porttest(void)
{
	int ok;

	ok = 1;
	if(labeltest())
		consprint("infernode/amd64: port: labels ok\n");
	else{
		consprint("infernode/amd64: port: labels failed\n");
		ok = 0;
	}
	if(tastest())
		consprint("infernode/amd64: port: tas ok\n");
	else{
		consprint("infernode/amd64: port: tas failed\n");
		ok = 0;
	}
	if(spltest())
		consprint("infernode/amd64: port: spl ok\n");
	else{
		consprint("infernode/amd64: port: spl failed\n");
		ok = 0;
	}

	if(ok)
		consprint("infernode/amd64: porttest passed\n");
	else
		consprint("infernode/amd64: porttest failed\n");
}
