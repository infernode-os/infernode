#
# BibTeX's databases
#

include "accents.b";

# an entry, as read
Bibentry: adt {
	typ:	string;
	key:	string;
	fields:	list of (string, string);	# raw: TeX's text
};

Bibin: adt {
	s:	string;
	i:	int;
	file:	string;
	macros:	list of (string, string);

	err:	fn(b: self ref Bibin, msg: string);
	ws:	fn(b: self ref Bibin);
	ident:	fn(b: self ref Bibin): string;
	skipbal:	fn(b: self ref Bibin, open, close: int);
	skipto:	fn(b: self ref Bibin, close: int);
	value:	fn(b: self ref Bibin): string;
};

months := array[] of {
	("jan", "January"), ("feb", "February"), ("mar", "March"), ("apr", "April"),
	("may", "May"), ("jun", "June"), ("jul", "July"), ("aug", "August"),
	("sep", "September"), ("oct", "October"), ("nov", "November"), ("dec", "December"),
};

# a database's entries, in order
bibtex_parse(s, file: string): list of ref Bibentry
{
	b := ref Bibin(s, 0, file, nil);
	for(i := 0; i < len months; i++)
		b.macros = months[i] :: b.macros;
	r: list of ref Bibentry;
	for(;;){
		while(b.i < len b.s && b.s[b.i] != '@')
			b.i++;
		if(b.i >= len b.s)
			break;
		b.i++;
		typ := tolower(b.ident());
		b.ws();
		if(b.i >= len b.s)
			break;
		open := b.s[b.i];
		if(open != '{' && open != '('){
			continue;
		}
		close := '}';
		if(open == '(')
			close = ')';
		b.i++;
		case typ {
		"comment" =>
			b.skipbal(open, close);
			continue;
		"preamble" =>
			b.skipbal(open, close);
			continue;
		"string" =>
			b.ws();
			name := tolower(b.ident());
			b.ws();
			if(b.i < len b.s && b.s[b.i] == '='){
				b.i++;
				b.macros = (name, b.value()) :: b.macros;
			}
			b.skipto(close);
			continue;
		}
		e := ref Bibentry(typ, nil, nil);
		b.ws();
		k := b.i;
		while(b.i < len b.s && b.s[b.i] != ',' && b.s[b.i] != close && !isspace(b.s[b.i]))
			b.i++;
		e.key = b.s[k:b.i];
		for(;;){
			b.ws();
			if(b.i < len b.s && b.s[b.i] == ',')
				b.i++;
			b.ws();
			if(b.i >= len b.s || b.s[b.i] == close){
				b.i++;
				break;
			}
			name := tolower(b.ident());
			if(name == ""){
				b.err("a field's name expected");
				b.skipto(close);
				break;
			}
			b.ws();
			if(b.i >= len b.s || b.s[b.i] != '='){
				b.err("= expected after " + name);
				b.skipto(close);
				break;
			}
			b.i++;
			e.fields = (name, b.value()) :: e.fields;
		}
		r = e :: r;
	}
	l: list of ref Bibentry;
	for(; r != nil; r = tl r)
		l = hd r :: l;
	return l;
}

Bibin.err(b: self ref Bibin, msg: string)
{
	line := 1;
	for(i := 0; i < b.i && i < len b.s; i++)
		if(b.s[i] == '\n')
			line++;
	sys->fprint(sys->fildes(2), "refer: %s:%d: %s\n", b.file, line, msg);
}

Bibin.ws(b: self ref Bibin)
{
	for(;;){
		while(b.i < len b.s && isspace(b.s[b.i]))
			b.i++;
		if(b.i < len b.s && b.s[b.i] == '%'){
			while(b.i < len b.s && b.s[b.i] != '\n')
				b.i++;
			continue;
		}
		return;
	}
}

Bibin.ident(b: self ref Bibin): string
{
	k := b.i;
	while(b.i < len b.s && !isspace(b.s[b.i]) && strchr("{}(),=\"#%", b.s[b.i]) < 0)
		b.i++;
	return b.s[k:b.i];
}

