implement Authproto;

#
#	proto=wpapsk role=client essid=<network>
#
#	Hands the network's passphrase to a supplicant that asked for it
#	by name.  The key's attributes carry the network, so a machine
#	that knows several networks keeps one key per network and the
#	supplicant gets the right one without naming a file:
#
#		key proto=wpapsk role=client essid=home !password=secret
#
#	Plan 9's factotum goes further and derives the pairwise transient
#	key inside itself, so that only the session key ever leaves.  It
#	can do that because its wpapsk protocol is told the two addresses
#	and the two nonces.  Here the derivation is ip/wpa(8)'s, which
#	means the passphrase does leave factotum -- to a program running
#	as the same user, which could read the key file anyway.  Moving
#	the derivation in is the improvement to make when there is a
#	second consumer to justify the interface.
#

include "sys.m";
	sys: Sys;

include "../authio.m";
	authio:	Authio;
	Attr, IO: import authio;

init(f: Authio): string
{
	sys = load Sys Sys->PATH;
	authio = f;
	return nil;
}

interaction(attrs: list of ref Attr, io: ref Authio->IO): string
{
	# the network is named: with no essid the query matched every
	# network's key, and the first one's passphrase was given
	if(authio->lookattrval(attrs, "essid") == nil)
		return "no essid given";
	# a secret in the query is a guess at one: "!password=guess" was a
	# pattern like any other, so the answer said whether it was right
	for(l := attrs; l != nil; l = tl l)
		if((a := hd l).tag == Authio->Aval && len a.name > 0 && a.name[0] == '!')
			return "a query may not give a secret attribute";
	(key, err) := io.findkey(attrs, "!password?");
	if(key == nil)
		return err;
	pass := authio->lookattrval(key.secrets, "!password");
	if(pass == nil)
		return "no passphrase";
	b := array of byte pass;
	io.write(b, len b);
	return nil;
}

keycheck(nil: ref Authio->Key): string
{
	return nil;
}
