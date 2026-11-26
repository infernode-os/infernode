/*
 * os/amd64/nettest.c -- boot to the network test.
 *
 * The same namespace the other tests build, with os/ip linked in and
 * the loopback medium registered.  The module binds #I at /net itself,
 * configures 127.0.0.1/8, sends an ICMP echo through the stack, and
 * mounts the host's namespace channel when the loader offers one.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

void
nettest(void)
{
	Chan *root;
	Pgrp *pg;

	if(portprocinit() < 0){
		consprint("nettest: no memory above the kernel\n");
		return;
	}

	/*
	 * The loopback medium, before the device table is reset: #I's
	 * reset registers the protocols, and "bind loopback" looks the
	 * medium up by name when an interface asks for it.
	 */
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
		consprint("nettest: no namespace\n");
		return;
	}
	if(devno('/', 0) < 0){
		consprint("nettest: no root device\n");
		return;
	}
	root = devtab[devno('/', 0)]->attach("");
	if(root == nil){
		consprint("nettest: root attach failed\n");
		return;
	}
	incref(&root->r);
	pg->dot = root;
	pg->slash = root;

	kproc("dis", disinit, "/nettest.dis", KPDUPPG|KPDUPFDG|KPDUPENVG);
	schedinit();
}
