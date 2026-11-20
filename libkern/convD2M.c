#include	"lib9.h"
#include	"fcall.h"

/*
 * A stat's size and each string's count are 16 bits.  A Dir whose
 * strings do not fit them was packed all the same, the counts mod
 * 65536: bytes that are no stat, given as one.  It has no size (0)
 * and is not packed (0).
 */
uint
sizeD2M(Dir *d)
{
	char *sv[4];
	int i, ns;
	ulong n;

	sv[0] = d->name;
	sv[1] = d->uid;
	sv[2] = d->gid;
	sv[3] = d->muid;

	ns = 0;
	for(i = 0; i < 4; i++)
		if(sv[i]){
			n = strlen(sv[i]);
			if(n > 0xFFFF)
				return 0;
			ns += n;
		}

	/* a stat's size is 16 bits and does not count itself */
	if(STATFIXLEN + ns - BIT16SZ > 0xFFFF)
		return 0;
	return STATFIXLEN + ns;
}

uint
convD2M(Dir *d, uchar *buf, uint nbuf)
{
	uchar *p, *ebuf;
	char *sv[4];
	int i, ns, nsv[4], ss;

	if(nbuf < BIT16SZ)
		return 0;
	if(sizeD2M(d) == 0)
		return 0;

	p = buf;
	ebuf = buf + nbuf;

	sv[0] = d->name;
	sv[1] = d->uid;
	sv[2] = d->gid;
	sv[3] = d->muid;

	ns = 0;
	for(i = 0; i < 4; i++){
		if(sv[i])
			nsv[i] = strlen(sv[i]);
		else
			nsv[i] = 0;
		ns += nsv[i];
	}

	ss = STATFIXLEN + ns;

	/* set size befor erroring, so user can know how much is needed */
	/* note that length excludes count field itself */
	PBIT16(p, ss-BIT16SZ);
	p += BIT16SZ;

	if(ss > nbuf)
		return BIT16SZ;

	PBIT16(p, d->type);
	p += BIT16SZ;
	PBIT32(p, d->dev);
	p += BIT32SZ;
	PBIT8(p, d->qid.type);
	p += BIT8SZ;
	PBIT32(p, d->qid.vers);
	p += BIT32SZ;
	PBIT64(p, d->qid.path);
	p += BIT64SZ;
	PBIT32(p, d->mode);
	p += BIT32SZ;
	PBIT32(p, d->atime);
	p += BIT32SZ;
	PBIT32(p, d->mtime);
	p += BIT32SZ;
	PBIT64(p, d->length);
	p += BIT64SZ;

	for(i = 0; i < 4; i++){
		ns = nsv[i];
		if(p + ns + BIT16SZ > ebuf)
			return 0;
		PBIT16(p, ns);
		p += BIT16SZ;
		if(ns)
			memmove(p, sv[i], ns);
		p += ns;
	}

	if(ss != p - buf)
		return 0;

	return p - buf;
}
