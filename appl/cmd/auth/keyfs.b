implement Keyfs;

#
# Copyright © 2002,2003 Vita Nuova Holdings Limited.  All rights reserved.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	AESbsize, AESstate: import kr;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg, Edot: import styxservers;

include "arg.m";

Keyfs: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

User: adt
{
	x:	int;		# table index
	name:	string;
	secret:	array of byte;	# eg, the password's SHA-256 (changelogin(8))
	expire:	int;	# expiration time (epoch seconds)
	status:	int;
	failed:	int;	# count of failed attempts
	path:		big;
};

Qroot, Quser, Qsecret, Qlog, Qstatus, Qexpire: con iota;
files := array[] of {
	(Qsecret, "secret"),
	(Qlog, "log"),
	(Qstatus, "status"),
	(Qexpire, "expire")
};

Maxsecret: con 255;
Maxname: con 255;	# bytes of UTF-8: an entry's name has one byte of length
Maxfail: con 50;
Maxcount: con 255;	# an entry's count of failures has one byte
users: array of ref User;
Sok, Sdisabled: con iota;
status := array[] of {Sok => "ok", Sdisabled => "disabled" };
Never: con 0;	# expiry time

Eremoved: con "user has been removed";

pathgen := 0;
keyversion := 0;
user: string;
now: int;

usage()
{
	sys->fprint(sys->fildes(2), "Usage: keyfs [-D] [-m mountpoint] [keyfile]\n");
	raise "fail:usage";
}

nomod(s: string)
{
	sys->fprint(sys->fildes(2), "keyfs: can't load %s: %r\n", s);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		nomod(Keyring->PATH);
	styx = load Styx Styx->PATH;
	if(styx == nil)
		nomod(Styx->PATH);
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		nomod(Styxservers->PATH);

	styx->init();
	styxservers->init(styx);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);
	arg->init(args);
	arg->setusage("keyfs [-m mntpt] [-D] [-n nvramfile] [keyfile]");
	mountpt := "/mnt/keys";
	keyfile := "/keydb/keys";
	nvram: string;
	while((o := arg->opt()) != 0)
		case o {
		'm' =>
			mountpt = arg->earg();
		'D' =>
			styxservers->traceset(1);
		'n' =>
			nvram = arg->earg();
		* =>
			usage();
		}
	args = arg->argv();
	arg = nil;

	if(args != nil)
		keyfile = hd args;

	# with no clock no account would ever expire: time() gave 0,
	# and every expiry time is after that
	if(time() == 0)
		error(sys->sprint("can't read the time from /dev/time: %r"));
	timefd = nil;	# the server opens its own, in its own fd group

	# The mount point is made here, readable by the signer's owner
	# alone, before the master key is asked for: no tree ships it
	# (security-check(8) refuses a tree with /mnt/keys in it), so
	# svc/auth on a fresh install asked for the key and then failed
	# to mount ("'/mnt/keys' does not exist"), and logind refused
	# every login.
	if(sys->stat(mountpt).t0 < 0){
		fd := sys->create(mountpt, Sys->OREAD, Sys->DMDIR|8r700);
		if(fd == nil)
			error(sys->sprint("can't make the mount point %s: %r", mountpt));
		fd = nil;
	}

	pwd, err: string;
	# The key as the nvram file has it, when that is not the key: a
	# file made by echo ends in a newline, which was taken as part of
	# the key, so the password typed at the console and the same one
	# kept in a file were two keys.  One trailing newline (and a
	# carriage return before it) is no part of the key; a store made
	# under the key with it is opened by trying that second, and put
	# under the key without it.
	rawkey: array of byte;
	if(nvram != nil){
		pwd = rf(nvram);
		if(pwd == nil)
			error(sys->sprint("can't read %s: %r", nvram));
		raw := pwd;
		if(len pwd > 0 && pwd[len pwd-1] == '\n')
			pwd = pwd[0:len pwd-1];
		if(len pwd > 0 && pwd[len pwd-1] == '\r')
			pwd = pwd[0:len pwd-1];
		if(pwd == nil)
			error(sys->sprint("%s holds no key", nvram));
		if(pwd != raw)
			rawkey = array of byte raw;
	}
	if(pwd == nil){
		# an error first: a line too long came back with no key,
		# and keyfs left without a word
		(pwd, err) = readconsline("Key: ", 1);
		if(err == "exit")
			exit;
		if(err != nil)
			error(sys->sprint("couldn't get key: %s", err));
		if(pwd == nil)
			exit;
		if(isfresh(keyfile)){
			pwd0 := pwd;
			(pwd, err) = readconsline("Confirm key: ", 1);
			if(err == "exit")
				exit;
			if(err != nil)
				error(sys->sprint("couldn't get key: %s", err));
			if(pwd == nil)
				exit;
			if(pwd != pwd0)
				error("key mismatch");
			for(i := 0; i < len pwd0; i++)
				pwd0[i] = ' ';	# clear it out
		}
	}

	sys->pctl(Sys->NEWPGRP|Sys->FORKFD, nil);	# immediately avoid sharing keyfd

	master := array of byte pwd;
	for(i:=0; i<len pwd; i++)
		pwd[i] = ' ';	# clear it out
	readkeys(keyfile, master, rawkey);
	clear(master);
	clear(rawkey);

	user = rf("/dev/user");
	if(user == nil)
		user = "keyfs";

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		error(sys->sprint("can't create pipe: %r"));

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;

	pidc := chan of int;
	spawn serveloop(tchan, srv, pidc, navops, keyfile);
	<-pidc;

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0)
		error(sys->sprint("mount on %s failed: %r", mountpt));
}

