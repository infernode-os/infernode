/*
 * IMPORTED from upstream Inferno (inferno-os/inferno-os), os/ip/ipaux.c.
 * The NOTICE at that tree's root states "The bulk of the tree is
 * covered by the permissive MIT licence"; this tree's LICENSE already
 * credits Vita Nuova's revisions.
 *
 * Being ported to 64-bit. No upstream os/ port has ever been LP64, and
 * os/ip is where that matters most quietly: the wire formats are all
 * uchar arrays so sizeof is exact and alignment is 1, but anything
 * holding an ADDRESS or a SEQUENCE NUMBER in a ulong is 32 bits of
 * meaning in a 64-bit word, and the arithmetic on those silently
 * changes answers rather than failing. See tests/host/iproute_test.sh.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"ip.h"
#include  "ipv6.h"

/*
 *  well known IP addresses
 */
uchar IPv4bcast[IPaddrlen] = {
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff
};
uchar IPv4allsys[IPaddrlen] = {
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0xff, 0xff,
	0xe0, 0, 0, 0x01
};
uchar IPv4allrouter[IPaddrlen] = {
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0xff, 0xff,
	0xe0, 0, 0, 0x02
};
uchar IPallbits[IPaddrlen] = {
	0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff
};

uchar IPnoaddr[IPaddrlen];

/*
 *  prefix of all v4 addresses
 */
uchar v4prefix[IPaddrlen] = {
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0xff, 0xff,
	0, 0, 0, 0
};


char *v6hdrtypes[Maxhdrtype] =
{
	[HBH]		"HopbyHop",
	[ICMP]		"ICMP",
	[IGMP]		"IGMP",
	[GGP]		"GGP",
	[IPINIP]		"IP",
	[ST]		"ST",
	[TCP]		"TCP",
	[UDP]		"UDP",
	[ISO_TP4]	"ISO_TP4",
	[RH]		"Routinghdr",
	[FH]		"Fraghdr",
	[IDRP]		"IDRP",
	[RSVP]		"RSVP",
	[AH]		"Authhdr",
	[ESP]		"ESP",
	[ICMPv6]	"ICMPv6",
	[NNH]		"Nonexthdr",
	[ISO_IP]	"ISO_IP",
	[IGRP]		"IGRP",
	[OSPF]		"OSPF",
};

/*
 *  well known IPv6 addresses
 */
