/*
 * os/amd64/jittest.c -- the JIT, and the interpreter it must agree with.
 *
 * The same module (/jittest.dis) is run twice: interptest sets cflag 0,
 * so parsemod() leaves every module as bytecode, and jittest sets it 1,
 * so comp-amd64.c compiles each one as it loads.  The harness requires
 * the same lines from both boots; anything the generator gets wrong
 * changes an answer or kills the Prog, and both are visible.
 *
 * cflag is read once per module, at load, and disinit loads the init
 * module -- so it is set here, before disinit's process starts.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

extern int	cflag;

static void
jitboot(int gen)
{
	Chan *root;
	Pgrp *pg;

	if(portprocinit() < 0){
		consprint("jittest: no memory above the kernel\n");
		return;
	}
	loopbackmediumlink();
	ethermediumlink();
	chandevreset();
	virtionetlink();
	chandevinit();

	pg = newpgrp();
	up->env->fgrp = newfgrp(nil);
	up->env->pgrp = pg;
	up->env->egrp = newegrp();
	if(pg == nil || up->env->fgrp == nil || up->env->egrp == nil){
		consprint("jittest: no namespace\n");
		return;
	}
	if(devno('/', 0) < 0){
		consprint("jittest: no root device\n");
		return;
	}
	root = devtab[devno('/', 0)]->attach("");
	if(root == nil){
		consprint("jittest: root attach failed\n");
		return;
	}
	incref(&root->r);
	pg->dot = root;
	pg->slash = root;

	cflag = gen;
	print("jittest: cflag %d (%s)\n", cflag,
		cflag ? "compiling Dis to amd64" : "interpreter only");
	kproc("dis", disinit, "/jittest.dis", KPDUPPG|KPDUPFDG|KPDUPENVG);
	schedinit();
}

void
jittest(void)
{
	jitboot(1);
}

void
interptest(void)
{
	jitboot(0);
}
