#!/bin/bash
#
# tests/host/audioring_test.sh
#
# The Raspberry Pis' /dev/audio, without a board: the ring of buffers
# os/bcm/audiopwm.c plays (os/bcm/audioring.h), against a simulated DMA
# engine, and each board's choice of PWM block.
#
# WHY. The ring's bugs were found by ear, on the bench Pi 4, on
# 2026-10-31, after the driver had shipped for six weeks: the first play
# after boot is always clean (the engine and the writer start together
# on buffer 0), and the only test anyone made was one tone per boot.
#
#   1. A writer with nothing queued began wherever the last one stopped,
#      behind the engine or in the buffer it was playing: a second tone
#      came out late, in pieces, out of order.
#   2. The buffer being played counted as free while it played silence,
#      so a writer come round the ring wrote into it under the engine: a
#      regular broken pattern.
#   3. The interrupt silenced the next buffer due if it was not yet full,
#      over a writer that had begun it: the first frames of a sound begun
#      just as the engine finished the buffer before. (Found by this
#      test, not by ear.)
#   4. The fix for 3 left a begun buffer alone whether or not its writer
#      was still writing. A writer that returned part way through a
#      buffer and was late with the rest (sdr/fm from a network mount,
#      2026-11-07) had that buffer played once a lap: its frames, then
#      the stale rest of the buffer, uncounted by audiostat. The second
#      simulation below is such a writer.
#
# And the Pi 4 was silent: its jack's pins are the SECOND PWM block's,
# and the driver, written for the 3B+, drove the first.
#
# HOW. The engine finishes one buffer per tick and records what it
# played; the writer makes sounds of several buffers each, at random
# moments, with the engine moving under the first buffer's write, after
# pauses that leave the engine anywhere in the ring, in both the default
# and the low-latency mode. Every buffer a sound writes is tagged
# (sound, part). What was played must be every sound, whole and in
# order, with silence only between sounds -- and no buffer may ever be
# written while the engine is playing it.
#
# Usage: tests/host/audioring_test.sh [-v]
#

set -u
cd "$(dirname "$0")/../.."
VERBOSE=0
for a in "$@"; do [[ "$a" == "-v" ]] && VERBOSE=1; done

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

PASSED=0; FAILED=0; SKIPPED=0
pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); }

echo -e "${BOLD}Raspberry Pi /dev/audio: the buffer ring, and each board's PWM${NC}"
echo ""

RING=os/bcm/audioring.h
[[ -f "$RING" ]] || { echo "ERROR: $RING not found" >&2; exit 1; }
CC="$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)"

if [[ -z "$CC" ]]; then
    skip "no C compiler: the ring is not run"
else
    BUILD="$(mktemp -d)"
    trap 'rm -rf "$BUILD"' EXIT
    cat > "$BUILD/t.c" <<EOF
#include <stdio.h>
#include <stdlib.h>
#include "$PWD/$RING"

enum { Silence = -1, Torn = -2, Parts = 6, Sounds = 400 };

static Ring r;
static int tag[Nbuf];		/* what each buffer holds: (sound*Parts+part), or Silence */
static int startedat[Sounds];	/* the tick at which each sound's writer began */
static int heardat[Sounds];	/* the tick that played its first part */
static int fresh[Sounds];	/* begun with nothing queued */
static int torn[Nbuf];		/* written while the engine was playing it */
static int played[Sounds*Parts*4 + 100000];
static int np;

/* the engine finishes pbuf: what it played, then the interrupt */
static void
tick(void)
{
	played[np++] = torn[r.pbuf] ? Torn : tag[r.pbuf];
	torn[r.pbuf] = 0;
	if(ringplayed(&r) != Rplay){	/* no writer here stops part way: never Rmove */
		if(r.pbuf == r.writing)
			torn[r.pbuf] = 1;	/* silence over a buffer the writer had begun */
		else
			tag[r.pbuf] = Silence;	/* the driver's fillsilence */
	}
}

