implement Authproto;

#
#	proto=btpin [addr=<remote>]
#
#	Hands a Bluetooth legacy-pairing PIN to bt9p(4) when a peer asks
#	for one.  Pre-shared, like a WPA passphrase, and held the same
#	way: a key per peer, addressed by the peer's address, so a board
#	that knows several old peripherals keeps a PIN for each --
#
#		key proto=btpin addr=00:1f:20:aa:bb:cc !pin=0000
#
#	and one with no addr is the PIN for anything not named.  bt9p
#	asks for the named one first and the unnamed one second.  On a
#	headless board the keys come off the card at boot, one write to
#	factotum's ctl per key, as the WiFi keys do (docs/BLUETOOTH.md).
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
	(key, err) := io.findkey(attrs, "!pin?");
	if(key == nil)
		return err;
	pin := authio->lookattrval(key.secrets, "!pin");
	if(pin == nil)
		return "no pin";
	a := array of byte pin;
	io.write(a, len a);
	return nil;
}

keycheck(nil: ref Authio->Key): string
{
	return nil;
}
