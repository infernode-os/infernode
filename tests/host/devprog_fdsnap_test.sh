#!/bin/sh
# A Prog's fd file (/prog/n/fd, devprog.c, both kernels): fdsnap, which
# takes a reference on every channel in the Prog's fd table for the
# listing.
#
# The Prog listed is in the kernel for its opens and closes, the Dis VM
# let go, so they run beside the reader.  A close takes a channel out of
# the table, under the table's lock, and frees it; an open that finds
# the table full replaces it with a longer one and frees the old.  The
# hosted kernel's fdsnap read the table with the lock not held (the
# native kernel's held it): a channel taken from the table could be
# freed before the reference was counted, and was then given back,
# freed twice; or the table read was the one just freed.
#
# fdsnap is extracted from each kernel's devprog.c and run against a
# table of the test's own:
#  - every reference it counts is counted with the table's lock held;
#  - and, where the compiler has ASan and threads, beside a thread that
#    closes channels and grows the table as the kernel does, for a
#    second: no use of freed memory.
# No emulator needed.

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

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#define nil ((void*)0)

typedef struct Lock Lock;
struct Lock { pthread_mutex_t m; int held; };
typedef struct Ref Ref;
struct Ref { long ref; };
typedef struct Chan Chan;
struct Chan { Ref r; int pad[6]; };
typedef struct Fgrp Fgrp;
struct Fgrp { Lock l; Chan **fd; int nfd; int maxfd; };
typedef struct Fdsnap Fdsnap;
struct Fdsnap { int n; Chan **c; int *fd; };

static char Enomem[] = "no memory";
static Fgrp grp;
static int single;	/* one thread: the lock's state can be asked */
static long counted, unlocked;

static void lock(Lock *l) { pthread_mutex_lock(&l->m); l->held = 1; }
static void unlock(Lock *l) { l->held = 0; pthread_mutex_unlock(&l->m); }
static void error(char *e) { printf("  error: %s\n", e); exit(2); }

static long
incref(Ref *r)
{
	if(single){
		counted++;
		if(!grp.l.held)
			unlocked++;
	}
	return __sync_add_and_fetch(&r->ref, 1);
}

static void
cclose(Chan *c)
{
	if(__sync_sub_and_fetch(&c->r.ref, 1) == 0)
		free(c);
}

static Chan*
newchan(void)
{
	Chan *c;

	c = calloc(1, sizeof(*c));
	c->r.ref = 1;
	return c;
}

static void
#include "fn.inc"

static volatile int stop;

/* closes and opens, as the kernel's fdclose and newfd do them */
static void*
changer(void *v)
{
	unsigned x = 12345;
	int i, n;
	Chan *c, **nfd, **ofd;

	(void)v;
	while(!stop){
		x = x*1103515245 + 12345;
		i = (x>>8) % grp.nfd;
		lock(&grp.l);
		c = grp.fd[i];
		grp.fd[i] = newchan();
		if(i > grp.maxfd)
			grp.maxfd = i;
		if((x>>20) % 4 == 0){
			/* the table replaced by one of another length, the old freed */
			n = 20 + (x>>24) % 60;
			if(n <= grp.maxfd)
				n = grp.maxfd+1;
			nfd = calloc(n, sizeof(Chan*));
			memmove(nfd, grp.fd, (grp.maxfd+1)*sizeof(Chan*));
			ofd = grp.fd;
			grp.fd = nfd;
			grp.nfd = n;
			free(ofd);
		}
		unlock(&grp.l);
		if(c != nil)
			cclose(c);
	}
	return nil;
}

int
main(int argc, char **argv)
{
	Fdsnap s;
	pthread_t th;
	int i, bad = 0;
	long rounds;

	pthread_mutex_init(&grp.l.m, nil);
	grp.nfd = 20;
	grp.fd = calloc(grp.nfd, sizeof(Chan*));
	grp.maxfd = 11;
	for(i = 0; i <= grp.maxfd; i += 2)
		grp.fd[i] = newchan();

	/* alone: what it counts, and with what held */
	single = 1;
	fdsnap(&grp, &s);
	single = 0;
	if(s.n != 6 || counted != 6){
		printf("  six open files gave %d entries and %ld references\n", s.n, counted);
		bad++;
	}
	for(i = 0; i < s.n; i++){
		if(s.fd[i] != 2*i || s.c[i] != grp.fd[2*i]){
			printf("  entry %d is fd %d\n", i, s.fd[i]);
			bad++;
		}
		cclose(s.c[i]);
	}
	free(s.c);
	free(s.fd);
	if(unlocked != 0){
		printf("  %ld of %ld references were counted with the table's lock not held\n", unlocked, counted);
		bad++;
	}
	if(grp.l.held){
		printf("  the table's lock is left held\n");
		bad++;
	}

	/* beside closes and a growing table */
	rounds = 0;
	if(argc > 1 && bad == 0){
		pthread_create(&th, nil, changer, nil);
		for(i = 0; i < 400; i++){
			int k;
			for(k = 0; k < 500; k++){
				fdsnap(&grp, &s);
				for(int j = 0; j < s.n; j++)
					cclose(s.c[j]);
				free(s.c);
				free(s.fd);
				rounds++;
			}
			usleep(100);
		}
		stop = 1;
		pthread_join(th, nil);
	}
	printf("%ld listings beside closes\n", rounds);
	return bad != 0;
}
EOT

SAN=""
echo 'int main(void){return 0;}' > "$BUILD/san.c"
if "$CC" -fsanitize=address -pthread -o "$BUILD/san" "$BUILD/san.c" 2>/dev/null && "$BUILD/san" 2>/dev/null; then
	SAN="-fsanitize=address"
fi

for k in emu os; do
	SRCFILE=$ROOT/$k/port/devprog.c
	if [ ! -f "$SRCFILE" ]; then
		fail "$SRCFILE not found"
		continue
	fi
	awk '/^fdsnap\(/,/^}/' "$SRCFILE" > "$BUILD/fn.inc"
	if ! grep -q 'incref(&c->r)' "$BUILD/fn.inc"; then
		fail "$k/port/devprog.c: fdsnap not found as it was"
		continue
	fi
	if ! "$CC" -std=gnu99 -Wall -Wno-unused-function -g -O1 $SAN -pthread -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
		fail "$k: test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
		continue
	fi
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "$k/port/devprog.c: every reference fdsnap counts is counted with the fd table's lock held"
	else
		fail "$k/port/devprog.c: $(grep -v '^$' "$BUILD/run.out" | head -4 | tr '\n' ' ' | cut -c1-400)"
		continue
	fi
	if [ -n "$SAN" ]; then
		if "$BUILD/test" threads > "$BUILD/run.out" 2>&1; then
			pass "$k/port/devprog.c: beside closes and a table that grows, no freed memory is used ($(tail -1 "$BUILD/run.out"), under ASan)"
		else
			fail "$k/port/devprog.c: beside closes: $(grep -m1 'ERROR: AddressSanitizer' "$BUILD/run.out" | cut -c1-200) $(grep -v '^$' "$BUILD/run.out" | grep -v '^=' | head -3 | tr '\n' ' ' | cut -c1-300)"
		fi
	fi
done

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
