implement Referstyle;

#
# chicago - The Chicago Manual of Style, 18th edition (2024): the
# notes and bibliography system
#
# A note the first time a work is cited in a chapter is its full note,
# a short note after (author's last name, short title, page); ibid. is
# not used, as the 18th edition advises. Up to three authors are named
# in a note, the first followed by et al. when there are more; up to
# six in the bibliography, the first three followed by et al. when
# there are more. A name repeated in the bibliography is repeated, not
# replaced by a dash. The place of publication is given only when the
# database gives it. Page ranges are inclusive numbers, abbreviated as
# the Manual abbreviates them (101–8, 321–28, 1496–1504).
#
# Kinds of work: book (author, editor, or both; translator; edition;
# volume), incollection and inbook (a chapter in an edited book),
# article, phdthesis and mastersthesis, online and misc; any with
# entrysubtype = {classical} (Aristotle, Nicomachean Ethics 1094a1–3) is
# cited by its parts without a comma, and by its short title after.
#

include "sys.m";
	sys: Sys;

include "referstyle.m";

init(): string
{
	sys = load Sys Sys->PATH;
	return nil;
}

get(r: ref Ref, f: string): string
{
	for(l := r.fields; l != nil; l = tl l)
		if((hd l).t0 == f)
			return (hd l).t1;
	return nil;
}

note(r: ref Ref, first: int, loc: string): string
{
	if(loc != nil)
		loc = locator(loc);
	if(classical(r))
		return clean(classicalnote(r, first, loc));
	if(!first)
		return clean(shortnote(r, loc));
	s: string;
	case r.typ {
	"article" =>
		s = articlenote(r, loc);
	"incollection" or "inbook" or "inproceedings" =>
		s = chapternote(r, loc);
	"phdthesis" or "mastersthesis" or "thesis" =>
		s = thesisnote(r, loc);
	"book" or "collection" or "mvbook" or "proceedings" =>
		s = booknote(r, loc);
	* =>
		if(get(r, "publisher") != nil)
			s = booknote(r, loc);
		else
			s = miscnote(r, loc);
	}
	return clean(s);
}

bib(r: ref Ref): string
{
	s: string;
	case r.typ {
	"article" =>
		s = articlebib(r);
	"incollection" or "inbook" or "inproceedings" =>
		s = chapterbib(r);
	"phdthesis" or "mastersthesis" or "thesis" =>
		s = thesisbib(r);
	"book" or "collection" or "mvbook" or "proceedings" =>
		s = bookbib(r);
	* =>
		if(get(r, "publisher") != nil)
			s = bookbib(r);
		else
			s = miscbib(r);
	}
	return clean(s);
}

sortkey(r: ref Ref): string
{
	k := "";
	if(len r.author > 0)
		k = r.author[0].last + " " + r.author[0].first;
	else if(len r.editor > 0)
		k = r.editor[0].last + " " + r.editor[0].first;
	t := get(r, "title");
	for(a := array[] of {"The ", "A ", "An "}; len a > 0; a = a[1:])
		if(len t > len a[0] && t[0:len a[0]] == a[0]){
			t = t[len a[0]:];
			break;
		}
	if(k == "")
		k = t;
	else
		k += " " + t;
	return fold(k);
}

#
# notes
#

booknote(r: ref Ref, loc: string): string
{
	s := "";
	if(len r.author > 0)
		s = notenames(r.author);
	else if(len r.editor > 0)
		s = notenames(r.editor) + ", " + eds(len r.editor);
	s = comma(s, ital(title(r)));
	if((v := get(r, "volume")) != nil)
		s += ", vol. " + v;
	if((e := edition(r)) != nil)
		s += ", " + e;
	if(len r.author > 0 && len r.editor > 0)
		s += ", ed. " + notenames(r.editor);
	if(len r.translator > 0)
		s += ", trans. " + notenames(r.translator);
	s += " (" + pubinfo(r) + ")";
	if(loc != nil)
		s += ", " + loc;
	if((u := link(r)) != nil)
		s += ", " + u;
	return s;
}

