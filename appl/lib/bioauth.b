implement Bioauth;

#
# bioauth — userspace wrapper around /phone/bio_*.
#
# See module/bioauth.m for the contract. The file protocol:
#
#   /phone/bio_status   r    one line: available|unavailable|unsupported
#   /phone/bio_store    w    "<name>\n<payload>" in a single write(2)
#   /phone/bio_retrieve rw   write(2) slot name; read(2) returns payload
#                            (or short-read on bridge error). The OS
#                            biometric prompt fires inside the bridge's
#                            read path — the calling thread blocks until
#                            the user responds.
#
# Slot names must satisfy valid_name() — non-empty, no '/', no NUL, no
# newline, <= 63 bytes (BIO_NAME_MAX-1 in devphone.c). The bridge
# revalidates; we check first so callers see a useful Limbo-side error
# instead of a raw 9p reject.
#

include "sys.m";
	sys: Sys;

include "bioauth.m";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "bioauth: cannot load Sys";
	return nil;
}

available(): int
{
	fd := sys->open(STATUS, Sys->OREAD);
	if(fd == nil)
		return AVAIL_NONE;
	buf := array[32] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return AVAIL_NONE;
	s := string buf[:n];
	# strip trailing newline(s)
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[:len s - 1];
	case s {
	"available" =>
		return AVAIL_OK;
	"unavailable" =>
		return AVAIL_NOENROL;
	* =>
		return AVAIL_NONE;
	}
}

valid_name(name: string): int
{
	if(len name == 0 || len name > 63)
		return 0;
	for(i := 0; i < len name; i++) {
		c := name[i];
		if(c == '/' || c == '\n' || c == 0)
			return 0;
	}
	return 1;
}

store(name, payload: string): string
{
	if(!valid_name(name))
		return "bioauth: invalid slot name";
	if(len payload == 0)
		return "bioauth: empty payload";

	fd := sys->open(STORE, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("bioauth: cannot open %s: %r", STORE);

	# Single write(2): "<name>\n<payload>". devphone parses on the
	# first '\n' so a payload may itself contain newlines safely.
	head := array of byte (name + "\n");
	body := array of byte payload;
	buf := array[len head + len body] of byte;
	buf[:] = head;
	buf[len head:] = body;
	n := sys->write(fd, buf, len buf);
	if(n != len buf)
		return sys->sprint("bioauth: short write to %s: %r", STORE);
	return nil;
}

retrieve(name: string): (string, string)
{
	if(!valid_name(name))
		return (nil, "bioauth: invalid slot name");

	fd := sys->open(RETRIEVE, Sys->ORDWR);
	if(fd == nil)
		return (nil, sys->sprint("bioauth: cannot open %s: %r", RETRIEVE));

	# Tell the bridge which slot to fetch. devphone caches the name
	# on the channel until close.
	nb := array of byte name;
	if(sys->write(fd, nb, len nb) != len nb)
		return (nil, sys->sprint("bioauth: cannot select slot: %r"));

	# A single read(2) returns the entire decrypted payload up to
	# CONTACTS_BUFSZ - BIO_NAME_MAX bytes. Anything bigger does not
	# belong in biometric storage. Seek to 0 so the bridge re-fetches
	# rather than continuing from the post-write offset.
	sys->seek(fd, big 0, Sys->SEEKSTART);

	buf := array[16*1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return (nil, sys->sprint("bioauth: read failed: %r"));
	if(n == 0)
		return (nil, "bioauth: empty slot or authentication cancelled");
	return (string buf[:n], nil);
}
