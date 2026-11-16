implement Authproto;

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
	(key, err) := io.findkey(attrs, "user? !password?");
	if(key == nil)
		return err;
	user := authio->lookattrval(key.attrs, "user");
	if(user == nil)
		return "unknown user";
	# a key with !password= and nothing after it was answered "ok user ''":
	# a success, with no password
	pass := authio->lookattrval(key.secrets, "!password");
	if(pass == nil)
		return "key has no password";
	a := sys->aprint("%q %q", user, pass);
	io.write(a, len a);
	return nil;
}

# A key of this protocol is a user and a password: with either missing
# it is answered "unknown user" or "key has no password" whenever it is
# asked for, so it is refused when it is stored.
keycheck(k: ref Authio->Key): string
{
	if(authio->lookattrval(k.attrs, "user") == nil)
		return "a pass key needs user=";
	if(authio->lookattrval(k.secrets, "!password") == nil)
		return "a pass key needs !password=, not empty";
	return nil;
}
