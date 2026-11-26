/*
 * os/amd64/ringdevtest.c -- the #~ device as a 9P connection.
 *
 * This is the client devmnt will be: it opens #~/host as a byte stream,
 * writes T-messages, reads R-messages, and runs a whole 9P2000
 * conversation over the ring -- version, attach, a two-element walk,
 * open, read and clunk -- through the same chan/dev layer and the same
 * convS2M/convM2S the kernel uses everywhere else.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include <kernel.h>
#include "console.h"
#include "port.h"

/* the ring's message size; board.h's Qid would collide with fcall.h's */
enum { MsgSize = 32768 };

static int	fd;
static uchar	tbuf[MsgSize], rbuf[MsgSize];

static int
fail(char *what)
{
	print("ringdev: %s\n", what);
	print("ringdevtest failed\n");
	conshalt();
	return -1;
}

static int
rpc(Fcall *f, Fcall *r)
{
	uint n, m;

	n = convS2M(f, tbuf, sizeof(tbuf));
	if(n == 0)
		return fail("convS2M");
	if(kwrite(fd, tbuf, n) != n)
		return fail("write");
	m = kread(fd, rbuf, sizeof(rbuf));
	if(m < 7)
		return fail("read");
	if(convM2S(rbuf, m, r) == 0)
		return fail("convM2S");
	if(r->type == Rerror)
		return fail(r->ename);
	return 0;
}

void
ringdevtest(void)
{
	Fcall f, r;
	char b[64];

	if(portprocinit() < 0){
		consprint("ringdev: no memory above the kernel\n");
		return;
	}
	chandevreset();
	chandevinit();
	up->env->pgrp = newpgrp();
	up->env->fgrp = newfgrp(nil);
	if(up->env->pgrp == nil || up->env->fgrp == nil){
		consprint("ringdev: no namespace\n");
		return;
	}

	fd = kopen("#~/host", ORDWR);
	if(fd < 0){
		print("ringdev: open #~/host: %s\n", up->env->errstr);
		conshalt();
	}

	/*
	 * A ring is one 9P stream, and completions are collected from it
	 * without regard to which stream submitted them.  A second open
	 * would steal the first one's replies, so the device refuses it.
	 */
	if(kopen("#~/host", ORDWR) >= 0){
		print("ringdev failed: a second open of #~/host succeeded\n");
		conshalt();
	}
	print("ringdev: a second open of the channel is refused\n");

	memset(&f, 0, sizeof(f));
	f.type = Tversion;
	f.tag = NOTAG;
	f.msize = MsgSize;
	f.version = "9P2000";
	if(rpc(&f, &r) < 0 || r.type != Rversion)
		fail("no Rversion");
	print("ringdev: %s msize %ud\n", r.version, r.msize);
	if(strcmp(r.version, "9P2000") != 0)
		fail("wrong version");

	memset(&f, 0, sizeof(f));
	f.type = Tattach;
	f.fid = 0;
	f.afid = NOFID;
	f.uname = "inferno";
	f.aname = "";
	if(rpc(&f, &r) < 0 || r.type != Rattach)
		fail("no Rattach");

	memset(&f, 0, sizeof(f));
	f.type = Twalk;
	f.fid = 0;
	f.newfid = 1;
	f.nwname = 2;
	f.wname[0] = "sub";
	f.wname[1] = "hello.txt";
	if(rpc(&f, &r) < 0 || r.type != Rwalk || r.nwqid != 2)
		fail("walk sub/hello.txt");

	memset(&f, 0, sizeof(f));
	f.type = Topen;
	f.fid = 1;
	f.mode = OREAD;
	if(rpc(&f, &r) < 0 || r.type != Ropen)
		fail("open");

	memset(&f, 0, sizeof(f));
	f.type = Tread;
	f.fid = 1;
	f.offset = 0;
	f.count = 4096;
	if(rpc(&f, &r) < 0 || r.type != Rread)
		fail("read");
	memset(b, 0, sizeof(b));
	if(r.count < sizeof(b))
		memmove(b, r.data, r.count);
	print("ringdev: read %ud \"%s\"\n", r.count, b);
	if(r.count != 15 || memcmp(r.data, "hello from 9vm\n", 15) != 0)
		fail("content");

	memset(&f, 0, sizeof(f));
	f.type = Tclunk;
	f.fid = 1;
	if(rpc(&f, &r) < 0 || r.type != Rclunk)
		fail("clunk");

	/*
	 * A clean close returns the ring to the pool: with every reply
	 * collected, the channel opens again.
	 */
	kclose(fd);
	fd = kopen("#~/host", ORDWR);
	if(fd < 0){
		print("ringdev failed: reopen after close: %s\n", up->env->errstr);
		conshalt();
	}
	print("ringdev: the channel reopens after a clean close\n");

	print("ringdevtest passed\n");
	conshalt();
}