static int
run(int ahead, unsigned seed, char *why, int nwhy)
{
	int i, s, p, want, insound;

	srand(seed);
	ringreset(&r);
	r.ahead = ahead;
	for(i = 0; i < Nbuf; i++){
		tag[i] = Silence;
		torn[i] = 0;
	}
	np = 0;
	for(s = 0; s < Sounds; s++){
		/* a pause: the engine goes on round, anywhere */
		for(i = rand() % 11; i > 0; i--)
			tick();
		/* one open, one sound */
		startedat[s] = np;
		fresh[s] = ringqueued(&r) == 0;
		for(p = 0; p < Parts; p++){
			ringbegin(&r);
			while(!ringroom(&r))
				tick();
			if(r.wbuf == r.pbuf)
				torn[r.wbuf] = 1;
			/*
			 * The writer fills a buffer in microseconds and the
			 * engine plays one in tens of milliseconds, so the
			 * engine moves under a write only at the start of a
			 * sound, when it may be at the very end of its buffer:
			 * then the interrupt silences the buffer it moves to if
			 * that is not yet full, and must not, over a writer
			 * that has begun it.
			 */
			ringwriting(&r);
			if(p == 0 && rand() % 2 == 0)
				tick();
			if(!torn[r.wbuf])
				tag[r.wbuf] = s*Parts + p;
			ringfilled(&r);
		}
	}
	for(i = 0; i < 2*Nbuf; i++)
		tick();

	want = 0;
	insound = 0;
	for(i = 0; i < np; i++){
		if(played[i] == Torn){
			snprintf(why, nwhy, "tick %d: a buffer's sound was lost: written while the engine played it, or silenced over the writer", i);
			return 0;
		}
		if(played[i] == Silence){
			if(insound){
				snprintf(why, nwhy, "tick %d: silence inside sound %d, after part %d", i, want/Parts, want%Parts - 1);
				return 0;
			}
			continue;
		}
		if(want % Parts == 0 && played[i] == want)
			heardat[want/Parts] = i;
		if(played[i] != want){
			snprintf(why, nwhy, "tick %d: played sound %d part %d, wanted sound %d part %d",
				i, played[i]/Parts, played[i]%Parts, want/Parts, want%Parts);
			return 0;
		}
		want++;
		insound = want % Parts != 0;
	}
	if(want != Sounds*Parts){
		snprintf(why, nwhy, "%d of %d parts played", want, Sounds*Parts);
		return 0;
	}
	/*
	 * A sound begun with nothing queued is heard when the buffer playing
	 * ends: its first part plays at the next tick, or the one after if
	 * the engine moved while it was being written. Not a lap of the ring
	 * later, as when the writer began where the last one had stopped.
	 */
	for(s = 0; s < Sounds; s++)
		if(fresh[s] && heardat[s] - startedat[s] > 2){
			snprintf(why, nwhy, "sound %d: begun at tick %d, first heard at tick %d", s, startedat[s], heardat[s]);
			return 0;
		}
	return 1;
}

int
main(void)
{
	char why[200];
	unsigned seed;
	int ahead, ok;

	ok = 1;
	for(ahead = 1; ahead <= Nbuf - 1; ahead += Nbuf - 2)
		for(seed = 1; seed <= 50; seed++)
			if(!run(ahead, seed, why, sizeof why)){
				printf("ahead %d, seed %u: %s\n", ahead, seed, why);
				ok = 0;
				break;
			}
	return ok ? 0 : 1;
}
EOF
    # A writer that stops part way through buffers. Each buffer is Q
    # quarters; the writer writes a few quarters at a time and goes
    # away while the engine plays a few buffers, as a program reading
    # from the network does. Every quarter is numbered. What is played
    # must be every quarter once, in order (nothing stale, nothing
    # twice), and the gaps the driver counts (Rsilence and Rmove while
    # sounding) must be the silent buffers played inside the stream.
    cat > "$BUILD/s.c" <<EOF
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "$PWD/$RING"

enum { Q = 4, Silence = -1, Quarters = 3000 };

static Ring r;
static int buf[Nbuf][Q];	/* what each buffer holds, quarter by quarter */
static int woff;		/* quarters written in the writer's buffer */
static int sounding;
static int counted;		/* gaps the driver counts */
static int played[Quarters*20 + 100000];
static int np;
static int ntick;		/* ticks so far */

static void
tick(void)
{
	int i, d;

	for(i = 0; i < Q; i++)
		played[np++] = buf[r.pbuf][i];
	ntick++;
	d = ringplayed(&r);
	if(d == Rmove){
		memmove(buf[(r.pbuf + 1) % Nbuf], buf[r.pbuf], woff * sizeof buf[0][0]);
		ringmove(&r);
	}
	if(d != Rplay){
		for(i = 0; i < Q; i++)
			buf[r.pbuf][i] = Silence;
		if(sounding)
			counted++;
	}
}

