Audit: module
{
	PATH:		con "/dis/lib/audit.dis";

	# The audit sink. A subject's namespace binds only this file
	# (write-only); it can append but cannot read or rewrite history.
	LOGFILE:	con "/mnt/audit/log";

	# The opt-in marker (created by audit-setup / AUDITMODE). Its
	# existence means this install REQUIRES auditing: fail-closed
	# callers stat it to distinguish "auditing is off" (absent sink is
	# ignorable) from "auditing is on but the sink is broken" (refuse
	# the operation). A compile-time constant — usable even when the
	# audit module itself failed to load.
	ONFILE:		con "/usr/inferno/audit/on";

	init:		fn();

	# log seals one event: it writes "source event msg" to the audit
	# log. Returns 0 on success, -1 if the audit service is not bound
	# into the namespace or the write fails. The caller decides whether
	# absence is fatal (fail-closed for high-value events) or ignorable.
	log:		fn(source, event, msg: string): int;
};