rf(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return nil;
	s := string b[0:n];
	clear(b);	# it may have been the master key
	return s;
}

quit(err: string)
{
	fd := sys->open("/prog/"+string sys->pctl(0, nil)+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	if(err != nil)
		raise "fail:"+err;
	exit;
}

error(s: string)
{
	sys->fprint(sys->fildes(2), "keyfs: %s\n", s);
	quit("error");
}

#
# the key of the old format: one SHA-1 of the master password, as Plan 9's
# aescbc has it. It is used only to read a file of that format.
#
oldkey(key: array of byte): array of byte
{
	skey := array[Keyring->SHA1dlen] of byte;
	sha := kr->sha1(array of byte "aescbc file", 11, nil, nil);
	kr->sha1(key, len key, skey, sha);
	return skey[0:AESbsize];
}

clear(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}

readconsline(prompt: string, raw: int): (string, string)
{
	fd := sys->open("/dev/cons", Sys->ORDWR);
	if(fd == nil)
		return (nil, sys->sprint("can't open cons: %r"));
	# echo off before the prompt: a key typed ahead of the console's
	# change of mode was echoed as it arrived
	fdctl: ref Sys->FD;
	if(raw){
		fdctl = sys->open("/dev/consctl", sys->OWRITE);
		if(fdctl == nil || sys->fprint(fdctl, "rawon") < 0)
			return (nil, sys->sprint("can't open consctl: %r"));
	}
	sys->fprint(fd, "%s", prompt);
	line := array[256] of byte;
	o := 0;
	err: string;
	buf := array[1] of byte;
  Read:
	while((r := sys->read(fd, buf, len buf)) > 0){
		c := int buf[0];
		case c {
		16r7F =>
			err = "interrupt";
			break Read;
		'\b' =>
			if(o > 0)
				o--;
		'\n' or '\r' or 16r4 =>
			break Read;
		* =>
			if(o >= len line){	# it was >, and a 257th character an array bounds error
				err = "line too long";
				break Read;
			}
			line[o++] = byte c;
		}
	}
	sys->fprint(fd, "\n");
	if(r < 0)
		err = sys->sprint("can't read cons: %r");
	if(raw)
		sys->fprint(fdctl, "rawoff");
	if(err != nil){
		clear(line);
		return (nil, err);
	}
	s := string line[0:o];
	clear(line);
	return (s, err);
}

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int, navops: chan of ref Navop, keyfile: string)
{
	pidc <-= sys->pctl(Sys->FORKNS|Sys->NEWFD, 1::2::srv.fd.fd::nil);
	while((gm := <-tchan) != nil){
		now = time();
		pick m := gm {
		Readerror =>
			error(sys->sprint("mount read error: %s", m.error));
		Attach =>
			# One user is served: the one that started keyfs, which
			# mounts it once on its own pipe.  The files' modes say
			# what each is (a user's directory holds its four files
			# and no others, so it is not writable), not who may do
			# what: there is no other user to keep out, and none is
			# let in.  Remove and Wstat, which styxservers does not
			# check, ask the same question.
			if(m.uname != user){
				srv.reply(ref Rmsg.Error(m.tag, "keyfs serves the user that started it, and no other"));
				break;
			}
			srv.default(gm);
		Create =>
			(c, mode, nil, err) := srv.cancreate(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			case TYPE(c.path) {	# parent
			Qroot =>
				if((m.perm & Sys->DMDIR) == 0){
					srv.reply(ref Rmsg.Error(m.tag, Eperm));
					break;
				}
				u := findusername(m.name);
				if(u != nil){
					srv.reply(ref Rmsg.Error(m.tag, "user already exists"));
					continue;
				}
				# in bytes, as an entry holds it: 86 runes of three
				# bytes each passed a count of runes, and pack then
				# stopped the server
				if(len array of byte m.name > Maxname){
					srv.reply(ref Rmsg.Error(m.tag, "user name too long"));
					continue;
				}
				u = newuser(m.name, nil);
				if(u == nil){
					srv.reply(ref Rmsg.Error(m.tag, "too many users"));
					continue;
				}
				qid := Qid((u.path | big Quser), 0, Sys->QTDIR);
				c.open(mode, qid);
				writekeys(keyfile);
				srv.reply(ref Rmsg.Create(m.tag, qid, srv.iounit()));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
				break;
			}
		Read =>
			(c, err) := srv.canread(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR){
				srv.read(m);	# does readdir
				break;
			}
			u := finduserpath(c.path);
			if(u == nil){
				srv.reply(ref Rmsg.Error(m.tag, Eremoved));
				break;
			}
			case TYPE(c.path) {
			Qsecret =>
				if(u.status != Sok){
					srv.reply(ref Rmsg.Error(m.tag, "user disabled"));
					break;
				}
				if(u.expire < now && u.expire != Never){
					srv.reply(ref Rmsg.Error(m.tag, "user expired"));
					break;
				}
				srv.reply(styxservers->readbytes(m, u.secret));
			Qlog =>
				srv.reply(styxservers->readstr(m, sys->sprint("%d", u.failed)));
			Qstatus =>
				s := status[u.status];
				if(u.status == Sok && u.expire != Never && u.expire < now)
					s = "expired";
				srv.reply(styxservers->readstr(m, s));
			Qexpire =>
				s: string;
				if(u.expire != Never)
					s = sys->sprint("%ud", u.expire);
				else
					s = "never";
				srv.reply(styxservers->readstr(m, s));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Write =>
			(c, merr) := srv.canwrite(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, merr));
				break;
			}
			u := finduserpath(c.path);
			if(u == nil){
				srv.reply(ref Rmsg.Error(m.tag, Eremoved));
				break;
			}
		    Case:
			case TYPE(c.path) {
			Qsecret =>
				if(m.offset != big 0 || len m.data > Maxsecret){
					srv.reply(ref Rmsg.Error(m.tag, "illegal write"));
					break;
				}
				u.secret = m.data;
				writekeys(keyfile);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qexpire =>
				s := trim(string m.data);
				if(s != "never"){
					# a time is kept in 31 bits: a larger number was
					# stored as the largest, not refused
					if(!isnumeric(s) || len s > 10 || big s > big 16r7FFFFFFF){
						srv.reply(ref Rmsg.Error(m.tag, "illegal expiry time"));
						break;
					}
					u.expire = int s;
				}else
					u.expire = Never;
				u.failed = 0;
				writekeys(keyfile);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qstatus =>
				s := trim(string m.data);
				for(i := 0; i < len status; i++)
					if(s == status[i]){
						u.status = i;
						if(i == Sok)
							u.failed = 0;
						writekeys(keyfile);
						srv.reply(ref Rmsg.Write(m.tag, len m.data));
						break Case;
					}
				srv.reply(ref Rmsg.Error(m.tag, "unknown status"));
			Qlog =>
				s := trim(string m.data);
				if(s != "good" && s != "ok"){
					# the file has a byte for the count: 300 was written as 44
					if(u.failed < Maxcount)
						u.failed++;
					if(u.failed >= Maxfail)
						u.status = Sdisabled;
				}else
					u.failed = 0;
				writekeys(keyfile);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Remove =>
			c := srv.getfid(m.fid);
			if(c == nil){
				srv.remove(m);	# let it diagnose the errors
				break;
			}
			if(c.uname != user){
				srv.delfid(c);
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
				break;
			}
			case TYPE(c.path) {
			Quser =>
				srv.delfid(c);
				u := finduserpath(c.path);
				if(u == nil){
					srv.reply(ref Rmsg.Error(m.tag, Eremoved));
					break;
				}
				removeuser(u);
				writekeys(keyfile);
				srv.reply(ref Rmsg.Remove(m.tag));
			Qsecret =>
				srv.delfid(c);
				u := finduserpath(c.path);
				if(u == nil){
					srv.reply(ref Rmsg.Error(m.tag, Eremoved));
					break;
				}
				u.secret = nil;
				writekeys(keyfile);
				srv.reply(ref Rmsg.Remove(m.tag));
			* =>
				srv.remove(m);	# let it reject it
			}
		Wstat =>
			# rename user
			c := srv.getfid(m.fid);
			if(c == nil || TYPE(c.path) != Quser){
				srv.default(gm);	# let it reject it
				break;
			}
			if(c.uname != user){
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
				break;
			}
			u := finduserpath(c.path);
			if(u == nil){
				srv.reply(ref Rmsg.Error(m.tag, Eremoved));
				break;
			}
			if((new := m.stat.name) == nil){
				srv.default(gm);
				break;
			}
			if(new == "." || new == ".."){
				srv.reply(ref Rmsg.Error(m.tag, Edot));
				break;
			}
			if(findusername(new) != nil){
				srv.reply(ref Rmsg.Error(m.tag, "user already exists"));
				break;
			}
			# a name too long for an entry reached pack, which
			# stopped the server
			if(len array of byte new > Maxname){
				srv.reply(ref Rmsg.Error(m.tag, "user name too long"));
				break;
			}
			if(!nameok(new)){
				srv.reply(ref Rmsg.Error(m.tag, "bad user name"));
				break;
			}
			# unhashuser(u);
			u.name = new;
			# hashuser(u);
			writekeys(keyfile);
			srv.reply(ref Rmsg.Wstat(m.tag));
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;		# shut down navigator
}

trim(s: string): string
{
	(nf, flds) := sys->tokenize(s, " \t\n");
	if(nf == 0)
		return nil;
	return hd flds;
}

isnumeric(s: string): int
{
	for(i:=0; i<len s; i++)
		if(!(s[i]>='0' && s[i]<='9'))
			return 0;
	return i>0;
}

TYPE(path: big): int
{
	return int path & 16rF;
}

#
# A path is the file's type in its low four bits, the user's slot in the
# 28 above and the slot's generation above that. The slot had 12 bits and
# the generation was shifted by 16: slot 4096 of one generation was slot 0
# of the next, so the 4097th user's files were another user's.
#
Maxusers: con 1<<28;

INDEX(path: big): int
{
	return int ((path >> 4) & big (Maxusers-1));
}

finduserpath(path: big): ref User
{
	i := INDEX(path);
	if(i >= len users || (u := users[i]) == nil || u.path != (path & ~big 16rF))
		return nil;
	return u;
}

findusername(name: string): ref User
{
	for(i := 0; i < len users; i++)
		if((u := users[i]) != nil && u.name == name)
			return u;
	return nil;
}

newuser(name: string, u: ref User): ref User
{
	for(i := 0; i < len users; i++)
		if(users[i] == nil)
			break;
	if(i >= Maxusers)
		return nil;
	if(i >= len users)
		users = (array[i+16+len users/4] of ref User)[0:] = users;
	path := (big pathgen++ << 32) | big (i<<4);
	if(u == nil)
		u = ref User(i, name, nil, Never, Sok, 0, path);
	else{
		u.x = i;
		u.path = path;
	}
	users[i] = u;
	return u;
}

removeuser(u: ref User)
{
	if(u != nil)
		users[u.x] = nil;
}

dirslot(n: int): int
{
	for(i := 0; i < len users; i++){
		u := users[i];
		if(u != nil){
			if(n == 0)
				break;
			n--;
		}
	}
	return i;
}

dir(qid: Sys->Qid, name: string, length: big, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(qid.qtype & Sys->QTDIR)
		perm |= Sys->DMDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = length;
	d.atime = now;
	d.mtime = now;
	return d;
}

dirgen(p: big, name: string, u: ref User): (ref Sys->Dir, string)
{
	case t := TYPE(p) {
	Qroot =>
		return (dir(Qid(big Qroot, keyversion,Sys->QTDIR), "/", big 0, 8r755), nil);
	Quser =>
		if(name == nil){
			if(u == nil){
				u = finduserpath(p);
				if(u == nil)
					return (nil, Enotfound);
			}
			name = u.name;
		}
		return (dir(Qid(p,0,Sys->QTDIR), name, big 0, 8r500), nil);	# note: unwritable
	* =>
		l := 0;
		if(t == Qsecret){
			if(u == nil)
				u = finduserpath(p);
			if(u != nil)
				l = len u.secret;
		}
		return (dir(Qid(p,0,Sys->QTFILE), name, big l, 8r600), nil);
	}
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil){
	   Pick:
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path, nil, nil);
		Walk =>
			case TYPE(n.path) {
			Qroot =>
				if(n.name == ".."){
					n.reply <-= dirgen(n.path, nil, nil);
					break;
				}
				u := findusername(n.name);
				if(u == nil){
					n.reply <-= (nil, Enotfound);
					break;
				}
				n.reply <-= dirgen(u.path | big Quser, u.name, u);
			Quser =>
				if(n.name == ".."){
					n.reply <-= dirgen(big Qroot, nil, nil);
					break;
				}
				for(j := 0; j < len files; j++){
					(ftype, name) := files[j];
					if(n.name == name){
						n.reply <-= dirgen((n.path & ~big 16rF) | big ftype, name, nil);
						break Pick;
					}
				}
				n.reply <-= (nil, Enotfound);
			* =>
				if(n.name != ".."){
					n.reply <-= (nil, Enotfound);
					break;
				}
				n.reply <-= dirgen((n.path & ~big 16rF) | big Quser, nil, nil);	# parent directory
			}
		Readdir =>
			case TYPE(n.path) {
			Qroot =>
				for(j := dirslot(n.offset); --n.count >= 0 && j < len users; j++)
					if((u := users[j]) != nil)
						n.reply <-= dirgen(u.path | big Quser, u.name, u);
				n.reply <-= (nil, nil);
			Quser =>
				u := finduserpath(n.path);
				if(u == nil){
					n.reply <-= (nil, Eremoved);
					break;
				}
				for(j := n.offset; --n.count >= 0 && j < len files; j++){
					(ftype, name) := files[j];
					n.reply <-= dirgen((n.path & ~big 16rF)|big ftype, name, u);
				}
				n.reply <-= (nil, nil);
			}
		}
	}
}

