#ifdef sun
#define	uint uxuint
#define	ulong uxulong
#define	ushort uxushort
#endif
#include <sys/types.h>
#include	<sys/time.h>
#include	<sys/socket.h>
#include	<net/if.h>
#ifndef IOS_ARM64
#include	<net/if_arp.h>	/* not shipped in the iOS SDK; only used under #ifdef SIOCGARP (undefined on iOS), so arpadd() falls back to "arp not implemented" */
#endif
#include	<netinet/in.h>
#include	<netinet/tcp.h>
#include	<arpa/inet.h>
#include	<netdb.h>
#include	<sys/ioctl.h>
#include	<errno.h>
#undef ulong
#undef ushort
#undef uint

#include        "dat.h"
#include        "fns.h"
#include        "ip.h"
#include        "error.h"

/*
 * Some kernels are built without IPv6 (CONFIG_IPV6=n), and some containers /
 * CI sandboxes disable it entirely; on those, socket(AF_INET6, ...) fails with
 * EAFNOSUPPORT and this device — which is otherwise dual-stack via v4-mapped
 * addresses — would have no working transport at all (no 9P/Styx, no mounts,
 * no node-to-node auth).  Detect that once and transparently fall back to a
 * classic AF_INET socket, translating the v4-mapped plan9 addresses to/from
 * sockaddr_in.  On a normal IPv6-capable host noipv6 stays 0 and every path
 * below is byte-for-byte the original AF_INET6 code.
 */
static int noipv6 = 0;

/*
 * Build a host sockaddr from a 16-byte plan9 IP address (v6 form, possibly
 * v4-mapped) plus a host-order port.  Returns the sockaddr length.  When
 * running IPv4-only, a genuine (non-mapped, non-unspecified) IPv6 address
 * cannot be represented and raises an error.
 */
static int
sockaddrfromip(struct sockaddr_storage *sa, uchar *ip, ushort port)
{
	struct sockaddr_in *sin;
	struct sockaddr_in6 *sin6;

	memset(sa, 0, sizeof(*sa));
	if(noipv6){
		sin = (struct sockaddr_in*)sa;
		sin->sin_family = AF_INET;
		hnputs((uchar*)&sin->sin_port, port);
		if(isv4(ip))
			memmove(&sin->sin_addr, ip+IPv4off, IPv4addrlen);
		else if(ipcmp(ip, v6Unspecified) == 0)
			sin->sin_addr.s_addr = INADDR_ANY;
		else
			error("IPv6 address on an IPv4-only host");
		return sizeof(*sin);
	}
	sin6 = (struct sockaddr_in6*)sa;
	sin6->sin6_family = AF_INET6;
	hnputs((uchar*)&sin6->sin6_port, port);
	memmove(&sin6->sin6_addr, ip, IPaddrlen);
	return sizeof(*sin6);
}

/*
 * Inverse of sockaddrfromip: decode a host sockaddr (either family) into a
 * 16-byte plan9 IP address (v4-mapped for AF_INET) and a host-order port.
 */
static void
ipfromsockaddr(struct sockaddr_storage *sa, uchar *ip, ushort *port)
{
	struct sockaddr_in *sin;
	struct sockaddr_in6 *sin6;

	switch(sa->ss_family){
	case AF_INET:
		sin = (struct sockaddr_in*)sa;
		v4tov6(ip, (uchar*)&sin->sin_addr);
		*port = nhgets((uchar*)&sin->sin_port);
		break;
	case AF_INET6:
		sin6 = (struct sockaddr_in6*)sa;
		memmove(ip, &sin6->sin6_addr, IPaddrlen);
		*port = nhgets((uchar*)&sin6->sin6_port);
		break;
	default:
		error("unexpected socket address family");
	}
}

int
so_socket(int type)
{
	int fd, one;
	int v6only;

	switch(type) {
	default:
		error("bad protocol type");
	case S_TCP:
		type = SOCK_STREAM;
		break;
	case S_UDP:
		type = SOCK_DGRAM;
		break;
	}

	fd = -1;
	if(!noipv6){
		fd = socket(AF_INET6, type, 0);
		if(fd < 0 && (errno == EAFNOSUPPORT || errno == EPROTONOSUPPORT))
			noipv6 = 1;	/* IPv4-only for the rest of this process */
	}
	if(fd < 0 && noipv6)
		fd = socket(AF_INET, type, 0);
	if(fd < 0)
		oserror();

	if(!noipv6){
		/* OpenBSD has v6only fixed to 1, so the following will fail */
		v6only = 0;
		if(setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (void*)&v6only, sizeof v6only) < 0)
			oserror();
	}

	if(type == SOCK_DGRAM){
		one = 1;
		setsockopt(fd, SOL_SOCKET, SO_BROADCAST, (char*)&one, sizeof(one));
	}else{
		one = 1;
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (char*)&one, sizeof(one));
	}
	return fd;
}