chapternote(r: ref Ref, loc: string): string
{
	s := notenames(r.author);
	s = comma(s, quote(title(r), ","));
	s += " in " + ital(get(r, "booktitle"));
	if(len r.editor > 0)
		s += ", ed. " + notenames(r.editor);
	if(len r.translator > 0)
		s += ", trans. " + notenames(r.translator);
	s += " (" + pubinfo(r) + ")";
	if(loc != nil)
		s += ", " + loc;
	if((u := link(r)) != nil)
		s += ", " + u;
	return s;
}

articlenote(r: ref Ref, loc: string): string
{
	s := notenames(r.author);
	s = comma(s, quote(title(r), ","));
	s += " " + ital(journal(r)) + volnum(r) + " (" + issuedate(r) + ")";
	if(loc != nil)
		s += ": " + loc;
	if((u := link(r)) != nil)
		s += ", " + u;
	return s;
}

thesisnote(r: ref Ref, loc: string): string
{
	s := notenames(r.author);
	s = comma(s, quote(title(r), ""));
	s += " (" + thesistype(r);
	if((sch := school(r)) != nil)
		s += ", " + sch;
	s += ", " + year(r) + ")";
	if(loc != nil)
		s += ", " + loc;
	if((u := link(r)) != nil)
		s += ", " + u;
	return s;
}

miscnote(r: ref Ref, loc: string): string
{
	s := notenames(r.author);
	if(len r.author == 0 && len r.editor > 0)
		s = notenames(r.editor) + ", " + eds(len r.editor);
	s = comma(s, quote(title(r), ","));
	if((h := site(r)) != nil)
		s += " " + h + ",";
	if((d := get(r, "date")) != nil || (d = get(r, "year")) != nil)
		s += " " + d + ",";
	if((u := link(r)) != nil)
		s += " " + u;
	s = strip(s, ",");
	if(loc != nil)
		s += ", " + loc;
	return s;
}

shortnote(r: ref Ref, loc: string): string
{
	s := "";
	if(len r.author > 0)
		s = shortnames(r.author);
	else if(len r.editor > 0)
		s = shortnames(r.editor);
	t := shorttitle(r);
	if(italic(r)){
		s = comma(s, ital(t));
		if(loc != nil)
			s += ", " + loc;
	}else{
		# a comma within the quotation marks
		if(loc != nil)
			s = comma(s, quote(t, ",")) + " " + loc;
		else
			s = comma(s, quote(t, ""));
	}
	return s;
}

classicalnote(r: ref Ref, first: int, loc: string): string
{
	s := "";
	if(len r.author > 0)
		s = notenames(r.author);
	t := title(r);
	if(!first)
		t = shorttitle(r);
	s = comma(s, ital(t));
	if(loc != nil)
		s += " " + loc;
	if(first && len r.translator > 0)
		s += ", trans. " + notenames(r.translator) + " (" + pubinfo(r) + ")";
	return s;
}

#
# bibliography
#

bookbib(r: ref Ref): string
{
	s := "";
	if(len r.author > 0)
		s = bibnames(r.author);
	else if(len r.editor > 0)
		s = bibnames(r.editor) + ", " + eds(len r.editor);
	s = period(s, ital(title(r)));
	if((v := get(r, "volume")) != nil)
		s = period(s, "Vol. " + v);
	if(len r.author > 0 && len r.editor > 0)
		s = period(s, "Edited by " + notenames(r.editor));
	if(len r.translator > 0)
		s = period(s, "Translated by " + notenames(r.translator));
	if((e := edition(r)) != nil)
		s = period(s, e);
	if((sr := get(r, "series")) != nil)
		s = period(s, sr);
	s = period(s, pubinfo(r));
	if((u := link(r)) != nil)
		s = period(s, u);
	return s + ".";
}

