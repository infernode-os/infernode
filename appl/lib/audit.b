implement Audit;

#
# audit - thin client for emitting to the tamper-evident audit log.
#
# Optional sugar over "write a line to /mnt/audit/log". Loosely coupled
# by design: if the audit service is not bound into the namespace, log()
# returns -1 and the caller chooses fail-closed (treat as a hard error,
# for high-value security events) or fail-open. The whole facility tears
# out by simply not mounting it.
#
# See docs/compliance/audit-log-design.md.
#

include "sys.m";
	sys: Sys;

include "audit.m";

init()
{
	sys = load Sys Sys->PATH;
}

# The encoding is Auditchain->value's, kept here so that an emitter needs
# only this module.
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

log(source, event, msg: string): int
{
	fd := sys->open(LOGFILE, Sys->OWRITE);
	if(fd == nil)
		return -1;
	line := source + " " + event + " " + msg;
	b := array of byte line;
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}
