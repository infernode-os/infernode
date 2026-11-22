implement Wiki;

include "sys.m";
	sys: Sys;
	Qid, open, read, write, create, werrstr, fprint: import sys;
include "daytime.m";
	daytime: Daytime;
	now: import daytime;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "wiki.m";
include "draw.m";
include "sh.m";

init(b: Bufio)
{
	sys = load Sys Sys->PATH;
	bufio = b;
	daytime = load Daytime Daytime->PATH;
	str = load String String->PATH;
	wikidir = ".";
}

# wdir

setwikidir(s: string)
{
	wikidir = s;
}

wname(s: string): string
{
	return  wikidir + "/" + s;
}

wopen(f: string, mode:int): ref Sys->FD
{
	f = wname(f);
	rv := sys->open(f, mode);
	return rv;
}

wcreate(f: string, mode, perm: int): ref Sys->FD
{
	f = wname(f);
	rv := sys->create(f, mode, perm);
	return rv;
}

wBopen(f: string, mode: int): ref Iobuf
{
	f = wname(f);
	rv := bufio->open(f, mode);
	return rv;
}

wdirstat(f: string): ref Sys->Dir
{
	f = wname(f);
	(n, d) := sys->stat(f);
	if(n < 0)
		return nil;
	else
		return ref d;
}

# cache 

Nhash: con 64;
Mcache: con 4;

Wcache: adt {
	n: int;
	use: int;
	tcurrent: int;
	thist: int;
	hist: ref Whist;
	current: ref Whist;
	qid: ref Qid;
	qidhist: ref Qid;
};

tab := array[Nhash] of list of ref Wcache;

# Counted at each write (voidcache): a file read while it was being
# written may have been read in part, and is read again
wgen := 0;

findcache(n: int): ref Wcache
{
	for(wl :=tab[n%Nhash]; wl != nil; wl= tl wl){
		w := hd wl;
		if(w.n == n){
			w.use = now();
			return w;	
		}
	}
	return nil;
}

# What the store holds is what is shown: a file that can no longer be
# read as a page is no page (it stayed the last one read), and is not
# read again until it changes.
current(w: ref Wcache)
{
	lock := sys->sprint("d/L.%d", w.n);
	file := sys->sprint("d/%d", w.n);
	if(w.tcurrent + Tcache >= now())
		return;
	if(((d := wdirstat(file)) == nil) || (d.qid.path == w.qid.path && d.qid.vers == w.qid.vers)){
		w.tcurrent = now();
		return;
	}
	g := wgen;
	wh := readwhist(file, lock, w.qid);
	if(wh != nil)
		wh.n = w.n;
	w.current = wh;
	w.tcurrent = now();
	if(g != wgen){
		w.tcurrent = 0;
		w.qid = ref Qid(big -1, 0, 0);
	}
}

currenthist(w: ref Wcache)
{
	lock := sys->sprint("d/L.%d", w.n);
	file := sys->sprint("d/%d.hist", w.n);
	if(w.thist + Tcache >= now())
		return;
	if(((d := wdirstat(file)) == nil) || (d.qid.path == w.qidhist.path && d.qid.vers == w.qidhist.vers)){
		w.thist = now();
		return;
	}
	g := wgen;
	wh := readwhist(file, lock, w.qidhist);
	if(wh != nil)
		wh.n = w.n;
	w.hist = wh;
	w.thist = now();
	if(g != wgen){
		w.thist = 0;
		w.qidhist = ref Qid(big -1, 0, 0);
	}
}

voidcache(n: int)
{
	wgen++;
	if(n >= 0 && (c := findcache(n)) != nil){
		c.tcurrent = 0;
		c.thist = 0;
		# and forget the files' qids: a host file's version is its
		# mtime in seconds (fs(3)), the same for a write in the same
		# second as the last read, which was then never read again
		c.qid = ref Qid(big -1, 0, 0);
		c.qidhist = ref Qid(big -1, 0, 0);
	}
}

# we want to avoid locking as much as possible because
# the flush message kills procs possibly leaving stray locks.
# use immutable types and just let last-one-in-wins for caches.
# (file locks are released when the file reference is garbage collected :)
getcache(n, hist: int): ref Whist
{
	wh: ref Whist;
	if(n < 0 || n >= Maxpages)
		return nil;
	if((c := findcache(n)) != nil){
		current(c);
		if(hist)
			currenthist(c);
		if(hist)
			wh = c.hist;
		else
			wh = c.current;
		return wh;
	}
	# A number that is no page has no place here: any number can be
	# asked for, and each took a page's place.
	if(wdirstat(sys->sprint("d/%d", n)) == nil)
		return nil;
	h := n%Nhash;
	c = ref Wcache(n, now(), 0, 0, nil, nil, ref Qid(big -1, 0, 0), ref Qid(big -1, 0, 0));

	# last in wins!
	tab[h] = c :: evict(tab[h]);
	current(c);
	if(hist)
		currenthist(c);
	if(hist)
		wh = c.hist;
	else
		wh = c.current;
	return wh;
}

# A bucket with room for one more, its least recently used gone.  (The
# least use was looked for below ~0, which is -1: nothing was less,
# nothing was evicted, and the loop that waits for room never ended;
# the fifth page of a bucket stopped every walk in the wiki for good.)
evict(ol: list of ref Wcache): list of ref Wcache
{
	while(len ol >= Mcache){
		old := hd ol;
		for(l := tl ol; l != nil; l = tl l)
			if((hd l).use <= old.use)
				old = hd l;
		keep: list of ref Wcache;
		for(; ol != nil; ol = tl ol)
			if(hd ol != old)
				keep = hd ol :: keep;
		ol = keep;
	}
	return ol;
}

getcurrent(n: int): ref Whist
{
	return getcache(n, 0);
}

getcurrentbyname(s: string): ref Whist
{
	if((n := nametonum(s)) < 0)
		return nil;
	return getcache(n, 0);
}

gethistory(n: int): ref Whist
{
	return getcache(n, 1);
}

# io

