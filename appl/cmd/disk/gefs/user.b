#
# gefs: the user table, /adm/users, as 9front's user.c:
#	id:name:leader:member,member,...
#

User: adt {
	id:	int;
	lead:	int;
	memb:	array of int;
	name:	string;
};

# a file's bytes, block by block, from the tree
slurp(t: ref Tree, path, length: big): array of byte
{
	ret := array[int length] of byte;
	for(o := big 0; o < length; o += big Blksz){
		k := array[Offksz] of byte;
		p8(k, 0, Kdat);
		p64(k, 1, path);
		p64(k, 9, o);
		kv := btlookup(t, k);
		if(kv == nil)
			error(Esrch);
		b := getblk(unpackbp(kv.v, 0), GBraw);
		n := Blksz;
		if(length - o < big Blksz)
			n = int (length - o);
		ret[int o:] = b.buf[0:n];
	}
	return ret;
}

name2user(name: string): ref User
{
	for(i := 0; i < len fs.users; i++)
		if(fs.users[i].name == name)
			return fs.users[i];
	return nil;
}

uid2user(id: int): ref User
{
	for(i := 0; i < len fs.users; i++)
		if(fs.users[i].id == id)
			return fs.users[i];
	return nil;
}

# fields of a line, split at c, as getfield splits them
fields(s: string, c: int): list of string
{
	l: list of string;
	start := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == c){
			l = s[start:i] :: l;
			start = i+1;
		}
	l = s[start:] :: l;
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

lines(s: string): list of string
{
	# readline: only lines that end with a newline
	l: list of string;
	start := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n'){
			l = s[start:i] :: l;
			start = i+1;
		}
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

parseusers(udata: string)
{
	ls := lines(udata);
	users: list of ref User;
	lnum := 0;
	for(l := ls; l != nil; l = tl l){
		lnum++;
		p := hd l;
		if(p == nil || p[0] == '#')
			continue;
		f := fields(p, ':');
		if(len f < 2)
			error(sys->sprint("%s: /adm/users:%d: missing ':' after id", Esyntax, lnum));
		if(len f < 3)
			error(sys->sprint("%s: /adm/users:%d: missing ':' after name", Esyntax, lnum));
		u := ref User(int hd f, noneid, nil, hd tl f);
		users = u :: users;
	}
	a := array[len users] of ref User;
	i := len a;
	for(; users != nil; users = tl users)
		a[--i] = hd users;

	i = 0;
	lnum = 0;
	for(l = ls; l != nil; l = tl l){
		lnum++;
		p := hd l;
		if(p == nil || p[0] == '#')
			continue;
		f := fields(p, ':');
		if(len f < 3)
			error(sys->sprint("%s: /adm/users:%d: missing ':' after name", Esyntax, lnum));
		lead := hd tl tl f;
		if(lead != nil){
			u: ref User;
			for(j := 0; j < len a; j++)
				if(a[j].name == lead)
					u = a[j];
			if(u == nil)
				error(sys->sprint("%s: /adm/users:%d: leader %s does not exist", Enouser, lnum, lead));
			if(u.id == noneid)
				error(sys->sprint("%s: /adm/users:%d: group leader may not be none", Esyntax, lnum));
			a[i].lead = u.id;
		}
		if(len f < 4)
			error(sys->sprint("%s: /adm/users:%d: missing field", Esyntax, lnum));
		grp: list of int;
		for(m := fields(hd tl tl tl f, ','); m != nil; m = tl m){
			if(hd m == nil)
				continue;
			u: ref User;
			for(j := 0; j < len a; j++)
				if(a[j].name == hd m)
					u = a[j];
			if(u == nil)
				error(sys->sprint("%s: /adm/users:%d: user %s does not exist", Enouser, lnum, hd m));
			grp = u.id :: grp;
		}
		ga := array[len grp] of int;
		k := len ga;
		for(; grp != nil; grp = tl grp)
			ga[--k] = hd grp;
		a[i].memb = ga;
		i++;
	}
	fs.users = a;
}

loadusers(t: ref Tree)
{
	{
		(ok, q, length) := walk1(t, big Qadmroot, "users");
		if(!ok)
			error(Esrch);
		if(q.qtype & Sys->QTDIR)
			error(Etype);
		if(length >= MiB)
			error(Efsize);
		parseusers(string slurp(t, q.path, length));
	} exception e {
	"gefs:*" =>
		sys->fprint(sys->fildes(2), "gefs: user table broken: %s\n", errmsg(e));
		if(fs.users != nil || !permissive)
			raise e;
		sys->fprint(sys->fildes(2), "\tfalling back to default\n");
		parseusers("-1:adm::\n0:none::\n");
	}
	if((u := name2user("none")) != nil)
		noneid = u.id;
	if((u = name2user("adm")) != nil)
		admid = u.id;
	if((u = name2user("nogroup")) != nil)
		nogroupid = u.id;
}
