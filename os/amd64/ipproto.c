/*
 * os/amd64/ipproto.c -- what a kernel configuration contributes to os/ip.
 *
 * Upstream generates ipprotoinit[] from the "ip" section of the kernel
 * configuration (os/port/mkdevc).  This port has no mkdevc, so the list
 * is written out here; the order is the ARM64 and RISC-V ports' and the
 * reason for it is theirs:
 *
 * ipifc FIRST.  It registers the protocol that OWNS interfaces --
 * binding a medium, assigning addresses, the routes that follow -- so
 * without it #I has no ipifc directory and there is no way to bring an
 * interface up at all.  ip_init() does not call it.
 *
 * The router daemon interface (/net/iproute) is not imported.  devip
 * exposes the file, so the entry points have to exist; refusing is
 * better than returning fake data, which would read as "no routes"
 * rather than "not built here".
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../ip/ip.h"

void	ipifcinit(Fs*);
void	icmpinit(Fs*);
void	icmp6init(Fs*);
void	udpinit(Fs*);
void	tcpinit(Fs*);

void (*ipprotoinit[])(Fs*) =
{
	ipifcinit,
	icmpinit,
	icmp6init,
	udpinit,
	tcpinit,
	nil,
};

/*
 * The user a new IP conversation is created as.  os/port would take it
 * from the host owner; on this machine the host owner is eve, set in
 * portprocinit, so this is the true answer rather than a stand-in.
 */
char*
commonuser(void)
{
	return eve;
}

/* the caller's error string, for os/ip's error reporting */
char*
commonerror(void)
{
	return up->env->errstr;
}

/*
 * os/ip/bootp.c -- BOOTP/DHCP address configuration -- is not
 * imported.  os/ip reaches it through these two hooks and always tests
 * them before calling, so nil is the true value for "this kernel
 * cannot configure an interface over the network", not a placeholder.
 */
char*	(*bootp)(Ipifc*);
int	(*bootpread)(char*, ulong, int);

/*
 * No hardware generator on this machine, which is what -1 means: tcp.c
 * then mixes nrand and the clock for its initial sequence number, as it
 * does on any board whose generator is absent.
 */
int
rnghw(uchar *p, int n)
{
	USED(p);
	USED(n);
	return -1;
}

void
iprouteropen(Fs *f)
{
	USED(f);
	error("iprouter not imported");
}

void
iprouterclose(Fs *f)
{
	USED(f);
}

long
iprouterread(Fs *f, void *a, int n)
{
	USED(f);
	USED(a);
	USED(n);
	error("iprouter not imported");
	return 0;
}
