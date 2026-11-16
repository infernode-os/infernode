/*
 * lib9's 9P marshalling (convM2S.c, convS2M.c, convM2D.c, convD2M.c,
 * fcallfmt.c; libkern's are the same files) at its edges, run by
 * tests/host/ninep_conv_test.sh under ASan and UBSan with every
 * message and every Fcall in a heap block exactly as long as it is.
 *
 *	convtest case
 *
 * prints a line for each check and exits 0 if all held.
 */
#include "lib9.h"
#include "fcall.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int nfail, nok;

static void
check(int cond, char *fmt, ...)
{
	va_list a;
	char buf[400];

	va_start(a, fmt);
	vsnprintf(buf, sizeof buf, fmt, a);
	va_end(a);
	if(cond)
		nok++;
	else{
		nfail++;
		printf("    not so: %s\n", buf);
	}
}

static void p32(uchar *p, uint v){ p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; }
static void p16(uchar *p, uint v){ p[0]=v; p[1]=v>>8; }

/* convM2S of n bytes in a block of n bytes */
static uint
m2s(uchar *msg, uint n, Fcall *f)
{
	static uchar *b;

	free(b);
	b = malloc(n ? n : 1);
	memcpy(b, msg, n);
	memset(f, 0xa5, sizeof *f);
	return convM2S(b, n, f);
}

static char*
fill(int n, int c)
{
	char *s;

	s = malloc(n+1);
	memset(s, c, n);
	s[n] = 0;
	return s;
}

static Fcall*
newfcall(int type)
{
	Fcall *f;

	f = malloc(sizeof *f);	/* at the end of its block */
	memset(f, 0, sizeof *f);
	f->type = type;
	f->tag = 1;
	return f;
}

/* a 9P string with a NUL in it is refused */
static void
m2snul(void)
{
	Fcall f;
	uchar m[256];
	uint r;

	/* Twalk, one name of five bytes: "..", NUL, "ab" */
	memset(m, 0, sizeof m);
	p32(m, 17+2+5); m[4] = Twalk; p16(m+5, 1); p32(m+7, 1); p32(m+11, 2); p16(m+15, 1); p16(m+17, 5);
	memcpy(m+19, "..\0ab", 5);
	r = m2s(m, 24, &f);
	check(r == 0, "a Twalk whose name is \"..\\0ab\" is taken (%u) as \"%s\"", r, r? f.wname[0]: "");
	memcpy(m+19, "..xab", 5);
	r = m2s(m, 24, &f);
	check(r == 24 && strcmp(f.wname[0], "..xab") == 0, "a Twalk with a name of five bytes is not read (%u)", r);
	memcpy(m+19, "..xa\0", 5);
	check(m2s(m, 24, &f) == 0, "a name ending in a NUL is taken");
	memcpy(m+19, "\0.xab", 5);
	check(m2s(m, 24, &f) == 0, "a name beginning with a NUL is taken");

	/* Rerror */
	memset(m, 0, sizeof m);
	p32(m, 9+4); m[4] = Rerror; p16(m+5, 1); p16(m+7, 4); memcpy(m+9, "a\0bc", 4);
	check(m2s(m, 13, &f) == 0, "an Rerror whose text has a NUL is taken");
	memcpy(m+9, "abcd", 4);
	r = m2s(m, 13, &f);
	check(r == 13 && strcmp(f.ename, "abcd") == 0, "an Rerror is not read (%u)", r);

	/* Tversion, Tattach (both strings), Tcreate */
	memset(m, 0, sizeof m);
	p32(m, 13+6); m[4] = Tversion; p16(m+5, 1); p32(m+7, 8192); p16(m+11, 6); memcpy(m+13, "9P\0abc", 6);
	check(m2s(m, 19, &f) == 0, "a Tversion whose version has a NUL is taken");
	memset(m, 0, sizeof m);
	p32(m, 15+2+3+2+3); m[4] = Tattach; p16(m+5, 1); p32(m+7, 1); p32(m+11, ~0);
	p16(m+15, 3); memcpy(m+17, "u\0r", 3); p16(m+20, 3); memcpy(m+22, "abc", 3);
	check(m2s(m, 25, &f) == 0, "a Tattach whose user name has a NUL is taken");
	memcpy(m+17, "usr", 3); memcpy(m+22, "a\0c", 3);
	check(m2s(m, 25, &f) == 0, "a Tattach whose aname has a NUL is taken");
	memcpy(m+22, "abc", 3);
	r = m2s(m, 25, &f);
	check(r == 25 && strcmp(f.uname, "usr") == 0 && strcmp(f.aname, "abc") == 0, "a Tattach is not read (%u)", r);
	memset(m, 0, sizeof m);
	p32(m, 11+2+3+4+1); m[4] = Tcreate; p16(m+5, 1); p32(m+7, 1); p16(m+11, 3); memcpy(m+13, "f\0g", 3);
	check(m2s(m, 21, &f) == 0, "a Tcreate whose name has a NUL is taken");
	/* an empty string is one */
	memset(m, 0, sizeof m);
	p32(m, 9); m[4] = Rerror; p16(m+5, 1); p16(m+7, 0);
	r = m2s(m, 9, &f);
	check(r == 9 && f.ename[0] == 0, "an Rerror with no text is not read (%u)", r);
}

