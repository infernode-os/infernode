/*
 * os/amd64/vmtest.c -- hand the machine to the Dis VM.
 *
 * Everything below this point is the kernel a Limbo program runs on:
 * devroot serves /dis/vmtest.dis out of the image, dis.c loads and
 * schedules it, and vmachine() interprets it.  The program prints
 * through Sys->print, which is a Dis call into os/port/inferno.c and
 * ends at the 16550, and it halts the machine through #c/sysctl when
 * it is done.
 *
 * The interpreter uses SSE for Dis REALs, so this boot also proves the
 * FP state survives a context switch: procsave/procrestore FXSAVE it
 * per process and dis.c saves each Prog's own copy per quantum.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

/* os/amd64/fpwork.c: the second floating point user, next to the VM */
void	fpwork(void*);

void
vmtest(void)
{
	Chan *root;
	Pgrp *pg;

	if(portprocinit() < 0){
		consprint("vmtest: no memory above the kernel\n");
		return;
	}
	chandevreset();
	chandevinit();

	pg = newpgrp();
	up->env->fgrp = newfgrp(nil);
	up->env->pgrp = pg;
	up->env->egrp = newegrp();
	if(pg == nil || up->env->fgrp == nil || up->env->egrp == nil){
		consprint("vmtest: no namespace\n");
		return;
	}
	if(devno('/', 0) < 0){
		consprint("vmtest: no root device\n");
		return;
	}
	root = devtab[devno('/', 0)]->attach("");
	if(root == nil){
		consprint("vmtest: root attach failed\n");
		return;
	}
	incref(&root->r);
	pg->dot = root;
	pg->slash = root;

	/*
	 * KPDUPPG|KPDUPFDG|KPDUPENVG: disinit opens #c/cons three times
	 * for fd 0/1/2 and loads the test module by name, so it needs the
	 * namespace, the descriptor group and the environment above.
	 */
	kproc("dis", disinit, "/dis/vmtest.dis",
	      KPDUPPG|KPDUPFDG|KPDUPENVG);
	kproc("fpwork", fpwork, nil, 0);
	schedinit();
}
