implement Bioget;

#
# bioget — fetch a biometric-protected secret to a file.
#
# Usage:  bioget slot outpath
#
# Used by /lib/lucifer/boot.sh to materialise the serve-llm keyfile from
# /phone/bio_retrieve into a tmpfs path that `mount -k` can chmod 0600.
# A single executable owns the open-write-read lifecycle because
# devphone tracks the requested slot name on the channel's aux pointer
# — separate shell redirections open separate FDs, losing the name.
#
# Triggers the OS biometric prompt; exit 0 on success, 1 on failure
# (cancelled, no enrollment, slot empty, write error). Errors go to
# stderr; the payload only ever lands at outpath.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bioauth.m";
	bioauth: Bioauth;

Bioget: module {
	PATH: con "/dis/bioget.dis";
	init: fn(nil: ref Draw->Context, args: list of string);
};

usage()
{
	sys->fprint(sys->fildes(2), "usage: bioget slot outpath\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	args = tl args;
	if(len args != 2)
		usage();

	slot := hd args;
	outpath := hd tl args;

	bioauth = load Bioauth Bioauth->PATH;
	if(bioauth == nil) {
		sys->fprint(sys->fildes(2), "bioget: cannot load %s: %r\n",
			Bioauth->PATH);
		raise "fail:load";
	}
	if((err := bioauth->init()) != nil) {
		sys->fprint(sys->fildes(2), "bioget: %s\n", err);
		raise "fail:init";
	}

	(payload, rerr) := bioauth->retrieve(slot);
	if(rerr != nil) {
		sys->fprint(sys->fildes(2), "bioget: %s\n", rerr);
		raise "fail:retrieve";
	}

	# 0600 — same rationale as keyringinst: factotum / mount -k refuse
	# a world-readable signer key. We create the file ourselves so
	# the umask of whoever ran us cannot accidentally relax it.
	fd := sys->create(outpath, Sys->OWRITE, 8r600);
	if(fd == nil) {
		sys->fprint(sys->fildes(2), "bioget: cannot create %s: %r\n",
			outpath);
		raise "fail:create";
	}
	b := array of byte payload;
	n := sys->write(fd, b, len b);
	if(n != len b) {
		sys->fprint(sys->fildes(2), "bioget: short write to %s: %r\n",
			outpath);
		raise "fail:write";
	}
}
