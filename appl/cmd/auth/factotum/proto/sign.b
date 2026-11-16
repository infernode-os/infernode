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
# The service is named, and the op is absent or "pubkey": with no service
# the first signing key there was signed, and any other op signed too.
#
# A certificate made here is a signature over what the caller wrote and
# nothing else, but in bytes it is a Keyring certificate, which is also
# what vouches for a public key in Inferno's authentication (the content
# then being the key's text). So that one made here is never one of
# those, it is given an expiry time of Signexp, a moment in 1970: the
# time is under the signature (keyring-auth(2): the signer's name and
# the expiry time are hashed after the content), and everything that
# takes a certificate as a credential refuses an expired one. A verifier
# of signatures (auditverify) does not look at the time, so certificates
# made with expiry 0 before this and those made now verify alike.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";

include "../authio.m";
	authio:	Authio;
	Attr, IO, Key: import authio;

Signexp: con 1;	# expiry time of every certificate made here

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

# CNSA 2.0: bind the certificate hash to the signing key's strength.
# ML-DSA / SLH-DSA (FIPS 204/205, NIST Cat >=3) keys pair with SHA-384;
# classical keys keep SHA-256 so pre-existing certs verify unchanged. The
# chosen name is stored in the certificate, so any verifier re-hashes to match.
certhash(sk: ref Keyring->SK): string
{
	if(sk != nil && sk.sa != nil)
		case sk.sa.name {
		"mldsa65" or "mldsa87" or "slhdsa192s" or "slhdsa256s" =>
			return "sha384";
		}
	return "sha256";
}

certdigest(sk: ref Keyring->SK, buf: array of byte): ref Keyring->DigestState
{
	if(certhash(sk) == "sha384")
		return kr->sha384(buf, len buf, nil, nil);
	return kr->sha256(buf, len buf, nil, nil);
}

# keyattrs strips the verb attribute (op=...) from the start attrs
# before key lookup: op selects the operation, not the key, and no
# stored key carries it — left in, findkey can never match. (This was
# exactly the op=pubkey failure: signing worked, /mnt/audit/pubkey
# always came back empty.)
keyattrs(attrs: list of ref Attr): list of ref Attr
{
	r: list of ref Attr;
	for(; attrs != nil; attrs = tl attrs)
		if((hd attrs).name != "op")
			r = hd attrs :: r;
	return r;
}

interaction(attrs: list of ref Attr, io: ref IO): string
{
	op := authio->lookattrval(attrs, "op");
	if(op != nil && op != "pubkey")
		return "sign: unknown op "+op;
	if(authio->lookattrval(attrs, "service") == nil)
		return "sign: no service named";
	(key, err) := io.findkey(keyattrs(attrs), "!sk?");
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
	if(op == "pubkey"){
		send(io, array of byte kr->pktostr(kr->sktopk(sk)));
		io.done(nil);
		return nil;
	}

	# In CNSA mode (/env/cnsamode) a signature is ML-DSA-87's or is
	# not made: a key of another algorithm, stored before the mode was
	# set, signed all the same.
	if((cerr := cnsarefuses(sk.sa.name)) != nil)
		return "sign: " + cerr;

	# the caller writes the bytes to sign
	content := io.read();
	if(content == nil || len content == 0)
		return "no content to sign";

	state := certdigest(sk, content);
	cert := kr->sign(sk, Signexp, state, certhash(sk));
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

# A signing key names its service (a query must) and holds a secret
# key that reads as one.
keycheck(k: ref Key): string
{
	if(authio->lookattrval(k.attrs, "service") == nil)
		return "a sign key needs service=";
	skenc := authio->lookattrval(k.secrets, "!sk");
	if(skenc == nil)
		return "a sign key needs !sk=";
	if(kr->strtosk(decode(skenc)) == nil)
		return "a sign key's !sk does not read as a secret key";
	return nil;
}

cnsarefuses(alg: string): string
{
	login := load Login Login->PATH;
	if(login == nil || !login->cnsamode())
		return nil;
	return login->cnsaalg(alg);
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