# skip to the brace or parenthesis closing one opened
Bibin.skipbal(b: self ref Bibin, open, close: int)
{
	d := 1;
	while(b.i < len b.s && d > 0){
		if(b.s[b.i] == open)
			d++;
		else if(b.s[b.i] == close)
			d--;
		b.i++;
	}
}

Bibin.skipto(b: self ref Bibin, close: int)
{
	d := 0;
	while(b.i < len b.s){
		c := b.s[b.i++];
		if(c == '{')
			d++;
		else if(c == '}' && d > 0)
			d--;
		else if(c == close && d == 0)
			return;
	}
}

# a field's value: its parts joined by #
Bibin.value(b: self ref Bibin): string
{
	v := "";
	for(;;){
		b.ws();
		if(b.i >= len b.s)
			break;
		c := b.s[b.i];
		if(c == '{'){
			k := ++b.i;
			d := 1;
			while(b.i < len b.s){
				if(b.s[b.i] == '\\' && b.i + 1 < len b.s){
					b.i += 2;
					continue;
				}
				if(b.s[b.i] == '{')
					d++;
				else if(b.s[b.i] == '}' && --d == 0)
					break;
				b.i++;
			}
			v += b.s[k:b.i];
			b.i++;
		}else if(c == '"'){
			k := ++b.i;
			d := 0;
			while(b.i < len b.s){
				if(b.s[b.i] == '\\' && b.i + 1 < len b.s){
					b.i += 2;
					continue;
				}
				if(b.s[b.i] == '{')
					d++;
				else if(b.s[b.i] == '}')
					d--;
				else if(b.s[b.i] == '"' && d == 0)
					break;
				b.i++;
			}
			v += b.s[k:b.i];
			b.i++;
		}else{
			name := b.ident();
			if(name == ""){
				b.i++;
				continue;
			}
			if(isdigit(name[0]))
				v += name;
			else{
				m := lookup(b.macros, tolower(name));
				if(m == nil)
					b.err("undefined string " + name);
				v += m;
			}
		}
		b.ws();
		if(b.i < len b.s && b.s[b.i] == '#'){
			b.i++;
			continue;
		}
		break;
	}
	return v;
}

lookup(l: list of (string, string), k: string): string
{
	for(; l != nil; l = tl l)
		if((hd l).t0 == k)
			return (hd l).t1;
	return nil;
}

# TeX's text as troff's
tex2troff(s: string): string
{
	(t, nil) := texrun(s, 0, 0);
	return t;
}

# TeX's text from s[i:], to the end of its group (depth) or of s; and where it ended
texrun(s: string, i: int, depth: int): (string, int)
{
	r := "";
	while(i < len s){
		c := s[i];
		case c {
		'{' =>
			# {\em x} and {\it x}: x in italics
			if(i + 3 < len s && s[i + 1] == '\\' && (s[i + 2:i + 4] == "em" || s[i + 2:i + 4] == "it") &&
					(i + 4 >= len s || !isalpha(s[i + 4]))){
				(t, e) := texrun(s, i + 4, depth + 1);
				r += "\\fI" + trim(t) + "\\fP";
				i = e;
				continue;
			}
			(t, e) := texrun(s, i + 1, depth + 1);
			r += t;
			i = e;
		'}' =>
			if(depth > 0)
				return (r, i + 1);
			i++;
		'\\' =>
			(t, e) := texcmd(s, i);
			r += t;
			i = e;
		'-' =>
			if(i + 2 < len s && s[i + 1] == '-' && s[i + 2] == '-'){
				r += "—";
				i += 3;
			}else if(i + 1 < len s && s[i + 1] == '-'){
				r += "–";
				i += 2;
			}else{
				r += "-";
				i++;
			}
		'`' =>
			if(i + 1 < len s && s[i + 1] == '`'){
				r += "“";
				i += 2;
			}else{
				r += "‘";
				i++;
			}
		'\'' =>
			if(i + 1 < len s && s[i + 1] == '\''){
				r += "”";
				i += 2;
			}else{
				r += "’";
				i++;
			}
		'~' =>
			r += "\\~";
			i++;
		'$' =>
			i++;
		'\n' or '\t' or '\r' =>
			if(r == "" || r[len r - 1] != ' ')
				r += " ";
			i++;
		' ' =>
			if(r == "" || r[len r - 1] != ' ')
				r += " ";
			i++;
		* =>
			r[len r] = c;
			i++;
		}
	}
	return (r, i);
}

