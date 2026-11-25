/*
 * tests/host/ns9p_stub.c -- the smallest 9P2000 server that lets the
 * boot test exercise 9vm's #~/ns relay.
 *
 * 9vm's -ns names a 9P server (tcp!host!port or unix!path) and relays the
 * guest's ns ring to it.  This stub listens on a unix socket, serves one
 * connection, and answers version, attach, walk, open and read; anything
 * else gets an Rerror.  It is not a namespace server: what is under test
 * is the relay and the guest's ns channel, not the server.
 *
 * Reads are the interesting part.  The stub collects eight Treads and
 * then answers them in REVERSE order, with the data derived from each
 * request's own offset, so a guest that assumes completions arrive in
 * submission order gets the wrong bytes and fails.  The file "data" is
 * the 'a' + offset%26 pattern; there is nothing else in the tree.
 *
 * Compiled and started by tests/host/amd64_boot_test.sh; not installed.
 */

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

enum
{
	Tversion	= 100,
	Rversion	= 101,
	Tattach		= 104,
	Rattach		= 105,
	Rerror		= 107,
	Twalk		= 110,
	Rwalk		= 111,
	Topen		= 112,
	Ropen		= 113,
	Tread		= 116,
	Rread		= 117,
	Qtdir		= 0x80,
	Maxmsg		= 8192,
	Nread		= 8,		/* Treads collected before answering */
	Iounit		= 100,		/* the read size the guest will use */
	Maxread		= 4096,
};

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

static int
readn(int fd, void *buf, size_t n)
{
	uint8_t *p = buf;
	ssize_t r;

	while(n > 0){
		r = read(fd, p, n);
		if(r <= 0)
			return -1;
		p += r;
		n -= r;
	}
	return 0;
}

static int
writen(int fd, const void *buf, size_t n)
{
	const uint8_t *p = buf;
	ssize_t r;

	while(n > 0){
		r = write(fd, p, n);
		if(r <= 0)
			return -1;
		p += r;
		n -= r;
	}
	return 0;
}

static int
rversion(int fd, uint16_t tag, uint32_t msize)
{
	static const char ver[] = "9P2000";
	uint8_t m[13 + sizeof(ver) - 1];
	uint32_t n;

	n = sizeof(m);
	p32(m, n);
	m[4] = Rversion;
	p16(m+5, tag);
	p32(m+7, msize);
	p16(m+11, sizeof(ver) - 1);
	memcpy(m+13, ver, sizeof(ver) - 1);
	return writen(fd, m, n);
}

static int
rattach(int fd, uint16_t tag)
{
	uint8_t m[20];

	p32(m, sizeof(m));
	m[4] = Rattach;
	p16(m+5, tag);
	m[7] = Qtdir;
	p32(m+8, 0);
	p32(m+12, 1);
	p32(m+16, 0);
	return writen(fd, m, sizeof(m));
}

static int	rerror(int, uint16_t, const char*);

static int
ropen(int fd, uint16_t tag)
{
	uint8_t m[24];

	p32(m, sizeof(m));
	m[4] = Ropen;
	p16(m+5, tag);
	m[7] = 0;			/* QTFILE */
	p32(m+8, 0);
	p32(m+12, 2);
	p32(m+16, 0);
	p32(m+20, Iounit);
	return writen(fd, m, sizeof(m));
}

static int
rread(int fd, uint16_t tag, uint64_t off, uint32_t count)
{
	uint8_t m[11 + Maxread];
	uint32_t i;

	if(count > Maxread)
		count = Maxread;
	p32(m, 11 + count);
	m[4] = Rread;
	p16(m+5, tag);
	p32(m+7, count);
	for(i = 0; i < count; i++)
		m[11 + i] = 'a' + (off + i) % 26;
	return writen(fd, m, 11 + count);
}

static int
rwalk(int fd, uint16_t tag, const uint8_t *req, uint32_t len)
{
	uint8_t m[9 + 16*13];
	uint16_t nwname;
	uint32_t n;
	int i;

	if(len < 17)
		return rerror(fd, tag, "short Twalk");
	nwname = g16(req+15);
	if(nwname > 16)
		return rerror(fd, tag, "too many walk elements");
	n = 9 + 13*nwname;
	p32(m, n);
	m[4] = Rwalk;
	p16(m+5, tag);
	p16(m+7, nwname);
	for(i = 0; i < nwname; i++){
		m[9 + 13*i] = Qtdir;
		p32(m+10 + 13*i, 0);
		p32(m+14 + 13*i, 1);
		p32(m+18 + 13*i, 0);
	}
	return writen(fd, m, n);
}

static int
rerror(int fd, uint16_t tag, const char *why)
{
	uint8_t m[9 + 64];
	uint32_t n;

	n = strlen(why);
	if(n > 64)
		n = 64;
	p32(m, 9 + n);
	m[4] = Rerror;
	p16(m+5, tag);
	p16(m+7, n);
	memcpy(m+9, why, n);
	return writen(fd, m, 9 + n);
}

struct pending
{
	uint16_t	tag;
	uint64_t	off;
	uint32_t	count;
};

static struct pending reads[Nread];
static int nreads;

int
main(int argc, char **argv)
{
	struct sockaddr_un sa;
	uint8_t m[Maxmsg];
	uint32_t len;
	uint16_t tag;
	int l, c, i;

	if(argc != 2){
		fprintf(stderr, "usage: ns9p_stub /path/to/socket\n");
		return 2;
	}
	l = socket(AF_UNIX, SOCK_STREAM, 0);
	if(l < 0){
		perror("socket");
		return 1;
	}
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	strncpy(sa.sun_path, argv[1], sizeof(sa.sun_path) - 1);
	unlink(argv[1]);
	if(bind(l, (struct sockaddr*)&sa, sizeof(sa)) < 0){
		perror("bind");
		return 1;
	}
	if(listen(l, 1) < 0){
		perror("listen");
		return 1;
	}
	c = accept(l, NULL, NULL);
	if(c < 0){
		perror("accept");
		return 1;
	}
	for(;;){
		if(readn(c, m, 4) < 0)
			break;
		len = g32(m);
		if(len < 7 || len > sizeof(m))
			break;
		if(readn(c, m+4, len-4) < 0)
			break;
		tag = g16(m+5);
		switch(m[4]){
		case Tversion:
			if(rversion(c, tag, g32(m+7)) < 0)
				return 0;
			break;
		case Tattach:
			if(rattach(c, tag) < 0)
				return 0;
			break;
		case Twalk:
			if(rwalk(c, tag, m, len) < 0)
				return 0;
			break;
		case Topen:
			if(ropen(c, tag) < 0)
				return 0;
			break;
		case Tread:
			if(len < 23)
				return 0;
			if(nreads < Nread){
				reads[nreads].tag = tag;
				reads[nreads].off = g64(m+11);
				reads[nreads].count = g32(m+19);
				nreads++;
			}
			if(nreads == Nread){
				/* reverse order: the last request answers first */
				for(i = nreads - 1; i >= 0; i--)
					if(rread(c, reads[i].tag, reads[i].off,
						 reads[i].count) < 0)
						return 0;
				nreads = 0;
			}
			break;
		default:
			if(rerror(c, tag, "ns9p_stub: not supported") < 0)
				return 0;
			break;
		}
	}
	close(c);
	close(l);
	return 0;
}
