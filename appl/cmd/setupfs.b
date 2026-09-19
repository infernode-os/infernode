implement Setupfs;

#
#	setupfs - what a phone in radio range may do to a board with no network
#
#	The namespace a board exports over Bluetooth (#647) when it has no
#	network to be reached by: enough to put it on one, or to find out
#	why it is not, and nothing else. It is never /. Radio range is a
#	weaker boundary than a wire, so what this serves is the whole of
#	what a paired phone can touch, and access control is by placement:
#	the listener exports this tree and only this tree.
#
#		mount {setupfs} /mnt/setup
#		listen 'bt!*!le9p' {export /mnt/setup}
#
#	wifi	read: the network the board is configured to join, and
#		whether a passphrase is set -- never the passphrase:
#			essid My Network
#			password set
#		write: a whole new configuration in one write, in the
#		card file's own syntax, both lines required:
#			essid My Network
#			password the passphrase, rest of line
#		It replaces the card's file (written beside it and renamed
#		over it, so a power cut leaves the old one or the new one)
#		and takes effect at the next boot: "reboot" to ctl.
#		An essid is 1 to 32 bytes; a WPA passphrase 8 to 63.
#	net	read only: each IP interface's status, as /net/ipifc gives it.
#	log	read only: the logs named with -l, each under its name.
#		By default the supplicant's, which is where a join that
#		failed says why.
#	ctl	write only: "reboot", or "tryboot" to boot the candidate
#		kernel once. Nothing else is accepted.
#
#	Writes are audited (/mnt/audit/log, if it is there). The
#	passphrase is never logged, read back, or kept in memory after
#	the file is written.
#
#	-w file	the Wi-Fi configuration (default /n/dos/wifi)
#	-c file	where reboot and tryboot are written (default /dev/sysctl)
#	-n dir	the IP interfaces (default /net/ipifc)
#	-l file	a log to serve; may be repeated (default /tmp/wpa.log)
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

Setupfs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Qdir, Qwifi, Qnet, Qlog, Qctl: con iota;

wififile := "/n/dos/wifi";
ctlfile := "/dev/sysctl";
netdir := "/net/ipifc";
logs: list of string;
user := "none";

Maxwrite: con 512;	# a configuration is two short lines

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	arg := load Arg Arg->PATH;
	if(styx == nil || styxservers == nil || nametree == nil || arg == nil){
		sys->fprint(sys->fildes(2), "setupfs: cannot load modules: %r\n");
		raise "fail:load";
	}
	arg->init(argv);
	arg->setusage("setupfs [-w wififile] [-c ctlfile] [-n ipifcdir] [-l logfile]...");
	while((o := arg->opt()) != 0)
		case o {
		'w' =>	wififile = arg->earg();
		'c' =>	ctlfile = arg->earg();
		'n' =>	netdir = arg->earg();
		'l' =>	logs = arg->earg() :: logs;
		* =>	arg->usage();
		}
	if(logs == nil)
		logs = "/tmp/wpa.log" :: nil;
	if((u := rdfile("/dev/user", 64)) != nil)
		user = u;

	styx->init();
	styxservers->init(styx);
	nametree->init();
	(tree, treeop) := nametree->start();
	tree.create(big Qdir, dir(".", Sys->DMDIR | 8r555, Qdir));
	tree.create(big Qdir, dir("wifi", 8r666, Qwifi));
	tree.create(big Qdir, dir("net", 8r444, Qnet));
	tree.create(big Qdir, dir("log", 8r444, Qlog));
	tree.create(big Qdir, dir("ctl", 8r222, Qctl));
	(tc, srv) := Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qdir);
	serve(tc, srv);
	tree.quit();
}

dir(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

serve(tc: chan of ref Tmsg, srv: ref Styxserver)
{
	while((tmsg := <-tc) != nil)
		pick tm := tmsg {
		Readerror =>
			return;
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			case int c.path {
			Qwifi =>	srv.reply(styxservers->readstr(tm, wifistate()));
			Qnet =>		srv.reply(styxservers->readstr(tm, netstate()));
			Qlog =>		srv.reply(styxservers->readstr(tm, logtext()));
			Qctl =>		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			* =>		srv.read(tm);
			}
		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			err: string;
			case int c.path {
			Qwifi =>	err = setwifi(tm.data);
			Qctl =>		err = control(tm.data);
			* =>		err = Styxservers->Eperm;
			}
			if(err != nil)
				srv.reply(ref Rmsg.Error(tm.tag, err));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		* =>
			srv.default(tmsg);
		}
}

rdfile(name: string, max: int): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[max] of byte;
	t := 0;
	while(t < max && (n := sys->read(fd, b[t:], max - t)) > 0)
		t += n;
	return string b[0:t];
}