# A lock for other servers of the store, where the file server has
# exclusive files (the emulator's host file system has none: there a
# page's writers are put in order by wikifs itself).  A lock held is
# waited for, with one line said of it, not ten a second; a lock that
# cannot be made at all (no d, a store that cannot be written) is not
# waited 200 seconds for at every look at a page.
getlock(lock:string): ref Sys->FD
{
	SECS := 200;

	for(i:=0; i<SECS*10; i++){
		fd := wcreate(lock, Sys->ORDWR, Sys->DMEXCL|8r666);
		if(fd != nil)
			return fd;
		e := sys->sprint("%r");
		if(!held(e)){
			werrstr(wname(lock) + ": " + e);
			return nil;
		}
		if(i == 0)
			sys->fprint(sys->fildes(2), "wikifs: waiting for %s: %s\n", wname(lock), e);
		sys->sleep(1000/10);
	}
	werrstr("couldn't acquire lock");
	return nil;
}

# the error of a file open for exclusive use somewhere else
held(e: string): int
{
	e = str->tolower(e);
	for(l := "lock" :: "exclusive" :: "in use" :: nil; l != nil; l = tl l){
		(nil, r) := str->splitstrl(e, hd l);
		if(r != nil)
			return 1;
	}
	return 0;
}


readwhist(file: string, lock: string, qid: ref Qid): ref Whist
{
	lfd: ref Sys->FD;
	d: ref Sys->Dir;
	b: ref Iobuf;
	wh: ref Whist;

	if((lfd = getlock(lock)) == nil)
		return nil;
	if((d = wdirstat(file)) == nil)
		return nil;
	if((b = wBopen(file, Sys->OREAD)) == nil)
		return nil;
	wh = Brdwhist(b);
	# a page or not, it is the file as it is now: one that is no page
	# is said to be once, and read again when it changes
	if(qid != nil)
		*qid =  d.qid;
	if(wh == nil)
		sys->fprint(sys->fildes(2), "wikifs: %s: no version of a page in it, left out\n", wname(file));
	lfd = nil;
	return wh;
}


Brdwline(b: ref Iobuf, nil: int): string
{
	p: string;

	if(b.getc() == '#'){
		p = b.gets('\n');
		return p;
	}else{
		b.ungetc();
		return nil;
	}
}

Srdwline(b: ref Iobuf, nil: int): string
{
	return b.gets('\n');
}

Brdwhist(b: ref Iobuf): ref Whist
{
	p, author, comment, title: string;
	current, conflict, c, n, t: int;
	w: array of ref Wdoc;
	h: ref Whist;

	if((p = b.gets('\n')) == nil){
		return nil;
	}

	title = strcondense(p);
	w = nil;
	n = 0;
	t = -1;
	author = nil;
	comment = nil;
	conflict = 0;
	current = 0;
	while((c = b.getc()) != Bufio->EOF){
		if(c != '#'){
			p = b.gets('\n');
			if(p == nil)
				break;
			case c {
			'D' =>
				t = int p;
			'A' =>
				author = p;
			'C' =>
				comment = p;
			'X' =>
				conflict = 1;
			};
		}else {
			b.ungetc();
			if(n == len w)
				w = (array[2*n+8] of ref Wdoc)[0:] = w;
			w[n] = ref Wdoc;
			w[n].time = t;
			w[n].author = author;
			w[n].comment = comment;
			w[n].wtxt = Brdpage(b, Brdwline);
			w[n].conflict = conflict;
			# a version with no text (a file cut short) is left out:
			# it raised, in whoever was reading the page
			if(w[n].wtxt == nil)
				w[n] = nil;
			else{
				if(!conflict)
					current = n;
				n++;
			}
			comment = nil;
			author = nil;
			conflict = 0;
			t = -1;
		}
	}
	# a title and nothing else is no page: its callers index doc
	if(n == 0)
		return nil;
	h = ref Whist;
	h.title = title;
	h.doc = w;
	h.ndoc = n;
	h.current = current;
	return h;
}


strcondense(s: string): string
{
	ss: string;
	ss = "";
	(nil, flds) := sys->tokenize(s, " \n\t\r");
	for(; flds != nil; flds = tl flds)
		if(tl flds == nil)
			ss += hd flds;
		else
			ss += hd flds + " ";
	return ss;
}

Brdpage(b: ref Iobuf, rdwline: ref fn(b: ref Iobuf, sep: int): string): list of ref Wpage
{
	p: string;
	pw: list of ref Wpage;
	waspara := 0;

	while((p = rdwline(b, '\n')) != nil){
		if(p[0] != '!')
			p = strcondense(p);
		if(len p == 0){
			if(waspara == 0){
				waspara=1;
				pw = ref Wpage(Wpara, nil, 0, nil) :: pw;
			}
			continue;
		}
		waspara = 0;
		case p[0] {
		'*' =>
			pw = ref Wpage(Wbullet, nil, 0, nil) :: pw;
			pw = ref Wpage(Wplain, p[1:], 0, nil) :: pw;
		'!' =>
			# kept as it is, with its newline: a last line without
			# one had the next line's # put on its end when stored
			# ("stays as it is#"), one more at each save
			t := p[1:];
			if(t == nil || t[len t - 1] != '\n')
				t += "\n";
			pw = ref Wpage(Wpre, t, 0, nil) :: pw;
		* =>
			(nil, c) := str->splitl(p, "a-z");
			(nil, d) := str->splitl(p, "A-Z");
			if(len c == 0 && len d != 0){
				pw = ref Wpage(Wheading, p, 0, nil) :: pw;
				continue;
			}
			pw = ref Wpage(Wplain, p, 0, nil) :: pw;
		}
	}
	if(pw == nil)
		return nil;
	pw = reverse(pw);
	pw = wcondense(pw);	# reverses
	pw = wlink(pw);		# reverses again
	return pw;
}

wcondense(wtxt: list of ref Wpage): list of ref Wpage
{
	nw : list of ref Wpage;

	wl := wtxt;
	while(wl != nil){
		if((hd wl).typ != Wplain){
			nw = hd wl :: nw;
			wl = tl wl;
			continue;
		}
		txt := "";
		first := "";
		while(wl != nil && (hd wl).typ == Wplain ){
			w := hd wl;
			w.text = strcondense(w.text);
			txt = txt + first + w.text;
			first = " ";
			wl = tl wl;
		}
		nw = ref Wpage(Wplain, txt, 0, nil) :: nw;
		if(wl == nil)
			break;
	}
	return nw;		# the list is now in reverse order
}