chapterbib(r: ref Ref): string
{
	s := bibnames(r.author);
	s = period(s, quote(title(r), "."));
	s += " In " + ital(get(r, "booktitle"));
	if(len r.editor > 0)
		s += ", edited by " + notenames(r.editor);
	if(len r.translator > 0)
		s += ", translated by " + notenames(r.translator);
	if((p := get(r, "pages")) != nil)
		s += ", " + range(p);
	s = period(s, pubinfo(r));
	if((u := link(r)) != nil)
		s = period(s, u);
	return s + ".";
}

articlebib(r: ref Ref): string
{
	s := bibnames(r.author);
	s = period(s, quote(title(r), "."));
	s += " " + ital(journal(r)) + volnum(r) + " (" + issuedate(r) + ")";
	if((p := get(r, "pages")) != nil)
		s += ": " + range(p);
	if((u := link(r)) != nil)
		s = period(s, u);
	return s + ".";
}

thesisbib(r: ref Ref): string
{
	s := bibnames(r.author);
	s = period(s, quote(title(r), "."));
	s += " " + thesistype(r);
	if((sch := school(r)) != nil)
		s += ", " + sch;
	s += ", " + year(r);
	if((u := link(r)) != nil)
		s = period(s, u);
	return s + ".";
}

miscbib(r: ref Ref): string
{
	s := bibnames(r.author);
	if(len r.author == 0 && len r.editor > 0)
		s = bibnames(r.editor) + ", " + eds(len r.editor);
	s = period(s, quote(title(r), "."));
	if((h := site(r)) != nil)
		s += " " + h + ".";
	if((d := get(r, "date")) != nil || (d = get(r, "year")) != nil)
		s += " " + d + ".";
	if((u := link(r)) != nil)
		s += " " + u + ".";
	if(s[len s - 1] != '.')
		s += ".";
	return s;
}

#
# parts
#

# names in a note: A; A and B; A, B, and C; A et al.
notenames(n: array of ref Name): string
{
	case len n {
	0 =>
		return "";
	1 =>
		return normal(n[0]);
	2 =>
		return normal(n[0]) + " and " + normal(n[1]);
	3 =>
		return normal(n[0]) + ", " + normal(n[1]) + ", and " + normal(n[2]);
	}
	return normal(n[0]) + " et al.";
}

# last names in a short note
shortnames(n: array of ref Name): string
{
	case len n {
	1 =>
		return lastof(n[0]);
	2 =>
		return lastof(n[0]) + " and " + lastof(n[1]);
	3 =>
		return lastof(n[0]) + ", " + lastof(n[1]) + ", and " + lastof(n[2]);
	}
	return lastof(n[0]) + " et al.";
}

# names in the bibliography: the first inverted; up to six, else three and et al.
bibnames(n: array of ref Name): string
{
	if(len n == 0)
		return "";
	k := len n;
	etal := 0;
	if(k > 6){
		k = 3;
		etal = 1;
	}
	s := inverted(n[0]);
	if(k == 1 && !etal)
		return s;
	if(k == 2 && !etal)
		return s + ", and " + normal(n[1]);
	for(i := 1; i < k; i++){
		if(i == k - 1 && !etal)
			s += ", and " + normal(n[i]);
		else
			s += ", " + normal(n[i]);
	}
	if(etal)
		s += ", et al";
	return s;
}

normal(n: ref Name): string
{
	s := n.first;
	if(n.von != "")
		s = join(s, " ", n.von);
	s = join(s, " ", n.last);
	if(n.jr != "")
		s += " " + n.jr;
	return s;
}

inverted(n: ref Name): string
{
	if(n.first == "" && n.von == "")
		return n.last;	# an organization
	s := n.last + ", " + n.first;
	if(n.von != "")
		s += " " + n.von;
	if(n.jr != "")
		s += ", " + n.jr;
	return s;
}

lastof(n: ref Name): string
{
	return n.last;
}

eds(n: int): string
{
	if(n > 1)
		return "eds.";
	return "ed.";
}

title(r: ref Ref): string
{
	t := get(r, "title");
	if((st := get(r, "subtitle")) != nil)
		t += ": " + st;
	return t;
}

