implement Auditchain;

#
# auditchain - the cryptographic spine of the InferNode audit log.
#
# A linear SHA-256 hash chain: H[0] = SHA-256(GENESIS), and for each
# record H[n] = SHA-256(H[n-1] ‖ record). Any edit, reorder, or deletion
# of a past record changes H[n] and every later hash, so a recomputation
# that disagrees with the stored chain proves tampering.
#
# This module is pure and deterministic (no I/O, no clock) so it can be
# unit-tested directly and reused by both the auditfs server and the
# offline verifier. It composes keyring->sha256; it adds no new crypto.
#
# See docs/compliance/audit-log-design.md.
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;

include "auditchain.m";

init()
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		raise "fail:auditchain: cannot load keyring";
}

hash1(b: array of byte): array of byte
{
	d := array[HASHLEN] of byte;
	kr->sha256(b, len b, d, nil);
	return d;
}

genesis(): array of byte
{
	return hash1(array of byte GENESIS);
}

extend(prev: array of byte, record: array of byte): array of byte
{
	buf := array[len prev + len record] of byte;
	for(i := 0; i < len prev; i++)
		buf[i] = prev[i];
	for(i = 0; i < len record; i++)
		buf[len prev + i] = record[i];
	return hash1(buf);
}

canon(seq, t: int, source, event, msg: string): string
{
	return sys->sprint("%d %d %s %s %s", seq, t, source, event, msg);
}

hexchars: con "0123456789abcdef";

hex(h: array of byte): string
{
	s := "";
	for(i := 0; i < len h; i++) {
		hi := (int h[i] >> 4) & 16rf;
		lo := int h[i] & 16rf;
		s += hexchars[hi:hi+1] + hexchars[lo:lo+1];
	}
	return s;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

unhex(s: string): array of byte
{
	n := len s / 2;
	b := array[n] of byte;
	for(i := 0; i < n; i++)
		b[i] = byte ((hexval(s[2*i]) << 4) | hexval(s[2*i+1]));
	return b;
}