int
so_send(int sock, void *va, int len, void *hdr, int hdrlen)
{
	int r;
	struct sockaddr_storage sa;
	struct sockaddr_in6 *sin6;
	char *h = hdr;

	osenter();
	if(hdr == 0)
		r = write(sock, va, len);
	else if(noipv6){
		/* IPv4-only host: decode the header into a v4-mapped addr+port,
		 * then let sockaddrfromip() emit a sockaddr_in. */
		uchar rip[IPaddrlen];
		ushort rport;
		int sl;

		memset(rip, 0, sizeof(rip));
		switch(hdrlen){
		case OUdphdrlenv4:
			v4tov6(rip, (uchar*)h);
			rport = nhgets((uchar*)h+2*IPv4addrlen);
			break;
		case OUdphdrlen:
			memmove(rip, h, IPaddrlen);
			rport = nhgets((uchar*)h+2*IPaddrlen);
			break;
		default:
			memmove(rip, h, IPaddrlen);
			rport = nhgets((uchar*)h+3*IPaddrlen);
			break;
		}
		sl = sockaddrfromip(&sa, rip, rport);
		r = sendto(sock, va, len, 0, (struct sockaddr*)&sa, sl);
	}
	else {
		memset(&sa, 0, sizeof(sa));
		sin6 = (struct sockaddr_in6*)&sa;
		sin6->sin6_family = AF_INET6;
		switch(hdrlen){
		case OUdphdrlenv4:
			v4tov6((uchar*)&sin6->sin6_addr, h);
			memmove(&sin6->sin6_port, h+8, 2);
			break;
		case OUdphdrlen:
			memmove((uchar*)&sin6->sin6_addr, h, IPaddrlen);
			memmove(&sin6->sin6_port, h+2*IPaddrlen, 2);	/* rport */
			break;
		default:
			memmove((uchar*)&sin6->sin6_addr, h, IPaddrlen);
			memmove(&sin6->sin6_port, h+3*IPaddrlen, 2);
			break;
		}
		r = sendto(sock, va, len, 0, (struct sockaddr*)sin6, sizeof(*sin6));
	}
	osleave();
	return r;
}