# the short title: given, else the title to its colon
shorttitle(r: ref Ref): string
{
	if((t := get(r, "shorttitle")) != nil)
		return t;
	t = get(r, "title");
	for(i := 0; i < len t; i++)
		if(t[i] == ':'){
			t = t[0:i];
			break;
		}
	# without an article it begins with
	for(a := array[] of {"The ", "A ", "An "}; len a > 0; a = a[1:])
		if(len t > len a[0] && t[0:len a[0]] == a[0])
			return t[len a[0]:];
	return t;
}

journal(r: ref Ref): string
{
	if((j := get(r, "journaltitle")) != nil)
		return j;
	return get(r, "journal");
}

# volume, number
volnum(r: ref Ref): string
{
	s := "";
	if((v := get(r, "volume")) != nil)
		s = " " + v;
	if((n := get(r, "number")) != nil || (n = get(r, "issue")) != nil)
		s += ", no. " + n;
	return s;
}

issuedate(r: ref Ref): string
{
	y := year(r);
	if((m := get(r, "month")) != nil)
		return m + " " + y;
	if((s := get(r, "season")) != nil)
		return s + " " + y;
	return y;
}

year(r: ref Ref): string
{
	if((y := get(r, "year")) != nil)
		return y;
	if((d := get(r, "date")) != nil && len d >= 4)
		return d[0:4];
	return "n.d.";
}

# [place: ]publisher, year
pubinfo(r: ref Ref): string
{
	s := "";
	if((p := get(r, "publisher")) != nil)
		s = p;
	if((a := get(r, "address")) != nil || (a = get(r, "location")) != nil){
		if(s != "")
			s = a + ": " + s;
		else
			s = a;
	}
	return join(s, ", ", year(r));
}

edition(r: ref Ref): string
{
	e := get(r, "edition");
	if(e == nil)
		return nil;
	n := 0;
	for(i := 0; i < len e; i++){
		if(e[i] < '0' || e[i] > '9')
			return e;	# as it is given
		n = n * 10 + e[i] - '0';
	}
	if(n == 1)
		return nil;
	sfx := "th";
	if(n % 100 < 11 || n % 100 > 13)
		case n % 10 {
		1 =>	sfx = "st";
		2 =>	sfx = "nd";
		3 =>	sfx = "rd";
		}
	return string n + sfx + " ed.";
}

# whether a work's title is in italics (a book's), else in quotation marks
italic(r: ref Ref): int
{
	case r.typ {
	"article" or "incollection" or "inbook" or "inproceedings" =>
		return 0;
	"book" or "collection" or "mvbook" or "proceedings" =>
		return 1;
	}
	return !thesis(r) && get(r, "publisher") != nil;
}

thesis(r: ref Ref): int
{
	return r.typ == "phdthesis" || r.typ == "mastersthesis" || r.typ == "thesis";
}

thesistype(r: ref Ref): string
{
	if((t := get(r, "type")) != nil)
		return t;
	if(r.typ == "mastersthesis")
		return "Master’s thesis";
	return "PhD diss.";
}

school(r: ref Ref): string
{
	if((s := get(r, "school")) != nil)
		return s;
	return get(r, "institution");
}

site(r: ref Ref): string
{
	if((h := get(r, "howpublished")) != nil)
		return h;
	if((h = get(r, "organization")) != nil)
		return h;
	return get(r, "publisher");
}

# a DOI as a URL, else the URL
link(r: ref Ref): string
{
	if((d := get(r, "doi")) != nil){
		if(len d > 4 && d[0:4] == "http")
			return d;
		return "https://doi.org/" + d;
	}
	return get(r, "url");
}

classical(r: ref Ref): int
{
	return get(r, "entrysubtype") == "classical" || r.typ == "classic";
}

# s in italics; italics within it roman
ital(s: string): string
{
	if(s == nil)
		return "";
	return "\\fI" + replace(s, "\\fI", "\\fR") + "\\fP";
}

# s in quotation marks, punct within them (none after ? or !); quotations within it single
quote(s, punct: string): string
{
	if(s == nil)
		return "";
	s = replace(replace(s, "“", "‘"), "”", "’");
	# a period, not a comma, gives way to a ? or ! ending the title
	# (the Manual's 6.134 since its 17th edition)
	if(punct == "." && (endsq(s) || endsin(s, ".")))
		punct = "";
	return "“" + s + punct + "”";
}