# "name value, rest of line": the card file's syntax, and osinit's reading of it
parse(text: string): (string, string)
{
	essid, pass: string;
	(nil, lines) := sys->tokenize(text, "\n\r");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		for(i := 0; i < len l && (l[i] == ' ' || l[i] == '\t'); i++)
			;
		l = l[i:];
		for(i = 0; i < len l && l[i] != ' ' && l[i] != '\t'; i++)
			;
		name := l[0:i];
		for(; i < len l && (l[i] == ' ' || l[i] == '\t'); i++)
			;
		val := l[i:];
		case name {
		"essid" =>	essid = val;
		"password" =>	pass = val;
		}
	}
	return (essid, pass);
}

wifistate(): string
{
	text := rdfile(wififile, 4096);
	if(text == nil)
		return "unconfigured\n";
	(essid, pass) := parse(text);
	text = nil;
	s := "essid " + essid + "\n";
	if(pass != nil)
		s += "password set\n";
	else
		s += "password unset\n";
	pass = nil;
	return s;
}

setwifi(data: array of byte): string
{
	if(len data > Maxwrite)
		return "configuration too long";
	(essid, pass) := parse(string data);
	if(essid == nil || pass == nil)
		return "a configuration is an essid line and a password line, in one write";
	if(len array of byte essid > 32)
		return "an essid is at most 32 bytes";
	n := len array of byte pass;
	if(n < 8 || n > 63)
		return "a WPA passphrase is 8 to 63 bytes";
	# beside it, then over it: never a half-written configuration
	tmp := wififile + ".new";
	fd := sys->create(tmp, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", tmp);
	b := array of byte ("essid " + essid + "\npassword " + pass + "\n");
	pass = nil;
	if(sys->write(fd, b, len b) != len b){
		e := sys->sprint("cannot write %s: %r", tmp);
		fd = nil;
		sys->remove(tmp);
		return e;
	}
	for(i := 0; i < len b; i++)
		b[i] = byte 0;
	fd = nil;
	sys->remove(wififile);
	d := sys->nulldir;
	d.name = basename(wififile);
	if(sys->wstat(tmp, d) < 0)
		return sys->sprint("cannot rename %s: %r", tmp);
	audit("wifi", "essid=" + essid);
	return nil;
}

basename(p: string): string
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return p[i+1:];
	return p;
}

netstate(): string
{
	fd := sys->open(netdir, Sys->OREAD);
	if(fd == nil)
		return "no network interfaces\n";
	s := "";
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			if((dirs[i].mode & Sys->DMDIR) == 0)
				continue;
			st := rdfile(netdir + "/" + dirs[i].name + "/status", 4096);
			if(st != nil)
				s += dirs[i].name + " " + st;
			if(len s > 0 && s[len s - 1] != '\n')
				s += "\n";
		}
	}
	if(s == "")
		return "no network interfaces\n";
	return s;
}

logtext(): string
{
	s := "";
	for(l := logs; l != nil; l = tl l){
		t := rdfile(hd l, 32*1024);
		s += "== " + hd l + "\n";
		if(t == nil)
			s += "(nothing)\n";
		else{
			s += t;
			if(t[len t - 1] != '\n')
				s += "\n";
		}
	}
	return s;
}

control(data: array of byte): string
{
	(nf, f) := sys->tokenize(string data, " \t\r\n");
	if(nf != 1 || (hd f != "reboot" && hd f != "tryboot"))
		return "ctl takes reboot or tryboot";
	audit("ctl", hd f);
	fd := sys->open(ctlfile, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open %s: %r", ctlfile);
	b := array of byte hd f;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%s: %r", hd f);
	return nil;
}

# absence of the mount is a no-op
audit(event, detail: string)
{
	fd := sys->open("/mnt/audit/log", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "setupfs %s %s", event, detail);
}
