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
# See doc/compliance/audit-log-design.md.
#

include "sys.m";
	sys: Sys;

include "audit.m";

init()
{
	sys = load Sys Sys->PATH;
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
