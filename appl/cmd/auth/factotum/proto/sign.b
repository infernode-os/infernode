implement Authproto;

#
# sign - factotum signing protocol.
#
# Performs one keyring private-key signature on a caller-supplied message
# using a signer key that factotum holds, and returns the keyring
# Certificate. The private key never leaves factotum: the caller (e.g.
# auditfs, for AU-10 audit checkpoints) sends bytes and receives only the
# public certificate. Access is gated by namespace placement of
# /mnt/factotum/rpc, like every other factotum capability.
#
# Key form (single line, so it survives factotum's key store):
#   key proto=sign service=audit !sk=<enc(sktostr(SK))>
# where enc is sktostr with its newlines mapped to '@' and base64 padding
# '=' mapped to '~' — neither occurs in base64 or the alg/owner names, so
# the value is single-line and '='-free (factotum's parseline mis-handles
# '=' inside a value, and the key line must fit one 8192-byte write). The
# SK is algorithm-agnostic; mldsa87 (ML-DSA, CNSA 2.0) is the audit
# default, but anything genSK/createsignerkey produces works unchanged.
#
# Wire protocol (caller drives /mnt/factotum/rpc directly):
#   start proto=sign role=client [service=...]
#   write <content-to-sign>
#   read  -> certtostr(cert), in one or more chunks
#   read  -> done
# The certificate can exceed AuthRpcMax (mldsa87 ~6KB), so it is sent in
# <=CHUNK pieces; the caller concatenates until the read returns done.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "../authio.m";
	authio:	Authio;
	Attr, IO, Key: import authio;

# Must stay under AuthRpcMax (4096) minus the 3-byte framing margin that
# IO.write reserves; 4000 leaves comfortable headroom.
CHUNK: con 4000;

init(f: Authio): string
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return sys->sprint("cannot load keyring: %r");
	authio = f;
	return nil;
}

interaction(attrs: list of ref Attr, io: ref IO): string
{
	(key, err) := io.findkey(attrs, "!sk?");
	if(key == nil)
		return err;
	skenc := authio->lookattrval(key.secrets, "!sk");
	if(skenc == nil)
		return "audit signer key has no !sk";
	sk := kr->strtosk(decode(skenc));
	if(sk == nil)
		return "audit signer key !sk does not parse";

	# op=pubkey returns the public key (not a secret); the default op
	# signs caller-supplied content. The private key is used either way
	# but never leaves factotum.
	if(authio->lookattrval(attrs, "op") == "pubkey"){
		send(io, array of byte kr->pktostr(kr->sktopk(sk)));
		io.done(nil);
		return nil;
	}

	# the caller writes the bytes to sign
	content := io.read();
	if(content == nil || len content == 0)
		return "no content to sign";

	state := kr->sha256(content, len content, nil, nil);
	cert := kr->sign(sk, 0, state, "sha256");
	if(cert == nil)
		return "sign failed";
	send(io, array of byte kr->certtostr(cert));
	io.done(nil);
	return nil;
}

# send writes a (possibly large) result to the caller in <=CHUNK pieces,
# since a result can exceed the RPC frame (an mldsa87 cert is ~6KB).
send(io: ref IO, b: array of byte)
{
	for(off := 0; off < len b; off += CHUNK){
		end := off + CHUNK;
		if(end > len b)
			end = len b;
		io.write(b[off:end], end-off);
	}
}

keycheck(nil: ref Key): string
{
	return nil;
}

# decode reverses mkauditkey's single-line encoding of sktostr: '@' back
# to newline and '~' back to base64 padding '='. (See the header note.)
decode(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'@' =>	c = '\n';
		'~' =>	c = '=';
		}
		r[len r] = c;
	}
	return r;
}