int
so_recv(int sock, void *va, int len, void *hdr, int hdrlen)
{
	int r, l;
	struct sockaddr_storage sa;
	struct sockaddr_in6 *sin6;
	char h[Udphdrlen];

	osenter();
	if(hdr == 0)
		r = read(sock, va, len);
	else if(noipv6){
		/* IPv4-only host: recvfrom into a sockaddr_storage (never hand the
		 * kernel a smaller address buffer), then rebuild the header in the
		 * same v4-mapped layout the AF_INET6 path produces. */
		struct sockaddr_storage lsa;
		uchar rip[IPaddrlen], lip[IPaddrlen];
		ushort rport, lport;

		l = sizeof(sa);
		r = recvfrom(sock, va, len, 0, (struct sockaddr*)&sa, &l);
		if(r >= 0){
			memset(h, 0, sizeof(h));
			ipfromsockaddr(&sa, rip, &rport);
			memset(&lsa, 0, sizeof(lsa));
			l = sizeof(lsa);
			if(getsockname(sock, (struct sockaddr*)&lsa, &l) < 0){
				memset(lip, 0, sizeof(lip));
				lport = 0;
			} else
				ipfromsockaddr(&lsa, lip, &lport);
			switch(hdrlen){
			case OUdphdrlenv4:
				memmove(h, rip+IPv4off, IPv4addrlen);
				hnputs((uchar*)h+2*IPv4addrlen, rport);
				memmove(h+IPv4addrlen, lip+IPv4off, IPv4addrlen);
				hnputs((uchar*)h+2*IPv4addrlen+2, lport);
				break;
			case OUdphdrlen:
				memmove(h, rip, IPaddrlen);
				hnputs((uchar*)h+2*IPaddrlen, rport);
				memmove(h+IPaddrlen, lip, IPaddrlen);
				hnputs((uchar*)h+2*IPaddrlen+2, lport);
				break;
			default:
				memmove(h, rip, IPaddrlen);
				hnputs((uchar*)h+3*IPaddrlen, rport);
				memmove(h+IPaddrlen, lip, IPaddrlen);
				memmove(h+2*IPaddrlen, lip, IPaddrlen);	/* ifcaddr */
				hnputs((uchar*)h+3*IPaddrlen+2, lport);
				break;
			}
			memmove(hdr, h, hdrlen);
		}
	}
	else {
		sin6 = (struct sockaddr_in6*)&sa;
		l = sizeof(sa);
		r = recvfrom(sock, va, len, 0, (struct sockaddr*)&sa, &l);
		if(r >= 0) {
			memset(h, 0, sizeof(h));
			switch(hdrlen){
			case OUdphdrlenv4:
				if(v6tov4(h, (uchar*)&sin6->sin6_addr) < 0) {
					osleave();
					error("OUdphdrlenv4 with IPv6 address");
				}
				memmove(h+2*IPv4addrlen, &sin6->sin6_port, 2);
				break;
			case OUdphdrlen:
				memmove(h, (uchar*)&sin6->sin6_addr, IPaddrlen);
				memmove(h+2*IPaddrlen, &sin6->sin6_port, 2);
				break;
			default:
				memmove(h, (uchar*)&sin6->sin6_addr, IPaddrlen);
				memmove(h+3*IPaddrlen, &sin6->sin6_port, 2);
				break;
			}

			/* alas there's no way to get the local addr/port correctly.  Pretend. */
			memset(&sa, 0, sizeof(sa));
			l = sizeof(sa);
			getsockname(sock, (struct sockaddr*)&sa, &l);
			switch(hdrlen){
			case OUdphdrlenv4:
				/*
				 * we get v6Unspecified/noaddr if local address cannot be determined.
				 * that's reasonable for ipv4 too.
				 */
				if(ipcmp(v6Unspecified, (uchar*)&sin6->sin6_addr) != 0
				&& v6tov4(h+IPv4addrlen, (uchar*)&sin6->sin6_addr) < 0) {
					osleave();
					error("OUdphdrlenv4 with IPv6 address");
				}
				memmove(h+2*IPv4addrlen+2, &sin6->sin6_port, 2);
				break;
			case OUdphdrlen:
				memmove(h+IPaddrlen, (uchar*)&sin6->sin6_addr, IPaddrlen);
				memmove(h+2*IPaddrlen+2, &sin6->sin6_port, 2);
				break;
			default:
				memmove(h+IPaddrlen, (uchar*)&sin6->sin6_addr, IPaddrlen);
				memmove(h+2*IPaddrlen, (uchar*)&sin6->sin6_addr, IPaddrlen);	/* ifcaddr */
				memmove(h+3*IPaddrlen+2, &sin6->sin6_port, 2);
				break;
			}
			memmove(hdr, h, hdrlen);
		}
	}
	osleave();
	return r;
}

void
so_close(int sock)
{
	close(sock);
}

void
so_connect(int fd, uchar *raddr, ushort rport)
{
	int r, len;
	struct sockaddr_storage sa;

	len = sockaddrfromip(&sa, raddr, rport);

	osenter();
	r = connect(fd, (struct sockaddr*)&sa, len);
	osleave();
	if(r < 0)
		oserror();
}

void
so_getsockname(int fd, uchar *laddr, ushort *lport)
{
	int len;
	struct sockaddr_storage sa;

	len = sizeof(sa);
	if(getsockname(fd, (struct sockaddr*)&sa, &len) < 0)
		oserror();

	ipfromsockaddr(&sa, laddr, lport);
}

void
so_listen(int fd)
{
	int r;

	osenter();
	r = listen(fd, 256);
	osleave();
	if(r < 0)
		oserror();
}

int
so_accept(int fd, uchar *raddr, ushort *rport)
{
	int nfd, len;
	struct sockaddr_storage sa;

	len = sizeof(sa);
	osenter();
	do {
		nfd = accept(fd, (struct sockaddr*)&sa, &len);
	} while(nfd < 0 && errno == EINTR);
	osleave();
	if(nfd < 0)
		oserror();

	ipfromsockaddr(&sa, raddr, rport);
	return nfd;
}