timefd: ref Sys->FD;

time(): int
{
	if(timefd == nil){
		timefd = sys->open("/dev/time", Sys->OREAD);
		if(timefd == nil)
			return 0;
	}
	buf := array[128] of byte;
	sys->seek(timefd, big 0, 0);
	n := sys->read(timefd, buf, len buf);
	if(n < 0)
		return 0;
	t := (big string buf[0:n]) / big 1000000;
	return int t;
}

#
# The key file.
#
# Its format (the second):
#	magic[8]	"keyfs 2\n"
#	iterations[4]	of PBKDF2, most significant byte first
#	salt[16]	random, made when the file is first written in this format
#	nonce[12]	random, new for every write
#	AES-256-GCM of count[4] and the entries, with the 40 bytes above as
#		its associated data (SP 800-38D)
#	tag[16]
# The key is the first 32 bytes of PBKDF2 with HMAC-SHA-384 (RFC 8018 5.2,
# SP 800-132) of the master password, the salt and the iterations.
#
# The first format was Plan 9's aescbc: a 16-byte IV, then AES-128-CBC of
# the entries and sixteen X's under SHA1("aescbc file" + password). A copy
# of the file tested a guess at the password with one SHA-1; a changed byte
# changed an entry (the first byte, a disabled account to ok) and nothing
# noticed; and it was rewritten in place, so a crash between the truncate
# and the write left an empty file, which is a new store. A file in that
# format is still read, and is written in this one at once, when keyfs
# starts (it was left until the next change, and until then a copy of it
# was still one SHA-1 from the master key). If it cannot be rewritten (a
# store that cannot be written) it is served as it is, and keyfs says so
# at every start.
#
Checkpat: con "XXXXXXXXXXXXXXXX";	# it's what Plan 9's aescbc uses
Checklen: con len Checkpat;

