implement Factotum, Authio;

#
# Copyright © 2003-2004 Vita Nuova Holdings Limited
#

include "sys.m";
	sys: Sys;
	Rread, Rwrite: import Sys;

include "draw.m";

include "string.m";
	str: String;

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "dial.m";

include "security.m";
	random: Random;

include "secstore.m";
	secstore: Secstore;

include "authio.m";

include "arg.m";

include "readdir.m";

include "audit.m";
	audit: Audit;

Factotum: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

#confirm, log

Files: adt {
	ctl:	ref Sys->FileIO;
	rpc:	ref Sys->FileIO;
	proto:	ref Sys->FileIO;
	needkey:	ref Sys->FileIO;
	secstore:	ref Sys->FileIO;
};

Debug: con 0;
debug := Debug;

files: Files;
authio: Authio;

keymanc: chan of (list of ref Attr, int, chan of (list of ref Key, string));
allkeys: array of ref Key;

# Persistence
#
# The key file: magic, nonce, AES-256-GCM of the keys (the magic its
# associated data), tag.  FKEY2's key is PBKDF2 with HMAC-SHA-384 of the
# password, salted with "factotum keyfile 2", a zero byte and the user's
# name, 200000 iterations, its first 32 bytes; FKEY1's was 10000 rounds
# of HMAC-SHA256 under a salt fixed for everyone, which is not CNSA 2.0's
# hash.  An FKEY1 file is read, and written again as FKEY2 at once.
#
KEYFILE_MAGIC: con "FKEY2\n";
KEYFILE_MAGIC1: con "FKEY1\n";
KEYFILE_KDF_ROUNDS: con 10000;
KEYFILE_ITER: con 200000;
AES_GCM_NONCE_LEN: con 12;
AES_GCM_TAG_LEN: con 16;

keyfilepath: string;
keyfilepass: array of byte;	# derived key, not raw password (FKEY2's)
keyfilepass1: array of byte;	# FKEY1's, until an FKEY1 file has been read and written again
Maxkeyfile: con 16*1024*1024;	# the most a key file may be
dirtyc: chan of int;		# signal dirty state to persist thread
syncc: chan of chan of string;	# request sync, reply with persistence error

# Secstore persistence
secstoreaddr: string;		# secstore server address (e.g. "net!localhost!secstore")
secstoreuser: string;		# username for secstore auth
secstorecreds: ref Secstore->Creds;	# every key the password gives (secstore(2) mkcreds)
keysc: chan of (string, array of byte);	# a secstore password (and data key) for persist to make the keys of
keyspending: int;	# a password given, its keys not yet made: saving is arranged all the same
keysvault: int;	# and with a data key
secstorerootkey: array of byte;	# the root the files are written under: root6, or a second-factor account's data key
secstorevault: array of byte;	# a second-factor account's vault key, shown before a save

# Cached secstore connection — avoids full PAK handshake on every save
secstoreconn: ref Dial->Connection;
secstoreconntime: int;		# when connection was established (seconds since epoch)
SECSTORE_CONN_TTL: con 300;	# 5 minute TTL

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	authio = load Authio "$self";

	# Optional: emit credential-lifecycle events to the tamper-evident
	# audit log (AU-2). Loosely coupled — a no-op if auditfs is not
	# mounted, and never holds or logs key material (see auditkey()).
	audit = load Audit Audit->PATH;
	if(audit != nil)
		audit->init();

	svcname := "#sfactotum";
	mntpt := "/mnt/factotum";
	keyfilepassarg: string;
	secstorepassarg: string;
	arg := load Arg Arg->PATH;
	if(arg != nil){
		arg->init(args);
		arg->setusage("auth/factotum [-d] [-f keyfile] [-p password] [-S addr] [-P secpass] [-u user] [-m /mnt/factotum] [-s factotum]");
		while((o := arg->opt()) != 0)
			case o {
			'd' =>	debug++;
			'f' =>	keyfilepath = arg->earg();
			'p' =>	keyfilepassarg = arg->earg();
			'S' =>	secstoreaddr = arg->earg();
			'P' =>	secstorepassarg = arg->earg();
			'u' =>	secstoreuser = arg->earg();
			'm' =>	mntpt = arg->earg();
			's' =>		svcname = "#s"+arg->earg();
			* =>	arg->usage();
			}
		args = arg->argv();
		if(args != nil)
			arg->usage();
		arg = nil;
	}

	# -S (secstore) takes precedence over -f (local keyfile)
	if(secstoreaddr != nil){
		kr = load Keyring Keyring->PATH;
		if(kr == nil)
			err("cannot load Keyring");
		random = load Random Random->PATH;
		if(random == nil)
			err("cannot load Random");
		secstore = load Secstore Secstore->PATH;
		if(secstore == nil)
			err("cannot load Secstore");
		secstore->init();
		if(secstoreuser == nil)
			secstoreuser = user();
		if(secstorepassarg != nil){
			setsecstorekeys(secstorepassarg, nil);
			secstorepassarg = nil;
		}
	} else if(keyfilepath != nil){
		kr = load Keyring Keyring->PATH;
		if(kr == nil)
			err("cannot load Keyring");
		random = load Random Random->PATH;
		if(random == nil)
			err("cannot load Random");
		if(keyfilepassarg != nil){
			setkeyfilepass(keyfilepassarg);
			keyfilepassarg = nil;
		}
	}
	sys->unmount(nil, mntpt);
	if(sys->bind(svcname, mntpt, Sys->MREPL) < 0)
		err(sys->sprint("can't bind %s on %s: %r", svcname, mntpt));
	files.ctl = sys->file2chan(mntpt, "ctl");
	files.rpc = sys->file2chan(mntpt, "rpc");
	files.proto = sys->file2chan(mntpt, "proto");
	files.needkey = sys->file2chan(mntpt, "needkey");
	files.secstore = sys->file2chan(mntpt, "secstore");
	if(files.ctl == nil || files.rpc == nil || files.proto == nil || files.needkey == nil || files.secstore == nil)
		err(sys->sprint("can't create %s/*: %r", mntpt));
	keymanc = chan of (list of ref Attr, int, chan of (list of ref Key, string));
	spawn factotumsrv();
}

# The keys a secstore password gives (secstore(2)'s mkcreds: the PAK
# hashes of each verifier version, the old and version 6 roots), and the
# root the files are written under, version 6's.  dk, when given, is a
# second-factor account's data key: the files are under it, and its
# vault key is shown to the server before each save.
setsecstorekeys(pass: string, dk: array of byte)
{
	secstore->erasecreds(secstorecreds);
	secstorecreds = secstore->mkcreds(secstoreuser, pass);
	if(dk != nil){
		secstorerootkey = dk;
		secstorevault = secstore->vaultkey(dk);
	}else{
		secstorerootkey = secstorecreds.root6;
		secstorevault = nil;
	}
}