mklink(s: string): ref Wpage
{	
	w : ref Wpage;
	for(i:=0; i < len s; i++)
		if(s[i] == '|')
			break;
	q := s[i:];
	if(len q == 0)
		w = ref Wpage(Wlink, strcondense(s), 0, nil);
	else
		w = ref Wpage(Wlink, strcondense(s[0:i]), 0, strcondense(s[i+1:]));
	return w;
}

wlink(wtxt: list of ref Wpage): list of ref Wpage
{
	nw: list of ref Wpage;
	for(wl := wtxt; wl != nil; wl = tl wl){
		w := hd wl;
		if(w.typ != Wplain){
			nw = w :: nw;
			continue;
		}
		# TODO this is all wrong
		l : list of ref Wpage;
		l = nil;
		for(;;){
			(a, b) := str->splitl(w.text, "[");
			if(len a > 0){
				w.text = a;
				l = w :: l;
			}
			(c, d) := str->splitl(b, "]");
			if(len c > 1)
				l = mklink(c[1:]) :: l;
			if(len d > 1)
				w = ref Wpage(Wplain, d[1:], 0, nil);
			else{
				for(; l != nil; l = tl l)
					nw = hd l :: nw;
				break;
			}
		}
	}
	return nw;
}

ismanchar(c: int): int
{
	return ('a' <= c && c <= 'z')
		|| ('A' <= c && c <= 'Z')
		|| ('0' <= c && c <= '9')
		|| c=='_' || c=='-' || c=='.' || c=='/'
		|| (c < 0);	# UTF
}


# map

# The map is d/map, a line a page: its number, a blank, its title.
# What is read of it never raises and is never nil: a line that is no
# entry is left out and said, a file past Maxmap is not read (the map
# before it stays; at the start that is no pages), so a store that has
# been damaged or filled answers "not found" where it stopped the
# wiki.  (With no map read, nametonum and numtoname went through nil,
# in the one process that every walk waits for.)
currentmap(force: int)
{
	lfd: ref Sys->FD;
	d: ref Sys->Dir;

	if(!force && map != nil && map.t+Tcache >= now())
		return;
	if(map == nil){
		map = ref Map;
		map.qid = Qid(big -1, 0, 0);
	}

	if((lfd = getlock("d/L.map")) == nil)
		return;
	if((d = wdirstat("d/map")) == nil)
		return;
	# A forced load (after allocnum adds a page) must not trust the qid:
	# a host file system can leave vers unchanged by a write within the
	# same second, which hid the new page from listings.
	if(!force && d.qid.path == map.qid.path && d.qid.vers == map.qid.vers){
		map.t = now();
		return;
	}

	if(d.length > big Maxmap){
		if(d.qid.path != map.qid.path || d.qid.vers != map.qid.vers)
			sys->fprint(sys->fildes(2), "wikifs: %s is %bd bytes, more than the %d a map may be: not read\n",
				wname("d/map"), d.length, Maxmap);
		map.qid = d.qid;
		map.t = now();
		return;
	}
	(text, ok) := readmap(int d.length);
	if(ok < 0)
		return;

	nmap := ref Map;
	m := 0;
	bad := 0;
	top := -1;
	e := 0;
	for(b := 0; b < len text; b = e) {
		e = lineend(text, b);
		s := text[b:e];
		(n, title) := mapline(s);
		if(n < 0){
			if(n == -1 && bad++ < 3)
				sys->fprint(sys->fildes(2), "wikifs: %s: \"%s\" is no entry, left out\n", wname("d/map"), printable(s, 40));
			continue;
		}
		if(m == len nmap.el)
			nmap.el = (array[2*m + 8] of ref Mapel)[0:] = nmap.el;
		nmap.el[m++] = ref Mapel(title, n);
		if(n > top)
			top = n;
	}
	if(bad > 3)
		sys->fprint(sys->fildes(2), "wikifs: %s: and %d more\n", wname("d/map"), bad - 3);
	nmap.byn = array[top + 1] of ref Mapel;
	for(i := 0; i < m; i++)
		nmap.byn[nmap.el[i].n] = nmap.el[i];
	mergesort(nmap.el[:m], array[m] of ref Mapel, m);
	nmap.qid = d.qid;
	nmap.t = now();
	nmap.nel = m;
	map = nmap;
	lfd = nil;
}

# The map file whole, n bytes of it (no more than Maxmap: its callers
# have looked), as text
readmap(n: int): (string, int)
{
	fd := wopen("d/map", Sys->OREAD);
	if(fd == nil)
		return (nil, -1);
	buf := array[n] of byte;
	for(i := 0; i < n; ){
		k := sys->read(fd, buf[i:], n - i);
		if(k <= 0)
			break;
		i += k;
	}
	return (string buf[0:i], 0);
}

# where the line of s that starts at i ends: past its newline
lineend(s: string, i: int): int
{
	for(; i < len s; i++)
		if(s[i] == '\n')
			return i+1;
	return i;
}

# A line of the map: (number, title); (-1, nil) if it is not one,
# (-2, nil) if it is empty
mapline(s: string): (int, string)
{
	if(s == "\n" || s == "")
		return (-2, nil);
	n := 0;
	for(i := 0; i < len s && s[i] >= '0' && s[i] <= '9'; i++){
		n = n*10 + s[i] - '0';
		if(n >= Maxpages)
			return (-1, nil);
	}
	if(i == 0 || i >= len s || s[i] != ' ')
		return (-1, nil);
	title := strcondense(s[i:]);
	if(title == nil)
		return (-1, nil);
	return (n, title);
}

# what a file held, fit to print: no control characters, no more than max
printable(s: string, max: int): string
{
	t := "";
	for(i := 0; i < len s && i < max; i++)
		if(s[i] < ' ' || s[i] == 16r7f)
			t[len t] = ' ';
		else
			t[len t] = s[i];
	return t;
}

mergesort(a, b: array of ref Mapel, r: int)
{
	if (r > 1) {
		m := (r-1)/2 + 1;
		mergesort(a[0:m], b[0:m], m);
		mergesort(a[m:r], b[m:r], r-m);
		b[0:] = a[0:r];
		for ((i, j, k) := (0, m, 0); i < m && j < r; k++) {
			if (b[i].s > b[j].s)
				a[k] = b[j++];
			else
				a[k] = b[i++];
		}
		if (i < m)
			a[k:] = b[i:m];
		else if (j < r)
			a[k:] = b[j:r];
	}
}

