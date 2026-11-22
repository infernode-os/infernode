#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"kernel.h"

typedef struct DS DS;

static int	call(char*, char*, DS*);
static int	csdial(DS*);
static void	_dial_string_parse(char*, DS*);
static int	nettrans(char*, char*, int na, char*, int);

enum
{
	Maxstring=	128,
	Maxpath=	100,
	Maxrecipes=	64	/* translations of one address tried */
};

struct DS
{
	char	buf[Maxstring];			/* dist string */
	char	*netdir;
	char	*proto;
	char	*rem;
	char	*local;				/* other args */
	char	*dir;
	int	*cfdp;
};

/*
 *  the dialstring is of the form '[/net/]proto!dest'
 */
int
kdial(char *dest, char *local, char *dir, int *cfdp)
{
	DS ds;
	int rv;
	char err[ERRMAX], alterr[ERRMAX];

	ds.local = local;
	ds.dir = dir;
	ds.cfdp = cfdp;

	_dial_string_parse(dest, &ds);
	if(ds.netdir)
		return csdial(&ds);

	ds.netdir = "/net";
	rv = csdial(&ds);
	if(rv >= 0)
		return rv;

	err[0] = 0;
	kerrstr(err, sizeof err);
	if(strstr(err, "refused") != 0){
		kerrstr(err, sizeof err);
		return rv;
	}

	ds.netdir = "/net.alt";
	rv = csdial(&ds);
	if(rv >= 0)
		return rv;

	alterr[0] = 0;
	kerrstr(alterr, sizeof err);

	if(strstr(alterr, "translate") || strstr(alterr, "does not exist"))
		kerrstr(err, sizeof err);
	else
		kerrstr(alterr, sizeof alterr);
	return rv;
}

/*
 * A connection server's answer is a translation, "clonefile address",
 * and is held to one: the clone file of a protocol in the network
 * directory that was asked, netdir/proto/clone, and an address of one
 * word.  The connection server is whatever file is at netdir/cs, which
 * can be the caller's own (a name space is the caller's to build), and
 * what it said was done as it stood: a clone file anywhere
 * (x/../../t/clone) was opened and "connect" written to it, and an
 * address of two words put a local address, or with a new line another
 * request, into what was written to the protocol.  As dial(2)'s Limbo
 * dial (appl/lib/dial.b).  ans is cut where its fields end; -1 if it
 * is no translation.
 */
static int
cstrans(char *netdir, char *ans, char *clone, int nclone, char **addrp)
{
	char *p, *f, *q, *e;
	int n;

	p = strchr(ans, ' ');
	if(p == nil)
		return -1;
	*p++ = 0;
	e = p + strlen(p);
	if(e > p && e[-1] == '\n')
		*--e = 0;
	for(q = p; *q != 0; q++)
		if((uchar)*q <= ' ')
			return -1;

	/* /net/proto/clone, whatever the first element: the directory is the one asked */
	f = ans;
	if(f[0] == '/' && f[1] != 0){
		q = strchr(f+1, '/');
		if(q != nil)
			f = q+1;
	}
	q = strchr(f, '/');
	if(q == nil || q == f || strcmp(q+1, "clone") != 0)
		return -1;
	n = q - f;
	if((n == 1 && f[0] == '.') || (n == 2 && f[0] == '.' && f[1] == '.'))
		return -1;
	if(strlen(netdir) + 1 + strlen(f) >= nclone)
		return -1;
	snprint(clone, nclone, "%s/%s", netdir, f);
	*addrp = p;
	return 0;
}

static int
csdial(DS *ds)
{
	int n, fd, rv, i;
	char *p, buf[Maxstring], clone[Maxpath], err[ERRMAX], besterr[ERRMAX];

	/*
	 *  open connection server
	 */
	snprint(buf, sizeof(buf), "%s/cs", ds->netdir);
	fd = kopen(buf, ORDWR);
	if(fd < 0){
		/* no connection server, don't translate */
		snprint(clone, sizeof(clone), "%s/%s/clone", ds->netdir, ds->proto);
		return call(clone, ds->rem, ds);
	}

	/*
	 *  ask connection server to translate
	 */
	snprint(buf, sizeof(buf), "%s!%s", ds->proto, ds->rem);
	if(kwrite(fd, buf, strlen(buf)) < 0){
		kerrstr(err, sizeof err);
		kclose(fd);
		kwerrstr("%s (%s)", err, buf);
		return -1;
	}

	/*
	 *  loop through each address from the connection server till
	 *  we get one that works.
	 */
	*besterr = 0;
	kstrcpy(err, Egreg, sizeof err);
	rv = -1;
	kseek(fd, 0, 0);
	/* (so many and no more: a connection server could go on answering for ever) */
	for(i = 0; i < Maxrecipes && (n = kread(fd, buf, sizeof(buf) - 1)) > 0; i++){
		buf[n] = 0;
		if(cstrans(ds->netdir, buf, clone, sizeof(clone), &p) < 0){
			kstrcpy(err, "cs: bad translation", sizeof err);
			continue;
		}
		rv = call(clone, p, ds);
		if(rv >= 0)
			break;
		err[0] = 0;
		kerrstr(err, sizeof err);
		if(strstr(err, "does not exist") == 0)
			memmove(besterr, err, sizeof besterr);
	}
	kclose(fd);

	if(rv < 0 && *besterr)
		kerrstr(besterr, sizeof besterr);
	else
		kerrstr(err, sizeof err);
	return rv;
}

