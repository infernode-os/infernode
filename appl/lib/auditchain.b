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

# What ends a word or a line, or is acted on rather than shown when a
# record is displayed.  Only blank, tab and newline were looked for, in
# two places with two rules: a CR beside a blank was hashed as two
# blanks and replayed as one, and the chain was broken from then on.
blank(c: int): int
{
	if(c <= ' ' || (c >= 16r7F && c <= 16rA0))
		return 1;
	if(c < 16r1680)
		return 0;
	return c == 16r1680 || (c >= 16r2000 && c <= 16r200B) ||
		c == 16r200E || c == 16r200F ||
		(c >= 16r2028 && c <= 16r202F) || c == 16r205F ||
		(c >= 16r2066 && c <= 16r2069) || c == 16r3000 || c == 16rFEFF;
}

token(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(blank(c))
			c = '_';
		r[len r] = c;
	}
	if(r == "")
		r = "-";
	return r;
}

text(s: string): string
{
	r := "";
	gap := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(blank(c)) {
			gap = 1;
			continue;
		}
		if(gap && r != "")
			r[len r] = ' ';
		gap = 0;
		r[len r] = c;
	}
	return r;
}

value(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!blank(c) && c != '=' && c != '%')
			r[len r] = c;
		else if(c < 16r100)
			r += sys->sprint("%%%.2X", c);
		else
			r += sys->sprint("%%u%.4X", c);
	}
	return r;
}

unvalue(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '%') {
			n := 2;
			o := i + 1;
			if(o < len s && s[o] == 'u') {
				n = 4;
				o++;
			}
			if(o + n <= len s && ishex(s[o:o+n], 1)) {
				c = 0;
				for(j := o; j < o + n; j++)
					c = (c << 4) | hexval(s[j]);
				i = o + n - 1;
			}
		}
		r[len r] = c;
	}
	return r;
}

record(seq, t: int, source, event, hash, msg: string): string
{
	return sys->sprint("%d %d %s %s %s %s", seq, t, source, event, hash, msg);
}

# A line is a record only if it is, byte for byte, the line record()
# writes for the fields read from it.  The numbers were converted
# whatever followed their digits and the fields rejoined whatever lay
# between them, so more than one line stood for the same record.
parse(line: string): (int, int, string, string, string, string, int)
{
	(n, toks) := sys->tokenize(line, " ");
	if(n < 5)
		return (0, 0, "", "", "", "", 0);
	seq := int hd toks; toks = tl toks;
	t := int hd toks; toks = tl toks;
	source := hd toks; toks = tl toks;
	event := hd toks; toks = tl toks;
	hash := hd toks; toks = tl toks;
	msg := "";
	for(; toks != nil; toks = tl toks) {
		if(msg != "")
			msg += " ";
		msg += hd toks;
	}
	if(seq < 1 || len hash != 2*HASHLEN || !ishex(hash, 0) ||
	   record(seq, t, source, event, hash, msg) != line)
		return (0, 0, "", "", "", "", 0);
	return (seq, t, source, event, hash, msg, 1);
}

# upper: capitals too (value's escapes); a hash is lowercase only.
ishex(s: string, upper: int): int
{
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') &&
		   !(upper && c >= 'A' && c <= 'F'))
			return 0;
	}
	return 1;
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