/* a stat's four strings likewise, by statcheck and by convM2D */
static void
m2dnul(void)
{
	Dir d, d2;
	uchar *buf, *b2;
	char *strs;
	uint n, r;
	int i, o;

	memset(&d, 0, sizeof d);
	d.name = "name"; d.uid = "user"; d.gid = "grp"; d.muid = "mu";
	n = sizeD2M(&d);
	buf = malloc(n);
	check(convD2M(&d, buf, n) == n, "a Dir is not packed");
	strs = malloc(n);
	check(statcheck(buf, n) == 0 && statcheckbuf(buf, n) == n, "a good stat is refused by statcheck");
	r = convM2D(buf, n, &d2, strs);
	check(r == n && strcmp(d2.name, "name") == 0 && strcmp(d2.uid, "user") == 0 && strcmp(d2.gid, "grp") == 0 && strcmp(d2.muid, "mu") == 0, "a good stat is not unpacked (%u)", r);
	/* a NUL in each string in turn: the offsets of their first bytes */
	o = STATFIXLEN - 4*BIT16SZ;
	for(i = 0; i < 4; i++){
		int l = buf[o] | buf[o+1]<<8;
		b2 = malloc(n);
		memcpy(b2, buf, n);
		b2[o+2+l-1] = 0;
		check(statcheck(b2, n) < 0, "statcheck takes a stat whose string %d ends in a NUL", i);
		check(statcheckbuf(b2, n) < 0, "statcheckbuf takes a stat whose string %d ends in a NUL", i);
		memset(&d2, 0, sizeof d2);
		check(convM2D(b2, n, &d2, strs) == 0, "convM2D takes a stat whose string %d ends in a NUL", i);
		memcpy(b2, buf, n);
		b2[o+2] = 0;
		check(statcheck(b2, n) < 0 && convM2D(b2, n, &d2, strs) == 0, "a stat whose string %d begins with a NUL is taken", i);
		free(b2);
		o += 2 + l;
	}
	/* empty strings (a wstat that changes nothing) are a stat */
	d.name = ""; d.uid = ""; d.gid = ""; d.muid = "";
	n = sizeD2M(&d);
	check(n == STATFIXLEN && convD2M(&d, buf, n) == n && statcheck(buf, n) == 0 && convM2D(buf, n, &d2, strs) == n, "a stat of empty strings is refused");
	free(buf);
	free(strs);
}

