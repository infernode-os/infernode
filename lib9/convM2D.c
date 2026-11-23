#include	"lib9.h"
#include	"fcall.h"

int
statcheck(uchar *buf, uint nbuf)
{
	uint n, remain;
	int i;

	if(nbuf < STATFIXLEN || nbuf != BIT16SZ + GBIT16(buf))
		return -1;

	buf += STATFIXLEN - 4 * BIT16SZ;
	remain = nbuf - (STATFIXLEN - 4 * BIT16SZ);

	for(i = 0; i < 4; i++){
		if(remain < BIT16SZ)
			return -1;
		n = GBIT16(buf);
		buf += BIT16SZ;
		remain -= BIT16SZ;
		if(n > remain)
			return -1;
		/* a name with a NUL in it is another name to C */
		if(n != 0 && memchr(buf, 0, n) != nil)
			return -1;
		buf += n;
		remain -= n;
	}

	if(remain != 0)
		return -1;

	return 0;
}

/* Check one stat inside a buffer that may contain following entries. */
int
statcheckbuf(uchar *buf, uint navail)
{
	uint nbuf;

	if(navail < BIT16SZ)
		return -1;
	nbuf = BIT16SZ + GBIT16(buf);
	if(nbuf > navail || statcheck(buf, nbuf) < 0)
		return -1;
	return nbuf;
}

static char nullstring[] = "";

/*
 * A wstat leaves mode, atime and mtime alone by sending ~0 in their
 * 32 bits. Where ulong is wider than that, keep it ~0 in the whole
 * ulong, or the ~0 and ~(ulong)0 tests that look for it never match.
 */
static ulong
gbit32dontcare(uchar *p)
{
	ulong v;

	v = GBIT32(p);
	if(v == 0xFFFFFFFFUL)
		return ~(ulong)0;	/* not ~0UL: an unsigned long is 32 bits on Windows (LLP64) */
	return v;
}

/*
 * strs is given no length: nbuf bytes are always enough (the four
 * strings and their NULs take the room of their counts and less),
 * and a caller whose buffer is of another size checks nbuf first.
 */
uint
convM2D(uchar *buf, uint nbuf, Dir *d, char *strs)
{
	uchar *p, *ebuf;
	char *sv[4];
	int i, ns;

	if(nbuf < STATFIXLEN)
		return 0; 

	p = buf;
	ebuf = buf + nbuf;

	p += BIT16SZ;	/* ignore size */
	d->type = GBIT16(p);
	p += BIT16SZ;
	d->dev = GBIT32(p);
	p += BIT32SZ;
	d->qid.type = GBIT8(p);
	p += BIT8SZ;
	d->qid.vers = GBIT32(p);
	p += BIT32SZ;
	d->qid.path = GBIT64(p);
	p += BIT64SZ;
	d->mode = gbit32dontcare(p);
	p += BIT32SZ;
	d->atime = gbit32dontcare(p);
	p += BIT32SZ;
	d->mtime = gbit32dontcare(p);
	p += BIT32SZ;
	d->length = GBIT64(p);
	p += BIT64SZ;

	for(i = 0; i < 4; i++){
		if(p + BIT16SZ > ebuf)
			return 0;
		ns = GBIT16(p);
		p += BIT16SZ;
		if(p + ns > ebuf)
			return 0;
		if(ns != 0 && memchr(p, 0, ns) != nil)
			return 0;
		if(strs){
			sv[i] = strs;
			memmove(strs, p, ns);
			strs += ns;
			*strs++ = '\0';
		}
		p += ns;
	}

	if(strs){
		d->name = sv[0];
		d->uid = sv[1];
		d->gid = sv[2];
		d->muid = sv[3];
	}else{
		d->name = nullstring;
		d->uid = nullstring;
		d->gid = nullstring;
		d->muid = nullstring;
	}
	
	return p - buf;
}
