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
	# (a secret given in the query, a guess at one, is refused by
	# factotum itself before any protocol is started)
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

# A network's key names the network and holds what WPA2 can use: a
# passphrase of 8 to 63 characters, or the 256-bit key made from one
# as 64 hexadecimal digits (IEEE 802.11-2020 12.7.1.3 and annex J.4).
keycheck(k: ref Authio->Key): string
{
	if(authio->lookattrval(k.attrs, "essid") == nil)
		return "a wpapsk key needs essid=";
	pass := authio->lookattrval(k.secrets, "!password");
	if(pass == nil)
		return "a wpapsk key needs !password=";
	n := len array of byte pass;
	if(n == 64){
		for(i := 0; i < len pass; i++)
			if(!ishex(pass[i]))
				return "a wpapsk key of 64 characters is 64 hexadecimal digits";
		return nil;
	}
	if(n < 8 || n > 63)
		return "a WPA2 passphrase is 8 to 63 characters (or its key, 64 hexadecimal digits)";
	return nil;
}

ishex(c: int): int
{
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F';
}
