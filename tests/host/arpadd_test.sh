#!/bin/sh
# The hosted emulator's arpadd (emu/port/ipif6-posix.c, and ipif-posix.c),
# which a write of "add address ether" to /net/arp reaches: extracted
# from the source and run against a host table of the test's own.
#
# The entry is made for the address that was parsed (the four bytes were
# taken from twelve characters into the text, past the end of a short
# string: the entry was for whatever the bytes after it spelled), and
# the removal of old entries ends when one cannot be removed, or after a
# few (while the host found an entry the loop went on, whether or not it
# could remove it: for ever, where the emulator may read the table and
# not change it). By the source, only eve opens /net/arp to write it.
#
# No emulator needed. Skips where the host has no SIOCGARP (macOS, iOS).

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

CC=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)
if [ -z "$CC" ]; then
	echo "SKIP: no C compiler"
	exit 0
fi
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

printf '#include <sys/ioctl.h>\n#include <net/if_arp.h>\n#ifndef SIOCGARP\n#error none\n#endif\nint main(void){return 0;}\n' > "$BUILD/have.c"
if ! "$CC" -o "$BUILD/have" "$BUILD/have.c" 2>/dev/null; then
	echo "SKIP: this host has no SIOCGARP"
	exit 0
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if_arp.h>

typedef unsigned char uchar;
#define nil ((void*)0)
enum { IPaddrlen = 16, IPv4addrlen = 4, IPv4off = 12, ERRMAX = 128 };
static char Ebadarg[] = "bad arg in system call";
static struct { struct { char errstr[ERRMAX]; } *env; } upv, *up = &upv;
static struct { char errstr[ERRMAX]; } envv;

static jmp_buf errlab;
static char lasterr[ERRMAX];
static void error(char *e) { snprintf(lasterr, sizeof lasterr, "%s", e); longjmp(errlab, 1); }
static void oserror(void) { error("host error"); }
static void oserrstr(char *b, unsigned n) { snprintf(b, n, "host refuses"); }

static uchar v4prefix[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
static unsigned long
parseip(uchar *to, char *from)
{
	struct in_addr in;

	memset(to, 0, IPaddrlen);
	if(inet_pton(AF_INET, from, &in) != 1)
		return 0;
	memmove(to, v4prefix, 12);
	memmove(to+IPv4off, &in, 4);
	return 1;
}
static int isv4(uchar *a) { return memcmp(a, v4prefix, 12) == 0; }
static int parsemac(uchar *to, char *from, int n) { memset(to, 0x42, n); (void)from; return n; }

/* the host: a table that always has an entry for the address asked */
static int canremove, removed, nget, nset, opens, closes;
static struct in_addr asked, set;
static int
fakeioctl(int fd, unsigned long req, void *arg)
{
	struct arpreq *a = arg;
	struct sockaddr_in *sin = (struct sockaddr_in*)&a->arp_pa;

	(void)fd;
	switch(req){
	case SIOCGARP:
		nget++;
		asked = sin->sin_addr;
		return 0;
	case SIOCDARP:
		if(!canremove){
			errno = EPERM;
			return -1;
		}
		removed++;
		return 0;
	case SIOCSARP:
		nset++;
		set = sin->sin_addr;
		if(!canremove){
			errno = EPERM;
			return -1;
		}
		return 0;
	}
	return -1;
}
static int fakesocket(int a, int b, int c) { (void)a; (void)b; (void)c; opens++; return 7; }
static int fakeclose(int fd) { (void)fd; closes++; return 0; }
#define ioctl fakeioctl
#define socket fakesocket
#define close fakeclose
#include "arpadd.inc"
#undef ioctl
#undef socket
#undef close

static int bad;
static void
check(int ok, const char *what)
{
	if(!ok){
		printf("  %s\n", what);
		bad++;
	}
}
static void
timeout(int s)
{
	static const char m[] = "arpadd did not return\n";

	(void)s;
	if(write(1, m, sizeof m - 1) < 0)
		_exit(3);
	_exit(2);
}

static int
call(char *ip, char *mac)
{
	nget = nset = removed = opens = closes = 0;
	memset(&asked, 0, sizeof asked);
	memset(&set, 0, sizeof set);
	lasterr[0] = 0;
	if(setjmp(errlab))
		return -1;
	arpadd(ip, mac, 3);
	return 0;
}

int
main(void)
{
	/* the command as devip's arpwrite has it: fields of one buffer */
	char buf[64];
	char *ip, *mac;
	struct in_addr want;

	up->env = (void*)&envv;
	signal(SIGALRM, timeout);
	alarm(10);

	memset(buf, 0, sizeof buf);
	strcpy(buf, "add");
	ip = buf+4;
	strcpy(ip, "10.1.2.3");
	mac = ip+strlen(ip)+1;
	strcpy(mac, "0123456789ab");	/* text twelve bytes on from the address is here */
	inet_pton(AF_INET, "10.1.2.3", &want);

	/* a host that lets the table be read and not changed */
	canremove = 0;
	check(call(ip, mac) == -1, "an entry the host refuses is an error");
	check(asked.s_addr == want.s_addr, "the entry looked for is the address given");
	check(set.s_addr == want.s_addr, "the entry asked for is the address given");
	check(nget == 1, "one look at the table when an entry cannot be removed");
	check(opens == 1 && closes == 1, "the socket is closed after the refusal");

	/* a host that removes what it is asked to and has another every time */
	canremove = 1;
	check(call(ip, mac) == 0, "an entry the host takes is made");
	check(removed > 0 && removed <= 64, "old entries are removed, and not for ever");
	check(nset == 1 && set.s_addr == want.s_addr, "the entry made is the address given");
	check(opens == 1 && closes == 1, "the socket is closed after");

	/* what is no IPv4 address makes no entry */
	strcpy(ip, "nonsense");
	check(call(ip, mac) == -1 && nset == 0 && nget == 0, "an address that is none reaches the host's table not at all");
	check(opens == closes, "and its socket is closed");
	return bad != 0;
}
EOT

for f in ipif6-posix.c ipif-posix.c; do
	SRC=$ROOT/emu/port/$f
	if [ ! -f "$SRC" ]; then
		fail "$SRC not found"
		continue
	fi
	{ echo 'static void'; awk '/^arpadd\(/,/^}/' "$SRC"; } > "$BUILD/arpadd.inc"
	if ! grep -q '^arpadd(' "$BUILD/arpadd.inc"; then
		fail "$f has no arpadd to run"
		continue
	fi
	if ! "$CC" -std=gnu99 -Wall -Wno-unused-function -Wno-unused-variable -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
		fail "$f: arpadd does not compile alone: $(head -5 "$BUILD/cc.err" | tr '\n' ' ')"
		continue
	fi
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "$f: an ARP entry is for the address given, and removing old ones ends"
	else
		fail "$f: arpadd: $(head -8 "$BUILD/run.out" | tr '\n' ' ')"
	fi
done

# only eve opens /net/arp to write it
if awk '/^ipopen\(/,/^}/' "$ROOT/emu/port/devip.c" | awk '/case Qarp:/,/break;/' | grep -q 'if(wantswrite(omode) && !iseve())'; then
	pass "emu/port/devip.c: only eve opens the ARP table to change it"
else
	fail "emu/port/devip.c lets anyone open /net/arp for writing"
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