# once this function has a local reference to map it doesn't need a lock
# because currentmap() will create a new object, the referenced object doesn't change.
nametonum(s: string): int
{
	lo, hi, m, rv: int;
	p: ref Map;

	s = str->tolower(s);
	for(i:=0;i< len s; i++)
		if(s[i] == '_')
			s[i] = ' ';
	currentmap(0);
	p = map;
	if(p == nil)
		return -1;
	lo = 0;
	hi = p.nel;
	while(hi-lo >1){
		m = (lo+hi)/2;
		if(s < p.el[m].s)
			hi = m;
		else
			lo = m;
	}
	if(hi-lo == 1 && s == p.el[lo].s)
		rv = p.el[lo].n;
	else
		rv = -1;
	return rv;
}

numtoname(n: int): string
{
	p: ref Map;
	currentmap(0);
	p = map;
	if(p == nil || n < 0 || n >= len p.byn || p.byn[n] == nil)
		return nil;
	return p.byn[n].s;
}

# A title as the map keeps it and a walk looks it up: lower case, its
# blanks single, a _ a blank (a page is named in a URL with _ for a
# blank).  nil, with the error string set, for one that can name no
# page: it was looked at before it was put in this form, so "Map",
# " new" and "42" made pages that a walk took for wikifs's own files
# or for a page's number, and a title of blanks a page named "".
goodtitle(title: string): string
{
	for(i := 0; i < len title; i++){
		c := title[i];
		if(c == '_')
			title[i] = ' ';
		else if(c < ' ' && c != '\t' || c == 16r7f){
			werrstr("a control character in the title");
			return nil;
		}
	}
	title = str->tolower(strcondense(title));
	if(title == nil){
		werrstr("no title");
		return nil;
	}
	if(len title > Maxtitle){
		werrstr(sys->sprint("title too long: at most %d characters", Maxtitle));
		return nil;
	}
	if(title == "map" || title == "new" || title == "." || title == ".."){
		werrstr("reserved title name");
		return nil;
	}
	(nil, b) := str->splitl(title, "/<>:\\");
	if(len b != 0){
		werrstr("invalid character in name");
		return nil;
	}
	# A page is asked for by its title, as a name in a path, and what
	# httpd(8) serves no file by, it serves no page by: a name that
	# begins with a dot or ends with one, a Windows device's (con,
	# nul.txt, com1), a volume's short alias (a~1).  Such a page was
	# made, listed, and reached only by its number.
	if(title[0] == '.' || title[len title - 1] == '.'){
		werrstr("a title that begins or ends with a dot cannot be asked for by name");
		return nil;
	}
	for(i = 0; i + 1 < len title; i++)
		if(title[i] == '~' && title[i+1] >= '0' && title[i+1] <= '9'){
			werrstr("a title with ~ before a digit cannot be asked for by name");
			return nil;
		}
	(base, nil) := str->splitl(title, ".");
	case base {
	"con" or "prn" or "aux" or "nul" or "conin$" or "conout$" or "clock$" =>
		werrstr("a title that is a device's name cannot be asked for by name");
		return nil;
	}
	if(len base == 4 && (base[0:3] == "com" || base[0:3] == "lpt") &&
	   (base[3] >= '0' && base[3] <= '9' || base[3] == 16rB9 || base[3] == 16rB2 || base[3] == 16rB3)){
		werrstr("a title that is a device's name cannot be asked for by name");
		return nil;
	}
	for(i = 0; i < len title; i++)
		if(title[i] < '0' || title[i] > '9')
			break;
	if(i == len title){
		werrstr("a title of digits alone is a page's number");
		return nil;
	}
	return title;
}

# The number of the page titled title, added to the map if it is new.
# A title is at most Maxtitle characters, the map at most Maxmap bytes
# and Maxpages pages: past either the wiki is full and says so (nothing
# was bounded: a title could be a whole request, a few hundred of them
# took the map past Maxmap, where it was no longer read while lines
# went on being added to it, twice for a title, and after the next
# start there was no map at all).
allocnum(title: string, mustbenew:int): int
{
	if((title = goodtitle(title)) == nil)
		return -1;
	if((n := nametonum(title)) >=0){
		if(mustbenew){
			werrstr("duplicate title");
			return -1;
		}
		return n;
	}

	if((lfd := getlock("d/L.map")) == nil)
		return -1;
	d := wdirstat("d/map");
	if(d == nil){
		werrstr(sys->sprint("cannot open %s: %r", wname("d/map")));
		return -1;
	}
	# full already: said before the file is read for the title
	if(d.length + big (len title + 3) > big Maxmap){
		werrstr("the wiki is full: no page can be added");
		return -1;
	}
	(text, ok) := readmap(int d.length);
	if(ok < 0){
		werrstr(sys->sprint("cannot open %s: %r", wname("d/map")));
		return -1;
	}
	# the file itself, for a title another server of the store has added
	n = 0;
	last := "\n";
	size := d.length;
	e := 0;
	for(o := 0; o < len text; o = e){
		e = lineend(text, o);
		s := text[o:e];
		last = s;
		(en, et) := mapline(s);
		if(en < 0)
			continue;
		if(et == title){
			lfd = nil;
			currentmap(1);
			if(mustbenew){
				werrstr("duplicate title");
				return -1;
			}
			return en;
		}
		if(en >= n)
			n = en + 1;
	}
	line := sys->sprint("%d %s\n", n, title);
	# a line a failed write cut short is ended, not joined to this one
	if(last[len last - 1] != '\n')
		line = "\n" + line;
	b := array of byte line;
	if(n >= Maxpages || size + big len b > big Maxmap){
		werrstr("the wiki is full: no page can be added");
		return -1;
	}
	afd := wopen("d/map", Sys->OWRITE);
	if(afd == nil || sys->seek(afd, big 0, Sys->SEEKEND) < big 0 || sys->write(afd, b, len b) != len b){
		werrstr(sys->sprint("cannot add to %s: %r", wname("d/map")));
		return -1;
	}
	afd = nil;
	lfd = nil;
	currentmap(1);
	return n;
}

# The doctext s, its version (D, a time in seconds) made later than ev,
# the version it replaces: two edits in one second are two versions,
# with their own names in the history, and an edit of the first is a
# conflict with the second
laterthan(s: string, ev: int): string
{
	(d, rest) := str->splitl(s, "\n");
	if(len d < 2 || d[0] != 'D')
		return s;
	if(int d[1:] > ev)
		return s;
	return sys->sprint("D%ud", ev + 1) + rest;
}