hexdig(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

# Decode a 64-hex-char (32-byte) data key, or nil if malformed. Lets a 2FA
# account encrypt its secstore save-back under the data key (see logon.b).
unhexkey(s: string): array of byte
{
	if(len s != 64)
		return nil;
	a := array[32] of byte;
	for(i := 0; i < 32; i++){
		hi := hexdig(s[2*i]);
		lo := hexdig(s[2*i+1]);
		if(hi < 0 || lo < 0)
			return nil;
		a[i] = byte((hi << 4) | lo);
	}
	return a;
}

user(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

err(s: string)
{
	sys->fprint(sys->fildes(2), "factotum: %s\n", s);
	raise "fail:error";
}

rlist: list of ref Fid;
Maxrpc: con 16;

factotumsrv()
{
	sys->pctl(Sys->NEWPGRP|Sys->FORKFD|Sys->FORKENV, nil);
	if(debug == 0)
		privacy();
	allkeys = array[0] of ref Key;
	pidc := chan of int;
	donec := chan of ref Fid;
	keysc = chan[1] of (string, array of byte);

	# Load keys from secstore or encrypted keyfile
	if(secstoreaddr != nil){
		dirtyc = chan[1] of int;	# one change is always remembered, whatever persist is doing
		syncc = chan of chan of string;
		e := secstoreload();
		# the load moved what was in an old form: the old forms' keys
		# and the password are not kept for the saves
		secstore->forgetold(secstorecreds);
		if(e != nil){
			# Go on with no keys, but save none either: the keys in
			# the store were not read, and the first key added
			# here was then saved over them.
			nosave = "the keys in secstore could not be read when factotum started (" + e + ")";
			sys->fprint(sys->fildes(2), "factotum: secstore: %s; nothing will be saved there\n", e);
		}
		spawn persist();
	} else if(keyfilepath != nil){
		dirtyc = chan[1] of int;	# one change is always remembered, whatever persist is doing
		syncc = chan of chan of string;
		e := loadkeyfile(keyfilepath);
		if(e != nil && debug)
			sys->fprint(sys->fildes(2), "factotum: keyfile: %s\n", e);
		spawn persist();
	}
#	keyc := chan of (list of ref Attr, chan of (ref Key, string));
	needfid := -1;
	needed, needy: list of (int, list of ref Attr, chan of (list of ref Key, string));
	needread: Sys->Rread;
	needtag := 0;
	for(;;) X: alt{
	r := <-donec =>
		r.pid = 0;
		cleanfid(r.fid);

	(off, nbytes, nil, rc) := <-files.ctl.read =>
		if(rc == nil)
			break;
		s := "";
		for(i := 0; i < len allkeys; i++)
			if((k := allkeys[i]) != nil)
				s += k.safetext()+"\n";
		rc <-= reads(s, off, nbytes);
	(nil, data, nil, wc) := <-files.ctl.write =>
		if(wc == nil)
			break;
		(nf, flds) := sys->tokenize(string data, "\n\r");
		if(nf > 1){
			# compatibility with plan 9; has the advantage you can tell which key is wrong
			wc <-= (0, "multiline write not allowed");
			break;
		}
		if(flds == nil || (hd flds)[0] == '#'){
			wc <-= (len data, nil);
			break;
		}
		s := hd flds;
		for(i := 0; i < len s && s[i] != ' '; i++){
			# skip
		}
		verb := s[0:i];
		if(i < len s)
			i++;
		s = s[i:];
		case verb {
		"key" =>
			k := Key.mk(parseline(s));
			if(k == nil){
				wc <-= (len data, nil);	# ignore it
				break;
			}
			if(lookattrval(k.attrs, "proto") == nil){
				wc <-= (0, "key without proto");
				break;
			}
			# keys are kept a line each
			if(hasnewline(k.attrs)){
				wc <-= (0, "key with a line break in it");
				break;
			}
			# its protocol's own check: a key the protocol could
			# never use (a link key that is not sixteen bytes, a
			# passphrase WPA does not take) is refused when it is
			# stored, not found out when it is wanted.  Every
			# module has a keycheck, and none was ever called.
			if((kerr := keycheck(k)) != nil){
				wc <-= (0, kerr);
				break;
			}
			allkeys = addkey(allkeys, k);
			auditkey("keyadd", k.safetext());
			wc <-= (len data, nil);
			if(dirtyc != nil)
				alt { dirtyc <-= 1 => ; * => ; }
		"genkey" =>
			# Generate a key inside factotum (e.g. the audit signer).
			# The private key is born here and never crosses the wire,
			# which is how a large PQC signing key is provisioned: an
			# mldsa87 key line is ~10KB, over the ctl write frame. The
			# generation directives alg= (default mldsa87) and owner=
			# (default audit) are consumed; the remaining attrs (e.g.
			# proto=sign service=audit) become the stored key, with the
			# secret key added as a single-line, '='-free !sk.
			gattrs := parseline(s);
			if(lookattrval(gattrs, "proto") == nil){
				wc <-= (0, "genkey without proto");
				break;
			}
			if(kr == nil)
				kr = load Keyring Keyring->PATH;
			if(kr == nil){
				wc <-= (0, "genkey: cannot load keyring");
				break;
			}
			galg := lookattrval(gattrs, "alg");
			if(galg == nil)
				galg = "mldsa87";
			# CNSA mode is a rule for every key made in it
			if((cerr := cnsarefuses(galg)) != nil){
				wc <-= (0, "genkey: " + cerr);
				break;
			}
			gowner := lookattrval(gattrs, "owner");
			if(gowner == nil)
				gowner = "audit";
			gsk := kr->genSK(galg, gowner, 0);
			if(gsk == nil){
				wc <-= (0, "genkey: cannot generate key (algorithm configured?)");
				break;
			}
			gka: list of ref Attr;
			for(gl := gattrs; gl != nil; gl = tl gl)
				if((hd gl).name != "alg")
					gka = hd gl :: gka;
			gka = ref Attr(Aval, "!sk", encodesk(kr->sktostr(gsk))) :: gka;
			gk := Key.mk(gka);
			if((gerr := keycheck(gk)) != nil){
				wc <-= (0, "genkey: " + gerr);
				break;
			}
			allkeys = addkey(allkeys, gk);
			auditkey("keygen", gk.safetext());
			wc <-= (len data, nil);
			if(dirtyc != nil)
				alt { dirtyc <-= 1 => ; * => ; }
		"delkey" =>
			attrs := parseline(s);
			for(al := attrs; al != nil; al = tl al){
				a := hd al;
				if(a.name[0] == '!' && (a.val != nil || a.tag != Aquery)){
					wc <-= (0, "cannot specify values for private fields");
					break X;
				}
			}
			if(delkey(allkeys, attrs) == 0)
				wc <-= (0, "no matching keys");
			else{
				auditkey("keydel", attrtext(attrs));
				wc <-= (len data, nil);
				if(dirtyc != nil)
					alt { dirtyc <-= 1 => ; * => ; }
			}
		"sync" =>
			serr: string;
			if(syncc != nil){
				rc := chan of string;
				syncc <-= rc;
				serr = <-rc;
			}
			else
				serr = "no persistence backend configured";
			if(serr != nil)
				wc <-= (0, "sync: " + serr);
			else
				wc <-= (len data, nil);
		"secstore" or "secstoreq" =>
			# ctl line: "secstore addr user password [datakey]", its
			# fields parted by blanks; or "secstoreq ...", the same
			# with the fields quoted as %q writes them, for a
			# password with a blank or a quote in it (cut at its
			# first blank, such an account logged in and then saved
			# nothing: the save's password was not the account's)
			stoks: list of string;
			if(verb == "secstoreq")
				stoks = str->unquoted(s);
			else
				(nil, stoks) = sys->tokenize(s, " \t");
			if(len stoks < 3){
				wc <-= (0, "usage: secstore addr user password [datakey]");
				break;
			}
			saddr := hd stoks; stoks = tl stoks;
			suser := hd stoks; stoks = tl stoks;
			spass := hd stoks; stoks = tl stoks;
			sdk := "";			# optional data key (hex): 2FA save-back encryption
			if(stoks != nil)
				sdk = hd stoks;
			secstoreaddr = saddr;
			secstoreuser = suser;
			if(secstore == nil){
				secstore = load Secstore Secstore->PATH;
				if(secstore == nil)
					sys->fprint(sys->fildes(2), "factotum: cannot load secstore: %r\n");
				else
					secstore->init();
			}
			if(kr == nil)
				kr = load Keyring Keyring->PATH;
			if(random == nil)
				random = load Random Random->PATH;
			if(secstore == nil){
				wc <-= (0, "cannot load secstore module");
				break;
			}
			if(sdk != "" && unhexkey(sdk) == nil){
				wc <-= (0, "the data key is 64 hexadecimal digits");
				break;
			}
			# 2FA: encrypt save-back under the data key (auth still uses the
			# password); ordinary accounts use the password-derived root key.
			# The keys are made by persist, which alone saves: made
			# here, the serving loop answered nothing for the 0.4 s
			# PBKDF2 takes (the login screen's own unlock waited on
			# it, and every reader of ctl, after making the same keys
			# itself).  A save asked for meanwhile waits for them.
			secstorecreds = nil;
			# whoever configured this read the store itself (the
			# login screen): what a failed load at start forbade
			# is allowed again
			nosave = nil;
			# Start persist thread if not already running
			if(dirtyc == nil){
				dirtyc = chan[1] of int;	# one change is always remembered, whatever persist is doing
				syncc = chan of chan of string;
				spawn persist();
			}
			keyspending = 1;
			keysvault = sdk != "";
			keysc <-= (spass, unhexkey(sdk));
			spass = nil;
			sdk = nil;
			wc <-= (len data, nil);
			sys->fprint(sys->fildes(2), "factotum: secstore configured: %s user=%s\n",
				saddr, suser);
		"debug" =>
			wc <-= (len data, nil);
		* =>
			wc <-= (0, "unknown verb");
		}

	(nil, nbytes, fid, rc) := <-files.rpc.read =>
		if(rc == nil)
			break;
		r := findfid(fid);
		if(r == nil){
			rc <-= (nil, "no rpc pending");
			break;
		}
		alt{
		r.read <-= (nbytes, rc) =>
			;
		* =>
			rc <-= (nil, "concurrent rpc read not allowed");
		}
	(nil, data, fid, wc) := <-files.rpc.write =>
		if(wc == nil){
			cleanfid(fid);
			break;
		}
		r := findfid(fid);
		if(r == nil){
			if(len rlist >= Maxrpc){
				wc <-= (-1, "too much activity");
				break;
			}
			r = ref Fid(fid, 0, nil, nil, chan[1] of (array of byte, Rwrite), chan[1] of (int, Rread), 0, nil);
			spawn request(r, pidc, donec);
			r.pid = <-pidc;
			rlist = r :: rlist;
		}
		# this non-blocking write avoids a potential deadlock situation that
		# can happen when a proto module calls findkey at the same time
		# a client tries to write to the rpc file. this might not be the correct fix!
		alt{
		r.write <-= (data, wc) =>
			;
		* =>
			wc <-= (-1, "concurrent rpc write not allowed");
		}

	(off, nbytes, nil, rc) := <-files.proto.read =>
		if(rc == nil)
			break;
		rc <-= reads(readprotos(), off, nbytes);
	(nil, nil, nil, wc) := <-files.proto.write =>
		if(wc != nil)
			wc <-= (0, "illegal operation");

	# Where the keys are kept, from the one program that knows: a
	# file in /tmp said "secstore is unlocked", made by whoever liked
	# and left there from boot to boot.
	(off, nbytes, nil, rc) := <-files.secstore.read =>
		if(rc == nil)
			break;
		rc <-= reads(savestatus(), off, nbytes);
	(nil, nil, nil, wc) := <-files.secstore.write =>
		if(wc != nil)
			wc <-= (0, "illegal operation");

	(nil, nil, fid, rc) := <-files.needkey.read =>
		if(rc == nil)
			break;
		if(needfid >= 0 && fid != needfid){
			rc <-= (nil, "file in use");
			break;
		}
		needfid = fid;
		if(needy != nil){
			(tag, attr, kc) := hd needy;
			needy = tl needy;
			needed = (tag, attr, kc) :: needed;
			rc <-= (sys->aprint("needkey tag=%ud %s", tag, attrtext(attr)), nil);
			break;
		}
		if(needread != nil){
			rc <-= (nil, "already reading");
			break;
		}
		needread = rc;
	(nil, data, fid, wc) := <-files.needkey.write =>
		if(wc == nil){
			if(needfid == fid){
				needfid = -1;	# TO DO? give needkey errors back to request
				needread = nil;
			}
			break;
		}
		if(needfid >= 0 && fid != needfid){
			wc <-= (0, "file in use");
			break;
		}
		needfid = fid;
		tagline := parseline(string data);
		if(len tagline != 1 || (t := lookattrval(tagline, "tag")) == nil){
			wc <-= (0, "no tag");
			break;
		}
		tag := int t;
		nl: list of (int, list of ref Attr, chan of (list of ref Key, string));
		found := 0;
		for(l := needed; l != nil; l = tl l){
			(ntag, attrs, kc) := hd l;
			if(tag == ntag){
				found = 1;
				k := findkey(allkeys, attrs);
				# never wait for the asker: it is waiting for this,
				# or it has gone (its fid clunked, its proc killed),
				# and a send to one that had gone stopped this
				# loop, and every file it serves, for good
				reply: (list of ref Key, string);
				if(k != nil)
					reply = (k :: nil, nil);
				else
					reply = (nil, "needkey "+attrtext(attrs));
				alt{
				kc <-= reply =>
					;
				* =>
					;
				}
				while((l = tl l) != nil)
					nl = hd l :: nl;
				break;
			}
			nl = hd l :: nl;
		}
		if(found){
			# answered, so no longer needed: the list without it was
			# made and never kept, and the tag answered again sent
			# to an asker no longer waiting
			needed = nl;
			wc <-= (len data, nil);
		}else
			wc <-= (0, "tag not found");

	(attrs, required, kc) := <-keymanc =>
		# look for key and reply
		kl := findkeys(allkeys, attrs);
		if(kl != nil){
			kc <-= (kl, nil);
			break;
		}else if(!required || needfid == -1){
			kc <-= (nil, "needkey "+attrtext(attrs));
			break;
		}
		# query surrounding environment using needkey
		if(needread != nil){
			needed = (needtag, attrs, kc) :: needed;
			needread <-= (sys->aprint("needkey tag=%ud %s", needtag, attrtext(attrs)), nil);
			needread = nil;
			needtag++;
		}else
			needy = (needtag++, attrs, kc) :: needy;
	}
}

findfid(fid: int): ref Fid
{
	for(rl := rlist; rl != nil; rl = tl rl){
		r := hd rl;
		if(r.fid == fid)
			return r;
	}
	return nil;
}

cleanfid(fid: int)
{
	rl := rlist;
	rlist = nil;
	for(; rl != nil; rl = tl rl){
		r := hd rl;
		if(r.fid != fid)
			rlist = r :: rlist;
		else if(r.pid)
			kill(r.pid);
	}
}

kill(pid: int)
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

privacy()
{
	fd := sys->open("#p/"+string sys->pctl(0, nil)+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "private") < 0)
		sys->fprint(sys->fildes(2), "factotum: warning: unable to make memory private: %r\n");
}

reads(str: string, off, nbytes: int): (array of byte, string)
{
	bstr := array of byte str;
	slen := len bstr;
	if(off < 0 || off >= slen)
		return (nil, nil);
	if(off + nbytes > slen)
		nbytes = slen - off;
	if(nbytes <= 0)
		return (nil, nil);
	return (bstr[off:off+nbytes], nil);
}

readprotos(): string
{
	readdir := load Readdir Readdir->PATH;
	if(readdir == nil)
		return "unknown\n";
	(dirs, nil) := readdir->init("/dis/auth/proto", Readdir->NAME|Readdir->COMPACT);
	s := "";
	for(i := 0; i < len dirs; i++){
		n := dirs[i].name;
		if(len n > 4 && n[len n-4:] == ".dis")
			s += n[0: len n-4]+"\n";
	}
	return s;
}

Ogok, Ostart, Oread, Owrite, Oauthinfo, Oattr: con iota;

ops := array[] of {
	(Ostart, "start"),
	(Oread, "read"),
	(Owrite, "write"),
	(Oauthinfo, "authinfo"),
	(Oattr, "attr"),
};

request(r: ref Fid, pidc: chan of int, donec: chan of ref Fid)
{
	pidc <-= sys->pctl(0, nil);
	rpc := rio(r);
	while(rpc != nil){
		if(rpc.cmd == Ostart){
			(proto, attrs, e) := startproto(string rpc.arg);
			if(e != nil){
				reply(rpc, "error "+e);
				rpc = rio(r);
				continue;
			}
			r.attrs = attrs;	# saved for attr request
			ok(rpc);
			io := ref IO(r, nil);
			{
				err := proto->interaction(attrs, io);
				if(debug && err != nil)
					sys->fprint(sys->fildes(2), "factotum: failure: %s\n", err);
				if(r.err == nil)
					r.err = err;
				r.done = 1;
			}exception ex{
			"*" =>
				r.done = 0;
				r.err = "exception "+ex;
			}
			if(r.err != nil)
				io.error(r.err);
			rpc = finish(r);
			r.attrs = nil;
			r.err = nil;
			r.done = 0;
			r.ai = nil;
		}else
			reply(rpc, "no current protocol");
	}
	flushreq(r, donec);
}

startproto(request: string): (Authproto, list of ref Attr, string)
{
	attrs := parseline(request);
	if(debug > 1)
		sys->print("-> %s <-\n", attrtext(attrs));
	p := lookattrval(attrs, "proto");
	if(p == nil)
		return (nil, nil, "did not specify protocol");
	if(debug > 1)
		sys->print("proto=%s\n", p);
	if(any(p, "./"))	# avoid unpleasantness
		return (nil, nil, "illegal protocol: "+p);
	# A secret attribute with a value in the request is a guess at
	# one: every attribute is a pattern, the secret ones too, so
	# "start proto=pass ... !password=guess" found a key when the
	# guess was right and "needkey" when it was not, for whoever can
	# open rpc.  delkey has always refused it; start refuses it for
	# every protocol (wpapsk alone did).
	for(al := attrs; al != nil; al = tl al){
		a := hd al;
		if(len a.name > 0 && a.name[0] == '!' && (a.val != nil || a.tag != Aquery))
			return (nil, nil, "cannot specify values for private fields");
	}
	# Plan 9's p9sk1, whose tickets are DES: with DES gone from the
	# system it could only fail, somewhere in the middle, with "module
	# not loaded".  Whoever asks for it is told why rather than that a
	# file is missing.  p9any is 9front's, and offers dp9ik alone
	# (proto/p9any.b).
	if(p == "p9sk1")
		return (nil, nil, "Plan 9's p9sk1 authentication is not available: it needs DES, which this system no longer has; 9front's dp9ik is (proto=p9any or proto=dp9ik)");
	proto := load Authproto "/dis/auth/proto/"+p+".dis";
	if(proto == nil)
		return (nil, nil, sys->sprint("protocol %s: %r", p));
	if(debug)
		sys->print("start %s\n", p);
	e: string;
	{
		e = proto->init(authio);
	}exception ex{
	"*" =>
		e = "exception "+ex;
	}
	if(e != nil)
		return (nil, nil, e);
	return (proto, attrs, nil);
}

finish(r: ref Fid): ref Rpc
{
	while((rpc := rio(r)) != nil)
		case rpc.cmd {
		Owrite =>
			phase(rpc, "protocol phase error");
		Oread =>
			if(r.err != nil)
				reply(rpc, "error "+r.err);
			else
				done(rpc, r.ai);
		Oauthinfo =>
			if(r.done){
				if(r.ai == nil)
					reply(rpc, "error no authinfo available");
				else{
					a := packai(r.ai);
					if(a == nil)
						reply(rpc, "error authinfo too large");
					else if(rpc.nbytes-3 < len a)
						reply(rpc, sys->sprint("toosmall %d", len a + 3));
					else
						okdata(rpc, a);
				}
			}else
				reply(rpc, "error authentication unfinished");
		Ostart =>
			return rpc;
		* =>
			reply(rpc, "error unexpected request");
		}
	return nil;
}

flushreq(r: ref Fid, donec: chan of ref Fid)
{
	for(;;) alt{
	donec <-= r =>
		exit;
	(nil, wc) := <-r.write =>
		wc <-= (0, "write rpc protocol error");
	(nil, rc) := <-r.read =>
		rc <-= (nil, "read rpc protocol error");
	}
}

rio(r: ref Fid): ref Rpc
{
	req: array of byte;
	for(;;) alt{
	(data, wc) := <-r.write =>
		if(req != nil){
			wc <-= (0, "rpc pending; read to clear");
			break;
		}
		req = data;
		wc <-= (len data, nil);

	(nbytes, rc) := <-r.read =>
		if(req == nil){
			rc <-= (nil, "no rpc pending");
			break;
		}
		(cmd, arg) := op(req, ops);
		req = nil;
		rpc := ref Rpc(r, cmd, arg, nbytes, rc);
		case cmd {
		Ogok =>
			reply(rpc, "error unknown rpc");
			break;
		Oattr =>
			if(r.attrs == nil)
				reply(rpc, "error no attributes");
			else
				reply(rpc, "ok "+attrtext(r.attrs));
			break;
		* =>
			return rpc;
		}
	}
}

ok(rpc: ref Rpc)
{
	reply(rpc, "ok");
}

okdata(rpc: ref Rpc, a: array of byte)
{
	b := array[len a + 3] of byte;
	b[0] = byte 'o';
	b[1] = byte 'k';
	b[2] = byte ' ';
	b[3:] = a;
	rpc.rc <-= (b, nil);
}

done(rpc: ref Rpc, ai: ref Authinfo)
{
	rpc.r.ai = ai;
	rpc.r.done = 1;
	if(ai != nil)
		reply(rpc, "done haveai");
	else
		reply(rpc, "done");
}

phase(rpc: ref Rpc, s: string)
{
	reply(rpc, "phase "+s);
}

needkey(rpc: ref Rpc, attrs: list of ref Attr)
{
	reply(rpc, "needkey "+attrtext(attrs));
}

reply(rpc: ref Rpc, s: string)
{
	rpc.rc <-= reads(s, 0, rpc.nbytes);
}

puta(a: array of byte, n: int, v: array of byte): int
{
	if(n < 0)
		return -1;
	c := len v;
	if(n+2+c > len a)
		return -1;
	a[n++] = byte c;
	a[n++] = byte (c>>8);
	a[n:] = v;
	return n + len v;
}

packai(ai: ref Authinfo): array of byte
{
	# as long as what goes in it: it was 1024 bytes, and information
	# that did not fit was answered "ok" with nothing
	a := array[4*2 + len array of byte ai.cuid + len array of byte ai.suid + len array of byte ai.cap + len ai.secret] of byte;
	i := puta(a, 0, array of byte ai.cuid);
	i = puta(a, i, array of byte ai.suid);
	i = puta(a, i, array of byte ai.cap);
	i = puta(a, i, ai.secret);
	if(i < 0)
		return nil;
	return a[0:i];
}

op(a: array of byte, ops: array of (int, string)): (int, array of byte)
{
	arg: array of byte;
	for(i := 0; i < len a; i++)
		if(a[i] == byte ' '){
			if(i+1 < len a)
				arg = a[i+1:];
			break;
		}
	s := string a[0:i];
	for(i = 0; i < len ops; i++){
		(cmd, name) := ops[i];
		if(s == name)
			return (cmd, arg);
	}
	return (Ogok, arg);
}

parseline(s: string): list of ref Attr
{
	fld := str->unquoted(s);
	rfld := fld;
	for(fld = nil; rfld != nil; rfld = tl rfld)
		fld = (hd rfld) :: fld;
	attrs: list of ref Attr;
	for(; fld != nil; fld = tl fld){
		n := hd fld;
		a := "";
		tag := Aattr;
		for(i:=0; i<len n; i++)
			if(n[i] == '='){
				a = n[i+1:];
				n = n[0:i];
				tag = Aval;
			}
		if(len n == 0)
			continue;
		if(tag == Aattr && len n > 1 && n[len n-1] == '?'){
			tag = Aquery;
			n = n[0:len n-1];
		}
		attrs = ref Attr(tag, n, a) :: attrs;
	}
	return attrs;
}

# whether an attribute's name or value would end a key's line
hasnewline(attrs: list of ref Attr): int
{
	for(; attrs != nil; attrs = tl attrs){
		a := hd attrs;
		t := a.name + a.val;
		for(i := 0; i < len t; i++)
			if(t[i] == '\n' || t[i] == '\r')
				return 1;
	}
	return 0;
}

Attr.text(a: self ref Attr): string
{
	case a.tag {
	Aattr =>
		return a.name;
	Aval =>
		# quoted where it must be: a value with a blank in it was
		# written bare, and read back as a value and more attributes
		return a.name+"="+sys->sprint("%q", a.val);
	Aquery =>
		return a.name+"?";
	* =>
		return "??";
	}
}

attrtext(attrs: list of ref Attr): string
{
	s := "";
	sp := 0;
	for(; attrs != nil; attrs = tl attrs){
		if(sp)
			s[len s] = ' ';
		sp = 1;
		s += (hd attrs).text();
	}
	return s;
}

# auditkey seals one credential-lifecycle event (AU-2). The descriptor
# must carry only public attributes — never a secret value. Key.safetext
# redacts secrets to "name?", and delkey patterns reject private fields,
# so both call sites are safe. A no-op when auditfs is not mounted.
auditkey(event, descr: string)
{
	if(audit != nil)
		audit->log("factotum", event, descr);
}

# encodesk maps sktostr's newlines to '@' and base64 padding '=' to '~',
# so a generated secret key stores as a single-line, '='-free value (the
# sign proto reverses it). Neither '@' nor '~' occurs in base64 or the
# alg/owner names. Must match proto/sign.b decode and mkauditkey/test.
encodesk(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'\n' =>	c = '@';
		'=' =>	c = '~';
		}
		r[len r] = c;
	}
	return r;
}