/* a Twalk of more names than there are, an Rwalk of more qids */
static void
s2mwalk(void)
{
	Fcall *f, g;
	uchar *buf;
	uint n, i;

	buf = malloc(4096);
	f = newfcall(Twalk);
	f->nwname = 17;
	for(i = 0; i < 16; i++)
		f->wname[i] = "a";
	n = sizeS2M(f);
	check(n == 0, "a Twalk of 17 names has a size (%u)", n);
	n = convS2M(f, buf, 4096);
	check(n == 0, "a Twalk of 17 names is packed (%u)", n);
	f->nwname = 0xffff;
	n = sizeS2M(f);
	check(n == 0, "a Twalk of 65535 names has a size (%u)", n);
	check(convS2M(f, buf, 4096) == 0, "a Twalk of 65535 names is packed");
	f->nwname = 16;
	n = convS2M(f, buf, 4096);
	check(n == 17+16*3 && m2s(buf, n, &g) == n && g.nwname == 16 && strcmp(g.wname[15], "a") == 0, "a Twalk of 16 names is not packed and read back (%u)", n);
	free(f);

	f = newfcall(Rwalk);
	f->nwqid = 17;
	check(sizeS2M(f) == 0 && convS2M(f, buf, 4096) == 0, "an Rwalk of 17 qids is packed");
	f->nwqid = 0xffff;
	check(sizeS2M(f) == 0 && convS2M(f, buf, 4096) == 0, "an Rwalk of 65535 qids is packed");
	f->nwqid = 16;
	n = convS2M(f, buf, 4096);
	check(n == 9+16*13 && m2s(buf, n, &g) == n && g.nwqid == 16, "an Rwalk of 16 qids is not packed and read back (%u)", n);
	free(f);
	free(buf);
}

/* a count that wraps the size */
static void
s2mcount(void)
{
	Fcall *f, g;
	uchar *buf;
	uint n;
	static uint counts[] = { 0xfffffff8, 0xfffffff5, 0xfffffff4, 0xffffffff, 0x80000000, 65 };
	int i;

	buf = malloc(64);
	for(i = 0; i < nelem(counts); i++){
		f = newfcall(Rread);
		f->count = counts[i];
		f->data = malloc(16);
		n = sizeS2M(f);
		check(n == 0 || n > 64, "an Rread of %#x bytes has the size %u", counts[i], n);
		n = convS2M(f, buf, 64);
		check(n == 0, "an Rread of %#x bytes is packed into 64 (%u)", counts[i], n);
		free(f->data);
		free(f);
		f = newfcall(Twrite);
		f->count = counts[i];
		f->data = malloc(16);
		n = sizeS2M(f);
		check(n == 0 || n > 64, "a Twrite of %#x bytes has the size %u", counts[i], n);
		n = convS2M(f, buf, 64);
		check(n == 0, "a Twrite of %#x bytes is packed into 64 (%u)", counts[i], n);
		free(f->data);
		free(f);
	}
	f = newfcall(Rread);
	f->count = 16;
	f->data = malloc(16);
	memset(f->data, 'd', 16);
	n = convS2M(f, buf, 64);
	check(n == 11+16 && m2s(buf, n, &g) == n && g.count == 16, "an Rread of 16 bytes is not packed and read back (%u)", n);
	free(f->data);
	free(f);
	free(buf);
}

/* a string whose length is not 16 bits */
static void
s2mstring(void)
{
	Fcall *f, g;
	uchar *buf;
	char *s;
	uint n, nbuf;

	nbuf = 200000;
	buf = malloc(nbuf);
	s = fill(70000, 'e');

	f = newfcall(Rerror);
	f->ename = s;
	n = convS2M(f, buf, nbuf);
	check(n == 0 && sizeS2M(f) == 0, "an Rerror with 70000 bytes of text is packed (%u, its count %u)", n, buf[7]|buf[8]<<8);
	s[65536] = 0;
	check(convS2M(f, buf, nbuf) == 0, "an Rerror with 65536 bytes of text is packed");
	s[65535] = 0;
	n = convS2M(f, buf, nbuf);
	check(n == 9+65535 && m2s(buf, n, &g) == n && strlen(g.ename) == 65535, "an Rerror with 65535 bytes of text is not packed and read back (%u)", n);
	free(f);
	memset(s, 'e', 70000);

	f = newfcall(Tattach);
	f->uname = "u";
	f->aname = s;
	n = convS2M(f, buf, nbuf);
	check(n == 0, "a Tattach with an aname of 70000 bytes is packed (%u)", n);
	f->uname = s;
	f->aname = "a";
	check(convS2M(f, buf, nbuf) == 0, "a Tattach with a user name of 70000 bytes is packed");
	free(f);

	f = newfcall(Tauth);
	f->uname = "u";
	f->aname = s;
	check(convS2M(f, buf, nbuf) == 0, "a Tauth with an aname of 70000 bytes is packed");
	free(f);

	f = newfcall(Tversion);
	f->msize = 8192;
	f->version = s;
	check(convS2M(f, buf, nbuf) == 0, "a Tversion with a version of 70000 bytes is packed");
	f->type = Rversion;
	check(convS2M(f, buf, nbuf) == 0, "an Rversion with a version of 70000 bytes is packed");
	free(f);

	f = newfcall(Tcreate);
	f->name = s;
	check(convS2M(f, buf, nbuf) == 0, "a Tcreate with a name of 70000 bytes is packed");
	free(f);

	f = newfcall(Twalk);
	f->nwname = 2;
	f->wname[0] = "a";
	f->wname[1] = s;
	check(convS2M(f, buf, nbuf) == 0, "a Twalk with a name of 70000 bytes is packed");
	f->wname[1] = "b";
	n = convS2M(f, buf, nbuf);
	check(n == 17+3+3 && m2s(buf, n, &g) == n, "a Twalk of two names is not packed and read back (%u)", n);
	free(f);
	free(s);
	free(buf);
}