# The newest version in the history file hist (its last D line; its
# text's lines begin with '#'), or 0, read from its end
histlast(hist: string): int
{
	fd := wopen(hist, Sys->OREAD);
	if(fd == nil)
		return 0;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return 0;
	end := d.length;
	for(n := big 4096; ; n *= big 2){
		off := end - n;
		if(off < big 0)
			off = big 0;
		buf := array[int (end - off)] of byte;
		k := sys->pread(fd, buf, len buf, off);
		if(k <= 0)
			return 0;
		s := string buf[0:k];
		for(i := len s - 1; i >= 0; i--)
			if(s[i] == 'D' && i > 0 && s[i-1] == '\n'){	# (the first line is the title)
				j := i + 1;
				while(j < len s && s[j] >= '0' && s[j] <= '9')
					j++;
				if(j < len s && s[j] == '\n')
					return int s[i+1:j];
			}
		if(off == big 0)
			return 0;
	}
}

# The versions in the history file hist (its D lines; a text's lines
# begin with '#') and its bytes
histsize(hist: string): (int, big)
{
	fd := wopen(hist, Sys->OREAD);
	if(fd == nil)
		return (0, big 0);
	nv := 0;
	n := big 0;
	bol := 0;	# (the first line is the title)
	buf := array[64*1024] of byte;
	while((k := sys->read(fd, buf, len buf)) > 0){
		for(i := 0; i < k; i++){
			c := buf[i];
			if(bol && c == byte 'D')
				nv++;
			bol = c == byte '\n';
		}
		n += big k;
	}
	return (nv, n);
}

# does the file end in a newline (or hold nothing)?
endsline(fd: ref Sys->FD): int
{
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || d.length == big 0)
		return 1;
	buf := array[1] of byte;
	return sys->pread(fd, buf, 1, d.length - big 1) != 1 || buf[0] == byte '\n';
}

