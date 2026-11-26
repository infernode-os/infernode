/*
 * p9.c -- 9P2000 over the #~ ring: just the messages this stage needs.
 *
 * The version, attach, walk, open, read and clunk messages are encoded
 * and decoded here, one message at a time except for the pipelined read.
 * A whole 9P client -- the fid table, the directory reads, the namespace
 * -- is what devmnt is for; it arrives with os/port, and then this file's
 * job is only to carry messages, not to be an API above them.
 */

#include <string.h>
#include "board.h"

static uint16_t
g16(const uint8_t *p)
{
	return (uint16_t)(p[0] | p[1]<<8);
}

static uint32_t
g32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1]<<8 |
		(uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}

static uint64_t
g64(const uint8_t *p)
{
	return (uint64_t)g32(p) | (uint64_t)g32(p+4)<<32;
}

static void
p16(uint8_t *p, uint32_t v)
{
	p[0] = v;
	p[1] = v>>8;
}

static void
p32(uint8_t *p, uint32_t v)
{
	p[0] = v;
	p[1] = v>>8;
	p[2] = v>>16;
	p[3] = v>>24;
}

static void
p64(uint8_t *p, uint64_t v)
{
	p32(p, (uint32_t)v);
	p32(p+4, (uint32_t)(v>>32));
}

/* A string on the wire: a two-byte length and the bytes. */
static uint32_t
putstr(uint8_t *p, const char *s)
{
	uint32_t n;

	n = strlen(s);
	p16(p, n);
	memmove(p+2, s, n);
	return 2 + n;
}

static int
seterr(P9Client *c, const char *s)
{
	uint32_t i;

	for(i = 0; i < sizeof(c->err) - 1 && s[i] != 0; i++)
		c->err[i] = s[i];
	c->err[i] = 0;
	return -1;
}

/* An Rerror's text, with the server's message kept for the console. */
static int
rerror(P9Client *c, const uint8_t *p, uint32_t n)
{
	uint32_t len;

	if(n < 9)
		return seterr(c, "short Rerror");
	len = g16(p+7);
	if(len > n - 9)
		len = n - 9;
	if(len > sizeof(c->err) - 1)
		len = sizeof(c->err) - 1;
	memmove(c->err, p+9, len);
	c->err[len] = 0;
	return -1;
}

static uint16_t
nexttag(P9Client *c)
{
	c->nexttag++;
	if(c->nexttag >= P9_Notag)
		c->nexttag = 1;
	return c->nexttag;
}

/*
 * Sends one message and waits for its reply.  The reply, and the error
 * text on failure, live in the ring buffer: the caller owns the buffer
 * until it calls ringdone, which every caller does before the next
 * request.
 */
static uint8_t*
call(P9Client *c, const uint8_t *msg, uint32_t len, RingMsg *m,
	uint32_t *rlen, int *rerr)
{
	uint8_t *p;
	int r;

	*rerr = 0;
	if(ringsubmit(c->ring, msg, len, m) < 0){
		seterr(c, "no free ring slot");
		return 0;
	}
	r = ringrecv(c->ring, m);
	if(r < 0){
		/*
		 * A timeout leaves the request published: the host may
		 * still write its buffer, so the slot stays reserved.
		 * A refusal consumed the completion; the slot is free.
		 */
		if(r == -2)
			ringdone(c->ring, m);
		seterr(c, r == -1 ? "no reply from the host" :
			"the host refused the request");
		return 0;
	}
	*rlen = m->len;
	p = c->ring->buf[m->slot].response;
	if(p[5] != (uint8_t)m->tag || p[6] != (uint8_t)(m->tag >> 8)){
		ringdone(c->ring, m);
		seterr(c, "reply carries the wrong tag");
		return 0;
	}
	if(p[4] == P9_Rerror)
		*rerr = 1;
	return p;
}

int
p9mount(P9Client *c, Ring *r, uint32_t msize)
{
	static const char ver[] = "9P2000";
	uint8_t m[32];
	RingMsg rm;
	uint8_t *p;
	uint32_t n, got, vlen;
	int rerr;

	memset(c, 0, sizeof(*c));
	c->ring = r;
	c->msize = msize;

	n = 7 + 4 + 2 + sizeof(ver) - 1;
	p32(m, n);
	m[4] = P9_Tversion;
	p16(m+5, P9_Notag);
	p32(m+7, msize);
	p16(m+11, sizeof(ver) - 1);
	memmove(m+13, ver, sizeof(ver) - 1);

	p = call(c, m, n, &rm, &n, &rerr);
	if(p == 0)
		return -1;
	if(rerr){
		rerror(c, p, n);
		ringdone(c->ring, &rm);
		return -1;
	}
	if(p[4] != P9_Rversion || n < 13){
		seterr(c, "bad Rversion");
		ringdone(c->ring, &rm);
		return -1;
	}
	got = g32(p+7);
	vlen = g16(p+11);
	if(n != 13 + vlen || vlen != sizeof(ver) - 1 || got == 0){
		seterr(c, "bad Rversion");
		ringdone(c->ring, &rm);
		return -1;
	}
	if(memcmp(p+13, ver, vlen) != 0){
		if(vlen > sizeof(c->err) - 1)
			vlen = sizeof(c->err) - 1;
		memmove(c->err, p+13, vlen);
		c->err[vlen] = 0;
		ringdone(c->ring, &rm);
		return -1;
	}
	if(got > msize)
		got = msize;
	c->msize = got;
	ringdone(c->ring, &rm);
	return 0;
}

