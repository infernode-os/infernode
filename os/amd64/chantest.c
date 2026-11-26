/*
 * os/amd64/chantest.c -- channels and a device, end to end.
 *
 * kpipe() walks the real path: devno('|') through the device table,
 * devattach, the pipe's directory walk to data/data1, devopen, and two
 * Queue-backed Chans.  A write on one end and a read on the other then
 * exercises devwrite/devread, the file-descriptor table and qio.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include <kernel.h>
#include "console.h"
#include "port.h"

void
chantest(void)
{
	int fd[2], n;
	char b[32];

	if(portprocinit() < 0){
		consprint("chantest: no memory above the kernel\n");
		return;
	}
	chandevreset();
	chandevinit();

	up->env->pgrp = newpgrp();
	up->env->fgrp = newfgrp(nil);
	if(up->env->pgrp == nil || up->env->fgrp == nil){
		consprint("chantest: no namespace\n");
		return;
	}

	if(kpipe(fd) < 0){
		print("chantest: kpipe: %s\n", up->env->errstr);
		conshalt();
	}
	if(kwrite(fd[1], "hello", 5) != 5){
		print("chantest: write: %s\n", up->env->errstr);
		conshalt();
	}
	n = kread(fd[0], b, sizeof(b)-1);
	if(n < 0){
		print("chantest: read: %s\n", up->env->errstr);
		conshalt();
	}
	b[n] = 0;
	print("chantest: read %d \"%s\"\n", n, b);
	if(n != 5 || memcmp(b, "hello", 5) != 0){
		print("chantest failed\n");
		conshalt();
	}
	print("chantest passed\n");
	conshalt();
}