# A file replaced whole: written beside it and renamed over it, so that
# a reader has the old file or the new and never a part, and a write
# that fails leaves the old.
replacefile(file: string, b: array of byte): int
{
	# a page made read-only is not to be written, by a rename either
	if(wdirstat(file) != nil && wopen(file, Sys->OWRITE) == nil)
		return -1;
	new := file + ".new";
	fd := wcreate(new, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	if(sys->write(fd, b, len b) != len b){
		e := sys->sprint("%r");
		fd = nil;
		sys->remove(wname(new));
		werrstr(e);
		return -1;
	}
	fd = nil;
	(nil, base) := str->splitr(file, "/");
	nd := sys->nulldir;
	nd.name = base;
	if(sys->wstat(wname(new), nd) >= 0)
		return 0;
	# a file server that will not rename over a file: the old one
	# goes first, with the new one already whole beside it
	sys->remove(wname(file));
	if(sys->wstat(wname(new), nd) >= 0)
		return 0;
	sys->remove(wname(new));
	if((fd = wcreate(file, Sys->OWRITE, 8r666)) == nil)
		return -1;
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

# A version of page num written: s is its doctext, t the version it was
# made from.  Its caller is the one process of wikifs that writes pages
# (the lock is a file made for exclusive use, which the emulator's host
# file system does not have: two edits of one version at once were both
# told they were the page).  Each write is checked, and the page is
# replaced whole or not at all: it was truncated and then written in
# two writes whose results nobody looked at, so a full disk, or a
# reader between them, had a page of a title and nothing else.
writepage(num: int, t: int, s: string, title: string): int
{
	err: string;
	tmp := sys->sprint("d/%d", num);
	tmplock := sys->sprint("d/L.%d", num);
	hist := sys->sprint("d/%d.hist", num);
	if((lfd := getlock(tmplock)) == nil)
		return -1;
	conflict := 0;
	if((b := wBopen(tmp, Sys->OREAD)) != nil){
		b.gets('\n');		# title
		p := b.gets('\n');		#version
		if(p == nil || p[0] != 'D'){
			err = sys->sprint("bad format in extant file");
			conflict = 1;
		}else{
			# an edit of a version not the current one, as Plan 9's
			# writepage: the same text sent again is taken as done,
			# anything else is a conflict, kept in the history
			ev := int p[1:];
			if(ev != t){
				os := "";
				while((l := b.gets('\n')) != nil)
					os += l;
				(nil, ns) := str->splitl(s, "\n");
				if(ns != nil && ns[1:] + "\n" == os){
					lfd = nil;
					return 0;
				}
				err = sys->sprint("update conflict %ud != %ud", t, ev);
				conflict = 1;
			}
		}
		b.close();
	}else{
		if(t != 0){
			lfd = nil;
			werrstr("did not expect to create");
			return -1;
		}
	}

	# A page's history has its limits, as its title and its text
	# have: an open wiki took versions for as long as they came (3780
	# of one page in a minute of writers, a history.html of them all
	# made at each request), and a disk's worth.  A page at its limit
	# takes no edit until its history has been cut or moved away.
	(nv, hlen) := histsize(hist);
	if(nv >= Maxvers || hlen + big (len array of byte s) > big Maxhist){
		lfd = nil;
		werrstr(sys->sprint("the page's history is full (%d versions, %bd bytes; at most %d and %d): d/%d.hist must be cut or moved before the page is edited again",
			nv, hlen, Maxvers, Maxhist, num));
		return -1;
	}

	# later than every version in the history, a conflicting one too
	s = laterthan(s, histlast(hist));
	rec := s + "\n";
	if(conflict)
		rec = "X\n" + rec;
	if((fd := wopen(hist, Sys->ORDWR)) == nil){
		if((fd = wcreate(hist, Sys->ORDWR, 8r666)) == nil){
			lfd = nil;
			return -1;
		}
		rec = title + "\n" + rec;
	}else if(!endsline(fd))
		rec = "\n" + rec;	# after a record a failed write cut short
	hb := array of byte rec;
	if(sys->seek(fd, big 0, Sys->SEEKEND) < big 0 || sys->write(fd, hb, len hb) != len hb){
		e := sys->sprint("cannot write the page's history: %r");
		lfd = nil;
		voidcache(num);
		werrstr(e);
		return -1;
	}
	fd = nil;

	if(conflict){
		lfd = nil;
		voidcache(num);
		werrstr(err);
		return -1;
	}

	if(replacefile(tmp, array of byte (title + "\n" + s + "\n")) < 0){
		e := sys->sprint("cannot write the page: %r");
		lfd = nil;
		voidcache(num);
		werrstr(e);
		return -1;
	}
	lfd = nil;
	voidcache(num);
	return 0;
}

# transform

endlin(s: string, dosharp: int): string
{
	if(dosharp){
		if(len s == 1 && s[0] == '#')
			return s;
		if(len s > 1 && s[len s - 2] == '\n' && s[len s - 1] == '#')
			return s;
		s += "\n#";
	}else{
		if(len s > 1 && s[len s - 1] == '\n')
			return s;
		s += "\n";
	}
	return s;
}

pagetext(page: list of ref Wpage, dosharp: int): string
{
	inlist, inpara: int;
	s, t, prefix, sharp: string;
	w: ref Wpage;

	inlist = 0;
	inpara = 0;
	prefix = "";
	if(dosharp)
		sharp = "#";
	else
		sharp = "";
	s = sharp;
	for(wl := page; wl != nil; wl = tl wl){
		w = hd wl;
		case w.typ{
		Wheading =>
			if(inlist){
				prefix = "";
				inlist = 0;
			}
			s = endlin(s, dosharp);
			if(!inpara){
				inpara = 1;
				s += "\n" + sharp;
			}
			s += w.text + "\n" + sharp + "\n" + sharp;
		Wpara =>
			s = endlin(s, dosharp);
			if(inlist){
				prefix = "";
				inlist = 0;
			}
			if(!inpara){
				inpara = 1;
				s += "\n" + sharp;
			}
		Wbullet =>
			s = endlin(s, dosharp);
			if(!inlist)
				inlist = 1;
			if(inpara)
				inpara = 0;
			s += " *\t";
			prefix = "\t";
		Wlink =>
			if(inpara)
				inpara = 0;
			t = "[" + w.text;
			if(w.url == nil)
				t += "]";
			else
				t += " | " + w.url + "]";
			s += t;
		Wpre =>
			if(inlist){
				prefix = "";
				inlist = 0;
			}
			if(inpara)
				inpara = 0;
			s = endlin(s, dosharp);
			# the text after the ! as it was read, blanks and all:
			# "! " put a blank more in front at each save
			s += "!" + w.text +  sharp;
		Wplain =>
			if(inpara)
				inpara = 0;
			s += w.text;
		}
	}
	s = endlin(s, dosharp);
	return s;
}

doctext(d: ref Wdoc): string
{
	s: string;
	s = sys->sprint("D%d", d.time);
	if(d.comment != nil)
		s += "\nC" + d.comment;
	if(d.author != nil)
		s += "\nA" + d.author;
	if(d.conflict)
		s += "\nX";
	s += "\n";
	s += pagetext(d.wtxt, 1);	
	return s;
}

reverse(wtxt: list of ref Wpage): list of ref Wpage
{
	nw: list of ref Wpage;
	for(; wtxt != nil; wtxt = tl wtxt)
		nw = hd wtxt :: nw;
	return nw;
}

printpage(wl: list of ref Wpage)
{
	for(; wl != nil; wl = tl wl){
		w := hd wl;
		case w.typ{
		Wpara =>
			sys->print("para\n");
		Wheading =>
			sys->print("heading '%s'\n", w.text);
		Wbullet =>
			sys->print("bullet\n");
		Wlink =>
			sys->print("link '%s' '%s'\n", w.text, w.url);
		Wman =>
			sys->print("man %d %s\n", w.section, w.text);
		Wplain =>
			sys->print("plain '%s'\n", w.text);
		Wpre =>
			sys->print("pre '%s'\n", w.text);
		}
	}
}

pagehtml(page: list of ref Wpage, ty: int): string
{
	inpre, inlist, inpara: int;
	s, p: string;
	w: ref Wpage;

	inlist = 0;
	inpara = 0;
	inpre = 0;

	for(wl := page; wl != nil; wl = tl wl){
		w = hd wl;
		case w.typ{
		Wheading =>
			if(!inpara){
				inpara = 1;
				s += "\n<p>\n";
			}
			s += "<b>" + hesc(w.text) + "</b>\n<p>\n";
		Wpara =>
			if(inlist){
				inlist = 0;
				s += "\n</ul>\n";
			}
			if(inpre){
				inpre = 0;
				s += "</pre>\n";
			}
			if(!inpara){
				inpara = 1;
				s += "\n<p>\n";
			}
		Wbullet =>
			if(inpre){
				inpre = 0;
				s += "</pre>\n";
			}
			if(!inlist){
				inlist = 1;
				s += "\n<ul>\n";
			}
			if(inpara)
				inpara = 0;
			s += "\n<li>\n";
		Wlink =>
			if(inpara)
				inpara = 0;
			if(w.url == nil)
				p = mkurl(w.text, ty);
			else
				p = w.url;
			# anyone may write a page: a link is to a page or a
			# place on the web, never script, and its URL stays
			# inside its attribute
			if(!safeurl(p)){
				s += escap(w.text, 0);
				break;
			}
			s += "<a href=\"" + hesc(p) + "\">";
			s += escap(w.text, 0);
			s += "</a>";
		Wpre =>
			if(inpara)
				inpara = 0;
			if(inlist){
				inlist = 0;
				s += "\n</ul>\n";
			}
			if(!inpre){
				inpre = 1;
				s += "\n<pre>\n";
			}
			s += escap(w.text, 1);
		Wplain =>
			if(inpre){
				inpre = 0;
				s += "</pre>\n";
			}
			if(inpara)
				inpara = 0;
			s += escap(w.text, 0);
		}
	}
	if(inlist)
		s += "\n</ul>\n";
	if(inpre)
		s += "</pre>\n";
	if(!inpara)
		s += "\n<p>\n";
	return s;
}

# The schemes a link may name; a URL with none is a path of this site
linkschemes := array[] of {"http", "https", "ftp", "mailto", "telnet", "file"};

safeurl(u: string): int
{
	for(i := 0; i < len u; i++){
		c := u[i];
		if(c == ':'){
			sch := str->tolower(u[0:i]);
			for(j := 0; j < len linkschemes; j++)
				if(sch == linkschemes[j])
					return 1;
			return 0;
		}
		if(c == '/' || c == '?' || c == '#')
			break;
	}
	return 1;
}

# What anyone wrote, inside an element or an attribute's quotes
hesc(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'&' =>	t += "&amp;";
		'<' =>	t += "&lt;";
		'>' =>	t += "&gt;";
		'"' =>	t += "&quot;";
		'\'' =>	t += "&#39;";
		* =>	t[len t] = s[i];
		}
	return t;
}

mkurl(s: string, ty: int): string
{
	if((len s >= 4 && s[0:4] == "ftp:")
		|| (len s >= 6 && s[0:6] == "https:")
		|| (len s >= 5 && (s[0:5] == "http:" ||s[0:5] == "file:"))
		|| (len s >= 7 && (s[0:7] == "mailto:" || s[0:7] == "telnet:")))
		return s;
	if(ty == Toldpage)
		s = sys->sprint("../../%s", s);
	else
		s = sys->sprint("../%s", s);
	for(i := 0; i < len s; i++)
		if(s[i] == ' ')
			s[i] = '_';
	return s;
}

escap(s: string, pre: int):string
{
	ss := "";
	for(i := 0; i < len s; i++){
		if(str->in(s[i], "<>& ")){
			case s[i] {
			'<' =>
				ss += "&lt;";
			'>' =>
				ss += "&gt;";
			'&' =>
				ss += "&amp;";
			' ' =>
				if(pre)
					ss += " ";
				else
					ss += "\n";
			}
		} else
			ss[len ss] = s[i];
	}
	return ss;
}

tohtml(h: ref Whist, d: ref Wdoc, ty: int): string
{
	s: string;
	sub := array[3] of Sub;
	nsub: int;

	t := gettemplate(ty);
	(p, q) := str->splitstrl(t, "PAGE");
	if(q != nil)
		q = q[4:];
	nsub = 0;
	if(h != nil){
		# in <title>, the heading and the edit form's value="..."
		sub[nsub] = Sub("TITLE", hesc(h.title));
		nsub++;
	}
	if(d != nil){
		ver := sys->sprint("%ud", d.time);
		sub[nsub] = Sub("VERSION", ver);
		nsub++;
		atime := daytime->text(daytime->local(d.time));
		sub[nsub] = Sub("DATE", atime);
		nsub++;
	}
	s = appendsub(p, sub[0:nsub]);
	case ty{
	Tpage or Toldpage =>
		s += pagehtml(d.wtxt, ty);
	Tedit =>
		# in a <textarea>: a page holding </textarea> stays text
		s += hesc(pagetext(d.wtxt, 0));
	Tdiff =>
		s += diffhtml(h);
	Thistory =>
		s += historyhtml(h);
	Tnew or Twerror =>
		;
	}
	if(q != nil)
		s += appendsub(q, sub[0:nsub]);
	return s;
}

name := array[] of {
	"page.html",
	"edit.html",
	"diff.html",
	"history.html",
	"new.html",
	"oldpage.html",
	"werror.html",
	# the text ones, in the same order (Ntemplate+T...); nil: there is none
	"page.txt",
	nil,
	"diff.txt",
	"history.txt",
	nil,
	"oldpage.txt",
	"werror.txt"
};

Template: adt {
	s: string;
	t: int;
	qid: Sys->Qid;
};

cache := array[2*Ntemplate] of ref Template;

gettemplate(typ: int): string
{
	# (it was typ >= Ntemplate: the text templates, which are asked for
	# as Ntemplate+T..., were never read)
	if(typ < 0 || typ >= len name || name[typ] == nil)
		return nil;

	c := cache[typ];
	if(c != nil && c.t + Tcache >= now())
		return c.s;
	d := wdirstat(name[typ]);
	if(d == nil && c != nil)
		return c.s;
	if(d == nil)
		return nil;
	if(c != nil && d.qid.vers == c.qid.vers && d.qid.path == c.qid.path){
		nt := ref Template(c.s, now(), d.qid);
		cache[typ] = nt;
		return nt.s;
	}
	b := wBopen(name[typ], Sys->OREAD);
	if(b == nil)
		return nil;
	ss: string;
	while((s := b.gets('\n')) != nil)
		ss += s;
	t := ref Template(ss, now(), d.qid);
	cache[typ] = t;
	return ss;
}

appendsub(p: string, sub: array of Sub): string
{
	r, q, s: string;
	
	while(len p > 0){
		m := -1;
		r = p;
		for(i:=0;i<len sub;i++){
			(r, q) = str->splitstrl(r, sub[i].match);
			if(q != nil){
				m = i;
			}
		}
		s += r;
		p = p[len r:];
		if(m >= 0){
			s += sub[m].sub;
			p = p[len sub[m].match:];
		}
	}
	return s;
}

historyhtml(h: ref Whist): string
{
	s, tmp, atime: string;

	s = "<ul>\n";
	for(i:=h.ndoc-1;i>=0;i--){
		if(i==h.current)
			tmp="index.html";
		else
			tmp=sys->sprint("%ud", h.doc[i].time);
		atime = daytime->text(daytime->local(h.doc[i].time));
		s += "<li><a href=\"" + tmp + "\">" + atime + "</a>";
		if(h.doc[i].author != nil)
			s += ", " + hesc(h.doc[i].author);
		if(h.doc[i].conflict)
			s += ", conflicting write";
		s += "\n";
		if(h.doc[i].comment != nil)
			s += "<br><i>" + hesc(h.doc[i].comment) + "</i>\n";
	}
	s += "</ul>";
	return s;
}

stringfromint(i: int): string
{
	s: string;
	s[0] = i;
	return s;
}

mktemp(as: string): string
{
	pid: int;
	s: string;

	s = nil;
	pid = sys->pctl(0, nil);
	for (x := len as - 1; x >= 0; x--)
		if (as[x] == 'X') {
			s = stringfromint('0' + pid % 10) + s;
			pid /= 10;
		}
		else
			s = stringfromint(as[x]) + s;
	s[len s] = 'a';
	for (;;) {
		(rv, nil) := sys->stat(s);
		if (rv < 0)
			break;
		if (s[len s - 1] == 'z')
			return "/";
		s[len s - 1]++;
	}
	return s;
}

exec(sync: chan of int, cmd : string, argl : list of string, out: array of ref Sys->FD)
{
	file := cmd;
	if(len file<4 || file[len file-4:]!=".dis")
		file += ".dis";

	sys->pctl(Sys->FORKFD, nil);
	sys->dup(out[1].fd, 1);
	out[0] = nil;
	out[1] = nil;
	sync <-= sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	c := load Command file;
	if(c == nil) {
		err := sys->sprint("%r");
		if(file[0]!='/' && file[0:2]!="./"){
			c = load Command "/dis/"+file;
			if(c == nil)
				err = sys->sprint("%r");
		}
		if(c == nil){
			# debug(sys->sprint("file %s not found\n", file));
			sys->fprint(sys->fildes(2), "%s: %s\n", cmd, err);
			return;
		}
	}
	c->init(nil, argl);
}

dodiff(f1, f2: string): ref Sys->FD
{
	p := array[2] of ref Sys->FD;

	if(sys->pipe(p) < 0)
		return nil;
	sync := chan of int;
	spawn exec(sync, "/dis/diff.dis", "diff" :: f1 :: f2 :: nil, (array[2] of ref Sys->FD)[0:] = p);
	<-sync;
	p[1] = nil;
	return p[0];
}

GREY :con "<font color=#777777>";
UNGREY  :con  "</font>";

copythru(s, new: string, line, end: int): (string, string, int)
{
	while(line < end){
		(r, q) := str->splitl(new, "\n");
		if(q != nil){
			s += r + "\n";
			new = q[1:];
		}else{
			s += r;
			new = nil;
			break;
		}
		line++;
	}
	if(line < end)
		line = end;
	return (s, new, line);
}

sdiff(h: ref Whist, i, j: int): string
{
	s : string;

	if(j < 0)
		return pagehtml(h.doc[i].wtxt, Tpage);
	fn1 := mktemp("/tmp/wiki.XXXXXX");
	if((fd1 := sys->create(fn1, Sys->ORDWR|Sys->ORCLOSE, 8r666)) == nil)
		return "\nopentemp failed; sorry\n";
	fn2 := mktemp("/tmp/wiki.XXXXXX");
	if((fd2 := sys->create(fn2, Sys->ORDWR|Sys->ORCLOSE, 8r666)) == nil)
		return "\nopentemp failed; sorry\n";

	new := pagehtml(h.doc[i].wtxt, Tpage);
	old := pagehtml(h.doc[j].wtxt, Tpage);
	sys->fprint(fd1, "%s", new);
	sys->fprint(fd2, "%s", old);
	
	fdiff := dodiff(fn2, fn1);
	if(fdiff == nil)
		s += "\ndiff failed; sorry\n";
	else{
		nline := 0;
		b := bufio->fopen(fdiff, Sys->OREAD);
		while((p := b.gets('\n')) != nil){
			if(p[0]=='<' || p[0]=='>' || p[0]=='-')
				continue;
			(nil, r) := str->splitl(p, "acd");
			if(r == nil)
				continue;
			case r[0] {
			'a' or 'c' =>
				(n1, nil) := str->toint(r[1:], 10);
				(nil,v) := str->splitl(r, ",");
				if(v != nil)
					(n2, nil) := str->toint(v[1:], 10);
				else
					n2 = n1;
				s += GREY;
				(s, new, nline) = copythru(s, new, nline, n1-1);	
				s += UNGREY;
				(s, new, nline) = copythru(s, new, nline, n2);
			}
		}
		s += GREY;
		s += new;
		s += UNGREY;
	}
	return s;
}

diffhtml(h: ref Whist): string
{
	s, tmp, atime: string;

	# The newest Maxdiff versions: each costs a diff, and a page
	# with thousands of versions never answered (anyone may add one).
	for(i:=h.ndoc-1;i>=0 && i >= h.ndoc-Maxdiff;i--){
		s += "<hr>\n";
		if(i==h.current)
			tmp = "index.html";
		else
			tmp = sys->sprint("%ud", h.doc[i].time);
		atime = daytime->text(daytime->local(h.doc[i].time));
		s += "<li><a href=\"" + tmp + "\">" + atime + "</a>";
		if(h.doc[i].author != nil)
			s += ", " + hesc(h.doc[i].author);
		if(h.doc[i].conflict)
			s += ", conflicting write";
		s += "\n";
		if(h.doc[i].comment != nil)
			s += "<br><i>" + hesc(h.doc[i].comment) + "</i>\n";
		s += "<br><hr>";
		s += sdiff(h, i, i-1);
	}
	s += "<hr>";
	if(i >= 0)
		s += sys->sprint("\n<p>The %d versions before these are in the <a href=\"history.html\">history</a>.\n", i+1);
	return s;
}

historytext(h: ref Whist): string
{
	s, tmp, atime: string;

	for(i:=h.ndoc-1;i>=0;i--){
		if(i==h.current)
			tmp = "[current]";
		else
			tmp = sys->sprint("[%ud/]", h.doc[i].time);
		atime = daytime->text(daytime->local(h.doc[i].time));
		s += " * " + tmp + " " + atime;
		if(h.doc[i].author != nil)
			s += ", " + h.doc[i].author;
		if(h.doc[i].conflict)
			s += ", conflicting write";
		s += "\n";
		if(h.doc[i].comment != nil)
			s += "<i>" + h.doc[i].comment + "</i>\n";
	}	
	return s;
}

totext(h: ref Whist, d: ref Wdoc, ty: int): string
{
	s: string;
	sub := array[3] of Sub;
	nsub: int;

	t := gettemplate(Ntemplate+ty);
	(p, q) := str->splitstrl(t, "PAGE");
	if(q != nil)
		q = q[4:];
	nsub = 0;
	if(h != nil){
		sub[nsub] = Sub("TITLE", h.title);
		nsub++;
	}
	if(d != nil){
		ver := sys->sprint("%ud", d.time);
		sub[nsub] = Sub("VERSION", ver);
		nsub++;
		atime := daytime->text(daytime->local(d.time));
		sub[nsub] = Sub("DATE", atime);
		nsub++;
	}
	s = appendsub(p, sub[0:nsub]);

	case ty{
	Tpage or Toldpage =>
		s += pagetext(d.wtxt, 0);
	Thistory =>
		s += historytext(h);
	Tnew or Twerror =>
		;
	}
	if(q != nil)
		s += appendsub(q, sub[0:nsub]);
	return s;
}
