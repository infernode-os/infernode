implement Rcpu;

#
# rcpu(1): a command run on a 9front cpu server, as 9front's rcpu runs
# it: rcpu's connection (rconnect(2)), the same server function, which
# mounts what this end serves over the connection at /mnt/term and runs
# the command with /mnt/term/fd/10, 11 and 12 as its input, output and
# error.  9front's rcpu serves its whole name space there; this serves a
# tree of its own and nothing else of this machine:
#
#	fd/10 fd/11 fd/12	this command's input, output, error
#	dev/cons		input and output
#	mnt/cpunote/data	notes for the far end (none are sent)
#	env/rstatus		where the far end leaves its exit status
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "factotum.m";

include "rconnect.m";
	rcon: Rconnect;

Rcpu: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

# 9front's rcpu's server function, as rc's whatis gives it
SERVER: con "fn server {\n" +
	"	mount -nc /fd/0 /mnt/term || exit\n" +
	"	bind -q /mnt/term/dev/cons /dev/cons\n" +
	"	</mnt/term/fd/10 >/mnt/term/fd/11 >[2]/mnt/term/fd/12 {\n" +
	"		~ $#dir 0 || cd $\"dir || echo 'can''t change directory: '^$\"dir >[1=2]\n" +
	"		switch($#cmd){\n" +
	"		case 0;	cmd=(rc -li)\n" +
	"		case 1; cmd=(rc -lc $cmd)\n" +
	"		case *; cmd=(rc -lc '$*' $cmd)\n" +
	"		}\n" +
	"		rm -f /env/^(cmd dir 'fn#server')\n" +
	"		service=cpu exec $cmd\n" +
	"	} &\n" +
	"	if(test -d /mnt/term/mnt/cpunote) {\n" +
	"		rfork e\n" +
	"		mainproc=$apid\n" +
	"		rm -f /mnt/term/env/rfailed\n" +
	"		{cat; echo -n hangup} </mnt/term/mnt/cpunote/data >/proc/$mainproc/notepg &\n" +
	"		noteproc=$apid\n" +
	"		wait $mainproc\n" +
	"		echo -n $status >/mnt/term/env/rstatus >[2]/dev/null\n" +
	"		echo -n hangup >/proc/$noteproc/notepg\n" +
	"	}\n" +
	"}\n";

stderr: ref Sys->FD;
rstatus := "";

fail(s: string)
{
	sys->fprint(stderr, "rcpu: %s\n", s);
	raise "fail:"+s;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("rcpu [-k keypattern] [-u user] [-h host] [-c cmd arg ...]");
	keyspec := "";
	host := readenv("cpu");
	cmd: list of string;
	dir := "";
	cflag := 0;
	while(!cflag && (o := arg->opt()) != 0)
		case o {
		'k' =>	keyspec += " "+arg->earg();
		'u' =>	keyspec += " user="+arg->earg();
		'h' =>	host = arg->earg();
		'd' =>	dir = arg->earg();
		'c' =>
			cmd = arg->argv();
			if(cmd == nil)
				arg->usage();
			cflag = 1;
		* =>	arg->usage();
		}
	if(!cflag && arg->argv() != nil)
		arg->usage();
	if(host == nil)
		fail("no host: -h host, or $cpu");

	rcon = load Rconnect Rconnect->PATH;
	if(rcon == nil)
		fail(sys->sprint("cannot load %s: %r", Rconnect->PATH));
	if((e := rcon->init()) != nil)
		fail(e);

	script := "dir=()\n";
	if(dir != nil)
		script = "dir="+rcon->rcquote(dir)+"\n";
	if(cmd == nil)
		script += "cmd=()\n";
	else{
		script += "cmd=(";
		for(l := cmd; l != nil; l = tl l){
			script += rcon->rcquote(hd l);
			if(tl l != nil)
				script += " ";
		}
		script += ")\n";
	}
	script += SERVER + "server\n";

	(fd, nil, err) := rcon->connect(host, keyspec, script);
	if(fd == nil)
		fail(err);
	# the tree once there is a connection to serve it on: the server's
	# mount waits for its answers until then
	sys->pctl(Sys->FORKNS, nil);
	root := mktree();
	xerr := "";
	if(sys->export(fd, root, Sys->EXPWAIT) < 0)
		xerr = sys->sprint("export: %r");
	rmtree(root);
	if(xerr != "")
		fail(xerr);
	if(rstatus != nil && rstatus != "")
		raise "fail:"+rstatus;
}

