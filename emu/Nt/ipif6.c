#define Unknown win_Unknown

/* vista (0x0600) was the first to support IPPROTO_IPV6 */
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0600

#include	<winsock2.h>
#include	<ws2def.h>
#include	<ws2tcpip.h>
#include	<wspiapi.h>
#undef Unknown

#include	"dat.h"
#include	"fns.h"
#include	"ip.h"
#include	"error.h"

extern int SOCK_SELECT;
extern SOCKET oswakesock(void);

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)	/* mstcpip.h */
#endif

/*
 * Whether an ICMP port unreachable for what a UDP socket sent fails its
 * next read.  Windows fails the next recvfrom of any UDP socket with
 * WSAECONNRESET; POSIX hosts fail only a connected one's (ECONNREFUSED).
 * So an announced socket answering many peers (a server) had a read
 * fail whenever a peer it had answered was gone, and a server that
 * reads until an error ended there.
 */
static void
udpconnreset(int fd, int on)
{
	BOOL b;
	DWORD n;

	b = on? TRUE: FALSE;
	n = 0;
	WSAIoctl(fd, SIO_UDP_CONNRESET, &b, sizeof(b), nil, 0, &n, nil, nil);
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

	fd = socket(AF_INET6, type, 0);
	if(fd < 0)
		oserror();

	/* OpenBSD has v6only fixed to 1, so the following will fail */
	v6only = 0;
	if(setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (void*)&v6only, sizeof v6only) < 0)
		oserror();

	if(type == SOCK_DGRAM){
		one = 1;
		setsockopt(fd, SOL_SOCKET, SO_BROADCAST, (char*)&one, sizeof(one));
		udpconnreset(fd, 0);	/* until it is connected, as POSIX has it */
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
		r = send(sock, va, len, 0);
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
	/*
	 * What was sent or read is the caller's, interrupted or not, as in
	 * ipif6-posix.c: osleave raised Eintr for a kill that came during a
	 * send or recv that had done its work, so bytes taken from the
	 * host were lost (devssl's record cut short: "bad digest") and
	 * bytes sent were reported unsent (devssl hung up the connection
	 * and every mount over it: "inappropriate use of fd";
	 * ninep_disconnect_test).
	 */
	if(r > 0)
		osleavekeep();
	else
		osleave();
	return r;
}

static int
doselect(int sock)
{
	fd_set	waitr;
	struct timeval seltime;
	SOCKET wake;
	char buf[16];

	/*
	 * oshostintr sends a byte to wake when it interrupts a Proc in
	 * SOCK_SELECT, which ends the select at once.  The timeout is
	 * kept for an interrupt that came before syscall said SOCK_SELECT
	 * (swipend is then set), or with no wake socket to be had.
	 */
	wake = oswakesock();
	lock(&up->sysio);
	up->syscall = SOCK_SELECT;
	unlock(&up->sysio);
	FD_ZERO(&waitr);
	FD_SET(sock, &waitr);
	if(wake != INVALID_SOCKET)
		FD_SET(wake, &waitr);
	for(;;){
		int nfds;
		fd_set in, exc;

		if(up->intwait || up->swipend) {
			up->intwait = 0;
			return -1;
		}
		in = waitr;
		exc = waitr;
		seltime.tv_sec = 1;
		seltime.tv_usec = 0L;
		nfds = select(sizeof(fd_set)*8, &in, (fd_set*)0, &exc, &seltime);
		if(wake != INVALID_SOCKET && FD_ISSET(wake, &in))
			while(recv(wake, buf, sizeof(buf), 0) > 0)
				;
		if(up->intwait) {
			up->intwait = 0;
			return -1;
		}
		if(nfds < 0) {
			print("select error\n");
			return 0;
		}
		if(FD_ISSET(sock, &in) || FD_ISSET(sock, &exc)){
			return 0;
		}
	}
}