# a TeX command at s[i:]; its text and where it ends
texcmd(s: string, i: int): (string, int)
{
	i++;	# the backslash
	if(i >= len s)
		return ("\\e", i);
	c := s[i];
	if(!isalpha(c)){
		i++;
		case c {
		'&' or '%' or '$' or '#' or '_' or '{' or '}' =>
			return (chr(c), i);
		' ' =>
			return (" ", i);
		'\\' =>
			return (" ", i);
		'-' =>
			return ("", i);	# a discretionary hyphen
		}
		for(k := 0; k < len accents; k++)
			if(accents[k].t0 == chr(c))
				return accent(accents[k].t1, s, i);
		return ("", i);
	}
	b := i;
	while(i < len s && isalpha(s[i]))
		i++;
	name := s[b:i];
	if(len name == 1)
		for(k := 0; k < len accents; k++)
			if(accents[k].t0 == name)
				return accent(accents[k].t1, s, i);
	sym := "";
	case name {
	"ss" =>	sym = "ß";
	"o" =>	sym = "ø";
	"O" =>	sym = "Ø";
	"ae" =>	sym = "æ";
	"AE" =>	sym = "Æ";
	"oe" =>	sym = "œ";
	"OE" =>	sym = "Œ";
	"aa" =>	sym = "å";
	"AA" =>	sym = "Å";
	"l" =>	sym = "ł";
	"L" =>	sym = "Ł";
	"i" =>	sym = "ı";
	"j" =>	sym = "ȷ";
	"S" =>	sym = "§";
	"P" =>	sym = "¶";
	"dag" =>	sym = "†";
	"ldots" or "dots" =>	sym = "…";
	"textendash" =>	sym = "–";
	"textemdash" =>	sym = "—";
	"LaTeX" =>	sym = "LaTeX";
	"TeX" =>	sym = "TeX";
	"emph" or "textit" or "textsl" or "mkbibemph" =>
		(t, e) := texarg(s, i);
		return ("\\fI" + t + "\\fP", e);
	"textbf" or "mkbibbold" =>
		(t, e) := texarg(s, i);
		return ("\\fB" + t + "\\fP", e);
	"mkbibquote" or "enquote" =>
		(t, e) := texarg(s, i);
		return ("“" + t + "”", e);
	* =>
		# any other: its argument, if it has one
		while(i < len s && s[i] == ' ')
			i++;
		if(i < len s && s[i] == '{')
			return texarg(s, i);
		return ("", i);
	}
	# a space after a command's name is its end
	if(i < len s && s[i] == ' ')
		i++;
	else if(i + 1 < len s && s[i] == '{' && s[i + 1] == '}')
		i += 2;
	return (sym, i);
}

# a command's argument: a group or a character
texarg(s: string, i: int): (string, int)
{
	while(i < len s && s[i] == ' ')
		i++;
	if(i >= len s)
		return ("", i);
	if(s[i] == '{')
		return texrun(s, i + 1, 1);
	if(s[i] == '\\')
		return texcmd(s, i);
	return (chr(s[i]), i + 1);
}

# an accent on the letter after it
accent(pairs: string, s: string, i: int): (string, int)
{
	(l, e) := texarg(s, i);
	if(l == "ı")
		l = "i";
	if(len l == 1)
		for(k := 0; k + 1 < len pairs; k += 2)
			if(pairs[k] == l[0])
				return (chr(pairs[k + 1]), e);
	return (l, e);
}