Magic: con "keyfs 2\n";
Saltlen: con 16;
Noncelen: con 12;	# SP 800-38D 8.2.2: 96 random bits
Taglen: con 16;
Keylen: con 32;
Filehdrlen: con len Magic+4+Saltlen+Noncelen;
#
# 200000 iterations of HMAC-SHA-384 are half a second on a 2 GHz amd64
# and a few seconds on a Raspberry Pi 3, paid once when keyfs starts
# (the key is kept, not derived again for each write). The count is in
# the file, so it can be raised without another format.
#
Iterations: con 200000;
Miniter: con 1000;
Maxiter: con 10000000;	# what a file may ask for: more is minutes of work on its say-so

thekey: array of byte;	# AES-256 key of the file as it will be written
salt: array of byte;
iterations := Iterations;

Hdrlen: con 1+1+4;

packedsize(u: ref User): int
{
	return Hdrlen+(1+len array of byte u.name)+(1+len u.secret);
}

pack(u: ref User): array of byte
{
	a := array[packedsize(u)] of byte;
	a[0] = byte u.status;
	failed := u.failed;
	if(failed > Maxcount)
		failed = Maxcount;
	a[1] = byte failed;
	a[2] = byte u.expire;
	a[3] = byte (u.expire>>8);
	a[4] = byte (u.expire>>16);
	a[5] = byte (u.expire>>24);
	bn := array of byte u.name;
	n := len bn;
	if(n > 255)
		error(sys->sprint("overlong user name: %s", u.name));	# shouldn't happen
	a[6] = byte n;
	a[7:] = bn;
	n += 7;
	a[n] = byte len u.secret;
	a[n+1:] = u.secret;
	return a;
}