lookattr(attrs: list of ref Attr, n: string): ref Attr
{
	for(; attrs != nil; attrs = tl attrs)
		if((a := hd attrs).tag != Aquery && a.name == n)
			return a;
	return nil;
}

lookattrval(attrs: list of ref Attr, n: string): string
{
	if((a := lookattr(attrs, n)) != nil)
		return a.val;
	return nil;
}

anyattr(attrs: list of ref Attr, n: string): ref Attr
{
	for(; attrs != nil; attrs = tl attrs)
		if((a := hd attrs).name == n)
			return a;
	return nil;
}

reverse[T](l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

setattrs(lv: list of ref Attr, rv: list of ref Attr): list of ref Attr
{
	# new attributes
	nl: list of ref Attr;
	for(rl := rv; rl != nil; rl = tl rl)
		if(anyattr(lv, (hd rl).name) == nil)
			nl = ref(*hd rl) :: nl;

	# new values
	for(; lv != nil; lv = tl lv){
		a := lookattr(rv, (hd lv).name);	# won't take queries
		if(a != nil)
			nl = ref *a :: nl;
	}

	return reverse(nl);
}

delattrs(lv: list of ref Attr, rv: list of ref Attr): list of ref Attr
{
	nl: list of ref Attr;
	for(; lv != nil; lv = tl lv)
		if(anyattr(rv, (hd lv).name) == nil)
			nl = hd lv :: nl;
	return reverse(nl);
}

ignored(s: string): int
{
	return s == "role" || s == "disabled";
}

matchattr(attrs: list of ref Attr, pat: ref Attr): int
{
	return (b := lookattr(attrs, pat.name)) != nil && (pat.tag == Aquery || b.val == pat.val) ||
			ignored(pat.name);
}

matchattrs(pub: list of ref Attr, secret: list of ref Attr, pats: list of ref Attr): int
{
	for(pl := pats; pl != nil; pl = tl pl)
		if(!matchattr(pub, hd pl) && !matchattr(secret, hd pl))
			return 0;
	return 1;
}

sortattrs(attrs: list of ref Attr): list of ref Attr
{
	a := array[len attrs] of ref Attr;
	i := 0;
	for(l := attrs; l != nil; l = tl l)
		a[i++] = hd l;
	shellsort(a);
	for(i = 0; i < len a; i++)
		l = a[i] :: l;
	return l;
}

# sort into decreasing order (we'll reverse the list)
shellsort(a: array of ref Attr)
{
	n := len a;
	for(gap := n; gap > 0; ) {
		gap /= 2;
		max := n-gap;
		ex: int;
		do{
			ex = 0;
			for(i := 0; i < max; i++) {
				j := i+gap;
				if(a[i].name > a[j].name || a[i].name == nil) {
					t := a[i]; a[i] = a[j]; a[j] = t;
					ex = 1;
				}
			}
		}while(ex);
	}
}

findkey(keys: array of ref Key, attrs: list of ref Attr): ref Key
{
	if(debug)
		sys->print("findkey %q\n", attrtext(attrs));
	for(i := 0; i < len keys; i++)
		if((k := keys[i]) != nil && matchattrs(k.attrs, k.secrets, attrs))
			return k;
	return nil;
}

findkeys(keys: array of ref Key, attrs: list of ref Attr): list of ref Key
{
	if(debug)
		sys->print("findkey %q\n", attrtext(attrs));
	kl: list of ref Key;
	for(i := 0; i < len keys; i++)
		if((k := keys[i]) != nil && matchattrs(k.attrs, k.secrets, attrs))
			kl = k :: kl;
	return reverse(kl);
}

delkey(keys: array of ref Key, attrs: list of ref Attr): int
{
	nk := 0;
	for(i := 0; i < len keys; i++)
		if((k := keys[i]) != nil)
			if(matchattrs(k.attrs, k.secrets, attrs)){
				nk++;
				keys[i] = nil;
			}
	return nk;
}

Key.mk(attrs: list of ref Attr): ref Key
{
	k := ref Key;
	for(; attrs != nil; attrs = tl attrs){
		a := hd attrs;
		if(a.name != nil){
			if(a.name[0] == '!')
				k.secrets = a :: k.secrets;
			else
				k.attrs = a :: k.attrs;
		}
	}
	if(k.attrs != nil || k.secrets != nil)
		return k;
	return nil;
}

addkey(keys: array of ref Key, k: ref Key): array of ref Key
{
	for(i := 0; i < len keys; i++)
		if(keys[i] == nil){
			keys[i] = k;
			return keys;
		}
	n := array[len keys+1] of ref Key;
	n[0:] = keys;
	n[len keys] = k;
	return n;
}

Key.text(k: self ref Key): string
{
	s := attrtext(k.attrs);
	if(s != nil && k.secrets != nil)
		s[len s] = ' ';
	return s + attrtext(k.secrets);
}

Key.safetext(k: self ref Key): string
{
	s := attrtext(sortattrs(k.attrs));
	sp := s != nil;
	for(sl := k.secrets; sl != nil; sl = tl sl){
		if(sp)
			s[len s] = ' ';
		s += sys->sprint("%s?", (hd sl).name);
	}
	return s;
}

any(s: string, t: string): int
{
	for(i := 0; i < len s; i++)
		for(j := 0; j < len t; j++)
			if(s[i] == t[j])
				return 1;
	return 0;
}

#
# findkey is for the key a protocol needs: with none, an agent reading
# needkey is asked for one.  findkeys is a look at what there is: the
# keys that match, or none, and nobody is asked (it asked, as findkey
# does, so a protocol that looked for a key under each of several names
# had the agent prompted for every one it did not find).  A protocol
# that has looked and found nothing asks with needkey.
#
IO.findkey(nil: self ref IO, attrs: list of ref Attr, extra: string): (ref Key, string)
{
	ea := parseline(extra);
	for(; ea != nil; ea = tl ea)
		attrs = hd ea :: attrs;
	kc := chan of (list of ref Key, string);
	keymanc <-= (attrs, 1, kc);
	(kl, err) := <-kc;
	if(kl != nil)
		return (hd kl, err);
	return (nil, err);
}

IO.findkeys(nil: self ref IO, attrs: list of ref Attr, extra: string): (list of ref Key, string)
{
	ea := parseline(extra);
	for(; ea != nil; ea = tl ea)
		attrs = hd ea :: attrs;
	kc := chan of (list of ref Key, string);
	keymanc <-= (attrs, 0, kc);
	return <-kc;
}

IO.needkey(nil: self ref IO, attrs: list of ref Attr, extra: string): (ref Key, string)
{
	ea := parseline(extra);
	for(; ea != nil; ea = tl ea)
		attrs = hd ea :: attrs;
	kc := chan of (list of ref Key, string);
	keymanc <-= (attrs, 1, kc);
	(kl, err) := <-kc;
	if(kl != nil)
		return (hd kl, err);
	return (nil, err);
}

IO.read(io: self ref IO): array of byte
{
	io.ok();
	while((rpc := rio(io.f)) != nil)
		case rpc.cmd {
		* =>
			phase(rpc, "protocol phase error");
		Oauthinfo =>
			reply(rpc, "error authentication unfinished");
		Owrite =>
			io.rpc = rpc;
			if(rpc.arg == nil)
				rpc.arg = array[0] of byte;
			return rpc.arg;
		}
	exit;
}

IO.readn(io: self ref IO, n: int): array of byte
{
	while((buf := io.read()) != nil && len buf < n)
		io.toosmall(n);
	return buf;
}

IO.write(io: self ref IO, buf: array of byte, n: int): int
{
	io.ok();
	while((rpc := rio(io.f)) != nil)
		case rpc.cmd {
		Oread =>
			if(rpc.nbytes-3 >= n){
				okdata(rpc, buf[0:n]);
				return n;
			}
			io.rpc = rpc;
			io.toosmall(n+3);
		Oauthinfo =>
			reply(rpc, "error authentication unfinished");
		* =>
			phase(rpc, "protocol phase error");
		}
	exit;
}

IO.rdwr(io: self ref IO): array of byte
{
	io.ok();
	while((rpc := rio(io.f)) != nil)
		case rpc.cmd {
		Oread =>
			io.rpc = rpc;
			if(rpc.nbytes >= 3)
				return nil;
			io.toosmall(128+3);		# make them read something
		Owrite =>
			io.rpc = rpc;
			if(rpc.arg == nil)
				rpc.arg = array[0] of byte;
			return rpc.arg;
		Oauthinfo =>
			reply(rpc, "error authentication unfinished");
		* =>
			phase(rpc, "protocol phase error");
		}
	exit;
}

IO.reply2read(io: self ref IO, buf: array of byte, n: int): int
{
	if(io.rpc == nil)
		return 0;
	rpc := io.rpc;
	if(rpc.cmd != Oread){
		io.rpc = nil;
		phase(rpc, "internal phase error");
		return 0;
	}
	if(rpc.nbytes-3 < n){
		io.toosmall(n+3);
		return 0;
	}
	io.rpc = nil;
	okdata(rpc, buf[0:n]);
	return 1;
}

IO.ok(io: self ref IO)
{
	if(io.rpc != nil){
		reply(io.rpc, "ok");
		io.rpc = nil;
	}
}

IO.toosmall(io: self ref IO, n: int)
{
	if(io.rpc != nil){
		reply(io.rpc, sys->sprint("toosmall %d", n));
		io.rpc = nil;
	}
}

IO.error(io: self ref IO, s: string)
{
	if(io.rpc != nil){
		io.rpc.rc <-= (nil, "error "+s);
		io.rpc = nil;
	}
}

IO.done(io: self ref IO, ai: ref Authinfo)
{
	io.f.ai = ai;
	io.ok();
	while((rpc := rio(io.f)) != nil)
		case rpc.cmd {
		Oread or Owrite =>
			done(rpc, ai);
			return;
		* =>
			phase(rpc, "protocol phase error");
		}
}

memrandom(a: array of byte, n: int)
{
	if(0){
		# speed up testing
		for(i := 0; i < len a; i++)
			a[i] = byte i;
		return;
	}
	fd := sys->open("/dev/notquiterandom", Sys->OREAD);
	if(fd == nil)
		err("can't open /dev/notquiterandom");
	if(sys->read(fd, a, n) != n)
		err("can't read /dev/notquiterandom");
}

eqbytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

netmkaddr(addr, net, svc: string): string
{
	if(net == nil)
		net = "net";
	(n, nil) := sys->tokenize(addr, "!");
	if(n <= 1){
		if(svc== nil)
			return sys->sprint("%s!%s", net, addr);
		return sys->sprint("%s!%s!%s", net, addr, svc);
	}
	if(svc == nil || n > 2)
		return addr;
	return sys->sprint("%s!%s", addr, svc);
}

# ── Keyfile persistence ──────────────────────────────────────

# both keys a key file's password gives: FKEY2's, and FKEY1's for a
# file not yet written again
setkeyfilepass(password: string)
{
	keyfilepass = derivekey2(password, user());
	keyfilepass1 = derivekey(password);
}

# FKEY2's key (see KEYFILE_MAGIC)
derivekey2(password, owner: string): array of byte
{
	pass := array of byte password;
	label := array of byte "factotum keyfile 2";
	o := array of byte owner;
	u := array[len label + 1 + len o + 4] of byte;
	u[0:] = label;
	u[len label] = byte 0;
	u[len label+1:] = o;
	u[len u-4:] = array[] of {byte 0, byte 0, byte 0, byte 1};
	t := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(u, len u, pass, t, nil);
	u = array[Keyring->SHA384dlen] of byte;
	u[0:] = t;
	v := array[Keyring->SHA384dlen] of byte;
	for(i := 1; i < KEYFILE_ITER; i++){
		kr->hmac_sha384(u, len u, pass, v, nil);
		for(j := 0; j < len t; j++)
			t[j] ^= v[j];
		(u, v) = (v, u);
	}
	key := array[32] of byte;
	key[0:] = t[0:32];
	for(i = 0; i < len t; i++){
		t[i] = byte 0;
		u[i] = byte 0;
		v[i] = byte 0;
	}
	for(i = 0; i < len pass; i++)
		pass[i] = byte 0;
	return key;
}

#
# FKEY1's key: a 32-byte AES-256 key from a password by iterated HMAC-SHA256.
#
derivekey(password: string): array of byte
{
	pass := array of byte password;
	salt := array of byte "factotum keyfile";
	key := array[Keyring->SHA256dlen] of byte;

	# First round: HMAC-SHA256(salt, password)
	kr->hmac_sha256(salt, len salt, pass, key, nil);

	# Iterate
	for(i := 1; i < KEYFILE_KDF_ROUNDS; i++){
		prev := array[Keyring->SHA256dlen] of byte;
		prev[0:] = key;
		kr->hmac_sha256(prev, len prev, pass, key, nil);
	}

	# Zero the password bytes
	for(i = 0; i < len pass; i++)
		pass[i] = byte 0;
	return key;
}

#
# Generate cryptographically random bytes using the host CSPRNG.
#
# nil, with the error string set, when there are none: it raised, in
# the thread that saves, which ended it; a sync was then never
# answered, and the serving loop, waiting for the answer, stopped.
cryptorand(n: int): array of byte
{
	buf := array[n] of byte;
	fd := sys->open("/dev/random", Sys->OREAD);
	if(fd == nil){
		sys->werrstr(sys->sprint("can't open /dev/random: %r"));
		return nil;
	}
	if(sys->readn(fd, buf, n) != n){
		sys->werrstr(sys->sprint("can't read /dev/random: %r"));
		return nil;
	}
	return buf;
}

#
# Load keys from an encrypted keyfile.
# Prompts for password via stdout/stderr if keyfilepass is nil.
# Returns nil on success, error string on failure.
#
loadkeyfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "keyfile does not exist (new installation)";

	# Read the whole file. It was read into 64K and no more, though
	# written at any length: seven post-quantum signing keys are more,
	# and then the file did not decrypt, the agent started with no
	# keys, and saved none after.
	buf := array[65536] of byte;
	total := 0;
	for(;;){
		if(total == len buf){
			if(len buf >= Maxkeyfile)
				return "keyfile too large";
			nbuf := array[2 * len buf] of byte;
			nbuf[0:] = buf;
			buf = nbuf;
		}
		n := sys->read(fd, buf[total:], len buf - total);
		if(n <= 0)
			break;
		total += n;
	}
	if(total == 0)
		return "empty keyfile";

	data := buf[0:total];

	# Check magic header: FKEY2, or FKEY1 to be written again
	magic := array of byte KEYFILE_MAGIC;
	if(total < len magic)
		return "keyfile too short";
	old := 0;
	i: int;
	for(i = 0; i < len magic; i++)
		if(data[i] != magic[i])
			break;
	if(i < len magic){
		magic = array of byte KEYFILE_MAGIC1;
		for(i = 0; i < len magic; i++)
			if(data[i] != magic[i])
				return "bad keyfile header";
		old = 1;
	}

	# Prompt for password if we don't have one yet
	if(keyfilepass == nil){
		pass := promptpassword("keyfile password: ");
		if(pass == nil)
			return "no password provided";
		setkeyfilepass(pass);
		# Zero the password string
		pass = nil;
	}
	key := keyfilepass;
	if(old)
		key = keyfilepass1;
	if(key == nil)
		return "an FKEY1 key file, and no key for it";

	# Extract nonce and ciphertext
	off := len magic;
	if(total - off < AES_GCM_NONCE_LEN + AES_GCM_TAG_LEN)
		return "keyfile too short for nonce+tag";

	nonce := data[off:off+AES_GCM_NONCE_LEN];
	off += AES_GCM_NONCE_LEN;
	ciphertext := data[off:total-AES_GCM_TAG_LEN];
	tag := data[total-AES_GCM_TAG_LEN:total];

	# Decrypt with AES-GCM
	state := kr->aesgcmsetup(key, nonce);
	if(state == nil)
		return "AES-GCM setup failed";
	plaintext := kr->aesgcmdecrypt(state, ciphertext, magic, tag);
	if(plaintext == nil){
		keyfilepass = nil;
		keyfilepass1 = nil;
		return "decryption failed (wrong password?)";
	}

	# Parse key lines and add to allkeys
	s := string plaintext;
	# Zero plaintext
	for(i = 0; i < len plaintext; i++)
		plaintext[i] = byte 0;

	while(len s > 0){
		eol := len s;
		for(j := 0; j < len s; j++)
			if(s[j] == '\n'){
				eol = j;
				break;
			}
		line := s[0:eol];
		if(eol < len s)
			s = s[eol+1:];
		else
			s = "";
		if(len line == 0)
			continue;
		# Strip "key " prefix if present
		if(len line > 4 && line[0:4] == "key ")
			line = line[4:];
		k := Key.mk(parseline(line));
		if(k != nil)
			allkeys = addkey(allkeys, k);
	}

	if(debug)
		sys->fprint(sys->fildes(2), "factotum: loaded %d keys from %s\n",
			len allkeys, path);
	# an FKEY1 file is written again as FKEY2 now (savekeyfile writes
	# beside and renames); until that works the old key is kept
	if(old){
		if((e := savekeyfile(path)) != nil)
			sys->fprint(sys->fildes(2), "factotum: %s not written again as FKEY2: %s\n", path, e);
		else{
			for(i = 0; i < len keyfilepass1; i++)
				keyfilepass1[i] = byte 0;
			keyfilepass1 = nil;
			sys->fprint(sys->fildes(2), "factotum: %s written again as FKEY2\n", path);
		}
	}
	return nil;
}