trim(s: string): string
{
	while(len s > 0 && s[0] == ' ')
		s = s[1:];
	while(len s > 0 && s[len s - 1] == ' ')
		s = s[0:len s - 1];
	return s;
}

# the names of a list (author, editor): split at "and"
bibnames(s: string): array of ref Name
{
	parts: list of string;
	d := 0;
	b := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '{')
			d++;
		else if(c == '}')
			d--;
		else if(d == 0 && isspace(c) && i + 4 < len s && s[i + 1:i + 4] == "and" && isspace(s[i + 4])){
			parts = s[b:i] :: parts;
			i += 4;
			b = i + 1;
		}
	}
	parts = s[b:] :: parts;
	# a name left empty ("Smith and", "and Jones") is no one
	ne: list of string;
	for(; parts != nil; parts = tl parts)
		if(trim(hd parts) != nil)
			ne = trim(hd parts) :: ne;
	n := 0;
	for(l := ne; l != nil; l = tl l)
		n++;
	a := array[n] of ref Name;
	for(k := 0; ne != nil; ne = tl ne)
		a[k++] = bibname(hd ne);
	return a;
}

# a name: First von Last, von Last, First, or von Last, Jr, First
bibname(s: string): ref Name
{
	# split at commas outside braces
	segs: list of string;
	d := 0;
	b := 0;
	for(i := 0; i < len s; i++){
		if(s[i] == '{')
			d++;
		else if(s[i] == '}')
			d--;
		else if(s[i] == ',' && d == 0){
			segs = trim(s[b:i]) :: segs;
			b = i + 1;
		}
	}
	segs = trim(s[b:]) :: segs;
	nseg := 0;
	for(l := segs; l != nil; l = tl l)
		nseg++;
	seg := array[nseg] of string;
	for(k := nseg - 1; k >= 0; k--){
		seg[k] = hd segs;
		segs = tl segs;
	}
	n := ref Name("", "", "", "");
	if(nseg == 1){
		w := words(seg[0]);
		if(len w <= 1){
			if(len w == 1)
				n.last = tex2troff(w[0]);
			return n;
		}
		# First von Last: von is the lower-case words; Last the rest
		f := 0;
		while(f < len w - 1 && !lowerword(w[f]))
			f++;
		v := f;
		while(v < len w - 1 && lowerword(w[v]))
			v++;
		if(f == v)	# no von: the last word is the last name
			f = v = len w - 1;
		n.first = tex2troff(join(w[0:f]));
		n.von = tex2troff(join(w[f:v]));
		n.last = tex2troff(join(w[v:]));
		return n;
	}
	# von Last, [Jr,] First
	w := words(seg[0]);
	v := 0;
	while(v < len w - 1 && lowerword(w[v]))
		v++;
	n.von = tex2troff(join(w[0:v]));
	n.last = tex2troff(join(w[v:]));
	if(nseg == 2)
		n.first = tex2troff(seg[1]);
	else{
		n.jr = tex2troff(seg[1]);
		n.first = tex2troff(seg[2]);
	}
	return n;
}

# the words of s, a braced group one word
words(s: string): array of string
{
	r: list of string;
	i := 0;
	for(;;){
		while(i < len s && isspace(s[i]))
			i++;
		if(i >= len s)
			break;
		b := i;
		d := 0;
		while(i < len s && (d > 0 || !isspace(s[i]))){
			if(s[i] == '{')
				d++;
			else if(s[i] == '}')
				d--;
			i++;
		}
		r = s[b:i] :: r;
	}
	n := 0;
	for(l := r; l != nil; l = tl l)
		n++;
	a := array[n] of string;
	for(; r != nil; r = tl r)
		a[--n] = hd r;
	return a;
}