#
# a name that can be a directory of the mount point
#
nameok(s: string): int
{
	if(s == nil || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '/' || s[i] == 0)
			return 0;
	return 1;
}

#
# An entry of the file, or why it is not one. A status that was neither
# ok nor disabled was taken, and the first read of the status file indexed
# the table of names with it: the server stopped, with its mount.
#
unpack(a: array of byte): (ref User, int, string)
{
	if(len a < Hdrlen+2)
		return (nil, 0, sys->sprint("%d bytes where an entry has at least %d", len a, Hdrlen+2));
	u := ref User;
	u.status = int a[0];
	u.failed = int a[1];
	u.expire = (int a[5] << 24) | (int a[4] << 16) | (int a[3] << 8) | int a[2];
	n := int a[6];
	j := 7+n;
	if(j >= len a)
		return (nil, 0, "name longer than what is left of the file");
	u.name = string a[7:j];
	if(!nameok(u.name))
		return (nil, 0, "bad name");
	# bytes that are not UTF-8 would not be written back as they were read
	bn := array of byte u.name;
	if(len bn != n)
		return (nil, 0, "name not UTF-8");
	for(i := 0; i < n; i++)
		if(bn[i] != a[7+i])
			return (nil, 0, "name not UTF-8");
	if(u.status < 0 || u.status >= len status)
		return (nil, 0, sys->sprint("%q: status %d", u.name, u.status));
	n = int a[j++];
	if(j+n > len a)
		return (nil, 0, sys->sprint("%q: secret longer than what is left of the file", u.name));
	if(n > 0){
		u.secret = array[n] of byte;
		u.secret[0:] = a[j:j+n];
	}
	return (u, j+n, nil);
}

