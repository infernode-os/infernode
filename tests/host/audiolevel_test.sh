#!/bin/bash
#
# tests/host/audiolevel_test.sh
#
# The Raspberry Pis' headphone jack, measured without ears: the code
# that turns samples into pulse widths and picks the clock
# (os/bcm/audiolevel.h), compiled for the host.
#
# WHY. On the bench 3B+ (2026-11-01) a pure tone had a fuzz on it at any
# volume, for the fourth round of listening. Two causes, each found by
# ear: samples cut to the range's resolution with the error dropped, and
# a fractional clock divider dithering every pulse edge. A person with
# earbuds should not be the test.
#
# HOW. Tones at several volumes go through audiolevel(), and a spectrum
# of what comes out must have no harmonic within HARMDB of the tone. The
# same test is compiled again with the carry taken out, and that build
# must FAIL: a test that cannot see the bug proves nothing. The clock is
# arithmetic: a whole divider, the rate within 0.1%, and enough range.
# Jitter itself cannot be simulated, so the driver is held to the
# integer path by reading it.
#
# Usage: tests/host/audiolevel_test.sh [-v]
#

set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/audiolevel.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
CC="$(command -v cc || command -v clang || command -v gcc)"
[ -n "$CC" ] || { echo "SKIP: no C compiler"; exit 0; }

cat > "$BUILD/t.c" <<'C'
#include <stdio.h>
#include <math.h>
#include "audiolevel.h"

enum { Rate = 44100, Secs = 2, N = Rate*Secs, Hdb = 50 };
static double y[N];
static int bad;

/* the magnitude of frequency f in y: a Goertzel, windowed by the whole tone */
static double
mag(double f)
{
	double w, c, a, b, t, re, im, win;
	int i;

	w = 2*M_PI*f/Rate;
	c = 2*cos(w);
	a = b = 0;
	for(i = 0; i < N; i++){
		win = 0.5 - 0.5*cos(2*M_PI*i/N);
		t = y[i]*win + c*a - b;
		b = a;
		a = t;
	}
	re = a - b*cos(w);
	im = b*sin(w);
	return sqrt(re*re + im*im);
}

static double
worst(double f, int amp, int range)
{
	double m0, m, w;
	int i, h, carry;

	carry = 0;
	for(i = 0; i < N; i++){
		h = audiolevel((int)(amp*sin(2*M_PI*f*i/Rate)), 100, 100, range, &carry);
		y[i] = h - range/2.0;
	}
	m0 = mag(f);
	w = -999;
	for(h = 2; h <= 12 && f*h < Rate/2; h++){
		m = 20*log10(mag(f*h)/m0 + 1e-12);
		if(m > w)
			w = m;
	}
	return w;
}

int
main(void)
{
	static long plld[] = { 500000000, 750000000 };
	static long rates[] = { 8000, 11025, 22050, 44100 };
	static int amps[] = { 16000, 8000, 4000, 2000 };
	static double tones[] = { 440, 441, 1000, 882 };
	double w, r;
	int i, j, d, range, carry, v, min, max;

	for(i = 0; i < 2; i++)
		for(j = 0; j < 4; j++){
			d = audiodivider(plld[i], rates[j]);
			range = audiorange(plld[i], rates[j]);
			r = (double)plld[i]/d/range;
			if(d < 2 || range < 1024 || fabs(r-rates[j])/rates[j] > 0.001){
				printf("clock %ld at %ld: divider %d range %d, %.1f Hz\n", plld[i], rates[j], d, range, r);
				bad++;
			}
		}
	range = audiorange(500000000, Rate);
	for(i = 0; i < 4; i++)
		for(j = 0; j < 4; j++){
			w = worst(tones[j], amps[i], range);
			if(w > -Hdb){
				printf("tone %.0f amp %d: harmonic at %.1f dB\n", tones[j], amps[i], w);
				bad++;
			}
		}
	/* silence is the middle, and full scale neither wraps nor sticks */
	carry = 0;
	min = 1<<30;
	max = -1;
	for(i = 0; i < 1000; i++){
		v = audiolevel(0, 100, 100, range, &carry);
		if(v != range/2 && v != range/2 + 1 && v != (range+1)/2){
			printf("silence at %d of %d\n", v, range);
			bad++;
			break;
		}
		v = audiolevel(i&1 ? 32767 : -32768, 100, 100, range, &carry);
		if(v < min) min = v;
		if(v > max) max = v;
	}
	if(min < 0 || max >= range || max-min < range-2){
		printf("full scale: %d..%d of %d\n", min, max, range);
		bad++;
	}
	return bad != 0;
}
C

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
no() { echo "FAIL: $1"; fail=$((fail+1)); }

"$CC" -O2 -I"$ROOT/os/bcm" -o "$BUILD/t" "$BUILD/t.c" -lm || { no "does not compile"; exit 1; }
"$CC" -O2 -DAUDIONOCARRY -I"$ROOT/os/bcm" -o "$BUILD/t0" "$BUILD/t.c" -lm

if out=$("$BUILD/t"); then ok "tones are clean, the clock whole, silence and full scale right"; else echo "$out"; no "tones or clock"; fi
if "$BUILD/t0" >/dev/null; then no "the same test passes with the carry removed: it cannot see the bug"; else ok "with the carry removed the test fails, as it should"; fi

A="$ROOT/os/bcm/audiopwm.c"
if grep -q 'Cmmash' "$A"; then no "audiopwm.c uses the fractional divider"; else ok "audiopwm.c has no MASH divider"; fi
if grep -q 'divf = 0;' "$A" && grep -q 'audiodivider(Plldhz' "$A" && grep -q 'audiolevel(s, gain' "$A"; then ok "audiopwm.c goes through audiolevel.h"; else no "audiopwm.c has left audiolevel.h"; fi

echo "Passed: $pass  Failed: $fail  Skipped: 0"
[ "$fail" = 0 ]