static int
run(int ahead, unsigned seed, char *why, int nwhy)
{
	int i, j, k, next, want, first, last, inside, gaps, b, closed;

	srand(seed);
	ringreset(&r);
	r.ahead = ahead;
	for(i = 0; i < Nbuf; i++)
		for(j = 0; j < Q; j++)
			buf[i][j] = Silence;	/* as ring() leaves them; what is stale later is this sound's own, played again */
	woff = 0;
	sounding = 0;
	counted = 0;
	np = 0;
	ntick = 0;
	for(i = rand() % 7; i > 0; i--)
		tick();
	next = 0;
	while(next < Quarters){
		ringunpark(&r);
		for(k = 1 + rand() % 7; k > 0 && next < Quarters; k--){
			if(woff == 0){
				ringbegin(&r);
				while(!ringroom(&r))
					tick();
				ringwriting(&r);
			}
			buf[r.wbuf][woff++] = next++;
			if(woff == Q){
				ringfilled(&r);
				woff = 0;
				sounding = 1;
			}
		}
		ringpark(&r);
		/* away: the network was slow */
		for(i = rand() % 8; i > 0; i--)
			tick();
	}
	/* the close: the part-filled buffer padded with silence and queued */
	if(woff != 0){
		for(; woff < Q; woff++)
			buf[r.wbuf][woff] = Silence;
		ringfilled(&r);
		woff = 0;
	}
	sounding = 0;
	closed = ntick;	/* the last buffer decided while open is played at tick closed */
	for(i = 0; i < 2*Nbuf; i++)
		tick();

	want = 0;
	first = last = -1;
	for(i = 0; i < np; i++){
		if(played[i] == Silence)
			continue;
		if(played[i] != want){
			snprintf(why, nwhy, "quarter %d of the playing: played %d, wanted %d%s", i, played[i], want,
				played[i] < want ? " (again: stale, what the buffer held a lap before)" : " (one skipped)");
			return 0;
		}
		if(first < 0)
			first = i;
		last = i;
		want++;
	}
	if(want != Quarters){
		snprintf(why, nwhy, "%d of %d quarters played", want, Quarters);
		return 0;
	}
	/*
	 * A gap is a silent buffer played after the sound began and decided
	 * on while the device was open: between its parts, and after the
	 * last of it if the writer was slow to close. The device ran dry
	 * while open, which is what an underrun is; the driver cannot tell
	 * the end of a sound from a pause.
	 */
	gaps = 0;
	for(b = first/Q + 1; b <= closed && b < np/Q; b++){
		inside = 1;
		for(j = 0; j < Q; j++)
			if(played[b*Q + j] != Silence)
				inside = 0;
		gaps += inside;
	}
	if(gaps != counted){
		snprintf(why, nwhy, "%d silent buffers played inside the sound, %d counted", gaps, counted);
		return 0;
	}
	return 1;
}

int
main(void)
{
	char why[200];
	unsigned seed;
	int ahead, ok;

	ok = 1;
	for(ahead = 1; ahead <= Nbuf - 1; ahead += Nbuf - 2)
		for(seed = 1; seed <= 50; seed++)
			if(!run(ahead, seed, why, sizeof why)){
				printf("ahead %d, seed %u: %s\n", ahead, seed, why);
				ok = 0;
				break;
			}
	return ok ? 0 : 1;
}
EOF
    if "$CC" -O2 -Wall -o "$BUILD/s" "$BUILD/s.c" 2>"$BUILD/cc2.log"; then
        if out="$("$BUILD/s")"; then
            pass "a writer that stops part way through buffers: every frame played once and in order, none stale, and every gap counted (3000 quarters, 50 seeds, default and low-latency)"
        else
            fail "a writer that stops part way: $out"
        fi
    else
        fail "the stalled-writer test did not compile"
        sed 's/^/    /' "$BUILD/cc2.log" | head -12
    fi

    if "$CC" -O2 -Wall -o "$BUILD/t" "$BUILD/t.c" 2>"$BUILD/cc.log"; then
        if out="$("$BUILD/t")"; then
            pass "every sound plays whole, in order, and as soon as the buffer playing ends (400 sounds of 6 buffers, 50 seeds, default and low-latency)"
        else
            fail "the ring: $out"
        fi
    else
        fail "the test did not compile"
        sed 's/^/    /' "$BUILD/cc.log" | head -12
    fi
fi

# Each board's PWM: the block whose channels GPIO 40/41 carry at ALT0, its
# DREQ, and PLLD's rate. On a 3B+ the one block; on a 4B the second.
board() {	# board <io.h> <name> <off> <dreq> <plld>
    local off dreq plld
    off=$(sed -n 's/^[[:space:]]*AUDIOPWMOFF[[:space:]]*=[[:space:]]*\(0x[0-9A-Fa-f]*\).*/\1/p' "$1")
    dreq=$(sed -n 's/^[[:space:]]*AUDIODREQ[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$1")
    plld=$(sed -n 's/^[[:space:]]*AUDIOPLLDHZ[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$1")
    if [[ "$off" == "$3" && "$dreq" == "$4" && "$plld" == "$5" ]]; then
        pass "$2: the jack's PWM at $off, DREQ $dreq, PLLD $plld Hz"
    else
        fail "$2: the jack's PWM is $off DREQ $dreq PLLD $plld; it is $3, $4, $5"
    fi
}
board os/bcm2837/io.h "3B+" 0x20C000 5 500000000
board os/bcm2711/io.h "4B" 0x20C800 1 750000000

echo ""
echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
[[ $FAILED -eq 0 ]]