int
p9attach(P9Client *c, uint32_t fid, const char *uname, const char *aname,
	P9Qid *q)
{
	uint8_t m[128];
	RingMsg rm;
	uint8_t *p, *qid;
	uint32_t n, off, lu, la;
	int rerr;

	/* measure before copying: putstr() writes as it measures */
	lu = strlen(uname);
	la = strlen(aname);
	if(lu > 0xFFFF || la > 0xFFFF ||
	   15 + 2 + lu + 2 + la > sizeof(m))
		return seterr(c, "attach message too long");
	off = 15;
	off += putstr(m+off, uname);
	off += putstr(m+off, aname);
	p32(m, off);
	m[4] = P9_Tattach;
	p16(m+5, nexttag(c));
	p32(m+7, fid);
	p32(m+11, P9_Nofid);

	p = call(c, m, off, &rm, &n, &rerr);
	if(p == 0)
		return -1;
	if(rerr || p[4] != P9_Rattach || n < 20){
		if(rerr)
			rerror(c, p, n);
		else
			seterr(c, "bad Rattach");
		ringdone(c->ring, &rm);
		return -1;
	}
	qid = p+7;
	q->type = qid[0];
	q->vers = g32(qid+1);
	q->path = g64(qid+5);
	ringdone(c->ring, &rm);
	return 0;
}

/*
 * qids is an array of at least nqmax elements; a walk may return one qid
 * per element, and more than the caller can hold is an error, not a copy.
 */
int
p9walk(P9Client *c, uint32_t fid, uint32_t newfid, const char **names,
	int nname, P9Qid *qids, int nqmax, int *nqid)
{
	uint8_t m[512];
	RingMsg rm;
	uint8_t *p, *q;
	uint32_t n, off;
	int i, rerr;

	if(nname < 0 || nname > P9_Maxwelem)
		return seterr(c, "walk count");
	off = 17;
	for(i = 0; i < nname; i++){
		if(strlen(names[i]) > 0xFFFF)
			return seterr(c, "walk name too long");
		off += 2 + strlen(names[i]);
		if(off > sizeof(m))
			return seterr(c, "walk name too long");
	}
	p32(m, off);
	m[4] = P9_Twalk;
	p16(m+5, nexttag(c));
	p32(m+7, fid);
	p32(m+11, newfid);
	p16(m+15, nname);
	off = 17;
	for(i = 0; i < nname; i++)
		off += putstr(m+off, names[i]);

	p = call(c, m, off, &rm, &n, &rerr);
	if(p == 0)
		return -1;
	if(rerr){
		rerror(c, p, n);
		ringdone(c->ring, &rm);
		return -1;
	}
	if(p[4] != P9_Rwalk || n < 9){
		seterr(c, "bad Rwalk");
		ringdone(c->ring, &rm);
		return -1;
	}
	*nqid = g16(p+7);
	if(*nqid > nname || *nqid > nqmax ||
	   n != 9 + 13*(uint32_t)*nqid){
		seterr(c, "bad Rwalk qids");
		ringdone(c->ring, &rm);
		return -1;
	}
	for(i = 0; i < *nqid; i++){
		q = p + 9 + 13*i;
		qids[i].type = q[0];
		qids[i].vers = g32(q+1);
		qids[i].path = g64(q+5);
	}
	ringdone(c->ring, &rm);
	return 0;
}

int
p9open(P9Client *c, uint32_t fid, int mode, P9Qid *q, uint32_t *iounit)
{
	uint8_t m[16];
	RingMsg rm;
	uint8_t *p, *qid;
	uint32_t n;
	int rerr;

	p32(m, 12);
	m[4] = P9_Topen;
	p16(m+5, nexttag(c));
	p32(m+7, fid);
	m[11] = mode;

	p = call(c, m, 12, &rm, &n, &rerr);
	if(p == 0)
		return -1;
	if(rerr){
		rerror(c, p, n);
		ringdone(c->ring, &rm);
		return -1;
	}
	if(p[4] != P9_Ropen || n < 24){
		seterr(c, "bad Ropen");
		ringdone(c->ring, &rm);
		return -1;
	}
	qid = p+7;
	q->type = qid[0];
	q->vers = g32(qid+1);
	q->path = g64(qid+5);
	*iounit = g32(p+20);
	ringdone(c->ring, &rm);
	return 0;
}

