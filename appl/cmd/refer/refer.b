implement Refer;

#
# refer - cite the works of a bibliography by their keys
#
# A translation of Ali Gholami Rudi's Neatrefer into Limbo, which reads
# BibTeX databases as well as refer's, and sets citations in a style:
#
#	refer -p works.bib -S chicago
#
# In a style, a line
#
#	.cite key [loc][; key [loc] ...]
#
# is a note citing the works (the full note the first time each is
# cited, the short note after), given to the macros as
#
#	.]fn
#	the note's text
#	.]fe
#
# the line before it continued (\c) so that the note's mark follows its
# text; \*[cite key loc] within a line is the note's text, for a note of
# one's own; and the line
#
#	.bibliography
#
# is the works cited, sorted, each an entry
#
#	.]bb
#	.]be
#	the entry's text
#	.]bz
#
# A request named with -r (chapter) begins a chapter: the works are
# cited in full again. Without a style, refer is Neatrefer.
#
# Copyright (C) 2011-2017 Ali Gholami Rudi <ali at rudi dot ir>
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "referstyle.m";
	style: Referstyle;
	Name, Ref: import Referstyle;

Refer: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

include "bibtex.b";

# a record of the database
Rec: adt {
	keys:	array of string;	# refer's fields, by letter
	auth:	array of string;	# authors
	nauth:	int;
	id:	int;			# its number, as cited; -1 if not
	rf:	ref Ref;		# as a style sees it
	cited:	int;		# cited in this chapter
};

refs: array of ref Rec;
refs_n := 0;
cites: array of ref Rec;	# the records cited
cites_n := 0;
inserted := 0;
multiref := 0;		# several references in one citation
accumulate := 0;	# accumulate the references
initials := 0;		# initials for authors' first names
sortall := 0;
refmac: string;		# the citation macro
refmac_auth: string;	# the author-year citation macro
resetmac := "chapter";	# the requests that begin a chapter
stdin, stdout: ref Iobuf;
pending: string;	# the line last read, not yet written (a style's)

usage := "usage: refer [options] <input >output\n" +
	"options:\n" +
	"\t-p bib    \tspecify the database file (refer's, or BibTeX's: .bib)\n" +
	"\t-e        \taccumulate references\n" +
	"\t-m        \tmerge multiple references in a single .[/.] block\n" +
	"\t-i        \tinitials for authors' first and middle names\n" +
	"\t-o xy     \tcitation macro (\\*[xy label])\n" +
	"\t-a xy     \tauthor-year citation macro (\\*[xy label])\n" +
	"\t-sa       \tsort by author last names\n" +
	"\t-S style  \tset citations in a style (chicago)\n" +
	"\t-r xy,... \trequests beginning a chapter, for a style (chapter)\n";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	{
		refermain(args);
	} exception e {
	"fail:*" =>
		if(stdout != nil)
			stdout.flush();
		raise e;
	"*" =>
		# where C would crash: said, and failed (a Broken program keeps emu alive)
		if(stdout != nil)
			stdout.flush();
		sys->fprint(sys->fildes(2), "refer: %s\n", e);
		raise "fail:" + e;
	}
}