# whether s ends in ? or !, its fonts aside
endsq(s: string): int
{
	for(;;){
		if(len s >= 3 && s[len s - 3:len s - 1] == "\\f")
			s = s[0:len s - 3];
		else if(len s > 0 && (s[len s - 1] == '”' || s[len s - 1] == '’'))
			s = s[0:len s - 1];
		else
			break;
	}
	return len s > 0 && (s[len s - 1] == '?' || s[len s - 1] == '!');
}

comma(a, b: string): string
{
	return join(a, ", ", b);
}

# a and b, a sentence each
period(a, b: string): string
{
	if(a == "")
		return b;
	if(b == "")
		return a;
	if(!endsq(a) && !endsin(a, "."))
		a += ".";
	return a + " " + b;
}

# whether s ends in c, its fonts and quotation marks aside
endsin(s, c: string): int
{
	for(;;){
		if(len s >= 3 && s[len s - 3:len s - 1] == "\\f")
			s = s[0:len s - 3];
		else if(len s > 0 && (s[len s - 1] == '”' || s[len s - 1] == '’'))
			s = s[0:len s - 1];
		else
			break;
	}
	return len s >= len c && s[len s - len c:] == c;
}

join(a, sep, b: string): string
{
	if(a == "")
		return b;
	if(b == "")
		return a;
	return a + sep + b;
}

# s without sep at its end
strip(s, sep: string): string
{
	if(len s >= len sep && s[len s - len sep:] == sep)
		return s[0:len s - len sep];
	return s;
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

# a period doubled where parts meet: ?. and .. (a title ending in a
# question, an initial ending a name)
clean(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == ',' || c == '.'){
			# the character before, fonts and closing quotation marks aside
			j := len r - 1;
			for(;;){
				if(j >= 2 && r[j - 2] == '\\' && r[j - 1] == 'f')
					j -= 3;
				else if(j >= 0 && (r[j] == '”' || r[j] == '’'))
					j--;
				else
					break;
			}
			if(c == '.' && j >= 0 && (r[j] == '?' || r[j] == '!'))
				continue;
			if(c == '.' && j >= 0 && r[j] == '.')
				continue;
		}
		r[len r] = c;
	}
	return r;
}

# a place in a work: a range's hyphen an en dash, its second number abbreviated
locator(s: string): string
{
	return range(s);
}

# numbers' ranges, as the Manual gives them: 3–10, 101–8, 321–28, 1496–1504
range(s: string): string
{
	r := "";
	i := 0;
	while(i < len s){
		c := s[i];
		if((c == '-' || c == '–') && i > 0 && isdigit(s[i - 1])){
			# a hyphen, or two (--), between two numbers
			e := i + 1;
			while(e < len s && (s[e] == '-' || s[e] == '–'))
				e++;
			if(e < len s && isdigit(s[e])){
				# the numbers on either side
				a := len r;
				while(a > 0 && isdigit(r[a - 1]))
					a--;
				b := e;
				while(b < len s && isdigit(s[b]))
					b++;
				# a dotted part (1.1-5) is not abbreviated
				dotted := a > 0 && r[a - 1] == '.';
				if(dotted || (b < len s && s[b] == '.'))
					r += "–" + s[e:b];
				else
					r += "–" + inclusive(r[a:], s[e:b]);
				i = b;
				continue;
			}
		}
		r[len r] = c;
		i++;
	}
	return r;
}