uchar v6Unspecified[IPaddrlen] = {
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
uchar v6loopback[IPaddrlen] = {
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0x01
};
uchar v6linklocal[IPaddrlen] = {
	0xfe, 0x80, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
uchar v6linklocalmask[IPaddrlen] = {
	0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff,
	0, 0, 0, 0,
	0, 0, 0, 0
};
int v6llpreflen = 8;	// link-local prefix length
uchar v6sitelocal[IPaddrlen] = {
	0xfe, 0xc0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
uchar v6sitelocalmask[IPaddrlen] = {
	0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff,
	0, 0, 0, 0,
	0, 0, 0, 0
};
int v6slpreflen = 6;	// site-local prefix length
uchar v6glunicast[IPaddrlen] = {
	0x08, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
uchar v6multicast[IPaddrlen] = {
	0xff, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
uchar v6multicastmask[IPaddrlen] = {
	0xff, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
int v6mcpreflen = 1;	// multicast prefix length
uchar v6allnodesN[IPaddrlen] = {
	0xff, 0x01, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0x01
};
uchar v6allnodesNmask[IPaddrlen] = {
	0xff, 0xff, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
int v6aNpreflen = 2;	// all nodes (N) prefix
uchar v6allnodesL[IPaddrlen] = {
	0xff, 0x02, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0x01
};
uchar v6allnodesLmask[IPaddrlen] = {
	0xff, 0xff, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
int v6aLpreflen = 2;	// all nodes (L) prefix
uchar v6allroutersN[IPaddrlen] = {
	0xff, 0x01, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0x02
};
uchar v6allroutersL[IPaddrlen] = {
	0xff, 0x02, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0x02
};
uchar v6allroutersS[IPaddrlen] = {
	0xff, 0x05, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0x02
};
uchar v6solicitednode[IPaddrlen] = {
	0xff, 0x02, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0x01,
	0xff, 0, 0, 0
};
uchar v6solicitednodemask[IPaddrlen] = {
	0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff,
	0xff, 0x0, 0x0, 0x0
};
int v6snpreflen = 13;




ushort
ptclcsum(Block *bp, int offset, int len)
{
	uchar *addr;
	ulong losum, hisum;
	ushort csum;
	int odd, blocklen, x;

	/* Correct to front of data area */
	while(bp != nil && offset && offset >= BLEN(bp)) {
		offset -= BLEN(bp);
		bp = bp->next;
	}
	if(bp == nil)
		return 0;

	addr = bp->rp + offset;
	blocklen = BLEN(bp) - offset;

	if(bp->next == nil) {
		if(blocklen < len)
			len = blocklen;
		return ~ptclbsum(addr, len) & 0xffff;
	}

	losum = 0;
	hisum = 0;

	odd = 0;
	while(len) {
		x = blocklen;
		if(len < x)
			x = len;

		csum = ptclbsum(addr, x);
		if(odd)
			hisum += csum;
		else
			losum += csum;
		odd = (odd+x) & 1;
		len -= x;

		bp = bp->next;
		if(bp == nil)
			break;
		blocklen = BLEN(bp);
		addr = bp->rp;
	}

	losum += hisum>>8;
	losum += (hisum&0xff)<<8;
	while((csum = losum>>16) != 0)
		losum = csum + (losum & 0xffff);

	return ~losum & 0xffff;
}

enum
{
	Isprefix= 16,
};

static uchar prefixvals[256] =
{
[0x00] 0 | Isprefix,
[0x80] 1 | Isprefix,
[0xC0] 2 | Isprefix,
[0xE0] 3 | Isprefix,
[0xF0] 4 | Isprefix,
[0xF8] 5 | Isprefix,
[0xFC] 6 | Isprefix,
[0xFE] 7 | Isprefix,
[0xFF] 8 | Isprefix,
};

int
eipfmt(Fmt *f)
{
	char buf[5*8];
	static char *efmt = "%.2lux%.2lux%.2lux%.2lux%.2lux%.2lux";
	static char *ifmt = "%d.%d.%d.%d";
	uchar *p, ip[16];
	ulong *lp;
	ushort s;
	int i, j, n, eln, eli;

	switch(f->r) {
	case 'E':		/* Ethernet address */
		p = va_arg(f->args, uchar*);
		return fmtprint(f, efmt, p[0], p[1], p[2], p[3], p[4], p[5]);

	case 'I':		/* Ip address */
		p = va_arg(f->args, uchar*);
common:
		if(memcmp(p, v4prefix, 12) == 0)
			return fmtprint(f, ifmt, p[12], p[13], p[14], p[15]);

		/* find longest elision */
		eln = eli = -1;
		for(i = 0; i < 16; i += 2){
			for(j = i; j < 16; j += 2)
				if(p[j] != 0 || p[j+1] != 0)
					break;
			if(j > i && j - i > eln){
				eli = i;
				eln = j - i;
			}
		}

		/* print with possible elision */
		n = 0;
		for(i = 0; i < 16; i += 2){
			if(i == eli){
				n += sprint(buf+n, "::");
				i += eln;
				if(i >= 16)
					break;
			} else if(i != 0)
				n += sprint(buf+n, ":");
			s = (p[i]<<8) + p[i+1];
			n += sprint(buf+n, "%ux", s);
		}
		return fmtstrcpy(f, buf);

	case 'i':		/* v6 address as 4 longs */
		lp = va_arg(f->args, ulong*);
		for(i = 0; i < 4; i++)
			hnputl(ip+4*i, *lp++);
		p = ip;
		goto common;

	case 'V':		/* v4 ip address */
		p = va_arg(f->args, uchar*);
		return fmtprint(f, ifmt, p[0], p[1], p[2], p[3]);

	case 'M':		/* ip mask */
		p = va_arg(f->args, uchar*);

		/* look for a prefix mask */
		for(i = 0; i < 16; i++)
			if(p[i] != 0xff)
				break;
		if(i < 16){
			if((prefixvals[p[i]] & Isprefix) == 0)
				goto common;
			for(j = i+1; j < 16; j++)
				if(p[j] != 0)
					goto common;
			n = 8*i + (prefixvals[p[i]] & ~Isprefix);
		} else
			n = 8*16;

		/* got one, use /xx format */
		return fmtprint(f, "/%d", n);
	}
	return fmtstrcpy(f, "(eipfmt)");
}

#define CLASS(p) ((*(uchar*)(p))>>6)

extern char*
v4parseip(uchar *to, char *from)
{
	int i;
	char *p;

	p = from;
	for(i = 0; i < 4 && *p; i++){
		to[i] = strtoul(p, &p, 0);
		if(*p == '.')
			p++;
	}
	switch(CLASS(to)){
	case 0:	/* class A - 1 uchar net */
	case 1:
		if(i == 3){
			to[3] = to[2];
			to[2] = to[1];
			to[1] = 0;
		} else if(i == 2){
			to[3] = to[1];
			to[1] = 0;
		}
		break;
	case 2:	/* class B - 2 uchar net */
		if(i == 3){
			to[3] = to[2];
			to[2] = 0;
		}
		break;
	}
	return p;
}

int
isv4(uchar *ip)
{
	return memcmp(ip, v4prefix, IPv4off) == 0;
}


/*
 *  the following routines are unrolled with no memset's to speed
 *  up the usual case
 */
void
v4tov6(uchar *v6, uchar *v4)
{
	v6[0] = 0;
	v6[1] = 0;
	v6[2] = 0;
	v6[3] = 0;
	v6[4] = 0;
	v6[5] = 0;
	v6[6] = 0;
	v6[7] = 0;
	v6[8] = 0;
	v6[9] = 0;
	v6[10] = 0xff;
	v6[11] = 0xff;
	v6[12] = v4[0];
	v6[13] = v4[1];
	v6[14] = v4[2];
	v6[15] = v4[3];
}

int
v6tov4(uchar *v4, uchar *v6)
{
	if(v6[0] == 0
	&& v6[1] == 0
	&& v6[2] == 0
	&& v6[3] == 0
	&& v6[4] == 0
	&& v6[5] == 0
	&& v6[6] == 0
	&& v6[7] == 0
	&& v6[8] == 0
	&& v6[9] == 0
	&& v6[10] == 0xff
	&& v6[11] == 0xff)
	{
		v4[0] = v6[12];
		v4[1] = v6[13];
		v4[2] = v6[14];
		v4[3] = v6[15];
		return 0;
	} else {
		memset(v4, 0, 4);
		return -1;
	}
}

ulong
parseip(uchar *to, char *from)
{
	int i, elipsis = 0, v4 = 1;
	ulong x;
	char *p, *op;

	memset(to, 0, IPaddrlen);
	p = from;
	for(i = 0; i < 16 && *p; i+=2){
		op = p;
		x = strtoul(p, &p, 16);
		if(*p == '.' || (*p == 0 && i == 0)){
			p = v4parseip(to+i, op);
			i += 4;
			break;
		} else {
			to[i] = x>>8;
			to[i+1] = x;
		}
		if(*p == ':'){
			v4 = 0;
			if(*++p == ':'){
				elipsis = i+2;
				p++;
			}
		}
	}
	if(i < 16){
		memmove(&to[elipsis+16-i], &to[elipsis], i-elipsis);
		memset(&to[elipsis], 0, 16-i);
	}
	if(v4){
		to[10] = to[11] = 0xff;
		return nhgetl(to+12);
	} else
		return 6;
}

/*
 *  hack to allow ip v4 masks to be entered in the old
 *  style
 */
ulong
parseipmask(uchar *to, char *from)
{
	ulong x;
	int i;
	uchar *p;

	if(*from == '/'){
		/* as a number of prefix bits */
		i = atoi(from+1);
		if(i < 0)
			i = 0;
		if(i > 128)
			i = 128;
		memset(to, 0, IPaddrlen);
		for(p = to; i >= 8; i -= 8)
			*p++ = 0xff;
		if(i > 0)
			*p = ~((1<<(8-i))-1);
		x = nhgetl(to+IPv4off);
	} else {
		/* as a straight bit mask */
		x = parseip(to, from);
		if(memcmp(to, v4prefix, IPv4off) == 0)
			memset(to, 0xff, IPv4off);
	}
	return x;
}

void
maskip(uchar *from, uchar *mask, uchar *to)
{
	int i;

	for(i = 0; i < IPaddrlen; i++)
		to[i] = from[i] & mask[i];
}

uchar classmask[4][16] = {
	0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0xff,  0xff,0x00,0x00,0x00,
	0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0xff,  0xff,0x00,0x00,0x00,
	0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0xff,  0xff,0xff,0x00,0x00,
	0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0xff,  0xff,0xff,0xff,0x00,
};

uchar*
defmask(uchar *ip)
{
	if(isv4(ip))
		return classmask[ip[IPv4off]>>6];
	else {
		if(ipcmp(ip, v6loopback) == 0)
			return IPallbits;
		else if(memcmp(ip, v6linklocal, v6llpreflen) == 0)
			return v6linklocalmask;
		else if(memcmp(ip, v6sitelocal, v6slpreflen) == 0)
			return v6sitelocalmask;
		else if(memcmp(ip, v6solicitednode, v6snpreflen) == 0)
			return v6solicitednodemask;
		else if(memcmp(ip, v6multicast, v6mcpreflen) == 0)
			return v6multicastmask;
		return IPallbits;
	}
}

void
ipv62smcast(uchar *smcast, uchar *a)
{
	assert(IPaddrlen == 16);
	memmove(smcast, v6solicitednode, IPaddrlen);
	smcast[13] = a[13];
	smcast[14] = a[14];
	smcast[15] = a[15];
}


/*
 *  parse a hex mac address
 */
int
parsemac(uchar *to, char *from, int len)
{
	char nip[4];
	char *p;
	int i;

	p = from;
	memset(to, 0, len);
	for(i = 0; i < len; i++){
		if(p[0] == '\0' || p[1] == '\0')
			break;

		nip[0] = p[0];
		nip[1] = p[1];
		nip[2] = '\0';
		p += 2;

		to[i] = strtoul(nip, 0, 16);
		if(*p == ':')
			p++;
	}
	return i;
}

/*
 *  hashing tcp, udp, ... connections
 */
ulong
iphash(uchar *sa, ushort sp, uchar *da, ushort dp)
{
	/*
	 * Unsigned, and it matters.
	 *
	 * sa[] is uchar, which promotes to signed int. A last address
	 * byte of 0x80 or more shifted left 24 sets the sign bit, the
	 * whole expression goes negative, and C's % returns a NEGATIVE
	 * remainder -- which is then assigned to a ulong and used to
	 * index ht->tab[]. The read lands astronomically out of bounds
	 * and whatever it finds is walked as a chain of Iphash.
	 *
	 * 255.255.255.255 is such an address, so this fires the moment
	 * anything speaks DHCP. The board took a data abort in iphtlook
	 * twice, at two different instructions, on the SAME faulting
	 * address both times -- 0x01b900001f580015 -- which is what a
	 * deterministic bad index looks like rather than heap
	 * corruption, and is what sent the first diagnosis after a
	 * double-hashed conversation that does not exist.
	 *
	 * The same sign-extension class as the nhgetl bug fixed earlier
	 * in this port, in the same family of file, for the same reason:
	 * this code was written where these promotions did not reach a
	 * 64-bit index.
	 */
	return (((ulong)sa[IPaddrlen-1]<<24) ^ ((ulong)sp << 16) ^
		((ulong)da[IPaddrlen-1]<<8) ^ (ulong)dp) % Nhash;
}

void
iphtadd(Ipht *ht, Conv *c)
{
	ulong hv;
	int i;
	Iphash *h, *p;

	hv = iphash(c->raddr, c->rport, c->laddr, c->lport);
	h = smalloc(sizeof(*h));
	if(ipcmp(c->raddr, IPnoaddr) != 0)
		h->match = IPmatchexact;
	else {
		if(ipcmp(c->laddr, IPnoaddr) != 0){
			if(c->lport == 0)
				h->match = IPmatchaddr;
			else
				h->match = IPmatchpa;
		} else {
			if(c->lport == 0)
				h->match = IPmatchany;
			else
				h->match = IPmatchport;
		}
	}
	h->c = c;

	lock(&ht->lk);
	/*
	 * Refuse to hash the same conversation twice, and look in EVERY
	 * bucket rather than in the one this address pair hashes to.
	 *
	 * udp announces AND connects through here, and closes once. A
	 * conversation that did both is added twice and removed once, so
	 * an entry survives pointing at a Conv the stack believes it has
	 * finished with. Searching only bucket hv does not catch it: the
	 * announce hashed with no remote address and the connect hashes
	 * with one, so the two land in different buckets and neither
	 * sees the other.
	 *
	 * That is also why the leftover is unreachable afterwards. The
	 * bucket a removal searches is computed from the conversation's
	 * CURRENT addresses, so a conversation that connected after
	 * announcing is looked for where it is not, and the entry stays
	 * in the table pointing at freed memory.
	 *
	 * The board faulted in iphtlook walking a chain into freed
	 * memory: the faulting address was an Iphash.next read from a
	 * pointer that was not one.
	 *
	 * Sixty-four buckets is a short walk and this is connection
	 * setup, not the packet path.
	 */
	for(i = 0; i < Nhash; i++)
		for(p = ht->tab[i]; p != nil; p = p->next)
			if(p->c == c){
				unlock(&ht->lk);
				free(h);
				return;
			}
	h->next = ht->tab[hv];
	ht->tab[hv] = h;
	unlock(&ht->lk);
}

void
iphtrem(Ipht *ht, Conv *c)
{
	int i;
	Iphash **l, *h;

	/*
	 * Search every bucket, not the one this conversation's addresses
	 * hash to NOW.
	 *
	 * The entry was filed under the addresses the conversation had
	 * when it was added, and connect changes them. Hashing here and
	 * searching only that bucket therefore looks in the wrong place
	 * for exactly the conversations that did anything interesting,
	 * finds nothing, and leaves an entry in the table pointing at a
	 * Conv that is about to be reused -- which iphtlook then walks.
	 *
	 * Removing by identity has no such failure mode: it does not
	 * matter where the entry was filed or what has changed since.
	 */
	lock(&ht->lk);
	for(i = 0; i < Nhash; i++)
		for(l = &ht->tab[i]; (*l) != nil; l = &(*l)->next)
			if((*l)->c == c){
				h = *l;
				(*l) = h->next;
				free(h);
				unlock(&ht->lk);
				return;
			}
	unlock(&ht->lk);
}

/* look for a matching conversation with the following precedence
 *	connected && raddr,rport,laddr,lport
 *	announced && laddr,lport
 *	announced && *,lport
 *	announced && laddr,*
 *	announced && *,*
 */
Conv*
iphtlook(Ipht *ht, uchar *sa, ushort sp, uchar *da, ushort dp)
{
	ulong hv;
	Iphash *h;
	Conv *c;

	/* exact 4 pair match (connection) */
	hv = iphash(sa, sp, da, dp);
	lock(&ht->lk);
	for(h = ht->tab[hv]; h != nil; h = h->next){
		if(h->match != IPmatchexact)
			continue;
		c = h->c;
		if(sp == c->rport && dp == c->lport
		&& ipcmp(sa, c->raddr) == 0 && ipcmp(da, c->laddr) == 0){
			unlock(&ht->lk);
			return c;
		}
	}
	
	/* match local address and port */
	hv = iphash(IPnoaddr, 0, da, dp);
	for(h = ht->tab[hv]; h != nil; h = h->next){
		if(h->match != IPmatchpa)
			continue;
		c = h->c;
		if(dp == c->lport && ipcmp(da, c->laddr) == 0){
			unlock(&ht->lk);
			return c;
		}
	}
	
	/* match just port */
	hv = iphash(IPnoaddr, 0, IPnoaddr, dp);
	for(h = ht->tab[hv]; h != nil; h = h->next){
		if(h->match != IPmatchport)
			continue;
		c = h->c;
		if(dp == c->lport){
			unlock(&ht->lk);
			return c;
		}
	}
	
	/* match local address */
	hv = iphash(IPnoaddr, 0, da, 0);
	for(h = ht->tab[hv]; h != nil; h = h->next){
		if(h->match != IPmatchaddr)
			continue;
		c = h->c;
		if(ipcmp(da, c->laddr) == 0){
			unlock(&ht->lk);
			return c;
		}
	}
	
	/* look for something that matches anything */
	hv = iphash(IPnoaddr, 0, IPnoaddr, 0);
	for(h = ht->tab[hv]; h != nil; h = h->next){
		if(h->match != IPmatchany)
			continue;
		c = h->c;
		unlock(&ht->lk);
		return c;
	}
	unlock(&ht->lk);
	return nil;
}
