/*
 * From a 16-bit sample to a PWM pulse width, and the clock that sets the
 * rate: apart from the hardware, as audioring.h is, so that
 * tests/host/audiolevel_test.sh measures exactly this. Both of these were
 * found by ear on the bench 3B+ (2026-11-01), as a fuzz on a pure tone.
 */

enum
{
	Audiorange	= 2048,		/* near enough: audiorange() */
};

/*
 * A whole number off PLLD, and the range makes up the difference: a
 * fractional divider gets its average by dithering the clock, and that
 * jitter is on every edge of the pulses, a fuzz on any tone. 500MHz/5 at
 * 44100 is a range of 2267, 44100.4Hz.
 */
static int
audiodivider(long plld, long rate)
{
	long d;

	d = plld / (rate * Audiorange);
	return d < 2 ? 2 : d;
}

static int
audiorange(long plld, long rate)
{
	return plld / audiodivider(plld, rate) / rate;
}

/*
 * The pulse width for sample s, at gain out of gainmax. What is below the
 * range's resolution goes into the next sample, not away: dropped, it
 * repeats with the waveform, and a pure tone comes out with a fuzz on it
 * at any volume; carried, it is noise, moved up out of the way.
 */
static int
audiolevel(int s, int gain, int gainmax, int range, int *carry)
{
	long v;

#ifdef AUDIONOCARRY
	*carry = 0;
#endif
	v = (long)s * gain / gainmax;		/* -32768..32767 */
	v = (v + 32768) * range + *carry;
	if(v < 0)
		v = 0;
	if(v >= 65536L * range)
		v = 65536L * range - 1;
	*carry = v & 0xFFFF;
	return v >> 16;
}