refermain(args: list of string)
{
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->fprint(sys->fildes(2), "refer: cannot load %s: %r\n", Bufio->PATH);
		raise "fail:load";
	}
	refs = array[64] of ref Rec;
	cites = array[64] of ref Rec;
	stylename: string;
	if(args != nil)
		args = tl args;
	for(; args != nil; args = tl args){
		a := hd args;
		o := 'h';
		if(len a > 1 && a[0] == '-')
			o = a[1];
		v: string;
		case o {
		'p' or 'o' or 'a' or 's' or 'S' or 'r' =>
			if(len a > 2)
				v = a[2:];
			else if(tl args != nil){
				args = tl args;
				v = hd args;
			}
		}
		case o {
		'm' =>
			multiref = 1;
		'e' =>
			accumulate = 1;
		'p' =>
			db_open(v);	# now: -i after it does not apply to it
		'o' =>
			refmac = v;
		'i' =>
			initials = 1;
		'a' =>
			refmac_auth = v;
		's' =>
			if(v != nil)
				sortall = v[0];
		'S' =>
			stylename = v;
		'r' =>
			resetmac = v;
		* =>
			sys->fprint(sys->fildes(2), "%s", usage);
			raise "fail:usage";
		}
	}
	if(stylename != nil){
		path := stylename;
		if(strchr(path, '/') < 0)
			path = "/dis/refer/" + stylename + ".dis";
		style = load Referstyle path;
		if(style == nil){
			sys->fprint(sys->fildes(2), "refer: cannot load style %s: %r\n", path);
			raise "fail:style";
		}
		if((e := style->init()) != nil){
			sys->fprint(sys->fildes(2), "refer: style %s: %s\n", stylename, e);
			raise "fail:style";
		}
		if(refmac == nil)
			refmac = "cite";
	}
	stdin = bufio->fopen(sys->fildes(0), Bufio->OREAD);
	stdout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	if(style != nil)
		refer_style();
	else
		refer();
	stdout.flush();
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

lnget(): string
{
	return stdin.gets('\n');
}

lnput(s: string)
{
	stdout.puts(s);
}

#
# the database
#

newrec(): ref Rec
{
	return ref Rec(array[128] of string, array[128] of string, 0, -1, nil, 0);
}

addrec(r: ref Rec)
{
	if(refs_n == len refs){
		n := array[2 * len refs] of ref Rec;
		n[0:] = refs[0:refs_n];
		refs = n;
	}
	refs[refs_n++] = r;
}

db_open(path: string)
{
	if(len path > 4 && path[len path - 4:] == ".bib"){
		b := readfile(path);
		if(b == nil){
			sys->fprint(sys->fildes(2), "refer: cannot read %s: %r\n", path);
			return;
		}
		for(l := bibtex_parse(string b, path); l != nil; l = tl l)
			addrec(bibrec(hd l));
		return;
	}
	f := bufio->open(path, Bufio->OREAD);
	if(f == nil)
		return;
	while((ln := f.gets('\n')) != nil)
		if(ln[0] != '\n')
			addrec(db_ref(f, ln));
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[64 * 1024] of byte;
	n := 0;
	for(;;){
		if(n == len b){
			nb := array[2 * len b] of byte;
			nb[0:] = b;
			b = nb;
		}
		m := sys->read(fd, b[n:], len b - n);
		if(m <= 0)
			break;
		n += m;
	}
	return b[0:n];
}

# s without its newline
sdup(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			return s[0:i];
	return s;
}

# an author's name as J. Smith
ref_author(r: string): string
{
	if(!initials)
		return sdup(r);
	out := "";
	i := 0;
	for(;;){
		while(i < len r && (r[i] == ' ' || r[i] == '.'))
			i++;
		if(i >= len r || r[i] == '\n')
			break;
		beg := i;
		while(i < len r && r[i] != ' ' && r[i] != '.' && r[i] != '\n')
			i++;
		if(out != "")
			out += " ";
		if(islower(r[beg]) || i >= len r || r[i] == '\n')
			out += r[beg:i];
		else{	# initials
			b := beg;
			do{
				out[len out] = r[b++];
				out += ".";
				while(b < i && r[b] != '-')
					b++;
				if(b < i && r[b] == '-')	# J.-K. Smith
					out[len out] = r[b++];
			}while(b < i);
		}
	}
	return out;
}

rstrip(s: string): string
{
	last := -1;
	for(i := 0; i < len s; i++)
		if(s[i] != ' ' && s[i] != '\n')
			last = i;
	return s[0:last + 1];
}