#
# Save all keys to an encrypted keyfile.
# Returns nil on success, error string on failure.
#
savekeyfile(path: string): string
{
	if(keyfilepass == nil)
		return "no keyfile password";

	# Serialize all keys
	# each slot is read once: the serving thread empties them (delkey)
	# while this one saves, and a slot found full and then empty was a
	# nil dereference that ended this thread, and with it every sync
	s := "";
	keys := allkeys;
	for(i := 0; i < len keys; i++)
		if((k := keys[i]) != nil)
			s += k.text() + "\n";

	plaintext := array of byte s;

	# Generate random nonce using host CSPRNG
	nonce := cryptorand(AES_GCM_NONCE_LEN);
	if(nonce == nil){
		why := sys->sprint("%r");
		for(j := 0; j < len plaintext; j++)
			plaintext[j] = byte 0;
		return "no nonce: " + why;
	}

	# Encrypt with AES-GCM
	magic := array of byte KEYFILE_MAGIC;
	state := kr->aesgcmsetup(keyfilepass, nonce);
	if(state == nil){
		for(j := 0; j < len plaintext; j++)
			plaintext[j] = byte 0;
		return "AES-GCM setup failed";
	}
	(ciphertext, tag) := kr->aesgcmencrypt(state, plaintext, magic);

	# Zero plaintext
	for(j := 0; j < len plaintext; j++)
		plaintext[j] = byte 0;

	if(ciphertext == nil || tag == nil)
		return "AES-GCM encryption failed";

	# Write atomically: magic + nonce + ciphertext + tag
	tmppath := path + ".tmp";
	fd := sys->create(tmppath, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", tmppath);

	# Build output buffer
	outlen := len magic + AES_GCM_NONCE_LEN + len ciphertext + len tag;
	out := array[outlen] of byte;
	off := 0;
	out[off:] = magic;
	off += len magic;
	out[off:] = nonce;
	off += AES_GCM_NONCE_LEN;
	out[off:] = ciphertext;
	off += len ciphertext;
	out[off:] = tag;

	n := sys->write(fd, out, len out);
	fd = nil;
	if(n != len out){
		sys->remove(tmppath);
		return sys->sprint("write failed: %r");
	}

	# Rename tmp to final (atomic on most filesystems)
	# Inferno doesn't have rename, so remove old + create new
	sys->remove(path);
	fd = sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	# Re-read tmp and write to final
	rfd := sys->open(tmppath, Sys->OREAD);
	if(rfd == nil){
		fd = nil;
		return sys->sprint("cannot reopen tmp: %r");
	}
	buf := array[len out] of byte;
	nr := sys->read(rfd, buf, len buf);
	rfd = nil;
	if(nr != len out){
		fd = nil;
		return "short read from tmp";
	}
	n = sys->write(fd, buf, len buf);
	fd = nil;
	sys->remove(tmppath);
	if(n != len buf)
		return sys->sprint("final write failed: %r");

	if(debug)
		sys->fprint(sys->fildes(2), "factotum: saved keys to %s\n", path);
	return nil;
}

#
# Background persistence thread.
# Waits for dirty signals or sync requests.
# Saves keyfile every 30 seconds if dirty, or immediately on sync.
#
persist()
{
	lasterr: string;
	dirty := 0;
	ticker := chan of int;
	spawn timer(ticker, 30000);

	for(;;) alt {
	(pass, dk) := <-keysc =>
		setsecstorekeys(pass, dk);
		pass = nil;
		# whoever configured this read the store and moved it: the
		# old forms' keys, and the password, are not kept
		secstore->forgetold(secstorecreds);
		secstoreconn = nil;	# a connection kept was another account's, or another password's
		keyspending = 0;

	<-dirtyc =>
		dirty = 1;

	<-ticker =>
		if(dirty){
			e := dosave();
			if(e != nil){
				# said once for each failure that is not the last one again
				if(e != lasterr)
					sys->fprint(sys->fildes(2), "factotum: keys not saved: %s\n", e);
				lasterr = e;
			}else{
				dirty = 0;
				lasterr = nil;
			}
		}

	rc := <-syncc =>
		e := dosave();
		if(e != nil){
			if(debug)
				sys->fprint(sys->fildes(2), "factotum: sync: %s\n", e);
		}else
			dirty = 0;
		rc <-= e;
	}
}

# Save keys via whichever backend is configured.  Whatever goes wrong
# is an answer: an exception in a save ended the thread that saves, and
# whoever asked for a sync waited for ever, with the serving loop.
dosave(): string
{
	{
		return dosave1();
	} exception e {
	"*" =>
		return "save failed: " + e;
	}
}

nosave: string;	# why nothing is saved, when nothing may be

# the secstore file: one line saying where keys added now are saved
savestatus(): string
{
	if(secstoreaddr != nil){
		if(nosave != nil)
			return "notsaving " + nosave + "\n";
		# while persist makes the keys of a password given, saving is
		# arranged: what is added now is saved once they are made
		if(secstorecreds == nil && !keyspending)
			return "notsaving no secstore password yet\n";
		s := sys->sprint("saving secstore %q %q", secstoreaddr, secstoreuser);
		if(secstorevault != nil || keyspending && keysvault)
			s += " 2fa";
		return s + "\n";
	}
	if(keyfilepath != nil && keyfilepass != nil)
		return sys->sprint("saving keyfile %q\n", keyfilepath);
	return "none\n";
}

dosave1(): string
{
	if(nosave != nil)
		return "not saved: " + nosave;
	if(secstoreaddr != nil)
		return secstoresave();
	if(keyfilepath != nil && keyfilepass != nil)
		return savekeyfile(keyfilepath);
	return "no persistence backend configured";
}

#
# A key's protocol module checks it (keycheck): nil, or why it is no key
# of that protocol.  A protocol with no module is a name for keys some
# other program asks for, and has no check.
#
keycheck(k: ref Key): string
{
	p := lookattrval(k.attrs, "proto");
	if(p == nil || any(p, "./"))
		return nil;
	{
		proto := load Authproto "/dis/auth/proto/"+p+".dis";
		if(proto == nil)
			return nil;
		e := proto->init(authio);
		if(e != nil)
			return nil;	# it cannot run here: nothing to say about its keys
		return proto->keycheck(k);
	} exception ex {
	"*" =>
		return "key check failed: " + ex;
	}
}

# In CNSA mode (/env/cnsamode: login(2)) the one signature algorithm
# is ML-DSA-87; nil, or why alg is refused.
cnsarefuses(alg: string): string
{
	login := load Login Login->PATH;
	if(login == nil || !login->cnsamode())
		return nil;
	return login->cnsaalg(alg);
}

timer(ch: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		alt { ch <-= 1 => ; * => ; }
	}
}

