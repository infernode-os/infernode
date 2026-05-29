implement Keyringinst;

#
# keyringinst - Install the serve-llm signer keyfile.
#
# Sister module to wm/settings (INFR-169). Settings owns the UI;
# this owns the testable bits — payload cleanup, file write with
# 0600 perms, presence check. tests/keyringinst_test.b drives both
# the pure transform and the on-disk install path (using /tmp/...
# fixtures) so the keyring install behaviour is covered without
# settings.b / wmclient / a real /lib/keyring on the test host.
#

include "sys.m";
	sys: Sys;

include "keyringinst.m";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "keyringinst: cannot load Sys";
	return nil;
}

present(): int
{
	(ok, nil) := sys->stat(DEFAULT_PATH);
	return ok >= 0;
}

status_text(): string
{
	if(present())
		return "Keyfile: present at " + DEFAULT_PATH;
	return "Keyfile: missing — install or push before relaunch";
}

prepare_payload(raw: string): string
{
	# Empty stays empty so the caller can flag it.
	if(len raw == 0)
		return raw;
	if(raw[len raw - 1] == '\r')
		return raw[:len raw - 1];
	return raw;
}

install_payload(payload, dst: string): string
{
	if(len payload == 0)
		return "keyringinst: empty payload";

	# mkdir -p the parent chain. sys->create with DMDIR is mkdir;
	# idempotent on existing dirs (returns nil, which we ignore).
	# We walk every '/' in dst (except a leading one) so a path
	# like /tmp/a/b/c/file gets /tmp, /tmp/a, /tmp/a/b, /tmp/a/b/c
	# created in order, regardless of which intermediate links
	# already exist.
	for(i := 1; i < len dst; i++) {
		if(dst[i] != '/')
			continue;
		dir := dst[:i];
		mkfd := sys->create(dir, Sys->OREAD, Sys->DMDIR | 8r755);
		if(mkfd != nil)
			mkfd = nil;
	}

	# Strict perms — factotum / mount -k refuse a world-readable
	# signer key in production. sys->create lets the umask shave bits
	# down to 0600 even on a server with a permissive umask.
	fd := sys->create(dst, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("keyringinst: cannot create %s: %r", dst);
	b := array of byte payload;
	n := sys->write(fd, b, len b);
	if(n != len b)
		return sys->sprint("keyringinst: short write to %s (%d of %d): %r",
			dst, n, len b);
	return nil;
}