# a record of refer's database
db_ref(f: ref Iobuf, ln: string): ref Rec
{
	r := newrec();
	do{
		if(len ln > 1 && ln[0] == '%' && ln[1] >= 'A' && ln[1] <= 'Z'){
			i := 2;
			while(i < len ln && isspace(ln[i]))
				i++;
			v := rstrip(ln[i:]);
			if(ln[1] == 'A')
				r.auth[r.nauth++] = ref_author(v);
			else
				r.keys[ln[1]] = sdup(v);
			r.id = -1;
		}
	}while((ln = f.gets('\n')) != nil && ln[0] != '\n');
	return r;
}

fields: con "LTABERJDVNPITOH";
fields_flag: con "OP";
kinds := array[] of {"Other", "Article", "Book", "In book", "Report"};

ref_kind(r: ref Rec): int
{
	if(r.keys['J'] != nil)
		return 1;
	if(r.keys['B'] != nil)
		return 3;
	if(r.keys['R'] != nil)
		return 4;
	if(r.keys['I'] != nil)
		return 2;
	return 0;
}

# a reference, as -ms's macros take it
ref_ins(r: ref Rec, id: int)
{
	kind := ref_kind(r);
	s := ".ds [F " + string id + "\n";
	s += ".]-\n";
	if(r.nauth){
		s += ".ds [A ";
		for(j := 0; j < r.nauth; j++){
			if(j)
				s += ", ";
			s += r.auth[j];
		}
		s += "\n";
	}
	for(j := 'B'; j <= 'Z'; j++){
		v := r.keys[j];
		if(v == nil || strchr(fields, j) < 0)
			continue;
		s += ".ds [" + chr(j) + " " + v + "\n";
		if(strchr(fields_flag, j) >= 0)
			s += ".nr [" + chr(j) + " 1\n";
	}
	s += ".][ " + string kind + " " + kinds[kind] + "\n";
	lnput(s);
}

chr(c: int): string
{
	s := "";
	s[0] = c;
	return s;
}

lastname(name: string): string
{
	last := 0;
	i := 0;
	while(i < len name){
		if(!islower(at(name, last)))
			last = i;
		while(i < len name && name[i] != ' ')
			if(name[i++] == '\\')
				i++;
		while(i < len name && name[i] == ' ')
			i++;
	}
	if(last > len name)
		return "";
	return name[last:];
}

at(s: string, i: int): int
{
	if(i < len s)
		return s[i];
	return 0;
}

refcmp(r1, r2: ref Rec): int
{
	if(!r2.nauth || (r1.keys['H'] != nil && r2.keys['H'] == nil))
		return -1;
	if(!r1.nauth || (r1.keys['H'] == nil && r2.keys['H'] != nil))
		return 1;
	return strcmp(lastname(r1.auth[0]), lastname(r2.auth[0]));
}

# C's strcmp, by bytes
strcmp(a, b: string): int
{
	x := array of byte a;
	y := array of byte b;
	for(i := 0; i < len x && i < len y; i++)
		if(x[i] != y[i])
			return int x[i] - int y[i];
	return len x - len y;
}

ref_all()
{
	sorted := array[cites_n] of ref Rec;
	sorted[0:] = cites[0:cites_n];
	if(sortall == 'a'){
		for(i := 1; i < cites_n; i++){
			j: int;
			for(j = i - 1; j >= 0 && refcmp(cites[i], sorted[j]) < 0; j--)
				sorted[j + 1] = sorted[j];
			sorted[j + 1] = cites[i];
		}
	}
	lnput(".]<\n");
	for(i := 0; i < cites_n; i++)
		ref_ins(sorted[i], sorted[i].id + 1);
	lnput(".]>");
}

# the record of label, cited; its number
refer_seen(label: string): int
{
	i: int;
	for(i = 0; i < refs_n; i++)
		if(refs[i].keys['L'] != nil && refs[i].keys['L'] == label)
			break;
	if(i == refs_n)
		return -1;
	if(refs[i].id < 0){
		refs[i].id = cites_n++;
		if(cites_n > len cites){
			n := array[2 * len cites] of ref Rec;
			n[0:] = cites[0:cites_n - 1];
			cites = n;
		}
		cites[refs[i].id] = refs[i];
	}
	return refs[i].id;
}

