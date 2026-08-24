/*
 * ptclbsum -- the partial ones-complement checksum os/ip is built on.
 *
 * Upstream implements this in assembly, once per architecture, and
 * there is no AArch64 version to import: every os/ port predates the
 * architecture. So this is written rather than ported.
 *
 * It is written in plain C on purpose. A checksum that is FAST and
 * wrong is worse than one that is slow and right -- a bad checksum does
 * not crash, it silently drops or accepts packets, and the symptom
 * appears as an unreliable network rather than as a bug here. The
 * assembly versions upstream exist because this runs over every byte of
 * every packet, so it is worth optimising eventually; it is not worth
 * optimising before it is known correct, and
 * tests/host/ipchecksum_test.sh is what establishes that.
 *
 * The contract, taken from how os/ip/ipaux.c uses it:
 *
 *   - the buffer is a sequence of 16-bit BIG-ENDIAN words
 *   - an odd trailing byte is the HIGH half of a final word
 *   - the result is folded to 16 bits, and the caller forms the actual
 *     checksum with ~ptclbsum(...) & 0xffff
 *
 * Endianness is handled by reading bytes rather than casting to
 * ushort*, which also removes any alignment requirement. Upstream's
 * assembly has to special-case an odd starting address; this does not.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

ushort
ptclbsum(uchar *addr, int len)
{
	ulong sum;

	sum = 0;

	/*
	 * Accumulate in a wide word and fold once at the end. Folding as
	 * we go would also be correct, but carries are cheap to defer and
	 * a single fold is easier to reason about.
	 */
	while(len >= 2){
		sum += ((ulong)addr[0] << 8) | addr[1];
		addr += 2;
		len -= 2;
	}

	/*
	 * A trailing odd byte pads on the RIGHT: it is the high half of
	 * the last word, not the low half. Getting this backwards yields
	 * a checksum that is correct for every even-length packet and
	 * wrong for every odd-length one, which is a memorably annoying
	 * way to spend a week.
	 */
	if(len)
		sum += (ulong)addr[0] << 8;

	while(sum >> 16)
		sum = (sum & 0xFFFF) + (sum >> 16);

	return (ushort)sum;
}
