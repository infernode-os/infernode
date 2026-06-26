Audit: module
{
	PATH:		con "/dis/lib/audit.dis";

	# The audit sink. A subject's namespace binds only this file
	# (write-only); it can append but cannot read or rewrite history.
	LOGFILE:	con "/mnt/audit/log";

	init:		fn();

	# log seals one event: it writes "source event msg" to the audit
	# log. Returns 0 on success, -1 if the audit service is not bound
	# into the namespace or the write fails. The caller decides whether
	# absence is fatal (fail-closed for high-value events) or ignorable.
	log:		fn(source, event, msg: string): int;
};