join(w: array of string): string
{
	s := "";
	for(i := 0; i < len w; i++){
		if(i)
			s += " ";
		s += w[i];
	}
	return s;
}

# whether a word begins in lower case, as BibTeX's von does
lowerword(w: string): int
{
	for(i := 0; i < len w; i++){
		c := w[i];
		if(c == '{' || c == '\\')
			return 0;
		if(isalpha(c) || c >= 16r80)
			return c >= 'a' && c <= 'z';
	}
	return 0;
}

# a name in order: First von Last, Jr
fullname(n: ref Name): string
{
	s := n.first;
	if(n.von != ""){
		if(s != "")
			s += " ";
		s += n.von;
	}
	if(s != "")
		s += " ";
	s += n.last;
	if(n.jr != "")
		s += ", " + n.jr;
	return s;
}

# a database's entry as a record, as refer's fields and as a style's
bibrec(e: ref Bibentry): ref Rec
{
	r := newrec();
	rf := ref Ref(e.key, e.typ, nil, array[0] of ref Name, array[0] of ref Name, array[0] of ref Name);
	r.keys['L'] = e.key;
	for(l := e.fields; l != nil; l = tl l){
		(name, raw) := hd l;
		case name {
		"author" =>
			rf.author = bibnames(raw);
			for(k := 0; k < len rf.author; k++)
				r.auth[r.nauth++] = ref_author(fullname(rf.author[k]));
			continue;
		"editor" =>
			rf.editor = bibnames(raw);
			s := "";
			for(k := 0; k < len rf.editor; k++){
				if(k)
					s += ", ";
				s += fullname(rf.editor[k]);
			}
			r.keys['E'] = s;
			continue;
		"translator" =>
			rf.translator = bibnames(raw);
			continue;
		}
		v := trim(tex2troff(raw));
		rf.fields = (name, v) :: rf.fields;
		case name {
		"title" =>	r.keys['T'] = v;
		"journal" or "journaltitle" =>	r.keys['J'] = v;
		"booktitle" =>	r.keys['B'] = v;
		"publisher" =>	r.keys['I'] = v;
		"address" or "location" =>	r.keys['C'] = v;
		"year" =>	r.keys['D'] = v;
		"date" =>
			if(r.keys['D'] == nil)
				r.keys['D'] = v;
		"volume" =>	r.keys['V'] = v;
		"number" =>	r.keys['N'] = v;
		"pages" =>	r.keys['P'] = v;
		"institution" =>	r.keys['R'] = v;
		"note" =>	r.keys['O'] = v;
		}
	}
	r.rf = rf;
	return r;
}

# a record of refer's database as a style sees it
referref(r: ref Rec): ref Ref
{
	typ := "misc";
	case ref_kind(r) {
	1 =>	typ = "article";
	2 =>	typ = "book";
	3 =>	typ = "incollection";
	4 =>	typ = "techreport";
	}
	rf := ref Ref(r.keys['L'], typ, nil, array[r.nauth] of ref Name, array[0] of ref Name, array[0] of ref Name);
	for(i := 0; i < r.nauth; i++)
		rf.author[i] = bibname(r.auth[i]);
	if(r.keys['E'] != nil)
		rf.editor = bibnames(replace(r.keys['E'], ", ", " and "));
	names := array[] of {
		('T', "title"), ('J', "journal"), ('B', "booktitle"), ('I', "publisher"),
		('C', "address"), ('D', "year"), ('V', "volume"), ('N', "number"),
		('P', "pages"), ('R', "institution"), ('O', "note"), ('S', "series"),
	};
	for(i = 0; i < len names; i++)
		if((v := r.keys[names[i].t0]) != nil)
			rf.fields = (names[i].t1, v) :: rf.fields;
	return rf;
}

replace(s, a, b: string): string
{
	r := "";
	for(i := 0; i < len s; ){
		if(i + len a <= len s && s[i:i + len a] == a){
			r += b;
			i += len a;
		}else
			r[len r] = s[i++];
	}
	return r;
}