int
so_recv(int sock, void *va, int len, void *hdr, int hdrlen)
{
	int r, l;
	struct sockaddr_storage sa;
	struct sockaddr_in6 *sin6;
	char h[Udphdrlen];

	osenter();
	if(doselect(sock) < 0) {
		osleave();
		return -1;
	}
	if(hdr == 0)
		r = recv(sock, va, len, 0);
	else {
		sin6 = (struct sockaddr_in6*)&sa;
		l = sizeof(sa);
		r = recvfrom(sock, va, len, 0, (struct sockaddr*)&sa, &l);
		if(r >= 0) {
			memset(h, 0, sizeof h);
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
			memset(&sa, 0, sizeof sa);
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
	/* bytes read are the caller's, interrupted or not: see so_send */
	if(r > 0)
		osleavekeep();
	else
		osleave();
	return r;
}

/*
 * Close a socket so that its peer gets what was written and the end of
 * it (FIN), and no reset.  A reset loses data at both ends on Windows:
 * the peer discards what it had received and not yet read, so a
 * server's answer followed by its close never arrived (an HTTP server
 * that answers once it has the headers, its client's body unread:
 * webclient_origin_test's "empty response", the client's recv
 * WSAECONNRESET; a proxy's refusal of CONNECT, llmclient_proxy_test;
 * ventisrv's greeting before its handshake deadline, auditprov_test).
 * Two things make one: an abortive close (SO_LINGER of {1, 0}, which
 * the POSIX hangup asks for), and a close with received data unread.
 * So what is waiting unread is taken first, without waiting for more
 * (a peer still sending more than this gets its reset), and the close
 * is Windows' own, which does not wait either: with linger off,
 * closesocket returns at once and the stack sends what is queued,
 * then the FIN.
 */
static int
closegently(int fd)
{
	int n;
	u_long one;
	char junk[2048];

	one = 1;
	if(ioctlsocket(fd, FIONBIO, &one) == 0){
		for(n = 0; n < 64; n++)	/* at most 128K */
			if(recv(fd, junk, sizeof junk, 0) <= 0)
				break;
	}
	shutdown(fd, SD_SEND);
	return closesocket(fd);
}

void
so_close(int sock)
{
	closegently(sock);
}

void
so_connect(int fd, unsigned char *raddr, unsigned short rport)
{
	int r, type, tl;
	struct sockaddr_storage sa;
	struct sockaddr_in6 *sin6;

	memset(&sa, 0, sizeof(sa));
	sin6 = (struct sockaddr_in6*)&sa;
	sin6->sin6_family = AF_INET6;
	hnputs(&sin6->sin6_port, rport);
	memmove((uchar*)&sin6->sin6_addr, raddr, IPaddrlen);

	osenter();
	r = connect(fd, (struct sockaddr*)sin6, sizeof(*sin6));
	osleave();
	if(r < 0)
		oserror();
	tl = sizeof(type);
	if(getsockopt(fd, SOL_SOCKET, SO_TYPE, (char*)&type, &tl) == 0 && type == SOCK_DGRAM)
		udpconnreset(fd, 1);
}

void
so_getsockname(int fd, unsigned char *laddr, unsigned short *lport)
{
	int len;
	struct sockaddr_storage sa;
	struct sockaddr_in6 *sin6;

	len = sizeof(*sin6);
	if(getsockname(fd, (struct sockaddr*)&sa, &len) < 0)
		oserror();

	sin6 = (struct sockaddr_in6*)&sa;
	if(sin6->sin6_family != AF_INET6 || len != sizeof(*sin6))
		error("not AF_INET6");

	memmove(laddr, &sin6->sin6_addr, IPaddrlen);
	*lport = nhgets(&sin6->sin6_port);
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
so_accept(int fd, unsigned char *raddr, unsigned short *rport)
{
	int nfd, len;
	struct sockaddr_storage sa;
	struct sockaddr_in6 *sin6;

	sin6 = (struct sockaddr_in6*)&sa;

	len = sizeof(*sin6);
	osenter();
	if(doselect(fd) < 0) {
		osleave();
		return -1;
	}
	nfd = accept(fd, (struct sockaddr*)&sa, &len);
	osleave();
	if(nfd < 0)
		oserror();

	if(sin6->sin6_family != AF_INET6 || len != sizeof(*sin6))
		error("not AF_INET6");

	memmove(raddr, &sin6->sin6_addr, IPaddrlen);
	*rport = nhgets(&sin6->sin6_port);
	return nfd;
}

void
so_bind(int fd, int su, unsigned char *addr, unsigned short port)
{
	int i, one;
	struct sockaddr_storage sa;
	struct sockaddr_in6 *sin6;

	sin6 = (struct sockaddr_in6*)&sa;

	one = 1;
	if(0 && setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (char*)&one, sizeof(one)) < 0) {
		oserrstr(up->genbuf, sizeof(up->genbuf));
		print("setsockopt: %s", up->genbuf);
	}

	if(su) {
		for(i = 600; i < 1024; i++) {
			memset(&sa, 0, sizeof(sa));
			sin6->sin6_family = AF_INET6;
			memmove(&sin6->sin6_addr, addr, IPaddrlen);
			hnputs(&sin6->sin6_port, i);

			if(bind(fd, (struct sockaddr*)sin6, sizeof(*sin6)) >= 0)	
				return;
		}
		oserror();
	}

	memset(&sa, 0, sizeof(sa));
	sin6->sin6_family = AF_INET6;
	memmove(&sin6->sin6_addr, addr, IPaddrlen);
	hnputs(&sin6->sin6_port, port);

	if(bind(fd, (struct sockaddr*)sin6, sizeof(*sin6)) < 0)
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
	hints.ai_flags = isnumeric ? AI_NUMERICHOST : 0;
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

	/* no reset: see closegently; nolinger needs none, as the close does not wait */
	USED(nolinger);
	osenter();
	r = closegently(fd);
	osleave();
	return r;
}

void
arpadd(char *ipaddr, char *eaddr, int n)
{
	error("arp not implemented");
}

int
so_mustbind(int restricted, int port)
{
	USED(restricted);
	USED(port);
	/* Windows requires bound sockets, even on port 0 */
	return 1;
}

void
so_keepalive(int fd, int ms)
{
	int on;

	USED(ms);
	on = 1;
	setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, (char*)&on, sizeof(on));
}