/* a Dir whose strings do not fit a stat's 16 bits */
static void
d2msize(void)
{
	Dir d, d2;
	uchar *buf;
	char *s, *strs;
	uint n, m, nbuf;
	int most;

	nbuf = 200000;
	buf = malloc(nbuf);
	memset(buf, 0, nbuf);
	strs = malloc(nbuf);
	memset(&d, 0, sizeof d);
	s = fill(70000, 'n');
	d.name = s; d.uid = "A"; d.gid = ""; d.muid = "";
	s[65540] = 0;
	n = convD2M(&d, buf, nbuf);
	m = sizeD2M(&d);
	check(n == 0 && m == 0, "a Dir with a name of 65540 bytes is packed: convD2M %u, sizeD2M %u, its size field %u, its name's count %u", n, m, buf[0]|buf[1]<<8, buf[41]|buf[42]<<8);
	/* the longest name a stat holds with the other strings empty */
	d.uid = "";
	most = 0xFFFF + BIT16SZ - STATFIXLEN;
	memset(s, 'n', 70000);
	s[most] = 0;
	n = convD2M(&d, buf, nbuf);
	check(n == STATFIXLEN+most && sizeD2M(&d) == n && (buf[0]|buf[1]<<8) == 0xFFFF && statcheck(buf, n) == 0, "a Dir with a name of %d bytes is not packed: %u", most, n);
	if(n != 0){
		m = convM2D(buf, n, &d2, strs);
		check(m == n && strlen(d2.name) == most, "the stat with a name of %d bytes is not read back (%u)", most, m);
	}
	s[most] = 'n';
	s[most+1] = 0;
	n = convD2M(&d, buf, nbuf);
	check(n == 0 && sizeD2M(&d) == 0, "a Dir with a name of %d bytes is packed (%u, its size field %u)", most+1, n, buf[0]|buf[1]<<8);
	/* a uid of 65536 bytes, alone */
	memset(s, 'n', 70000);
	s[65536] = 0;
	d.name = "";
	d.uid = s;
	check(convD2M(&d, buf, nbuf) == 0 && sizeD2M(&d) == 0, "a Dir with a uid of 65536 bytes is packed");
	/* a buffer too small still says how much is needed */
	d.name = "name"; d.uid = "u"; d.gid = "g"; d.muid = "m";
	n = convD2M(&d, buf, 10);
	check(n == BIT16SZ && (buf[0]|buf[1]<<8) == STATFIXLEN+7-BIT16SZ, "a Dir packed into 10 bytes does not say what it needs (%u, %u)", n, buf[0]|buf[1]<<8);
	free(s);
	free(buf);
	free(strs);
}