trying := 0;	# a key that may not be the one: a failure is raised, not fatal

corrupt(keyfile: string)
{
	if(trying)
		raise "keyfs:badkey";
	error(sys->sprint("%s: incorrect key or corrupt/damaged keyfile", keyfile));
}

badentry(keyfile: string, n: int, why: string)
{
	error(sys->sprint("%s: entry %d: %s", keyfile, n, why));
}

random(n: int): array of byte
{
	a := array[n] of byte;
	fd := sys->open("/dev/notquiterandom", Sys->OREAD);
	if(fd == nil || sys->readn(fd, a, n) != n)
		error(sys->sprint("can't read /dev/notquiterandom: %r"));
	return a;
}

#
# PBKDF2 (RFC 8018 5.2) with HMAC-SHA-384: the first Keylen bytes of
# its first block
#
pbkdf2(pw, salt: array of byte, iter: int): array of byte
{
	u := array[len salt + 4] of byte;
	u[0:] = salt;
	u[len salt:] = array[] of {byte 0, byte 0, byte 0, byte 1};
	t := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(u, len u, pw, t, nil);
	u = array[Keyring->SHA384dlen] of byte;
	u[0:] = t;
	v := array[Keyring->SHA384dlen] of byte;
	for(i := 1; i < iter; i++){
		kr->hmac_sha384(u, len u, pw, v, nil);
		for(j := 0; j < len t; j++)
			t[j] ^= v[j];
		(u, v) = (v, u);
	}
	k := array[Keylen] of byte;
	k[0:] = t[0:Keylen];
	clear(t);
	clear(u);
	clear(v);
	return k;
}

put4(a: array of byte, v: int)
{
	a[0] = byte (v>>24);
	a[1] = byte (v>>16);
	a[2] = byte (v>>8);
	a[3] = byte v;
}

get4(a: array of byte): int
{
	return (int a[0]<<24) | (int a[1]<<16) | (int a[2]<<8) | int a[3];
}

ismagic(buf: array of byte): int
{
	m := array of byte Magic;
	if(len buf < len m)
		return 0;
	for(i := 0; i < len m; i++)
		if(buf[i] != m[i])
			return 0;
	return 1;
}

#
# a file that is there and empty is a store not yet begun
# (keyfs does not make the file, and does not leave it empty)
#
isfresh(keyfile: string): int
{
	(rc, d) := sys->stat(keyfile);
	return rc == 0 && d.length == big 0;
}

lastelem(s: string): string
{
	for(i := len s; i > 0; i--)
		if(s[i-1] == '/')
			return s[i:];
	return s;
}

#
# The file is written whole beside the old one and renamed over it, so
# at any moment one of them is a whole file. Where a file server will not
# rename onto a name in use, the old file is removed first: a stop just
# then leaves only the new one, which is taken at the next start (it is
# known to be whole because it authenticates).
#
newname(keyfile: string): string
{
	return keyfile+".new";
}

readkeys(keyfile: string, master, rawkey: array of byte)
{
	fd := sys->open(keyfile, Sys->OREAD);
	if(fd == nil){
		why := sys->sprint("%r");
		fd = sys->open(newname(keyfile), Sys->OREAD);
		if(fd == nil)
			error(sys->sprint("can't open %s: %s", keyfile, why));
		warn(sys->sprint("%s is not there: reading %s, left by a change that was interrupted", keyfile, newname(keyfile)));
		loadkeys(fd, newname(keyfile), keyfile, master, rawkey, 1);
		fd = nil;
		# loadkeys may have written the file anew, at its own name
		(ok, nil) := sys->stat(keyfile);
		if(ok >= 0){
			sys->remove(newname(keyfile));
			return;
		}
		d := sys->nulldir;
		d.name = lastelem(keyfile);
		if(sys->wstat(newname(keyfile), d) < 0)
			error(sys->sprint("can't rename %s to %s: %r", newname(keyfile), keyfile));
		return;
	}
	loadkeys(fd, keyfile, keyfile, master, rawkey, 0);
}