refer_quote(s: string): string
{
	if(strchr(s, ' ') < 0 && (len s == 0 || s[0] != '"'))
		return s;
	d := "\"";
	for(i := 0; i < len s; i++){
		if(s[i] == '"')
			d += "\"";
		d[len d] = s[i];
	}
	return d + "\"";
}

# the citation at s replaced by numbers or author and year; the references' numbers
refer_cite(s: string, auth: int): array of int
{
	id := array[256] of int;
	nid := 0;
	msg := "";
	i := 0;
	while(!nid || multiref){
		while(i < len s && strchr(" \t\n,", s[i]) >= 0)
			i++;
		b := i;
		while(i < len s && strchr(" \t\n,]", s[i]) < 0)
			i++;
		label := s[b:i];
		if(label == "$LIST$"){
			ref_all();
			break;
		}
		if(nid < len id)
			id[nid] = refer_seen(label);
		if(nid >= len id || id[nid] < 0)
			sys->fprint(sys->fildes(2), "refer: <%s> not found\n", label);
		else
			nid++;
		if(i >= len s || s[i] == '\n' || s[i] == ']')
			break;
	}
	if(!auth){	# numbered
		isort(id[0:nid]);
		k := 0;
		while(k < nid){
			beg := k++;
			while(k < nid && id[k] == id[k - 1] + 1)
				k++;
			if(beg)
				msg += ",";
			if(beg == k - 1)
				msg += string (id[beg] + 1);
			else{
				msg += string (id[beg] + 1);
				if(beg < k - 2)
					msg += "\\-";
				else
					msg += ",";
				msg += string (id[k - 1] + 1);
			}
		}
	}else if(nid){	# year and authors
		r := cites[id[0]];
		d := r.keys['D'];
		if(d == nil)
			d = "-";
		msg = d + " " + string r.nauth;
		for(k := 0; k < r.nauth; k++)
			msg += " " + refer_quote(lastname(r.auth[k]));
	}
	lnput(msg);
	return id[0:nid];
}

isort(a: array of int)
{
	for(i := 1; i < len a; i++){
		v := a[i];
		j := i;
		for(; j > 0 && a[j - 1] > v; j--)
			a[j] = a[j - 1];
		a[j] = v;
	}
}

# the name of the request at s; and whether it has an argument
refer_reqname(s: string): (string, int)
{
	if(len s == 0 || s[0] != '.')
		return (nil, 0);
	i := 1;
	while(i < len s && i < 257 && s[i] != ' ' && s[i] != '\n')
		i++;
	return (s[1:i], i < len s && s[i] == ' ');
}

# the name of the string \*[name at s; and whether an argument follows
refer_macname(s: string, i: int): (string, int)
{
	if(i + 2 >= len s || s[i] != '\\' || s[i + 1] != '*' || s[i + 2] != '[')
		return (nil, 0);
	b := i + 3;
	e := b;
	while(e < len s && e - b < 256 && s[e] != ' ')
		e++;
	return (s[b:e], e < len s && s[e] == ' ');
}

# whether mac is one of the comma-separated pat
refer_refmac(pat, mac: string): int
{
	if(pat == nil || mac == "")
		return 0;
	for(i := 0; i + len mac <= len pat; i++)
		if(pat[i:i + len mac] == mac){
			if((i == 0 || pat[i - 1] == ',') &&
					(i + len mac == len pat || pat[i + len mac] == ','))
				return 1;
			return 0;	# strstr's first match only
		}
	return 0;
}

refer_insert(id: array of int)
{
	for(i := 0; i < len id; i++)
		ref_ins(cites[id[i]], ++inserted);
}