/* %F of a stat */
static uchar*
twstat(uint nstat, uint namelen, uint *np)
{
	uchar *m;
	uint n;

	n = 7+4+2+nstat;
	m = malloc(n);
	memset(m, 0, n);
	p32(m, n); m[4] = Twstat; p16(m+5, 1); p32(m+7, 1); p16(m+11, nstat);
	p16(m+13, nstat-2);
	p16(m+13+41, namelen);
	if(namelen != 0xffff)
		memset(m+13+43, 'A', namelen);
	*np = n;
	return m;
}

static void
fmtstat(void)
{
	Fcall f;
	uchar *m;
	char out[1024], *as;
	uint n, r, nstat;
	static uint sizes[] = { 49, 60, 149, 150, 151, 153, 199, 200, 201, 255, 256, 257, 300, 1000, 8000 };
	int i;

	fmtinstall('F', fcallfmt);
	for(i = 0; i < nelem(sizes); i++){
		nstat = sizes[i];
		m = twstat(nstat, nstat-STATFIXLEN, &n);
		r = convM2S(m, n, &f);
		check(r == n, "a Twstat with a stat of %u bytes is not read (%u)", nstat, r);
		if(r != n)
			continue;
		memset(out, 0, sizeof out);
		snprint(out, sizeof out, "%F", &f);
		check(strncmp(out, "Twstat tag 1 fid 1", 18) == 0, "%%F of a Twstat with a stat of %u bytes begins \"%.30s\"", nstat, out);
		if(nstat <= 256){
			as = fill(nstat-STATFIXLEN < 100 ? nstat-STATFIXLEN : 100, 'A');
			check(strstr(out, " stat '") != nil && strstr(out, as) != nil, "%%F of a stat of %u bytes does not show its name: %.60s", nstat, out);
			free(as);
		}else
			check(strstr(out, "bytes)") != nil && strstr(out, "AAAA") == nil, "%%F of a stat of %u bytes: %.60s", nstat, out);
		free(m);
	}

	/* an Rstat of four bytes, which is no stat */
	n = 7+2+4;
	m = malloc(n);
	memset(m, 0, n);
	p32(m, n); m[4] = Rstat; p16(m+5, 1); p16(m+7, 4); p16(m+9, 2);
	r = convM2S(m, n, &f);
	check(r == n, "an Rstat of four bytes is not read (%u)", r);
	memset(out, 'x', sizeof out);
	snprint(out, sizeof out, "%F", &f);
	check(strstr(out, "malformed") != nil && strchr(out, '\'') == nil, "%%F of an Rstat of four bytes: %.80s", out);
	free(m);

	/* a Twstat whose first string says it is 65535 bytes */
	m = twstat(60, 0xffff, &n);
	r = convM2S(m, n, &f);
	check(r == n, "a Twstat with a stat of 60 bytes is not read (%u)", r);
	memset(out, 'x', sizeof out);
	snprint(out, sizeof out, "%F", &f);
	check(strstr(out, "malformed") != nil && strchr(out, '\'') == nil, "%%F of a Twstat whose stat's name is cut: %.80s", out);
	free(m);

	/* a Twrite of bytes past 0x7f */
	n = 23+64;
	m = malloc(n);
	memset(m, 0, n);
	p32(m, n); m[4] = Twrite; p16(m+5, 1); p32(m+7, 1); p32(m+19, 64);
	memset(m+23, 0x80, 64); m[23+1] = 0x81; m[23+2] = 0x82; m[23+3] = 0x83;
	r = convM2S(m, n, &f);
	snprint(out, sizeof out, "%F", &f);
	check(r == n && strstr(out, "'80818283 80808080 ") != nil && strstr(out, "ffff") == nil, "%%F of a Twrite of bytes past 7f: %.80s", out);
	free(m);
}