#
# Prompt for a password on stderr, reading from /dev/cons with echo disabled.
#
promptpassword(prompt: string): string
{
	# echo off before the prompt, so nothing typed ahead is echoed
	consctl := sys->open("/dev/consctl", Sys->OWRITE);
	if(consctl != nil)
		sys->fprint(consctl, "rawon");
	sys->fprint(sys->fildes(2), "%s", prompt);

	fd := sys->open("/dev/cons", Sys->OREAD);
	if(fd == nil)
		return nil;

	buf := array[256] of byte;
	pass := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s := string buf[0:n];
		for(i := 0; i < len s; i++){
			if(s[i] == '\n' || s[i] == '\r'){
				if(consctl != nil)
					sys->fprint(consctl, "rawoff");
				sys->fprint(sys->fildes(2), "\n");
				return pass;
			}
			pass[len pass] = s[i];
		}
	}

	if(consctl != nil)
		sys->fprint(consctl, "rawoff");
	sys->fprint(sys->fildes(2), "\n");
	if(len pass > 0)
		return pass;
	return nil;
}

# ── Secstore persistence ─────────────────────────────────────

#
# Load keys from secstore server.
# Connects, authenticates, fetches the "factotum" file, decrypts, parses keys.
# Prompts for password if there are no secstore keys yet.
#
secstoreload(): string
{
	if(secstoreaddr == nil)
		return "no secstore address";

	# Prompt for password if not provided via -P
	if(secstorecreds == nil){
		pass := promptpassword("secstore password: ");
		if(pass == nil)
			return "no password provided";
		setsecstorekeys(pass, nil);
		pass = nil;
	}

	# Connect and authenticate
	(conn, sname, diag) := secstore->connect6(secstoreaddr, secstorecreds);
	if(conn == nil){
		reason := "";
		if(diag != nil)
			reason = diag;
		else
			reason = sys->sprint("%r");
		# A new account is made only where it can be: the server said
		# it has none, and it is this machine's, whose store is the
		# directory written.  Any failure did it before: a wrong
		# password, a server of another version or another machine's
		# (the directory made on this machine's disk, or refused, and
		# the reason the user was told was the setup's, not the
		# server's).
		if(!contains(reason, "no account") || !localaddr(secstoreaddr))
			return reason;
		sys->fprint(sys->fildes(2), "factotum: secstore has no account for %s: creating it\n", secstoreuser);
		e := secstoresetup();
		if(e != nil)
			return "secstore setup: " + e;
		# Retry connect after setup
		(conn, sname, diag) = secstore->connect6(secstoreaddr, secstorecreds);
		if(conn == nil){
			if(diag != nil)
				return "secstore connect after setup: " + diag;
			return sys->sprint("secstore connect after setup: %r");
		}
	}

	if(debug)
		sys->fprint(sys->fildes(2), "factotum: secstore: connected to %s as %s\n",
			sname, secstoreuser);

	# Fetch the "factotum" file.  An account with nothing stored has
	# none, and the server says so; a file that could not be read, or
	# is empty, is another matter: it was taken for the same, and the
	# keys added afterwards were saved over the file that was not read.
	(file, absent, ferr) := secstore->fetch(conn, "factotum", 0);

	if(absent){
		secstore->bye(conn);
		if(debug)
			sys->fprint(sys->fildes(2), "factotum: secstore: no factotum file (new account)\n");
		return nil;	# Not an error — new account, no keys yet
	}
	if(ferr != nil){
		secstore->bye(conn);
		return "cannot read the keys: " + ferr;
	}
	if(len file == 0){
		secstore->bye(conn);
		return "the key file is empty (damaged)";
	}

	# Decrypt (auto-detects modern GCM vs legacy CBC format)
	# The format written, and no other: given the older formats' keys
	# every time, the file chose its own format, a weaker one if
	# whoever wrote it liked.
	# Under the data key, or under the version 6 root; a file under the
	# old root (SGCM2) opens and is written again in the new form at
	# once, opened again before it is stored.
	plaintext := secstore->decrypt3(file, secstorerootkey, nil, nil);
	if(plaintext == nil && secstorevault == nil)
		(plaintext, nil) = secstore->openfile(file, secstorecreds);
	if(plaintext == nil){
		secstore->bye(conn);
		if(!secstore->iscurrent(file) && !(len file >= 6 && string file[0:6] == "SGCM2\n"))
			return "the key file is in an old format: move it with auth/secstore m factotum";
		return "secstore: decryption failed (wrong password, or a second-factor account's file)";
	}
	if(!secstore->iscurrent(file)){
		shown := secstorevault == nil;
		if(!shown){
			(nil, verr) := secstore->showvault(conn, secstorevault);
			shown = verr == nil;
		}
		nf := secstore->encrypt3(plaintext, secstorerootkey);
		back: array of byte;
		if(nf != nil)
			back = secstore->decrypt3(nf, secstorerootkey, nil, nil);
		if(shown && back != nil && string back == string plaintext && secstore->putfile(conn, "factotum", nf) >= 0)
			sys->fprint(sys->fildes(2), "factotum: secstore: the key file moved to the new form (SGCM3)\n");
		if(back != nil)
			secstore->erasekey(back);
	}
	secstore->bye(conn);

	# Parse key lines
	s := string plaintext;
	secstore->erasekey(plaintext);

	nloaded := 0;
	while(len s > 0){
		eol := len s;
		for(j := 0; j < len s; j++)
			if(s[j] == '\n'){
				eol = j;
				break;
			}
		line := s[0:eol];
		if(eol < len s)
			s = s[eol+1:];
		else
			s = "";
		if(len line == 0)
			continue;
		# Strip "key " prefix if present
		if(len line > 4 && line[0:4] == "key ")
			line = line[4:];
		k := Key.mk(parseline(line));
		if(k != nil){
			allkeys = addkey(allkeys, k);
			nloaded++;
		}
	}

	if(debug)
		sys->fprint(sys->fildes(2), "factotum: secstore: loaded %d keys\n", nloaded);
	return nil;
}