refer()
{
	while((ln := lnget()) != nil){
		id: array of int;
		# .[ rudi17 .]
		if(len ln > 1 && ln[0] == '.' && ln[1] == '['){
			lnput(sdup(ln[2:]));
			if((ln = lnget()) != nil){
				id = refer_cite(ln, 0);
				while(ln != nil && (len ln < 2 || ln[0] != '.' || ln[1] != ']'))
					ln = lnget();
				if(ln != nil)
					lnput(ln[2:]);
			}
			if(!accumulate)
				refer_insert(id);
			continue;
		}
		# .cite rudi17
		(mac, arg) := refer_reqname(ln);
		if(mac != nil && arg && (refer_refmac(refmac, mac) || refer_refmac(refmac_auth, mac))){
			i := 1;
			while(i < len ln && ln[i] != ' ')
				i++;
			while(i < len ln && ln[i] == ' ')
				i++;
			lnput(ln[0:i]);
			id = refer_cite(ln[i:], refer_refmac(refmac_auth, mac));
			while(i < len ln && ln[i] != ' ' && ln[i] != '\n')
				i++;
			lnput(ln[i:]);
			if(!accumulate)
				refer_insert(id);
			continue;
		}
		# \*[cite rudi17]
		s := 0;
		r := 0;
		for(;;){
			while(r < len ln && ln[r] != '\\')
				r++;
			if(r >= len ln)
				break;
			r++;
			(m, a) := refer_macname(ln, r - 1);
			if(m == nil || !a)
				continue;
			if(!refer_refmac(refmac, m) && !refer_refmac(refmac_auth, m))
				continue;
			if(strchr(ln[r:], ']') < 0)
				continue;
			r += strchr(ln[r:], ' ') + 1;
			lnput(ln[s:r]);
			id = refer_cite(ln[r:], refer_refmac(refmac_auth, m));
			while(r < len ln && ln[r] != ' ' && ln[r] != ']')
				r++;
			s = r;
		}
		lnput(ln[s:]);
		if(!accumulate)
			refer_insert(id);
	}
}

#
# a style
#

refer_style()
{
	while((ln := lnget()) != nil){
		(mac, arg) := refer_reqname(ln);
		if(mac != nil && refer_refmac(resetmac, mac)){
			for(i := 0; i < refs_n; i++)
				refs[i].cited = 0;
			put(ln);
			continue;
		}
		if(mac == "bibliography" || (len ln > 1 && ln[0] == '.' && ln[1] == '[' && strstr(ln, "$LIST$") >= 0)){
			put(nil);
			bibliography();
			continue;
		}
		if(len ln > 1 && ln[0] == '.' && ln[1] == '['){
			# .[ key loc .], as .cite
			c := sdup(ln[2:]);
			while((ln = lnget()) != nil && (len ln < 2 || ln[0] != '.' || ln[1] != ']'))
				c += " " + sdup(ln);
			footnote(cite(c, 1));
			continue;
		}
		if(mac != nil && arg && refer_refmac(refmac, mac)){
			i := 1;
			while(i < len ln && ln[i] != ' ')
				i++;
			footnote(cite(sdup(ln[i:]), 1));
			continue;
		}
		put(inline(ln));
	}
	put(nil);
}

# write the line before; keep s
put(s: string)
{
	if(pending != nil)
		lnput(pending);
	pending = s;
}

# a note citing, for its mark to follow the text before
footnote(text: string)
{
	if(text == nil)
		return;
	if(pending != nil && len pending > 0 && pending[0] != '.' && pending[0] != '\''){
		p := sdup(pending);
		if(len p < 2 || p[len p - 2:] != "\\c")
			p += "\\c";
		pending = p + "\n";
	}
	put(".]fn\n" + troffline(text) + ".]fe\n");
}

# text as lines of troff's input
troffline(s: string): string
{
	if(len s > 0 && (s[0] == '.' || s[0] == '\''))
		s = "\\&" + s;
	return s + "\n";
}