/* random stats and messages: what is taken lies in its bytes and has no NUL */
static void
randoms(void)
{
	Fcall f;
	Dir d2;
	uchar *buf, *b;
	char *strs;
	uint nbuf, bad, ok, t, i, n, r, o, k, l;
	int hasnul, sc;

	bad = 0;
	ok = 0;
	srandom(7);
	for(t = 0; t < 300000; t++){
		nbuf = random() % 120;
		buf = malloc(nbuf ? nbuf : 1);
		for(i = 0; i < nbuf; i++)
			buf[i] = random() % 3 ? 'a' + random()%26 : random();
		if(nbuf >= 2 && (random() & 1)){
			buf[0] = nbuf-2;
			buf[1] = (nbuf-2)>>8;
		}
		hasnul = 0;
		if(nbuf >= STATFIXLEN){
			o = 41;
			for(k = 0; k < 4 && o+2 <= nbuf; k++){
				l = random() % 3 ? random() % (nbuf - o) : random() & 0xffff;
				if(k == 3 && (random() & 1))
					l = nbuf - o - 2;
				buf[o] = l;
				buf[o+1] = l >> 8;
				if(o+2+l <= nbuf && l != 0 && memchr(buf+o+2, 0, l) != nil)
					hasnul = 1;
				o += 2 + l;
			}
		}
		strs = malloc(nbuf ? nbuf : 1);	/* nbuf bytes are always enough */
		n = convM2D(buf, nbuf, &d2, strs);
		sc = statcheck(buf, nbuf);
		if(n != 0)
			ok++;
		if(sc == 0 && n != nbuf)
			bad++;		/* statcheck says good: convM2D takes all of it */
		if((sc == 0 || n != 0) && hasnul)
			bad++;
		free(strs);
		free(buf);
	}
	check(bad == 0 && ok > 1000, "300000 random stats: %u taken, %u where statcheck and convM2D disagree or a NUL was taken", ok, bad);

	bad = 0;
	ok = 0;
	srandom(1);
	for(t = 0; t < 1000000; t++){
		n = random() % 64;
		b = malloc(n ? n : 1);
		for(r = 0; r < n; r++)
			b[r] = random() % 4 ? 'a' + random()%26 : random();
		if(n >= 7){
			if(random()&1)
				p32(b, n);
			b[4] = 100 + random()%28;
			if(n >= 9 && (random()&3) == 0)
				p16(b+7, random()%n);
		}
		buf = malloc(n ? n : 1);
		memcpy(buf, b, n);
		r = convM2S(b, n, &f);
		if(r != 0 && r != n)
			bad++;
		if(r != 0){
			ok++;
			switch(f.type){
			case Twrite: case Rread:
				if((uchar*)f.data < b || (uchar*)f.data + f.count > b+n) bad++;
				break;
			case Twstat: case Rstat:
				if(f.stat < b || f.stat + f.nstat > b+n) bad++;
				break;
			case Rerror:
				/* the string C reads is as long as its count on the wire */
				if((uchar*)f.ename < b || (uchar*)f.ename + strlen(f.ename) >= b+n) bad++;
				if(strlen(f.ename) != (buf[7]|buf[8]<<8)) bad++;
				break;
			case Twalk:
				o = 17;
				for(r = 0; r < f.nwname; r++){
					if((uchar*)f.wname[r] < b || (uchar*)f.wname[r] + strlen(f.wname[r]) >= b+n) bad++;
					l = buf[o]|buf[o+1]<<8;
					if(strlen(f.wname[r]) != l) bad++;
					o += 2+l;
				}
				break;
			}
		}
		free(buf);
		free(b);
	}
	check(bad == 0 && ok > 1000, "1000000 random messages: %u taken, %u given back wrong", ok, bad);
}

int
main(int argc, char **argv)
{
	char *which;

	which = argc > 1 ? argv[1] : "";
	if(strcmp(which, "m2snul") == 0)
		m2snul();
	else if(strcmp(which, "m2dnul") == 0)
		m2dnul();
	else if(strcmp(which, "s2mwalk") == 0)
		s2mwalk();
	else if(strcmp(which, "s2mcount") == 0)
		s2mcount();
	else if(strcmp(which, "s2mstring") == 0)
		s2mstring();
	else if(strcmp(which, "d2msize") == 0)
		d2msize();
	else if(strcmp(which, "fmtstat") == 0)
		fmtstat();
	else if(strcmp(which, "random") == 0)
		randoms();
	else{
		fprintf(stderr, "usage: convtest m2snul|m2dnul|s2mwalk|s2mcount|s2mstring|d2msize|fmtstat|random\n");
		return 2;
	}
	printf("%s: %d checks, %d not so\n", which, nok+nfail, nfail);
	return nfail != 0;
}
