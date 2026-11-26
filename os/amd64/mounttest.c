/*
 * os/amd64/mounttest.c -- mount the #~ ring as a filesystem.
 *
 * The namespace root is the kernel's root device with one directory
 * (/n).  The 9P stream from #~/host is handed to kmount, which attaches
 * it with devmnt and records the mount on /n; opening /n/sub/hello.txt
 * then walks through the mount into 9vm's exported tree.  This is the
 * whole exercise in one boot: the ring is a device, the device is a 9P
 * connection, and the connection is a mounted filesystem.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include <kernel.h>
#include "../9vm/board.h"
#include "console.h"
#include "port.h"

void
mounttest(void)
{
	Chan *root;
	Pgrp *pg;
	int fd, mfd, n;
	char b[32];

	if(portprocinit() < 0){
		consprint("mounttest: no memory above the kernel\n");
		return;
	}
	chandevreset();
	chandevinit();

	pg = newpgrp();
	up->env->fgrp = newfgrp(nil);
	up->env->pgrp = pg;
	if(pg == nil || up->env->fgrp == nil){
		consprint("mounttest: no namespace\n");
		return;
	}
	if(devno('/', 0) < 0){
		consprint("mounttest: no root device\n");
		return;
	}
	root = devtab[devno('/', 0)]->attach("");
	if(root == nil){
		consprint("mounttest: root attach failed\n");
		return;
	}
	incref(&root->r);
	pg->dot = root;
	pg->slash = root;

	fd = kopen("#~/host", ORDWR);
	if(fd < 0){
		print("mounttest: open #~/host: %s\n", up->env->errstr);
		conshalt();
	}
	if(kmount(fd, -1, "/n", MREPL, "") < 0){
		print("mounttest: mount /n: %s\n", up->env->errstr);
		conshalt();
	}
	print("mounttest: #~/host mounted on /n\n");

	mfd = kopen("/n/sub/hello.txt", OREAD);
	if(mfd < 0){
		print("mounttest: open /n/sub/hello.txt: %s\n", up->env->errstr);
		conshalt();
	}
	n = kread(mfd, b, sizeof(b)-1);
	if(n < 0){
		print("mounttest: read: %s\n", up->env->errstr);
		conshalt();
	}
	b[n] = 0;
	print("mounttest: read %d \"%s\"\n", n, b);
	if(n != 15 || memcmp(b, "hello from 9vm\n", 15) != 0){
		print("mounttest failed\n");
		conshalt();
	}
	/* the ns channel, when 9vm was given a server to relay to */
	if(vmboard != nil && vmboard->nchan >= 2){
		fd = kopen("#~/ns", ORDWR);
		if(fd < 0){
			print("mounttest: open #~/ns: %s\n", up->env->errstr);
			conshalt();
		}
		if(kmount(fd, -1, "/m", MREPL, "") < 0){
			print("mounttest: mount /m: %s\n", up->env->errstr);
			conshalt();
		}
		print("mounttest: #~/ns mounted on /m\n");

		mfd = kopen("/m/hello", OREAD);
		if(mfd < 0){
			print("mounttest: open /m/hello: %s\n", up->env->errstr);
			conshalt();
		}
		n = kread(mfd, b, sizeof(b)-1);
		if(n < 0){
			print("mounttest: ns read: %s\n", up->env->errstr);
			conshalt();
		}
		b[n] = 0;
		print("mounttest: ns read %d \"%s\"\n", n, b);
		if(n != 14 || memcmp(b, "hello from ns\n", 14) != 0){
			print("mounttest failed: ns content\n");
			conshalt();
		}
	}

	print("mounttest passed\n");
	conshalt();
}
