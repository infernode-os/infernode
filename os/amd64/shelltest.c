/*
 * os/amd64/shelltest.c -- boot to a shell.
 *
 * The same namespace the other tests build, with the kernel's own init
 * as the first Dis module: it binds #c at /dev, so /dev/cons is the
 * console sh checks for, and hands over to /dis/sh.dis.  The console
 * poller started here is what makes the other direction work -- the
 * shell can type, and a person can answer.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

void
shelltest(void)
{
	Chan *root;
	Pgrp *pg;

	if(portprocinit() < 0){
		consprint("shelltest: no memory above the kernel\n");
		return;
	}
	chandevreset();
	chandevinit();

	pg = newpgrp();
	up->env->fgrp = newfgrp(nil);
	up->env->pgrp = pg;
	up->env->egrp = newegrp();
	if(pg == nil || up->env->fgrp == nil || up->env->egrp == nil){
		consprint("shelltest: no namespace\n");
		return;
	}
	if(devno('/', 0) < 0){
		consprint("shelltest: no root device\n");
		return;
	}
	root = devtab[devno('/', 0)]->attach("");
	if(root == nil){
		consprint("shelltest: root attach failed\n");
		return;
	}
	incref(&root->r);
	pg->dot = root;
	pg->slash = root;

	/* the receive side: kbdq exists now, so the poller can fill it */
	consinputinit();

	/*
	 * KPDUPPG|KPDUPFDG|KPDUPENVG: disinit opens #c/cons three times
	 * for fd 0/1/2 and loads the init module by name, so it needs the
	 * namespace, the descriptor group and the environment above.
	 */
	kproc("dis", disinit, "/init.dis", KPDUPPG|KPDUPFDG|KPDUPENVG);
	schedinit();
}
