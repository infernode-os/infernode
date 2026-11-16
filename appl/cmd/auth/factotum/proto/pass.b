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

keycheck(nil: ref Authio->Key): string
{
	return nil;
}