/*
 * Issues n reads on fid at consecutive offsets and keeps all n in flight.
 * The replies stay in their ring buffers, and each P9Read's data points
 * at one, until p9pdone.  That is the point of the ring: the guest reads
 * the host's answer in place, with no copy, and the host is free to
 * complete them in any order.
 *
 * Submit and collect are separate so a caller can put one channel's ring
 * to work while another's requests are outstanding; p9pread is both.
 */
int
p9psubmit(P9Client *c, uint32_t fid, uint64_t off, uint32_t count, int n,
	P9Read *rd)
{
	uint8_t m[32];
	int i;

	if(n < 1 || n > P9_HOST_SLOTS)
		return seterr(c, "pipeline depth");
	memset(rd, 0, n * sizeof(*rd));
	for(i = 0; i < n; i++)
		rd[i].msg.slot = -1;

	for(i = 0; i < n; i++){
		p32(m, 23);
		m[4] = P9_Tread;
		p16(m+5, nexttag(c));
		p32(m+7, fid);
		p64(m+11, off + (uint64_t)i*count);
		p32(m+19, count);
		if(ringsubmit(c->ring, m, 23, &rd[i].msg) < 0){
			/*
			 * Everything already submitted is published; the
			 * host may still complete it, so those buffers
			 * stay reserved rather than being handed to a
			 * later request that a stale completion could
			 * satisfy.
			 */
			seterr(c, "no free ring slot");
			return -1;
		}
		rd[i].off = off + (uint64_t)i*count;
		rd[i].count = count;
	}
	return 0;
}

int
p9pcollect(P9Client *c, int n, P9Read *rd)
{
	uint8_t *p;
	uint32_t got;
	int i, r;

	for(i = 0; i < n; i++){
		r = ringrecv(c->ring, &rd[i].msg);
		if(r < 0){
			/*
			 * A timeout leaves this request and every later
			 * one published: return only the replies already
			 * collected.  A refusal consumed this request's
			 * completion, so its buffer may be freed too.
			 */
			if(r == -2)
				p9pdone(c, rd, i+1);
			else
				p9pdone(c, rd, i);
			seterr(c, r == -1 ? "no reply from the host" :
				"the host refused the request");
			return -1;
		}
		p = c->ring->buf[rd[i].msg.slot].response;
		if(p[5] != (uint8_t)rd[i].msg.tag ||
		   p[6] != (uint8_t)(rd[i].msg.tag >> 8)){
			seterr(c, "reply carries the wrong tag");
			p9pdone(c, rd, i+1);
			return -1;
		}
		if(p[4] == P9_Rerror){
			rerror(c, p, rd[i].msg.len);
			/* this reply arrived; later ones are still out */
			p9pdone(c, rd, i+1);
			return -1;
		}
		if(p[4] != P9_Rread || rd[i].msg.len < P9_Readhdrsz){
			seterr(c, "bad Rread");
			p9pdone(c, rd, i+1);
			return -1;
		}
		got = g32(p+7);
		if(got > rd[i].count || rd[i].msg.len != P9_Readhdrsz + got){
			seterr(c, "bad Rread count");
			p9pdone(c, rd, i+1);
			return -1;
		}
		rd[i].data = p + P9_Readhdrsz;
		rd[i].len = got;
	}
	return 0;
}

int
p9pread(P9Client *c, uint32_t fid, uint64_t off, uint32_t count, int n,
	P9Read *rd)
{
	if(p9psubmit(c, fid, off, count, n, rd) < 0)
		return -1;
	return p9pcollect(c, n, rd);
}

void
p9pdone(P9Client *c, P9Read *rd, int n)
{
	int i;

	for(i = 0; i < n; i++){
		ringdone(c->ring, &rd[i].msg);
		rd[i].data = 0;
		rd[i].len = 0;
	}
}

int
p9clunk(P9Client *c, uint32_t fid)
{
	uint8_t m[16];
	RingMsg rm;
	uint8_t *p;
	uint32_t n;
	int rerr;

	p32(m, 11);
	m[4] = P9_Tclunk;
	p16(m+5, nexttag(c));
	p32(m+7, fid);

	p = call(c, m, 11, &rm, &n, &rerr);
	if(p == 0)
		return -1;
	if(rerr){
		rerror(c, p, n);
		ringdone(c->ring, &rm);
		return -1;
	}
	if(p[4] != P9_Rclunk){
		seterr(c, "bad Rclunk");
		ringdone(c->ring, &rm);
		return -1;
	}
	ringdone(c->ring, &rm);
	return 0;
}

char*
p9err(P9Client *c)
{
	return c->err;
}