#
# Auto-create secstore account if none exists.
# Computes the PAK verifier and writes it to the store directory.
# Uses the keys already made from the password (secstorecreds).
#
secstoresetup(): string
{
	if(secstorecreds == nil)
		return "no password";

	storedir := "/usr/inferno/secstore";
	userdir := storedir + "/" + secstoreuser;
	# never over an account that is there
	if(sys->stat(userdir + "/PAK").t0 >= 0)
		return userdir + "/PAK exists: the account is there";

	# Create directories
	sys->create(storedir, Sys->OREAD, Sys->DMDIR | 8r700);
	fd := sys->create(userdir, Sys->OREAD, Sys->DMDIR | 8r700);
	if(fd == nil)
		return sys->sprint("can't create %s: %r", userdir);
	fd = nil;

	hexHi := secstore->mkverifier(secstoreuser, "secstore6", secstorecreds.h6);
	if(hexHi == nil)
		return "can't make the verifier";

	# Write PAK verifier
	pakpath := userdir + "/PAK";
	fd = sys->create(pakpath, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("can't create %s: %r", pakpath);
	b := array of byte (secstore->formatverifier("secstore6", hexHi) + "\n");
	# a verifier cut short locked the account out, with "created" said
	if(sys->write(fd, b, len b) != len b){
		why := sys->sprint("%r");
		fd = nil;
		sys->remove(pakpath);
		return sys->sprint("can't write %s: %s", pakpath, why);
	}
	fd = nil;

	sys->fprint(sys->fildes(2), "factotum: secstore account created for %s\n", secstoreuser);
	return nil;
}

#
# Save all keys to secstore server.
# Connects, authenticates, encrypts keys, puts the "factotum" file.
#
secstoresave(): string
{
	if(secstoreaddr == nil)
		return "no secstore address";
	if(secstorecreds == nil || secstorerootkey == nil)
		return "no secstore credentials";

	# Serialize all keys
	s := "";
	keys := allkeys;	# each slot read once, as in savekeyfile
	for(i := 0; i < len keys; i++)
		if((k := keys[i]) != nil)
			s += "key " + k.text() + "\n";

	plaintext := array of byte s;

	# Encrypt with modern AES-GCM
	encrypted := secstore->encrypt3(plaintext, secstorerootkey);
	secstore->erasekey(plaintext);

	if(encrypted == nil)
		return "secstore: encryption failed";

	# Try cached connection first (avoids expensive PAK re-handshake)
	now := int (sys->millisec() / 1000);
	if(secstoreconn != nil && (now - secstoreconntime) < SECSTORE_CONN_TTL) {
		rc := secstore->putfile(secstoreconn, "factotum", encrypted);
		if(rc < 0)
			sys->fprint(sys->fildes(2), "factotum: secstore: store on the kept connection: %r\n");
		if(rc >= 0) {
			secstoreconntime = now;	# refresh TTL on success
			if(debug)
				sys->fprint(sys->fildes(2), "factotum: secstore: saved keys (cached conn)\n");
			return nil;
		}
		# Cached connection failed — fall through to fresh connect
		if(debug)
			sys->fprint(sys->fildes(2), "factotum: secstore: cached conn failed, reconnecting\n");
		secstoreconn = nil;
	}

	# Connect and authenticate (full PAK handshake)
	(conn, nil, diag) := secstore->connect6(secstoreaddr, secstorecreds);
	if(conn == nil){
		if(diag != nil)
			return "secstore save connect: " + diag;
		return sys->sprint("secstore save connect: %r");
	}

	# A second-factor account's files change only in a session that
	# has shown the vault key; an account whose factor was enrolled
	# before the server kept such keys is enrolled now.
	if(secstorevault != nil){
		(shown, verr) := secstore->showvault(conn, secstorevault);
		if(shown == 0)
			verr = secstore->enrolvault(conn, secstorevault);
		if(verr != nil){
			secstore->bye(conn);
			return "secstore: the second factor's vault key: " + verr;
		}
	}

	# Put the file (a version 4 session is told whether it was stored)
	rc := secstore->putfile(conn, "factotum", encrypted);
	if(rc < 0) {
		e := sys->sprint("%r");
		secstore->bye(conn);
		return "secstore putfile: " + e;
	}

	# Cache the connection for reuse (don't call bye)
	secstoreconn = conn;
	secstoreconntime = now;

	if(debug)
		sys->fprint(sys->fildes(2), "factotum: secstore: saved keys\n");
	return nil;
}

# s has t in it
contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

# a dial string naming this machine's own loopback
localaddr(addr: string): int
{
	(n, f) := sys->tokenize(addr, "!");
	host: string;
	if(n == 1)
		host = hd f;
	else if(n >= 2)
		host = hd tl f;
	else
		return 0;
	case host {
	"localhost" or "127.0.0.1" or "::1" or "$localhost" =>
		return 1;
	}
	return 0;
}