# \*[cite key loc] in a line replaced by the citation's text
inline(ln: string): string
{
	r := 0;
	for(;;){
		while(r < len ln && ln[r] != '\\')
			r++;
		if(r >= len ln)
			return ln;
		(m, a) := refer_macname(ln, r);
		if(m == nil || !a || !refer_refmac(refmac, m)){
			r++;
			continue;
		}
		e := r;
		while(e < len ln && ln[e] != ']')
			e++;
		if(e >= len ln){
			r++;
			continue;
		}
		b := r + 3 + len m + 1;
		t := cite(ln[b:e], 0);
		ln = ln[0:r] + t + ln[e + 1:];
		r += len t;
	}
}

# the text of a citation of "key loc; key loc ...", a note's (ending in a
# period) or within a line
cite(s: string, note: int): string
{
	text := "";
	for(l := split(s, ';'); l != nil; l = tl l){
		(key, loc) := keyloc(hd l);
		if(key == nil)
			continue;
		rec := find(key);
		if(rec == nil){
			sys->fprint(sys->fildes(2), "refer: <%s> not found\n", key);
			continue;
		}
		if(rec.id < 0)
			refer_seen(key);
		if(rec.rf == nil)
			rec.rf = referref(rec);
		n := style->note(rec.rf, !rec.cited, loc);
		rec.cited = 1;
		if(text != "")
			text += "; ";
		text += n;
	}
	if(text == "")
		return nil;
	if(note && !endspunct(text))
		text += ".";
	return text;
}

# whether s ends a sentence: . ? or !, fonts and quotation marks aside
endspunct(s: string): int
{
	for(;;){
		if(len s >= 3 && s[len s - 3:len s - 1] == "\\f")
			s = s[0:len s - 3];
		else if(len s > 0 && (s[len s - 1] == '”' || s[len s - 1] == '’'))
			s = s[0:len s - 1];
		else
			break;
	}
	return len s > 0 && (s[len s - 1] == '.' || s[len s - 1] == '?' || s[len s - 1] == '!');
}

find(key: string): ref Rec
{
	for(i := 0; i < refs_n; i++)
		if(refs[i].keys['L'] == key)
			return refs[i];
	return nil;
}

# a citation's key and where in the work
keyloc(s: string): (string, string)
{
	i := 0;
	while(i < len s && isspace(s[i]))
		i++;
	b := i;
	while(i < len s && !isspace(s[i]))
		i++;
	key := s[b:i];
	while(i < len s && isspace(s[i]))
		i++;
	loc := s[i:];
	while(len loc > 0 && isspace(loc[len loc - 1]))
		loc = loc[0:len loc - 1];
	if(key == "")
		key = nil;
	if(loc == "")
		loc = nil;
	return (key, loc);
}

split(s: string, c: int): list of string
{
	r: list of string;
	b := len s;
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == c){
			r = s[i + 1:b] :: r;
			b = i;
		}
	return s[0:b] :: r;
}

# the works cited, sorted
bibliography()
{
	n := cites_n;
	a := array[n] of ref Rec;
	k := array[n] of string;
	for(i := 0; i < n; i++){
		a[i] = cites[i];
		if(a[i].rf == nil)
			a[i].rf = referref(a[i]);
		k[i] = style->sortkey(a[i].rf);
	}
	# sorted stably
	for(i = 1; i < n; i++){
		r := a[i];
		rk := k[i];
		j := i;
		for(; j > 0 && k[j - 1] > rk; j--){
			a[j] = a[j - 1];
			k[j] = k[j - 1];
		}
		a[j] = r;
		k[j] = rk;
	}
	s := ".]bb\n";
	for(i = 0; i < n; i++)
		s += ".]be\n" + troffline(style->bib(a[i].rf));
	lnput(s + ".]bz\n");
}

#
# helpers
#

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

islower(c: int): int
{
	return c >= 'a' && c <= 'z';
}

strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

strstr(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i + len t] == t)
			return i;
	return -1;
}

isalpha(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

tolower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		r[len r] = c;
	}
	return r;
}