readenv(name: string): string
{
	fd := sys->open("/env/"+name, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

# the tree served to the far end: directories made in a scratch place of
# this name space's own, each a #s of its own with its files in it
mktree(): string
{
	root := "/tmp/rcpu."+string sys->pctl(0, nil);
	{
		mktree1(root);
	} exception {
	"fail:*" =>
		rmtree(root);
		raise;
	}
	return root;
}

mktree1(root: string)
{
	for(d := list of {"", "/fd", "/dev", "/mnt", "/mnt/cpunote", "/env"}; d != nil; d = tl d)
		if(sys->create(root + hd d, Sys->OREAD, Sys->DMDIR|8r700) == nil && sys->stat(root + hd d).t0 < 0)
			fail(sys->sprint("cannot make %s: %r", root + hd d));
	for(d = list of {"/fd", "/dev", "/mnt/cpunote", "/env"}; d != nil; d = tl d)
		if(sys->bind("#s", root + hd d, Sys->MREPL) < 0)
			fail(sys->sprint("bind #s %s: %r", root + hd d));
	in := sys->fildes(0);
	out := sys->fildes(1);
	err := sys->fildes(2);
	file(root+"/fd", "10", in, nil);
	file(root+"/fd", "11", nil, out);
	file(root+"/fd", "12", nil, err);
	file(root+"/dev", "cons", in, out);
	note := sys->file2chan(root+"/mnt/cpunote", "data");
	if(note == nil)
		fail(sys->sprint("file2chan: %r"));
	spawn noteserve(note);
	st := sys->file2chan(root+"/env", "rstatus");
	if(st == nil)
		fail(sys->sprint("file2chan: %r"));
	spawn statusserve(st);
	# the far end makes nothing on this machine's disk: the two
	# directories that are the scratch place's own are made read-only
	ro := sys->nulldir;
	ro.mode = Sys->DMDIR|8r500;
	sys->wstat(root+"/mnt", ro);
	sys->wstat(root, ro);
}

rmtree(root: string)
{
	for(l := list of {"/fd", "/dev", "/mnt/cpunote", "/env"}; l != nil; l = tl l)
		sys->unmount(nil, root + hd l);
	d := sys->nulldir;
	d.mode = Sys->DMDIR|8r700;
	sys->wstat(root, d);
	sys->wstat(root+"/mnt", d);
	for(l = list of {"/fd", "/dev", "/mnt/cpunote", "/mnt", "/env", ""}; l != nil; l = tl l)
		sys->remove(root + hd l);
}

file(dir, name: string, in, out: ref Sys->FD)
{
	f := sys->file2chan(dir, name);
	if(f == nil)
		fail(sys->sprint("file2chan %s/%s: %r", dir, name));
	spawn serve(f, in, out);
}

serve(f: ref Sys->FileIO, in, out: ref Sys->FD)
{
	for(;;) alt {
	(nil, n, nil, rc) := <-f.read =>
		if(rc == nil)
			continue;
		if(in == nil){
			rc <-= (nil, "not open for reading");
			continue;
		}
		if(n > Sys->ATOMICIO)
			n = Sys->ATOMICIO;
		b := array[n] of byte;
		m := sys->read(in, b, n);
		if(m < 0)
			rc <-= (nil, sys->sprint("%r"));
		else
			rc <-= (b[0:m], nil);
	(nil, data, nil, wc) := <-f.write =>
		if(wc == nil)
			continue;
		if(out == nil){
			wc <-= (0, "not open for writing");
			continue;
		}
		if(sys->write(out, data, len data) != len data)
			wc <-= (0, sys->sprint("%r"));
		else
			wc <-= (len data, nil);
	}
}

# reads of the notes file wait: no note is sent from here
noteserve(f: ref Sys->FileIO)
{
	held: list of Sys->Rread;
	for(;;) alt {
	(nil, nil, nil, rc) := <-f.read =>
		if(rc != nil)
			held = rc :: held;
	(nil, nil, nil, wc) := <-f.write =>
		if(wc != nil)
			wc <-= (0, "permission denied");
	}
}

statusserve(f: ref Sys->FileIO)
{
	for(;;) alt {
	(off, n, nil, rc) := <-f.read =>
		if(rc == nil)
			continue;
		b := array of byte rstatus;
		if(off >= len b)
			rc <-= (nil, nil);
		else{
			if(off + n > len b)
				n = len b - off;
			rc <-= (b[off:off+n], nil);
		}
	(nil, data, nil, wc) := <-f.write =>
		if(wc == nil)
			continue;
		rstatus = string data;
		wc <-= (len data, nil);
	}
}