#
# Read the file at name (to be the store keyfile) under master; or, if
# it does not open under master and rawkey is given, under rawkey (the
# nvram file's bytes, newline and all), and then put the store under
# master.
#
loadkeys(fd: ref Sys->FD, name, keyfile: string, master, rawkey: array of byte, mustnew: int)
{
	if(rawkey == nil){
		rdkeys(fd, name, keyfile, master, mustnew);
		return;
	}
	{
		trying = 1;
		rdkeys(fd, name, keyfile, master, mustnew);
		trying = 0;
		return;
	} exception {
	"keyfs:badkey" =>
		;
	}
	trying = 0;
	sys->seek(fd, big 0, 0);
	rdkeys(fd, name, keyfile, rawkey, mustnew);	# the end, if this is not the key either
	under := thekey;
	thekey = pbkdf2(master, salt, iterations);
	err := putkeys(keyfile);
	if(err == nil){
		clear(under);
		warn(sys->sprint("%s was under a key ending in a newline (the nvram file's last byte): it is now under the key without it, which is the one typed at the console", keyfile));
		return;
	}
	clear(thekey);
	thekey = under;
	warn(sys->sprint("WARNING: %s is under a key ending in a newline (the nvram file's last byte) and cannot be rewritten under the key without it: %s", keyfile, err));
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "keyfs: %s\n", s);
}

# name is the file read; keyfile where the store is kept (the same, but
# after a change that was interrupted)
rdkeys(fd: ref Sys->FD, name, keyfile: string, master: array of byte, mustnew: int)
{
	keyfile0 := keyfile;
	keyfile = name;
	(rc, d) := sys->fstat(fd);
	if(rc < 0)
		error(sys->sprint("can't get status of %s: %r", keyfile));
	#
	# keyfs does not make the file, so its mode is whatever its maker's
	# was: after "touch /keydb/keys", readable by all. It is put right
	# rather than refused: refusing would stop every login of a realm
	# that was set up as the manual said, and whoever could read the
	# file has had the time to copy it either way, which is said.
	#
	if(d.mode & 8r077){
		nd := sys->nulldir;
		nd.mode = (d.mode & ~8r777) | 8r600;
		if(sys->fwstat(fd, nd) < 0)
			warn(sys->sprint("%s has mode %uo, open to users other than its owner, and it cannot be changed: %r", keyfile, d.mode&8r777));
		else
			warn(sys->sprint("%s had mode %uo, open to users other than its owner: now 600. If others could reach it, change the master key and the users' secrets",
				keyfile, d.mode&8r777));
	}
	if(d.length > big (64*1024*1024))
		error(sys->sprint("%s: %bd bytes is no key file", keyfile, d.length));
	length := int d.length;
	if(length == 0){
		if(mustnew)
			corrupt(keyfile);
		warn(sys->sprint("%s is empty: a new store, under the key given", keyfile));
		salt = random(Saltlen);
		thekey = pbkdf2(master, salt, iterations);
		return;
	}
	buf := array[length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf)
		error(sys->sprint("can't read %s: %r", keyfile));
	plain: array of byte;
	if(ismagic(buf)){
		if(length < Filehdrlen+4+Taglen)
			corrupt(keyfile);
		o := len Magic;
		iter := get4(buf[o:]);
		if(iter < Miniter || iter > Maxiter)
			corrupt(keyfile);
		o += 4;
		salt = array[Saltlen] of byte;
		salt[0:] = buf[o:o+Saltlen];
		o += Saltlen;
		iterations = iter;
		thekey = pbkdf2(master, salt, iterations);
		state := kr->aesgcmsetup(thekey, buf[o:o+Noncelen]);
		if(state == nil)
			error("can't initialise AES");
		# nil unless the tag is right for the header and every byte after it
		plain = kr->aesgcmdecrypt(state, buf[Filehdrlen:length-Taglen], buf[0:Filehdrlen], buf[length-Taglen:]);
		if(plain == nil || len plain < 4)
			corrupt(keyfile);
		n := get4(plain);
		i := 4;
		for(e := 0; e < n; e++){
			(u, m, err) := unpack(plain[i:]);
			if(u == nil)
				badentry(keyfile, e, err);
			adduser(keyfile, e, u);
			i += m;
		}
		if(i != len plain)
			error(sys->sprint("%s: %d bytes after the last of %d entries", keyfile, len plain-i, n));
		clear(plain);
		return;
	}
	if(mustnew || length < AESbsize+Checklen)
		corrupt(keyfile);
	okey := oldkey(master);
	state := kr->aessetup(okey, buf[0:AESbsize]);
	if(state == nil)
		error("can't initialise AES");
	kr->aescbc(state, buf[AESbsize:], length-AESbsize, Keyring->Decrypt);
	clear(okey);
	if(string buf[length-Checklen:] != Checkpat)
		corrupt(keyfile);
	length -= Checklen;
	e := 0;
	for(i := AESbsize; i < length; e++){
		(u, n, err) := unpack(buf[i:length]);
		if(u == nil)
			badentry(keyfile, e, err);
		adduser(keyfile, e, u);
		i += n;
	}
	clear(buf);
	salt = random(Saltlen);
	thekey = pbkdf2(master, salt, iterations);
	# Written in the new format now, not at the next change: until
	# then a copy of the file was one SHA-1 from the master key, and a
	# store nobody changed stayed that way for good.
	err := putkeys(keyfile0);
	if(err == nil)
		warn(sys->sprint("%s was in the old format (no check of its integrity, a key one SHA-1 from the master key) and has been written in the new one; a copy made before this is still in the old", keyfile0));
	else
		warn(sys->sprint("WARNING: %s is in the old format, which has no check of its integrity and a key one SHA-1 from the master key, and cannot be written in the new one: %s. It is served as it is. Make the store writable and start keyfs again", keyfile0, err));
}