static int
call(char *clone, char *dest, DS *ds)
{
	int fd, cfd, n;
	char name[Maxpath], data[Maxpath], err[ERRMAX], *p, *e, *q;

	cfd = kopen(clone, ORDWR);
	if(cfd < 0){
		kerrstr(err, sizeof err);
		kwerrstr("%s (%s)", err, clone);
		return -1;
	}

	/* get directory name */
	n = kread(cfd, name, sizeof(name)-1);
	if(n < 0){
		kerrstr(err, sizeof err);
		kclose(cfd);
		kwerrstr("read %s: %s", clone, err);
		return -1;
	}
	name[n] = 0;
	/*
	 * the conversation's number, and nothing else: whatever else a
	 * clone file said was conversation 0
	 */
	for(p = name; *p == ' ' || *p == '\t'; p++)
		;
	for(e = p; *e >= '0' && *e <= '9'; e++)
		;
	for(q = e; *q == ' ' || *q == '\t' || *q == '\n'; q++)
		;
	if(e == p || e - p > 9 || *q != 0){
		kclose(cfd);
		kwerrstr("clone file's reply is not a number (%s)", clone);
		return -1;
	}
	snprint(name, sizeof(name), "%ld", strtoul(p, 0, 10));
	/*
	 * The clone file is what the connection server said, and the
	 * connection server is whatever is at netdir/cs: a file of the
	 * caller's own will do. With no slash in it there was nothing
	 * to cut, and the nil was written through.
	 */
	p = strrchr(clone, '/');
	if(p == nil){
		kclose(cfd);
		kwerrstr("bad clone file name: %s", clone);
		return -1;
	}
	*p = 0;
	if(ds->dir)
		snprint(ds->dir, NETPATHLEN, "%s/%s", clone, name);
	snprint(data, sizeof(data), "%s/%s/data", clone, name);

	/* connect */
	if(ds->local && ds->local[0] != 0)	/* (an empty one left a blank after the address) */
		snprint(name, sizeof(name), "connect %s %s", dest, ds->local);
	else
		snprint(name, sizeof(name), "connect %s", dest);
	if(kwrite(cfd, name, strlen(name)) < 0){
		err[0] = 0;
		kerrstr(err, sizeof err);
		kclose(cfd);
		kwerrstr("%s (%s)", err, name);
		return -1;
	}

	/* open data connection */
	fd = kopen(data, ORDWR);
	if(fd < 0){
		err[0] = 0;
		kerrstr(err, sizeof err);
		kwerrstr("%s (%s)", err, data);
		kclose(cfd);
		return -1;
	}
	if(ds->cfdp)
		*ds->cfdp = cfd;
	else
		kclose(cfd);

	return fd;
}

/*
 *  parse a dial string
 */
static void
_dial_string_parse(char *str, DS *ds)
{
	char *p, *p2;

	strncpy(ds->buf, str, Maxstring);
	ds->buf[Maxstring-1] = 0;

	p = strchr(ds->buf, '!');
	if(p == 0) {
		ds->netdir = 0;
		ds->proto = "net";
		ds->rem = ds->buf;
	} else {
		if(*ds->buf != '/' && *ds->buf != '#'){
			ds->netdir = 0;
			ds->proto = ds->buf;
		} else {
			/*
			 * back to the slash before the protocol. A string
			 * that begins with # need have none ("#!x"): the
			 * search went on below the buffer, down the stack,
			 * and wrote a zero where it found one.
			 */
			for(p2 = p; p2 > ds->buf && *p2 != '/'; p2--)
				;
			if(*p2 != '/'){
				ds->netdir = 0;
				ds->proto = ds->buf;
			}else{
				*p2++ = 0;
				ds->netdir = ds->buf;
				ds->proto = p2;
			}
		}
		*p = 0;
		ds->rem = p + 1;
	}
}

/*
 *  announce a network service.
 */