void
so_bind(int fd, int su, uchar *addr, ushort port)
{
	int i, one, len;
	struct sockaddr_storage sa;

	one = 1;
	if(setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (char*)&one, sizeof(one)) < 0) {
		oserrstr(up->genbuf, sizeof(up->genbuf));
		print("setsockopt: %s", up->genbuf);
	}

	if(su) {
		for(i = 600; i < 1024; i++) {
			len = sockaddrfromip(&sa, addr, i);
			if(bind(fd, (struct sockaddr*)&sa, len) >= 0)
				return;
		}
		oserror();
	}

	len = sockaddrfromip(&sa, addr, port);
	if(bind(fd, (struct sockaddr*)&sa, len) < 0)
		oserror();
}

static int
resolve(char *name, char **hostv, int n, int isnumeric)
{
	int i;
	struct addrinfo *res0, *r;
	char buf[5*8];
	uchar addr[IPaddrlen];
	struct addrinfo hints;

	memset(&hints, 0, sizeof hints);
	hints.ai_flags = isnumeric? AI_NUMERICHOST: 0;
	hints.ai_family = PF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	if(getaddrinfo(name, nil, &hints, &res0) < 0)
		return 0;
	i = 0;
	for(r = res0; r != nil && i < n; r = r->ai_next) {
		if(r->ai_family == AF_INET)
			v4tov6(addr, (uchar*)&((struct sockaddr_in*)r->ai_addr)->sin_addr);
		else if(r->ai_family == AF_INET6)
			memmove(addr, &((struct sockaddr_in6*)r->ai_addr)->sin6_addr, IPaddrlen);
		else
			continue;

		snprint(buf, sizeof buf, "%I", addr);
		hostv[i++] = strdup(buf);
	}

	freeaddrinfo(res0);
	return i;
}

int
so_gethostbyname(char *host, char **hostv, int n)
{
	return resolve(host, hostv, n, 0);
}

int
so_gethostbyaddr(char *addr, char **hostv, int n)
{
	return resolve(addr, hostv, n, 1);
}

int
so_getservbyname(char *service, char *net, char *port)
{
	ushort p;
	struct servent *s;

	s = getservbyname(service, net);
	if(s == 0)
		return -1;
	p = s->s_port;
	sprint(port, "%d", nhgets(&p));	
	return 0;
}

int
so_hangup(int fd, int nolinger)
{
	int r;
	static struct linger l = {1, 0};

	osenter();
	if(nolinger)
		setsockopt(fd, SOL_SOCKET, SO_LINGER, (char*)&l, sizeof(l));
	r = shutdown(fd, 2);
	if(r >= 0)
		r = close(fd);
	osleave();
	return r;
}

void
arpadd(char *ipaddr, char *eaddr, int n)
{
#ifdef SIOCGARP
	struct arpreq a;
	struct sockaddr_in pa;
	int s;
	uchar addr[IPaddrlen];

	s = socket(AF_INET, SOCK_DGRAM, 0);
	memset(&a, 0, sizeof(a));
	memset(&pa, 0, sizeof(pa));
	pa.sin_family = AF_INET;
	pa.sin_port = 0;
	parseip(addr, ipaddr);
	if(!isv4(addr)){
		close(s);
		error(Ebadarg);
	}
	memmove(&pa.sin_addr, ipaddr+IPv4off, IPv4addrlen);
	memmove(&a.arp_pa, &pa, sizeof(pa));
	while(ioctl(s, SIOCGARP, &a) != -1) {
		ioctl(s, SIOCDARP, &a);
		memset(&a.arp_ha, 0, sizeof(a.arp_ha));
	}
	a.arp_ha.sa_family = AF_UNSPEC;
	parsemac((uchar*)a.arp_ha.sa_data, eaddr, 6);
	a.arp_flags = ATF_PERM;
	if(ioctl(s, SIOCSARP, &a) == -1) {
		oserrstr(up->env->errstr, ERRMAX);
		close(s);
		error(up->env->errstr);
	}
	close(s);
#else
	error("arp not implemented");
#endif
}

int
so_mustbind(int restricted, int port)
{
	return restricted || port != 0;
}

void
so_keepalive(int fd, int ms)
{
	int on;

	on = 1;
	setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, (char*)&on, sizeof(on));
#ifdef TCP_KEEPIDLE
	if(ms <= 120000)
		ms = 120000;
	ms /= 1000;
	setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, (char*)&ms, sizeof(ms));
#endif
}