#
# names seen in the file, to refuse a second entry of a name
# (it could never be reached: a walk finds the first)
#
seen: array of list of string;

adduser(keyfile: string, e: int, u: ref User)
{
	if(seen == nil)
		seen = array[1021] of list of string;
	h := 0;
	for(i := 0; i < len u.name; i++)
		h = (h*31 + u.name[i]) & 16r7FFFFFF;
	h %= len seen;
	for(l := seen[h]; l != nil; l = tl l)
		if(hd l == u.name)
			badentry(keyfile, e, sys->sprint("%q: a second entry of that name", u.name));
	seen[h] = u.name :: seen[h];
	if(newuser(u.name, u) == nil)
		error(sys->sprint("%s: too many entries", keyfile));
}

writekeys(keyfile: string)
{
	err := putkeys(keyfile);
	if(err != nil)
		error(err);
}

# the file written whole in the new format; nil, or why not (and then
# the file is as it was)
putkeys(keyfile: string): string
{
	seen = nil;
	length := 4;
	n := 0;
	for(i := 0; i < len users; i++)
		if((u := users[i]) != nil){
			length += packedsize(u);
			n++;
		}
	plain := array[length] of byte;
	put4(plain, n);
	j := 4;
	for(i = 0; i < len users; i++)
		if((u = users[i]) != nil){
			a := pack(u);
			plain[j:] = a;
			j += len a;
			clear(a);
		}
	hdr := array[Filehdrlen] of byte;
	hdr[0:] = array of byte Magic;
	o := len Magic;
	put4(hdr[o:], iterations);
	o += 4;
	hdr[o:] = salt;
	o += Saltlen;
	# a new nonce for each write under the one key (SP 800-38D 8.2.2)
	nonce := random(Noncelen);
	hdr[o:] = nonce;
	state := kr->aesgcmsetup(thekey, nonce);
	if(state == nil){
		clear(plain);
		return "can't initialise AES";
	}
	(ct, tag) := kr->aesgcmencrypt(state, plain, hdr);
	clear(plain);
	if(ct == nil || len ct != length || tag == nil || len tag != Taglen)
		return "can't encrypt the key file";
	buf := array[Filehdrlen+length+Taglen] of byte;
	buf[0:] = hdr;
	buf[Filehdrlen:] = ct;
	buf[Filehdrlen+length:] = tag;

	# a file left there keeps its mode when created again: start afresh
	new := newname(keyfile);
	sys->remove(new);
	fd := sys->create(new, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("can't create %s: %r", new);
	if(sys->write(fd, buf, len buf) != len buf){
		why := sys->sprint("%r");
		fd = nil;
		sys->remove(new);
		return sys->sprint("error writing to %s: %s", new, why);
	}
	# a wstat that changes nothing is a request to commit the file (stat(5))
	sys->fwstat(fd, sys->nulldir);
	fd = nil;
	d := sys->nulldir;
	d.name = lastelem(keyfile);
	if(sys->wstat(new, d) < 0){
		sys->remove(keyfile);
		if(sys->wstat(new, d) < 0)
			return sys->sprint("can't rename %s to %s: %r", new, keyfile);
	}
	return nil;
}