int
kannounce(char *addr, char *dir)
{
	int ctl, n, m;
	char buf[NETPATHLEN];
	char buf2[Maxpath];
	char netdir[NETPATHLEN];
	char naddr[Maxpath];
	char *cp;

	/*
	 *  translate the address
	 */
	if(nettrans(addr, naddr, sizeof(naddr), netdir, sizeof(netdir)) < 0)
		return -1;

	/*
	 * get a control channel
	 */
	ctl = kopen(netdir, ORDWR);
	if(ctl<0)
		return -1;
	cp = strrchr(netdir, '/');
	if(cp == nil){
		/* a connection server's answer with no slash in it */
		kclose(ctl);
		kwerrstr("bad clone file name: %s", netdir);
		return -1;
	}
	*cp = 0;

	/*
	 *  find out which line we have
	 */
	n = snprint(buf, sizeof(buf), "%.*s/", (int)sizeof(buf)-1, netdir);
	m = kread(ctl, &buf[n], sizeof(buf)-n-1);
	if(m <= 0){
		kclose(ctl);
		return -1;
	}
	buf[n+m] = 0;

	/*
	 *  make the call
	 */
	n = snprint(buf2, sizeof buf2, "announce %s", naddr);
	if(kwrite(ctl, buf2, n)!=n){
		kclose(ctl);
		return -1;
	}

	/*
	 *  return directory etc.
	 */
	if(dir)
		kstrcpy(dir, buf, NETPATHLEN);	/* the caller's is NETPATHLEN, as buf is */
	return ctl;
}

/*
 *  listen for an incoming call
 */
int
klisten(char *dir, char *newdir)
{
	int ctl, n, m;
	char buf[NETPATHLEN];
	char lbuf[NETPATHLEN+8];	/* Flawfinder: ignore — written only by snprint(lbuf, sizeof lbuf) below */
	char *cp;

	/*
	 * The directory is the caller's: a program's string, of any
	 * length. It was copied into 40 bytes with strcpy, over the
	 * rest of the stack, once a name made of its first 39 bytes
	 * had opened (the name was cut to fit; "/dev////...//null"
	 * opens). It is a conversation's directory and is no longer
	 * than one, and has a slash in it.
	 */
	if(strlen(dir) >= sizeof(buf) || strrchr(dir, '/') == nil){	/* Flawfinder: ignore — dir is a C string made by the caller (string2c) */
		kwerrstr("bad network directory: %.60s", dir);
		return -1;
	}

	/*
	 *  open listen, wait for a call
	 */
	snprint(lbuf, sizeof lbuf, "%s/listen", dir);
	ctl = kopen(lbuf, ORDWR);
	if(ctl < 0)
		return -1;

	/*
	 *  find out which line we have
	 */
	kstrcpy(buf, dir, sizeof buf);
	cp = strrchr(buf, '/');
	*++cp = 0;
	n = cp-buf;
	m = kread(ctl, cp, sizeof(buf) - n - 1);
	if(m <= 0){
		kclose(ctl);
		return -1;
	}
	buf[n+m] = 0;

	/*
	 *  return directory etc.
	 */
	if(newdir)
		kstrcpy(newdir, buf, NETPATHLEN);	/* the caller's is NETPATHLEN, as buf is */
	return ctl;

}

/*
 *  perform the identity translation (in case we can't reach cs)
 */
static int
identtrans(char *netdir, char *addr, char *naddr, int na, char *file, int nf)
{
	char proto[Maxpath];
	char *p;

	USED(nf);

	/* parse the protocol */
	snprint(proto, sizeof(proto), "%s", addr);
	p = strchr(proto, '!');
	if(p)
		*p++ = 0;

	snprint(file, nf, "%s/%s/clone", netdir, proto);
	if(p != nil)
		snprint(naddr, na, "%s", p);
	else
		naddr[0] = '\0';

	return 1;
}

/*
 *  call up the connection server and get a translation
 */
static int
nettrans(char *addr, char *naddr, int na, char *file, int nf)
{
	int i, fd;
	char buf[Maxpath];
	char netdir[NETPATHLEN];
	char *p, *p2;
	long n;

	/*
	 *  parse, get network directory
	 */
	p = strchr(addr, '!');
	if(p == 0){
		kwerrstr("bad dial string: %s", addr);
		return -1;
	}
	if(*addr != '/'){
		strcpy(netdir, "/net");
	} else {
		for(p2 = p; *p2 != '/'; p2--)
			;
		i = p2 - addr;
		if(i == 0 || i >= sizeof(netdir)){
			kwerrstr("bad dial string: %s", addr);
			return -1;
		}
		strncpy(netdir, addr, i);
		netdir[i] = 0;
		addr = p2 + 1;
	}

	/*
	 *  ask the connection server
	 */
	snprint(buf, sizeof(buf), "%s/cs", netdir);
	fd = kopen(buf, ORDWR);
	if(fd < 0)
		return identtrans(netdir, addr, naddr, na, file, nf);
	if(kwrite(fd, addr, strlen(addr)) < 0){
		kclose(fd);
		return -1;
	}
	kseek(fd, 0, 0);
	n = kread(fd, buf, sizeof(buf)-1);
	kclose(fd);
	if(n <= 0)
		return -1;
	buf[n] = 0;

	/*
	 *  parse the reply: a translation, or nothing (see cstrans)
	 */
	if(cstrans(netdir, buf, file, nf, &p) < 0){
		kwerrstr("cs: bad translation");
		return -1;
	}
	strncpy(naddr, p, na);
	naddr[na-1] = 0;
	return 0;
}