inclusive(a, b: string): string
{
	x := int a;
	y := int b;
	if(len a != len b || y <= x || x < 100 || x % 100 == 0)
		return b;
	# the digits that change
	k := 0;
	while(k < len a && a[k] == b[k])
		k++;
	if(len a == 4 && len a - k >= 3)
		return b;
	if(x % 100 >= 10 && len b - k < 2)
		k = len b - 2;
	return b[k:];
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

# a key to sort by: lower case, without accents, fonts or quotation marks
fold(s: string): string
{
	# pairs of a letter with an accent and its letter, in lower case (from
	# Unicode's decompositions)
	fold := "ÀaÁaÂaÃaÄaÅaÇcÈeÉeÊeËeÌiÍiÎiÏiÑnÒoÓoÔoÕoÖoÙuÚuÛuÜuÝyàaáaâaãaäaåaçcèeéeêeëeìiíiîiïiñnòoóoôoõoöoùuúuûuüuýyÿyĀaāaĂaăaĄaąaĆcćcĈcĉcĊcċcČcčcĎdďdĒeēeĔeĕeĖeėeĘeęeĚeěeĜgĝgĞgğgĠgġgĢgģgĤhĥhĨiĩiĪiīiĬiĭiĮiįiİiĴjĵjĶkķkĹlĺlĻlļlĽlľlŃnńnŅnņnŇnňnŌoōoŎoŏoŐoőoŔrŕrŖrŗrŘrřrŚsśsŜsŝsŞsşsŠsšsŢtţtŤtťtŨuũuŪuūuŬuŭuŮuůuŰuűuŲuųuŴwŵwŶyŷyŸyŹzźzŻzżzŽzžzƠoơoƯuưuǍaǎaǏiǐiǑoǒoǓuǔuǕuǖuǗuǘuǙuǚuǛuǜuǞaǟaǠaǡaǦgǧgǨkǩkǪoǫoǬoǭoǰjǴgǵgǸnǹnǺaǻaȀaȁaȂaȃaȄeȅeȆeȇeȈiȉiȊiȋiȌoȍoȎoȏoȐrȑrȒrȓrȔuȕuȖuȗuȘsșsȚtțtȞhȟhȦaȧaȨeȩeȪoȫoȬoȭoȮoȯoȰoȱoȲyȳyḀaḁaḂbḃbḄbḅbḆbḇbḈcḉcḊdḋdḌdḍdḎdḏdḐdḑdḒdḓdḔeḕeḖeḗeḘeḙeḚeḛeḜeḝeḞfḟfḠgḡgḢhḣhḤhḥhḦhḧhḨhḩhḪhḫhḬiḭiḮiḯiḰkḱkḲkḳkḴkḵkḶlḷlḸlḹlḺlḻlḼlḽlḾmḿmṀmṁmṂmṃmṄnṅnṆnṇnṈnṉnṊnṋnṌoṍoṎoṏoṐoṑoṒoṓoṔpṕpṖpṗpṘrṙrṚrṛrṜrṝrṞrṟrṠsṡsṢsṣsṤsṥsṦsṧsṨsṩsṪtṫtṬtṭtṮtṯtṰtṱtṲuṳuṴuṵuṶuṷuṸuṹuṺuṻuṼvṽvṾvṿvẀwẁwẂwẃwẄwẅwẆwẇwẈwẉwẊxẋxẌxẍxẎyẏyẐzẑzẒzẓzẔzẕzẖhẗtẘwẙyẠaạaẢaảaẤaấaẦaầaẨaẩaẪaẫaẬaậaẮaắaẰaằaẲaẳaẴaẵaẶaặaẸeẹeẺeẻeẼeẽeẾeếeỀeềeỂeểeỄeễeỆeệeỈiỉiỊiịiỌoọoỎoỏoỐoốoỒoồoỔoổoỖoỗoỘoộoỚoớoỜoờoỞoởoỠoỡoỢoợoỤuụuỦuủuỨuứuỪuừuỬuửuỮuữuỰuựuỲyỳyỴyỵyỶyỷyỸyỹy";
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '\\' && i + 2 < len s && s[i + 1] == 'f'){
			i += 2;
			continue;
		}
		if(c == '“' || c == '”' || c == '‘' || c == '’' || c == '"')
			continue;
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		if(c >= 16rc0)
			for(k := 0; k + 1 < len fold; k += 2)
				if(fold[k] == c){
					c = fold[k + 1];
					break;
				}
		r[len r] = c;
	}
	return r;
}
