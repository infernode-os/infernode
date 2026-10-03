implement Html;

#
# The HTML parser: WHATWG HTML §13.2, tokenization (§13.2.5) and tree
# construction (§13.2.6).  Section numbers in comments are from the
# living standard.
#
# Departures, all deliberate:
#  - The script-data escape states (<!-- ... --> inside <script>) are not
#    modelled: a script ends at the first </script>.
#  - Parse errors are not reported; recovery is as specified.
#  - Template contents are children of the template element rather than
#    a separate fragment; the tree dump shows them under "content".
#  - Encoding: BOM, transport charset, <meta> prescan, else UTF-8.
#    No encoding changes once parsing has started.
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "convcs.m";
	convcs: Convcs;
include "web/dom.m";
	dom: Dom;
	Doc, Node: import dom;
	Document, Doctype, Element, Text, Comment, HTML, SVG, MathML: import Dom;
	Tnone, Ta, Tabbr, Taddress, Tapplet, Tarea, Tarticle, Taside, Taudio,
	Tb, Tbase, Tbasefont, Tbdi, Tbdo, Tbgsound, Tbig, Tblockquote, Tbody,
	Tbr, Tbutton, Tcanvas, Tcaption, Tcenter, Tcite, Tcode, Tcol, Tcolgroup,
	Tdata, Tdatalist, Tdd, Tdel, Tdetails, Tdfn, Tdialog, Tdir, Tdiv, Tdl,
	Tdt, Tem, Tembed, Tfieldset, Tfigcaption, Tfigure, Tfont, Tfooter,
	Tform, Tframe, Tframeset, Th1, Th2, Th3, Th4, Th5, Th6, Thead, Theader,
	Thgroup, Thr, Thtml, Ti, Tiframe, Timage, Timg, Tinput, Tins, Tkbd,
	Tkeygen, Tlabel, Tlegend, Tli, Tlink, Tlisting, Tmain, Tmap, Tmark,
	Tmarquee, Tmenu, Tmeta, Tmeter, Tnav, Tnobr, Tnoembed, Tnoframes,
	Tnoscript, Tobject, Tol, Toptgroup, Toption, Toutput, Tp, Tparam,
	Tpicture, Tplaintext, Tpre, Tprogress, Tq, Trb, Trp, Trt, Trtc, Truby,
	Ts, Tsamp, Tscript, Tsearch, Tsection, Tselect, Tslot, Tsmall, Tsource,
	Tspan, Tstrike, Tstrong, Tstyle, Tsub, Tsummary, Tsup, Ttable, Ttbody,
	Ttd, Ttemplate, Ttextarea, Ttfoot, Tth, Tthead, Ttime, Ttitle, Ttr,
	Ttrack, Ttt, Tu, Tul, Tvar, Tvideo, Twbr, Txmp, Tsvg, Tmath, Tdesc,
	TforeignObject, Tmi, Tmo, Tmn, Tms, Tmtext, Tannotation_xml,
	Ntags: import Dom;
include "web/html.m";

ENTITIES: con "/lib/web/entities";

# ---- tokens ----

Kdoctype, Kstart, Kend, Kchars, Kcomment, Keof: con iota;

Tok: adt {
	kind:	int;
	name:	string;		# tag or doctype name, lower case
	tag:	int;		# Dom tag of name
	attrs:	list of (string, string);
	selfclose:	int;
	data:	string;		# characters, comment text, doctype public id
	sysid:	string;		# doctype system id
	haspub, hassys:	int;
	quirks:	int;		# doctype force-quirks flag
};

# tokenizer states the tree builder can select
Sdata, Srcdata, Srawtext, Sscript, Splaintext: con iota;

# insertion modes (§13.2.4.1)
Minitial, Mbeforehtml, Mbeforehead, Minhead, Minheadnoscript, Mafterhead,
Minbody, Mtext, Mintable, Mintabletext, Mincaption, Mincolgroup,
Mintablebody, Minrow, Mincell, Minselect, Minselectintable, Mintemplate,
Mafterbody, Minframeset, Mafterframeset, Mafterafterbody,
Mafterafterframeset: con iota;

# an entry in the list of active formatting elements; node 0 is a marker
Afe: adt {
	node:	int;
	tok:	ref Tok;
};

P: adt {
	d:	ref Doc;
	s:	string;		# input, newlines normalised
	i:	int;		# tokenizer position
	state:	int;		# Sdata etc.
	endname:	string;	# the appropriate end tag for rcdata/rawtext/script

	mode:	int;
	origmode:	int;	# for Mtext and Mintabletext
	tmodes:	list of int;	# stack of template insertion modes
	stack:	array of int;	# open elements; stack[0] is html
	sp:	int;
	afe:	array of ref Afe;
	nafe:	int;
	head:	int;
	form:	int;
	framesetok:	int;
	foster:	int;
	pendchars:	string;	# Mintabletext
	pendnonws:	int;
	skiplf:	int;		# ignore a newline right after <pre>, <listing>, <textarea>
	stopped:	int;
};

# ---- module ----

init()
{
	sys = load Sys Sys->PATH;
	dom = load Dom Dom->PATH;
	bufio = load Bufio Bufio->PATH;
	mksets();
}

parsestring(s, url: string): ref Doc
{
	if(sys == nil)
		init();
	p := ref P(
		Doc.new(url), normnl(s), 0, Sdata, nil,
		Minitial, Minitial, nil, array[64] of int, 0, array[16] of ref Afe, 0,
		0, 0, 1, 0, nil, 0, 0, 0);
	run(p);
	return p.d;
}

parse(data: array of byte, cs, url: string): ref Doc
{
	if(sys == nil)
		init();
	cs = charset(data, cs);
	if(len data >= 3 && data[0] == byte 16rEF && data[1] == byte 16rBB && data[2] == byte 16rBF)
		data = data[3:];
	d := parsestring(decode(data, cs), url);
	d.charset = cs;
	d.lang = metalang(d);
	return d;
}

# ---- XML ----

XHTMLNS: con "http://www.w3.org/1999/xhtml";
SVGNS: con "http://www.w3.org/2000/svg";
MATHNS: con "http://www.w3.org/1998/Math/MathML";
OTHERNS: con -1;	# an element in a namespace we know nothing about

parsexml(data: array of byte, cs, url: string): ref Doc
{
	if(sys == nil)
		init();
	if(cs == nil) {
		cs = "utf-8";
		if(len data > 5 && string data[0:5] == "<?xml") {
			e := 0;
			while(e < len data && e < 200 && data[e] != byte '>')
				e++;
			decl := string data[0:e];
			if((v := xmlattr(decl, "encoding")) != nil)
				cs = v;
		}
	}
	cs = charset(data, cs);
	if(len data >= 3 && data[0] == byte 16rEF && data[1] == byte 16rBB && data[2] == byte 16rBF)
		data = data[3:];
	s := normnl(decode(data, cs));
	if(entities == nil)
		loadentities();

	d := Doc.new(url);
	d.xml = 1;
	d.charset = cs;
	d.lang = metalang(d);
	stack := array[64] of int;
	nss := array[64] of list of (string, string);	# prefix bindings in scope
	stack[0] = 1;
	nss[0] = ("xml", "http://www.w3.org/XML/1998/namespace") :: nil;
	sp := 0;
	i := 0;
	n := len s;
	while(i < n) {
		if(s[i] != '<') {
			j := i;
			while(j < n && s[j] != '<')
				j++;
			xmltext(d, stack[sp], xmlunescape(s[i:j]));
			i = j;
			continue;
		}
		if(hasat(s, i, "<!--")) {
			e := find(s, i + 4, "-->");
			c := d.create(Dom->Comment, nil, Dom->HTML);
			d.settext(c, s[i+4:e]);
			d.append(stack[sp], c);
			i = e + 3;
		} else if(hasat(s, i, "<![CDATA[")) {
			e := find(s, i + 9, "]]>");
			xmltext(d, stack[sp], s[i+9:e]);
			i = e + 3;
		} else if(hasat(s, i, "<!")) {	# DOCTYPE, with any internal subset
			depth := 0;
			for(i += 2; i < n; i++) {
				if(s[i] == '[')
					depth++;
				else if(s[i] == ']')
					depth--;
				else if(s[i] == '>' && depth <= 0)
					break;
			}
			i++;
		} else if(hasat(s, i, "<?")) {
			i = find(s, i + 2, "?>") + 2;
		} else if(hasat(s, i, "</")) {
			e := find(s, i, ">");
			(nil, name) := splitq(trimws(s[i+2:e]));
			i = e + 1;
			for(k := sp; k > 0; k--)
				if(localname(d, stack[k]) == name) {
					sp = k - 1;
					break;
				}
		} else {
			# a start tag: name, attributes, maybe />
			j := i + 1;
			while(j < n && !xmlspace(s[j]) && s[j] != '>' && s[j] != '/')
				j++;
			name := s[i+1:j];
			attrs: list of (string, string);
			empty := 0;
			for(;;) {
				while(j < n && xmlspace(s[j]))
					j++;
				if(j >= n)
					break;
				if(s[j] == '>') {
					j++;
					break;
				}
				if(s[j] == '/') {
					empty = 1;
					j++;
					continue;
				}
				a := j;
				while(j < n && !xmlspace(s[j]) && s[j] != '=' && s[j] != '>' && s[j] != '/')
					j++;
				an := s[a:j];
				while(j < n && xmlspace(s[j]))
					j++;
				av := "";
				if(j < n && s[j] == '=') {
					j++;
					while(j < n && xmlspace(s[j]))
						j++;
					if(j < n && (s[j] == '"' || s[j] == '\'')) {
						q := s[j];
						e := j + 1;
						while(e < n && s[e] != q)
							e++;
						av = xmlunescape(s[j+1:e]);
						j = e + 1;
					}
				}
				if(an != "")
					attrs = (an, av) :: attrs;
			}
			i = j;
			# namespaces in scope here
			scope := nss[sp];
			for(l := attrs; l != nil; l = tl l) {
				(an, av) := hd l;
				if(an == "xmlns")
					scope = ("", av) :: scope;
				else if(len an > 6 && an[0:6] == "xmlns:")
					scope = (an[6:], av) :: scope;
			}
			(prefix, local) := splitq(name);
			uri := lookupns(scope, prefix);
			ns := Dom->HTML;
			case uri {
			XHTMLNS =>	ns = Dom->HTML;
			SVGNS =>	ns = Dom->SVG;
			MATHNS =>	ns = Dom->MathML;
			* =>		ns = OTHERNS;
			}
			el: int;
			if(ns == OTHERNS) {
				el = d.create(Dom->Element, name, Dom->HTML);
				d.nodes[el].tag = Dom->Tnone;	# not an HTML element, whatever its name
			} else
				el = d.create(Dom->Element, local, ns);
			for(r := rev(attrs); r != nil; r = tl r) {
				(an, av) := hd r;
				d.setattr(el, an, av);
			}
			d.append(stack[sp], el);
			if(!empty) {
				if(sp + 1 >= len stack) {
					ns2 := array[2*len stack] of int;
					ns2[0:] = stack;
					stack = ns2;
					nn := array[len stack] of list of (string, string);
					nn[0:] = nss;
					nss = nn;
				}
				sp++;
				stack[sp] = el;
				nss[sp] = scope;
			}
		}
	}
	return d;
}

rev(l: list of (string, string)): list of (string, string)
{
	r: list of (string, string);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# the element's local name, for matching end tags
localname(d: ref Doc, n: int): string
{
	(nil, l) := splitq(d.nodes[n].name);
	return l;
}

splitq(name: string): (string, string)
{
	for(i := 0; i < len name; i++)
		if(name[i] == ':')
			return (name[0:i], name[i+1:]);
	return ("", name);
}

lookupns(scope: list of (string, string), prefix: string): string
{
	for(; scope != nil; scope = tl scope)
		if((hd scope).t0 == prefix)
			return (hd scope).t1;
	if(prefix == "")
		return XHTMLNS;	# no declaration: as browsers treat a bare document
	return nil;
}

xmltext(d: ref Doc, parent: int, t: string)
{
	if(t == "" || parent == 1)
		return;	# outside the root element there is no text, only white space
	last := d.nodes[parent].last;
	if(last != 0 && d.nodes[last].kind == Dom->Text) {
		d.settext(last, d.nodes[last].text + t);
		return;
	}
	c := d.create(Dom->Text, nil, Dom->HTML);
	d.settext(c, t);
	d.append(parent, c);
}

xmlunescape(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '&')
			break;
	if(i == len s)
		return s;
	r := s[0:i];
	while(i < len s) {
		c := s[i];
		if(c != '&') {
			r[len r] = c;
			i++;
			continue;
		}
		e := i + 1;
		while(e < len s && e - i < 40 && s[e] != ';' && s[e] != '&' && s[e] != '<')
			e++;
		if(e >= len s || s[e] != ';') {
			r[len r] = c;
			i++;
			continue;
		}
		name := s[i+1:e];
		if(len name > 1 && name[0] == '#') {
			v := 0;
			k := 1;
			base := 10;
			if(name[1] == 'x' || name[1] == 'X') {
				k = 2;
				base = 16;
			}
			if(k >= len name)
				v = -1;
			for(; k < len name && v >= 0; k++) {
				dv := digitval(name[k], base == 16);
				if(dv < 0 || v > 16r10FFFF)
					v = -1;
				else
					v = v*base + dv;
			}
			if(v <= 0 || v > 16r10FFFF || v >= 16rD800 && v <= 16rDFFF)
				v = 16rFFFD;
			r[len r] = v;
		} else {
			(ok, t) := entity(name + ";");
			if(ok)
				r += t;
			else
				r += s[i:e+1];
		}
		i = e + 1;
	}
	return r;
}

xmlattr(decl, name: string): string
{
	i := find(decl, 0, name);
	if(i >= len decl)
		return nil;
	for(i += len name; i < len decl && decl[i] != '"' && decl[i] != '\''; i++)
		;
	if(i >= len decl)
		return nil;
	q := decl[i];
	e := i + 1;
	while(e < len decl && decl[e] != q)
		e++;
	return decl[i+1:e];
}

xmlspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

hasat(s: string, i: int, t: string): int
{
	return i + len t <= len s && s[i:i+len t] == t;
}

# the index of t in s at or after i, or len s
find(s: string, i: int, t: string): int
{
	for(; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return len s;
}

trimws(s: string): string
{
	i := 0;
	while(i < len s && xmlspace(s[i]))
		i++;
	j := len s;
	while(j > i && xmlspace(s[j-1]))
		j--;
	return s[i:j];
}

normnl(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\r')
			break;
	if(i == len s)
		return s;
	r := s[0:i];
	for(; i < len s; i++) {
		if(s[i] == '\r') {
			r[len r] = '\n';
			if(i+1 < len s && s[i+1] == '\n')
				i++;
		} else
			r[len r] = s[i];
	}
	return r;
}

# ---- encoding (§13.2.3) ----

charset(data: array of byte, transport: string): string
{
	if(len data >= 3 && data[0] == byte 16rEF && data[1] == byte 16rBB && data[2] == byte 16rBF)
		return "utf-8";
	if(len data >= 2 && data[0] == byte 16rFE && data[1] == byte 16rFF)
		return "utf-16be";
	if(len data >= 2 && data[0] == byte 16rFF && data[1] == byte 16rFE)
		return "utf-16le";
	if(transport != nil)
		return canoncs(transport);
	n := len data;
	if(n > 1024)
		n = 1024;
	cs := prescan(string data[0:n]);
	if(cs != nil)
		return cs;
	# Undeclared: §13.2.3.2 step 9 leaves the default to the locale and
	# the implementation; browsers in a Western locale take
	# windows-1252.  Valid UTF-8 is far too unlikely by chance to be
	# anything else, so it decides.
	if(validutf8(data))
		return "utf-8";
	return "windows-1252";
}

# well-formed UTF-8 throughout (RFC 3629): no stray continuation or
# truncated sequence, no overlong form, no surrogate
validutf8(b: array of byte): int
{
	n := len b;
	for(i := 0; i < n; ) {
		c := int b[i];
		if(c < 16r80) {
			i++;
			continue;
		}
		k := 0;
		lo := 16r80;
		if(c >= 16rC2 && c <= 16rDF)
			k = 1;
		else if(c >= 16rE0 && c <= 16rEF) {
			k = 2;
			if(c == 16rE0)
				lo = 16rA0;
		} else if(c >= 16rF0 && c <= 16rF4) {
			k = 3;
			if(c == 16rF0)
				lo = 16r90;
		} else
			return 0;
		if(i + k >= n)
			return 0;
		hi := 16rBF;
		if(c == 16rED)
			hi = 16r9F;	# no surrogates
		if(c == 16rF4)
			hi = 16r8F;	# no more than U+10FFFF
		d := int b[i+1];
		if(d < lo || d > hi)
			return 0;
		for(j := 2; j <= k; j++) {
			d = int b[i+j];
			if(d < 16r80 || d > 16rBF)
				return 0;
		}
		i += k + 1;
	}
	return 1;
}

canoncs(cs: string): string
{
	cs = lower(trim(cs));
	case cs {
	"utf8" or "unicode-1-1-utf-8" or "x-unicode20utf8" =>
		return "utf-8";
	"latin1" or "iso-8859-1" or "iso8859-1" or "us-ascii" or "ascii" or "l1" or "cp1252" or "x-cp1252" or
	"x-user-defined" =>
		return "windows-1252";	# as the Encoding standard maps them
	"gbk" or "gb18030" or "gb_2312" or "gb_2312-80" or "x-gbk" or "chinese" or "csgb2312" =>
		return "gb2312";	# the superset's common characters; its own tables are not here
	"shift_jis" or "shift-jis" or "sjis" or "x-sjis" or "ms_kanji" or "windows-31j" or "cp932" =>
		return "cp932";
	"utf-16" or "unicodefffe" or "unicodefeff" or "ucs-2" =>
		return "utf-16";	# the byte-order mark or a guess decides the order
	}
	return cs;
}

# <meta http-equiv=content-language content=...>: the document's language
metalang(d: ref Doc): string
{
	for(i := 1; i < d.n; i++) {
		nd := d.nodes[i];
		if(nd == nil || nd.kind != Dom->Element || nd.tag != Dom->Tmeta)
			continue;
		if(lower(d.attr(i, "http-equiv")) == "content-language") {
			l := trim(d.attr(i, "content"));
			for(k := 0; k < len l; k++)
				if(l[k] == ',')
					return trim(l[0:k]);	# the first of a list
			return l;
		}
	}
	return nil;
}

# Find <meta charset=...> or <meta http-equiv=content-type content="...charset=...">.
prescan(s: string): string
{
	ls := lower(s);
	for(i := 0; i < len ls; i++) {
		if(ls[i] != '<' || i+5 >= len ls || ls[i+1:i+5] != "meta")
			continue;
		e := i;
		while(e < len ls && ls[e] != '>')
			e++;
		tag := ls[i:e];
		v := attrval(tag, "charset");
		if(v == nil) {
			c := attrval(tag, "content");
			if(c != nil) {
				for(k := 0; k+7 < len c; k++)
					if(c[k:k+7] == "charset") {
						v = trim(c[k+7:]);
						if(len v > 0 && v[0] == '=')
							v = trim(v[1:]);
						break;
					}
			}
		}
		if(v != nil) {
			for(k := 0; k < len v; k++)
				if(v[k] == ';' || v[k] == '"' || v[k] == '\'' || v[k] == ' ') {
					v = v[0:k];
					break;
				}
			v = canoncs(v);
			if(len v > 6 && v[0:6] == "utf-16")
				v = "utf-8";	# a document that can be read as ASCII is not UTF-16
			return v;
		}
	}
	return nil;
}

attrval(tag, name: string): string
{
	for(i := 0; i+len name < len tag; i++) {
		if(tag[i:i+len name] != name || (i > 0 && !isspace(tag[i-1])))
			continue;
		j := i+len name;
		while(j < len tag && isspace(tag[j]))
			j++;
		if(j >= len tag || tag[j] != '=')
			continue;
		j++;
		while(j < len tag && isspace(tag[j]))
			j++;
		if(j < len tag && (tag[j] == '"' || tag[j] == '\'')) {
			q := tag[j++];
			k := j;
			while(k < len tag && tag[k] != q)
				k++;
			return tag[j:k];
		}
		k := j;
		while(k < len tag && !isspace(tag[k]) && tag[k] != '/')
			k++;
		return tag[j:k];
	}
	return nil;
}

decode(data: array of byte, cs: string): string
{
	if(cs == "utf-8" || cs == nil)
		return string data;
	if(cs == "utf-16" || cs == "utf-16be" || cs == "utf-16le")
		return utf16(data, cs);
	if(convcs == nil) {
		convcs = load Convcs Convcs->PATH;
		if(convcs == nil || convcs->init(nil) != nil) {
			convcs = nil;
			return string data;
		}
	}
	(btos, err) := convcs->getbtos(cs);
	if(err != nil && cs == "windows-1252")
		(btos, err) = convcs->getbtos("iso-8859-1");
	if(err != nil)
		return string data;
	(nil, s, nil) := btos->btos(Convcs->Startstate, data, -1);
	return s;
}

# UTF-16 in either byte order; a byte order mark decides and is
# dropped, and without one utf-16 is little-endian (Encoding §14.4)
utf16(data: array of byte, cs: string): string
{
	be := cs == "utf-16be";
	if(len data >= 2) {
		if(data[0] == byte 16rFE && data[1] == byte 16rFF) {
			be = 1;
			data = data[2:];
		} else if(data[0] == byte 16rFF && data[1] == byte 16rFE) {
			be = 0;
			data = data[2:];
		}
	}
	s := "";
	hi := 0;
	for(i := 0; i + 1 < len data; i += 2) {
		c := int data[i] << 8 | int data[i+1];
		if(!be)
			c = int data[i+1] << 8 | int data[i];
		if(hi != 0) {
			if(c >= 16rDC00 && c <= 16rDFFF) {
				s[len s] = 16r10000 + ((hi - 16rD800) << 10) + (c - 16rDC00);
				hi = 0;
				continue;
			}
			s[len s] = 16rFFFD;
			hi = 0;
		}
		if(c >= 16rD800 && c <= 16rDBFF) {
			hi = c;
			continue;
		}
		if(c >= 16rDC00 && c <= 16rDFFF)
			c = 16rFFFD;
		s[len s] = c;
	}
	if(hi != 0)
		s[len s] = 16rFFFD;
	return s;
}

cssdecode(data: array of byte, transport, hint, docs: string): string
{
	if(len data >= 3 && data[0] == byte 16rEF && data[1] == byte 16rBB && data[2] == byte 16rBF)
		return string data[3:];
	if(len data >= 2 && data[0] == byte 16rFE && data[1] == byte 16rFF)
		return utf16(data, "utf-16be");
	if(len data >= 2 && data[0] == byte 16rFF && data[1] == byte 16rFE)
		return utf16(data, "utf-16le");
	cs := "utf-8";
	if(transport != nil)
		cs = canoncs(transport);
	else if((a := atcharset(data)) != nil)
		cs = a;
	else if(hint != nil)
		cs = canoncs(hint);
	else if(docs != nil)
		cs = docs;
	return decode(data, cs);
}

# the label of an @charset "..."; rule at the very start, byte for byte
atcharset(data: array of byte): string
{
	pfx := "@charset \"";
	if(len data < len pfx || string data[0:len pfx] != pfx)
		return nil;
	for(i := len pfx; i < len data && i < 1024; i++)
		if(data[i] == byte '"') {
			if(i + 1 < len data && data[i+1] == byte ';') {
				cs := canoncs(string data[len pfx:i]);
				if(cs == "utf-16" || cs == "utf-16be" || cs == "utf-16le")
					cs = "utf-8";	# the rule was readable, so the bytes are not UTF-16
				return cs;
			}
			return nil;
		}
	return nil;
}

# ---- character references (§13.2.5.72) ----

Nehash: con 1024;
entities: array of list of (string, string);
maxentity := 0;

loadentities()
{
	t := array[Nehash] of list of (string, string);
	if(bufio != nil && (f := bufio->open(ENTITIES, Bufio->OREAD)) != nil) {
		while((l := f.gets('\n')) != nil) {
			if(l[0] == '#')
				continue;
			(nil, fl) := sys->tokenize(l, " \n");
			if(len fl < 2)
				continue;
			name := hd fl;
			v := "";
			for(fl = tl fl; fl != nil; fl = tl fl)
				v[len v] = hexval(hd fl);
			h := strhash(name, Nehash);
			t[h] = (name, v) :: t[h];
			if(len name > maxentity)
				maxentity = len name;
		}
	} else {
		# without the table, at least the five XML ones
		for(l := list of {("amp;", "&"), ("lt;", "<"), ("gt;", ">"), ("quot;", "\""), ("apos;", "'"),
				("amp", "&"), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("nbsp;", " ")}; l != nil; l = tl l) {
			h := strhash((hd l).t0, Nehash);
			t[h] = hd l :: t[h];
		}
		maxentity = 5;
	}
	entities = t;
}

entity(name: string): (int, string)
{
	for(l := entities[strhash(name, Nehash)]; l != nil; l = tl l)
		if((hd l).t0 == name)
			return (1, (hd l).t1);
	return (0, nil);
}

# windows-1252 meanings of numeric references 0x80-0x9F
c1 := array[] of {
	16r20AC, 16r81, 16r201A, 16r0192, 16r201E, 16r2026, 16r2020, 16r2021,
	16r02C6, 16r2030, 16r0160, 16r2039, 16r0152, 16r8D, 16r017D, 16r8F,
	16r90, 16r2018, 16r2019, 16r201C, 16r201D, 16r2022, 16r2013, 16r2014,
	16r02DC, 16r2122, 16r0161, 16r203A, 16r0153, 16r9D, 16r017E, 16r0178,
};

# s[i] is '&'; return the replacement text and the index after the reference.
charref(s: string, i, inattr: int): (string, int)
{
	n := len s;
	j := i+1;
	if(j >= n)
		return ("&", j);
	c := s[j];
	if(c == '#') {
		j++;
		hex := 0;
		if(j < n && (s[j] == 'x' || s[j] == 'X')) {
			hex = 1;
			j++;
		}
		base := 10;
		if(hex)
			base = 16;
		v := 0;
		st := j;
		for(; j < n; j++) {
			d := digitval(s[j], hex);
			if(d < 0)
				break;
			if(v < 16r110000)
				v = v*base + d;
		}
		if(j == st)
			return ("&", i+1);
		if(j < n && s[j] == ';')
			j++;
		if(v == 0 || v > 16r10FFFF || (v >= 16rD800 && v <= 16rDFFF))
			v = 16rFFFD;
		else if(v >= 16r80 && v <= 16r9F)
			v = c1[v-16r80];
		r := "";
		r[0] = v;
		return (r, j);
	}
	if(!isalnum(c))
		return ("&", j);
	if(entities == nil)
		loadentities();
	# longest name in the table that prefixes the input
	e := j;
	while(e < n && e-j < maxentity && isalnum(s[e]))
		e++;
	if(e < n && s[e] == ';' && e-j < maxentity)
		e++;
	for(k := e; k > j; k--) {
		(ok, v) := entity(s[j:k]);
		if(!ok)
			continue;
		if(s[k-1] != ';' && inattr && k < n && (s[k] == '=' || isalnum(s[k])))
			return ("&", i+1);
		return (v, k);
	}
	return ("&", i+1);
}

# ---- tokenizer (§13.2.5) ----

eoftok: ref Tok;

chartok(s: string): ref Tok
{
	return ref Tok(Kchars, nil, 0, nil, 0, s, nil, 0, 0, 0);
}

lex(p: ref P): ref Tok
{
	if(p.i >= len p.s)
		return ref Tok(Keof, nil, 0, nil, 0, nil, nil, 0, 0, 0);
	case p.state {
	Srcdata =>
		return lexraw(p, 1);
	Srawtext or Sscript =>
		return lexraw(p, 0);
	Splaintext =>
		t := chartok(nulls(p.s[p.i:], 16rFFFD));
		p.i = len p.s;
		return t;
	}
	s := p.s;
	n := len s;
	i := p.i;
	if(s[i] == '<') {
		t := lextag(p);
		if(t != nil)
			return t;
		i++;	# a '<' that starts nothing is text
	}
	text := "";
	st := p.i;
	while(i < n && s[i] != '<') {
		if(s[i] == '&') {
			text += s[st:i];
			r: string;
			(r, i) = charref(s, i, 0);
			text += r;
			st = i;
		} else
			i++;
	}
	text += s[st:i];
	p.i = i;
	return chartok(text);
}

# RCDATA, RAWTEXT and script data: text up to the appropriate end tag.
lexraw(p: ref P, refs: int): ref Tok
{
	s := p.s;
	n := len s;
	en := p.endname;
	i := p.i;
	for(e := i; e < n; e++) {
		if(s[e] != '<' || e+1 >= n || s[e+1] != '/' || e+2+len en > n)
			continue;
		if(lower(s[e+2:e+2+len en]) != en)
			continue;
		k := e+2+len en;
		if(k < n && !isspace(s[k]) && s[k] != '/' && s[k] != '>')
			continue;
		break;
	}
	if(e == i) {
		if(e+2+len en >= n) {
			# "</script" at the end of the input is text (§13.2.5.17)
			p.i = n;
			return chartok(s[i:n]);
		}
		return tagtok(p, i+2, Kend);
	}
	text := s[i:e];
	if(refs) {
		r := "";
		st := 0;
		for(k := 0; k < len text; )
			if(text[k] == '&') {
				r += text[st:k];
				x: string;
				(x, k) = charref(text, k, 0);
				r += x;
				st = k;
			} else
				k++;
		text = r + text[st:];
	}
	p.i = e;
	return chartok(nulls(text, 16rFFFD));
}

nulls(s: string, r: int): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == 0)
			s[i] = r;
	return s;
}

# At '<'.  Returns nil if the '<' does not start markup.
lextag(p: ref P): ref Tok
{
	s := p.s;
	n := len s;
	i := p.i;
	if(i+1 >= n)
		return nil;
	c := s[i+1];
	if(isalpha(c))
		return tagtok(p, i+1, Kstart);
	if(c == '/') {
		if(i+2 >= n)
			return nil;
		if(isalpha(s[i+2]))
			return tagtok(p, i+2, Kend);
		if(s[i+2] == '>') {
			p.i = i+3;
			return lex(p);
		}
		return bogus(p, i+2);
	}
	if(c == '?')
		return bogus(p, i+1);
	if(c != '!')
		return nil;
	j := i+2;
	if(j+1 < n && s[j] == '-' && s[j+1] == '-')
		return comment(p, j+2);
	if(j+7 <= n && lower(s[j:j+7]) == "doctype")
		return doctype(p, j+7);
	if(j+7 <= n && s[j:j+7] == "[CDATA[" && p.sp > 0 && p.d.nodes[cur(p)].ns != HTML) {
		e := index(s, "]]>", j+7);
		if(e < 0)
			e = n;
		p.i = e+3;
		if(p.i > n)
			p.i = n;
		return chartok(s[j+7:e]);
	}
	return bogus(p, j);
}

bogus(p: ref P, j: int): ref Tok
{
	e := j;
	while(e < len p.s && p.s[e] != '>')
		e++;
	t := ref Tok(Kcomment, nil, 0, nil, 0, nulls(p.s[j:e], 16rFFFD), nil, 0, 0, 0);
	p.i = e+1;
	if(p.i > len p.s)
		p.i = len p.s;
	return t;
}

comment(p: ref P, j: int): ref Tok
{
	s := p.s;
	n := len s;
	e, end: int;
	if(j < n && s[j] == '>') {		# <!-->
		e = j;
		end = j+1;
	} else if(j+1 < n && s[j] == '-' && s[j+1] == '>') {	# <!--->
		e = j;
		end = j+2;
	} else {
		e = j;
		for(;;) {
			e = index(s, "--", e);
			if(e < 0) {
				e = end = n;
				break;
			}
			if(e+2 < n && s[e+2] == '>') {
				end = e+3;
				break;
			}
			if(e+3 < n && s[e+2] == '!' && s[e+3] == '>') {
				end = e+4;
				break;
			}
			e++;
		}
	}
	p.i = end;
	return ref Tok(Kcomment, nil, 0, nil, 0, nulls(s[j:e], 16rFFFD), nil, 0, 0, 0);
}

doctype(p: ref P, j: int): ref Tok
{
	s := p.s;
	n := len s;
	e := j;
	while(e < n && s[e] != '>')
		e++;
	p.i = e+1;
	if(p.i > n)
		p.i = n;
	t := ref Tok(Kdoctype, nil, 0, nil, 0, nil, nil, 0, 0, 0);
	if(e == n)
		t.quirks = 1;
	b := s[j:e];
	k := 0;
	while(k < len b && isspace(b[k]))
		k++;
	st := k;
	while(k < len b && !isspace(b[k]))
		k++;
	t.name = nulls(lower(b[st:k]), 16rFFFD);
	if(t.name == "")
		t.quirks = 1;
	while(k < len b && isspace(b[k]))
		k++;
	if(k >= len b)
		return t;
	kw := lower(b[k:]);
	if(len kw >= 6 && kw[0:6] == "public") {
		k += 6;
		(t.data, k, t.haspub) = quoted(b, k);
		if(!t.haspub) {
			t.quirks = 1;
			return t;
		}
		(t.sysid, k, t.hassys) = quoted(b, k);
	} else if(len kw >= 6 && kw[0:6] == "system") {
		k += 6;
		(t.sysid, k, t.hassys) = quoted(b, k);
		if(!t.hassys)
			t.quirks = 1;
	} else
		t.quirks = 1;
	return t;
}

quoted(b: string, k: int): (string, int, int)
{
	while(k < len b && isspace(b[k]))
		k++;
	if(k >= len b || (b[k] != '"' && b[k] != '\''))
		return (nil, k, 0);
	q := b[k++];
	st := k;
	while(k < len b && b[k] != q)
		k++;
	return (b[st:k], k+1, 1);
}

# A start or end tag whose name begins at s[j].
tagtok(p: ref P, j, kind: int): ref Tok
{
	s := p.s;
	n := len s;
	st := j;
	while(j < n && !isspace(s[j]) && s[j] != '/' && s[j] != '>')
		j++;
	t := ref Tok(kind, nulls(lower(s[st:j]), 16rFFFD), 0, nil, 0, nil, nil, 0, 0, 0);
	t.tag = dom->atom(t.name);
	attrs: list of (string, string);
	for(;;) {
		while(j < n && isspace(s[j]))
			j++;
		if(j >= n) {	# EOF in tag: the tag is dropped
			p.i = n;
			return ref Tok(Keof, nil, 0, nil, 0, nil, nil, 0, 0, 0);
		}
		if(s[j] == '>') {
			j++;
			break;
		}
		if(s[j] == '/') {
			j++;
			if(j < n && s[j] == '>') {
				t.selfclose = 1;
				j++;
				break;
			}
			continue;
		}
		st = j++;
		while(j < n && !isspace(s[j]) && s[j] != '/' && s[j] != '>' && s[j] != '=')
			j++;
		name := nulls(lower(s[st:j]), 16rFFFD);
		val := "";
		while(j < n && isspace(s[j]))
			j++;
		if(j < n && s[j] == '=') {
			j++;
			while(j < n && isspace(s[j]))
				j++;
			if(j < n && (s[j] == '"' || s[j] == '\'')) {
				q := s[j++];
				st = j;
				while(j < n && s[j] != q)
					j++;
				val = s[st:j];
				if(j < n)
					j++;
			} else {
				st = j;
				while(j < n && !isspace(s[j]) && s[j] != '>')
					j++;
				val = s[st:j];
			}
			val = attrrefs(val);
		}
		dup := 0;
		for(l := attrs; l != nil; l = tl l)
			if((hd l).t0 == name)
				dup = 1;
		if(!dup)
			attrs = (name, nulls(val, 16rFFFD)) :: attrs;
	}
	for(; attrs != nil; attrs = tl attrs)
		t.attrs = hd attrs :: t.attrs;
	p.i = j;
	return t;
}

attrrefs(v: string): string
{
	for(i := 0; i < len v; i++)
		if(v[i] == '&')
			break;
	if(i == len v)
		return v;
	r := v[0:i];
	st := i;
	while(i < len v)
		if(v[i] == '&') {
			r += v[st:i];
			x: string;
			(x, i) = charref(v, i, 1);
			r += x;
			st = i;
		} else
			i++;
	return r + v[st:];
}

# ---- small things ----

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r';
}

isalpha(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

isalnum(c: int): int
{
	return isalpha(c) || (c >= '0' && c <= '9');
}

digitval(c, hex: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(hex && c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(hex && c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

hexval(s: string): int
{
	v := 0;
	for(i := 0; i < len s; i++)
		v = v*16 + digitval(s[i], 1);
	return v;
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			break;
	if(i == len s)
		return s;
	r := s;
	for(; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
}

trim(s: string): string
{
	i := 0;
	while(i < len s && isspace(s[i]))
		i++;
	e := len s;
	while(e > i && isspace(s[e-1]))
		e--;
	return s[i:e];
}

index(s, t: string, from: int): int
{
	n := len t;
	for(i := from; i+n <= len s; i++)
		if(s[i] == t[0] && s[i:i+n] == t)
			return i;
	return -1;
}

strhash(s: string, m: int): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h*31 + s[i];
	return (h & 16r7FFFFFFF) % m;
}

# ---- element categories (§13.2.4.2, §13.2.6) ----

special, formatting, implied, thorough, scopebase, headings: array of byte;

mkset(l: list of int): array of byte
{
	a := array[Ntags] of {* => byte 0};
	for(; l != nil; l = tl l)
		a[hd l] = byte 1;
	return a;
}

mksets()
{
	special = mkset(list of {Taddress, Tapplet, Tarea, Tarticle, Taside, Tbase,
		Tbasefont, Tbgsound, Tblockquote, Tbody, Tbr, Tbutton, Tcaption, Tcenter,
		Tcol, Tcolgroup, Tdd, Tdetails, Tdir, Tdiv, Tdl, Tdt, Tembed, Tfieldset,
		Tfigcaption, Tfigure, Tfooter, Tform, Tframe, Tframeset, Th1, Th2, Th3,
		Th4, Th5, Th6, Thead, Theader, Thgroup, Thr, Thtml, Tiframe, Timg, Tinput,
		Tkeygen, Tli, Tlink, Tlisting, Tmain, Tmarquee, Tmenu, Tmeta, Tnav,
		Tnoembed, Tnoframes, Tnoscript, Tobject, Tol, Tp, Tparam, Tplaintext,
		Tpre, Tscript, Tsearch, Tsection, Tselect, Tsource, Tstyle, Tsummary,
		Ttable, Ttbody, Ttd, Ttemplate, Ttextarea, Ttfoot, Tth, Tthead, Ttitle,
		Ttr, Ttrack, Tul, Twbr, Txmp});
	formatting = mkset(list of {Ta, Tb, Tbig, Tcode, Tem, Tfont, Ti, Tnobr, Ts,
		Tsmall, Tstrike, Tstrong, Ttt, Tu});
	implied = mkset(list of {Tdd, Tdt, Tli, Toptgroup, Toption, Tp, Trb, Trp, Trt, Trtc});
	thorough = mkset(list of {Tdd, Tdt, Tli, Toptgroup, Toption, Tp, Trb, Trp, Trt,
		Trtc, Tcaption, Tcolgroup, Ttbody, Ttd, Ttfoot, Tth, Tthead, Ttr});
	scopebase = mkset(list of {Tapplet, Tcaption, Thtml, Ttable, Ttd, Tth, Tmarquee,
		Tobject, Ttemplate});
	headings = mkset(list of {Th1, Th2, Th3, Th4, Th5, Th6});
}

# the tag of n if it is an HTML element, else Tnone
htag(p: ref P, n: int): int
{
	nd := p.d.nodes[n];
	if(nd.ns != HTML)
		return Tnone;
	return nd.tag;
}

isspecial(p: ref P, n: int): int
{
	nd := p.d.nodes[n];
	case nd.ns {
	HTML =>
		return int special[nd.tag];
	MathML =>
		return mathtextip(nd) || nd.name == "annotation-xml";
	SVG =>
		return nd.name == "foreignObject" || nd.name == "desc" || nd.name == "title";
	}
	return 0;
}

mathtextip(nd: ref Node): int
{
	if(nd.ns != MathML)
		return 0;
	case nd.name {
	"mi" or "mo" or "mn" or "ms" or "mtext" =>
		return 1;
	}
	return 0;
}

htmlip(p: ref P, n: int): int
{
	nd := p.d.nodes[n];
	if(nd.ns == SVG)
		return nd.name == "foreignObject" || nd.name == "desc" || nd.name == "title";
	if(nd.ns == MathML && nd.name == "annotation-xml") {
		e := lower(p.d.attr(n, "encoding"));
		return e == "text/html" || e == "application/xhtml+xml";
	}
	return 0;
}

# ---- the stack of open elements ----

Sdefault, Slist, Sbutton, Stable, Sselect: con iota;

cur(p: ref P): int
{
	if(p.sp == 0)
		return 0;
	return p.stack[p.sp-1];
}

curtag(p: ref P): int
{
	if(p.sp == 0)
		return Tnone;
	return htag(p, p.stack[p.sp-1]);
}

push(p: ref P, n: int)
{
	if(p.sp >= len p.stack) {
		a := array[2*len p.stack] of int;
		a[0:] = p.stack;
		p.stack = a;
	}
	p.stack[p.sp++] = n;
}

pop(p: ref P)
{
	if(p.sp > 0)
		p.sp--;
}

onstack(p: ref P, n: int): int
{
	for(i := p.sp-1; i >= 0; i--)
		if(p.stack[i] == n)
			return i;
	return -1;
}

removeat(p: ref P, i: int)
{
	p.stack[i:] = p.stack[i+1:p.sp];
	p.sp--;
}

insertat(p: ref P, i, n: int)
{
	push(p, 0);
	p.stack[i+1:] = p.stack[i:p.sp-1];
	p.stack[i] = n;
}

stackhas(p: ref P, tag: int): int
{
	for(i := 0; i < p.sp; i++)
		if(htag(p, p.stack[i]) == tag)
			return 1;
	return 0;
}

boundary(p: ref P, n, kind: int): int
{
	nd := p.d.nodes[n];
	t := htag(p, n);
	case kind {
	Stable =>
		return t == Thtml || t == Ttable || t == Ttemplate;
	Sselect =>
		return t != Toptgroup && t != Toption;
	}
	if(nd.ns == HTML) {
		if(int scopebase[t])
			return 1;
		if(kind == Slist && (t == Tol || t == Tul))
			return 1;
		if(kind == Sbutton && t == Tbutton)
			return 1;
		return 0;
	}
	return mathtextip(nd) || (nd.ns == MathML && nd.name == "annotation-xml") ||
		(nd.ns == SVG && (nd.name == "foreignObject" || nd.name == "desc" || nd.name == "title"));
}

inscope(p: ref P, tag, kind: int): int
{
	for(i := p.sp-1; i >= 0; i--) {
		n := p.stack[i];
		if(htag(p, n) == tag)
			return 1;
		if(boundary(p, n, kind))
			return 0;
	}
	return 0;
}

nodeinscope(p: ref P, target, kind: int): int
{
	for(i := p.sp-1; i >= 0; i--) {
		n := p.stack[i];
		if(n == target)
			return 1;
		if(boundary(p, n, kind))
			return 0;
	}
	return 0;
}

headinginscope(p: ref P): int
{
	for(i := p.sp-1; i >= 0; i--) {
		n := p.stack[i];
		if(int headings[htag(p, n)])
			return 1;
		if(boundary(p, n, Sdefault))
			return 0;
	}
	return 0;
}

# pop until an HTML element with tag has been popped
popto(p: ref P, tag: int)
{
	while(p.sp > 0) {
		t := curtag(p);
		pop(p);
		if(t == tag)
			return;
	}
}

genimplied(p: ref P, except: int)
{
	while(p.sp > 0 && (t := curtag(p)) != except && int implied[t])
		pop(p);
}

genthorough(p: ref P)
{
	while(p.sp > 0 && int thorough[curtag(p)])
		pop(p);
}

closep(p: ref P)
{
	genimplied(p, Tp);
	popto(p, Tp);
}

closepinbutton(p: ref P)
{
	if(inscope(p, Tp, Sbutton))
		closep(p);
}

# pop until the current node is one of tags (or html)
clearto(p: ref P, tags: list of int)
{
	while(p.sp > 1) {
		t := curtag(p);
		for(l := tags; l != nil; l = tl l)
			if(hd l == t)
				return;
		if(t == Thtml)
			return;
		pop(p);
	}
}

# ---- inserting nodes (§13.2.6.1) ----

insloc(p: ref P, target: int): (int, int)
{
	if(p.foster) {
		case htag(p, target) {
		Ttable or Ttbody or Ttfoot or Tthead or Ttr =>
			lt := -1;
			ltab := -1;
			for(i := p.sp-1; i >= 0; i--) {
				t := htag(p, p.stack[i]);
				if(t == Ttemplate && lt < 0)
					lt = i;
				if(t == Ttable && ltab < 0)
					ltab = i;
			}
			if(lt >= 0 && (ltab < 0 || lt > ltab))
				return (p.stack[lt], 0);
			if(ltab < 0)
				return (p.stack[0], 0);
			tab := p.stack[ltab];
			if(p.d.nodes[tab].parent != 0)
				return (p.d.nodes[tab].parent, tab);
			return (p.stack[ltab-1], 0);
		}
	}
	return (target, 0);
}

newelem(p: ref P, t: ref Tok, ns: int): int
{
	n := p.d.create(Element, t.name, ns);
	p.d.nodes[n].attrs = t.attrs;
	return n;
}

insert(p: ref P, n: int)
{
	(par, bef) := insloc(p, cur(p));
	p.d.insert(par, n, bef);
}

insertelem(p: ref P, t: ref Tok): int
{
	n := newelem(p, t, HTML);
	insert(p, n);
	push(p, n);
	return n;
}

synth(name: string): ref Tok
{
	return ref Tok(Kstart, name, dom->atom(name), nil, 0, nil, nil, 0, 0, 0);
}

insertchars(p: ref P, s: string)
{
	if(s == "")
		return;
	(par, bef) := insloc(p, cur(p));
	if(p.d.nodes[par].kind == Document)
		return;
	prev: int;
	if(bef != 0)
		prev = p.d.nodes[bef].prev;
	else
		prev = p.d.nodes[par].last;
	if(prev != 0 && p.d.nodes[prev].kind == Text) {
		p.d.nodes[prev].text += s;
		p.d.gen++;
		return;
	}
	n := p.d.create(Text, nil, HTML);
	p.d.nodes[n].text = s;
	p.d.insert(par, n, bef);
}

insertcomment(p: ref P, s: string, par: int)
{
	n := p.d.create(Comment, nil, HTML);
	p.d.nodes[n].text = s;
	if(par != 0)
		p.d.append(par, n);
	else
		insert(p, n);
}

# ---- active formatting elements (§13.2.4.3) ----

pushafe(p: ref P, n: int, t: ref Tok)
{
	nd := p.d.nodes[n];
	same := 0;
	first := -1;
	for(i := p.nafe-1; i >= 0 && p.afe[i].node != 0; i--) {
		e := p.d.nodes[p.afe[i].node];
		if(e.name == nd.name && e.ns == nd.ns && sameattrs(e.attrs, nd.attrs)) {
			same++;
			first = i;
		}
	}
	if(same >= 3)
		removeafe(p, first);
	insertafe(p, p.nafe, n, t);
}

sameattrs(a, b: list of (string, string)): int
{
	if(len a != len b)
		return 0;
	for(; a != nil; a = tl a) {
		found := 0;
		for(l := b; l != nil; l = tl l)
			if((hd l).t0 == (hd a).t0 && (hd l).t1 == (hd a).t1)
				found = 1;
		if(!found)
			return 0;
	}
	return 1;
}

insertafe(p: ref P, i, n: int, t: ref Tok)
{
	if(p.nafe >= len p.afe) {
		a := array[2*len p.afe] of ref Afe;
		a[0:] = p.afe;
		p.afe = a;
	}
	p.afe[i+1:] = p.afe[i:p.nafe];
	p.afe[i] = ref Afe(n, t);
	p.nafe++;
}

removeafe(p: ref P, i: int)
{
	p.afe[i:] = p.afe[i+1:p.nafe];
	p.nafe--;
}

marker(p: ref P)
{
	insertafe(p, p.nafe, 0, nil);
}

afeindex(p: ref P, n: int): int
{
	for(i := p.nafe-1; i >= 0; i--)
		if(p.afe[i].node == n)
			return i;
	return -1;
}

clearafe(p: ref P)
{
	while(p.nafe > 0) {
		n := p.afe[--p.nafe].node;
		if(n == 0)
			break;
	}
}

reconstruct(p: ref P)
{
	if(p.nafe == 0)
		return;
	e := p.afe[p.nafe-1];
	if(e.node == 0 || onstack(p, e.node) >= 0)
		return;
	i := p.nafe-1;
	while(i > 0) {
		i--;
		if(p.afe[i].node == 0 || onstack(p, p.afe[i].node) >= 0) {
			i++;
			break;
		}
	}
	for(; i < p.nafe; i++) {
		t := p.afe[i].tok;
		n := insertelem(p, t);
		p.afe[i] = ref Afe(n, t);
	}
}

# The adoption agency algorithm (§13.2.6.4.7).  Returns 0 if the
# token should instead be handled as "any other end tag".
adoption(p: ref P, t: ref Tok): int
{
	c := cur(p);
	if(htag(p, c) == t.tag && afeindex(p, c) < 0) {
		pop(p);
		return 1;
	}
	for(outer := 0; outer < 8; outer++) {
		fi := -1;
		for(k := p.nafe-1; k >= 0 && p.afe[k].node != 0; k--)
			if(htag(p, p.afe[k].node) == t.tag) {
				fi = k;
				break;
			}
		if(fi < 0)
			return 0;
		fe := p.afe[fi].node;
		si := onstack(p, fe);
		if(si < 0) {
			removeafe(p, fi);
			return 1;
		}
		if(!nodeinscope(p, fe, Sdefault))
			return 1;
		fb := -1;
		for(k = si+1; k < p.sp; k++)
			if(isspecial(p, p.stack[k])) {
				fb = k;
				break;
			}
		if(fb < 0) {
			p.sp = si;
			removeafe(p, fi);
			return 1;
		}
		ca := p.stack[si-1];
		furthest := p.stack[fb];
		bm := fi;
		last := furthest;
		ni := fb;
		for(inner := 1; ; inner++) {
			ni--;
			n := p.stack[ni];
			if(n == fe)
				break;
			ai := afeindex(p, n);
			if(inner > 3 && ai >= 0) {
				removeafe(p, ai);
				if(ai < bm)
					bm--;
				ai = -1;
			}
			if(ai < 0) {
				removeat(p, ni);
				continue;
			}
			ne := newelem(p, p.afe[ai].tok, HTML);
			p.afe[ai] = ref Afe(ne, p.afe[ai].tok);
			p.stack[ni] = ne;
			if(last == furthest)
				bm = ai+1;
			p.d.append(ne, last);
			last = ne;
		}
		(par, bef) := insloc(p, ca);
		p.d.insert(par, last, bef);
		fi = afeindex(p, fe);
		ftok := p.afe[fi].tok;
		ne := newelem(p, ftok, HTML);
		while((k = p.d.nodes[furthest].first) != 0)
			p.d.append(ne, k);
		p.d.append(furthest, ne);
		insertafe(p, bm, ne, ftok);
		removeafe(p, afeindex(p, fe));
		removeat(p, onstack(p, fe));
		insertat(p, onstack(p, furthest)+1, ne);
	}
	return 1;
}

anyotherend(p: ref P, t: ref Tok)
{
	for(k := p.sp-1; k >= 0; k--) {
		n := p.stack[k];
		nd := p.d.nodes[n];
		if(nd.ns == HTML && nd.name == t.name) {
			genimplied(p, t.tag);
			p.sp = k;
			return;
		}
		if(isspecial(p, n))
			return;
	}
}

# ---- insertion mode reset (§13.2.4.1) ----

resetmode(p: ref P)
{
	for(k := p.sp-1; k >= 0; k--) {
		last := k == 0;
		case htag(p, p.stack[k]) {
		Tselect =>
			for(a := k-1; a > 0; a--) {
				at := htag(p, p.stack[a]);
				if(at == Ttemplate)
					break;
				if(at == Ttable) {
					p.mode = Minselectintable;
					return;
				}
			}
			p.mode = Minselect;
			return;
		Ttd or Tth =>
			if(!last) {
				p.mode = Mincell;
				return;
			}
		Ttr =>
			p.mode = Minrow;
			return;
		Ttbody or Tthead or Ttfoot =>
			p.mode = Mintablebody;
			return;
		Tcaption =>
			p.mode = Mincaption;
			return;
		Tcolgroup =>
			p.mode = Mincolgroup;
			return;
		Ttable =>
			p.mode = Mintable;
			return;
		Ttemplate =>
			p.mode = hd p.tmodes;
			return;
		Thead =>
			if(!last) {
				p.mode = Minhead;
				return;
			}
		Tbody =>
			p.mode = Minbody;
			return;
		Tframeset =>
			p.mode = Minframeset;
			return;
		Thtml =>
			if(p.head == 0)
				p.mode = Mbeforehead;
			else
				p.mode = Mafterhead;
			return;
		}
		if(last)
			break;
	}
	p.mode = Minbody;
}

# ---- driving ----

run(p: ref P)
{
	while(!p.stopped) {
		t := lex(p);
		if(p.skiplf) {
			p.skiplf = 0;
			if(t.kind == Kchars && len t.data > 0 && t.data[0] == '\n') {
				t.data = t.data[1:];
				if(t.data == "")
					continue;
			}
		}
		dispatch(p, t);
		if(t.kind == Keof)
			break;
	}
}

dispatch(p: ref P, t: ref Tok)
{
	if(useforeign(p, t))
		foreign(p, t);
	else
		rules(p, t, p.mode);
}

useforeign(p: ref P, t: ref Tok): int
{
	if(p.sp == 0 || t.kind == Keof)
		return 0;
	n := cur(p);
	nd := p.d.nodes[n];
	if(nd.ns == HTML)
		return 0;
	if(mathtextip(nd) && ((t.kind == Kstart && t.name != "mglyph" && t.name != "malignmark") || t.kind == Kchars))
		return 0;
	if(nd.ns == MathML && nd.name == "annotation-xml" && t.kind == Kstart && t.name == "svg")
		return 0;
	if(htmlip(p, n) && (t.kind == Kstart || t.kind == Kchars))
		return 0;
	return 1;
}

# split leading whitespace from the rest of a character token
wssplit(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(!isspace(s[i]))
			break;
	return (s[0:i], s[i:]);
}

allws(s: string): int
{
	for(i := 0; i < len s; i++)
		if(!isspace(s[i]))
			return 0;
	return 1;
}

onlyws(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(isspace(s[i]))
			r[len r] = s[i];
	return r;
}

dropnul(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == 0)
			break;
	if(i == len s)
		return s;
	r := s[0:i];
	for(; i < len s; i++)
		if(s[i] != 0)
			r[len r] = s[i];
	return r;
}

isstart(t: ref Tok, tags: list of int): int
{
	if(t.kind != Kstart)
		return 0;
	for(; tags != nil; tags = tl tags)
		if(hd tags == t.tag)
			return 1;
	return 0;
}

isend(t: ref Tok, tags: list of int): int
{
	if(t.kind != Kend)
		return 0;
	for(; tags != nil; tags = tl tags)
		if(hd tags == t.tag)
			return 1;
	return 0;
}

rawtext(p: ref P, t: ref Tok, state: int)
{
	insertelem(p, t);
	p.state = state;
	p.endname = t.name;
	p.origmode = p.mode;
	p.mode = Mtext;
}

rules(p: ref P, t: ref Tok, mode: int)
{
	case mode {
	Minitial => initial(p, t);
	Mbeforehtml => beforehtml(p, t);
	Mbeforehead => beforehead(p, t);
	Minhead => inhead(p, t);
	Minheadnoscript => inheadnoscript(p, t);
	Mafterhead => afterhead(p, t);
	Minbody => inbody(p, t);
	Mtext => text(p, t);
	Mintable => intable(p, t);
	Mintabletext => intabletext(p, t);
	Mincaption => incaption(p, t);
	Mincolgroup => incolgroup(p, t);
	Mintablebody => intablebody(p, t);
	Minrow => inrow(p, t);
	Mincell => incell(p, t);
	Minselect => inselect(p, t);
	Minselectintable => inselectintable(p, t);
	Mintemplate => intemplate(p, t);
	Mafterbody => afterbody(p, t);
	Minframeset => inframeset(p, t);
	Mafterframeset => afterframeset(p, t);
	Mafterafterbody => afterafterbody(p, t);
	Mafterafterframeset => afterafterframeset(p, t);
	}
}

reprocess(p: ref P, t: ref Tok, mode: int)
{
	p.mode = mode;
	dispatch(p, t);
}

# §13.2.6.4.1
initial(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		(nil, rest) := wssplit(t.data);
		if(rest == "")
			return;
		t = chartok(rest);
	Kcomment =>
		insertcomment(p, t.data, 1);
		return;
	Kdoctype =>
		n := p.d.create(Doctype, t.name, HTML);
		p.d.nodes[n].text = t.data;
		p.d.append(1, n);
		p.d.quirks = quirky(t);
		p.mode = Mbeforehtml;
		return;
	}
	p.d.quirks = 1;
	reprocess(p, t, Mbeforehtml);
}

quirky(t: ref Tok): int
{
	if(t.quirks || t.name != "html")
		return 1;
	pub := lower(t.data);
	if(pub == "-//w3o//dtd w3 html strict 3.0//en//" || pub == "-/w3c/dtd html 4.0 transitional/en" || pub == "html")
		return 1;
	if(lower(t.sysid) == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd")
		return 1;
	for(i := 0; i < len quirkpfx; i++)
		if(prefix(pub, quirkpfx[i]))
			return 1;
	if(!t.hassys && (prefix(pub, "-//w3c//dtd html 4.01 frameset//") || prefix(pub, "-//w3c//dtd html 4.01 transitional//")))
		return 1;
	return 0;
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

# the commonest of the standard's quirky public identifiers
# public identifier prefixes that put the document in quirks mode
# (§13.2.6.4.1), where several of the standard's start the same way
quirkpfx := array[] of {
	"+//silmaril//dtd html pro v0r11 19970101//",
	"-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
	"-//as//dtd html 3.0 aswedit + extensions//",
	"-//ietf//dtd html 2.0",
	"-//ietf//dtd html 2.1e//",
	"-//ietf//dtd html 3",
	"-//ietf//dtd html//",
	"-//ietf//dtd html level",
	"-//ietf//dtd html strict",
	"-//metrius//dtd metrius presentational//",
	"-//microsoft//dtd internet explorer",
	"-//netscape comm. corp.//dtd",
	"-//o'reilly and associates//dtd html",
	"-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
	"-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
	"-//spyglass//dtd html 2.0 extended//",
	"-//sq//dtd html 2.0 hotmetal + extensions//",
	"-//sun microsystems corp.//dtd hotjava",
	"-//w3c//dtd html 3",
	"-//w3c//dtd html 4.0 frameset//",
	"-//w3c//dtd html 4.0 transitional//",
	"-//w3c//dtd html experimental",
	"-//w3c//dtd w3 html//",
	"-//w3o//dtd w3 html 3.0//",
	"-//webtechs//dtd mozilla html",
};

# §13.2.6.4.2
beforehtml(p: ref P, t: ref Tok)
{
	case t.kind {
	Kdoctype =>
		return;
	Kcomment =>
		insertcomment(p, t.data, 1);
		return;
	Kchars =>
		(nil, rest) := wssplit(t.data);
		if(rest == "")
			return;
		t = chartok(rest);
	Kstart =>
		if(t.tag == Thtml) {
			n := newelem(p, t, HTML);
			p.d.append(1, n);
			push(p, n);
			p.mode = Mbeforehead;
			return;
		}
	Kend =>
		if(!isend(t, list of {Thead, Tbody, Thtml, Tbr}))
			return;
	}
	n := newelem(p, synth("html"), HTML);
	p.d.append(1, n);
	push(p, n);
	reprocess(p, t, Mbeforehead);
}

# §13.2.6.4.3
beforehead(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		(nil, rest) := wssplit(t.data);
		if(rest == "")
			return;
		t = chartok(rest);
	Kcomment =>
		insertcomment(p, t.data, 0);
		return;
	Kdoctype =>
		return;
	Kstart =>
		if(t.tag == Thtml) {
			inbody(p, t);
			return;
		}
		if(t.tag == Thead) {
			p.head = insertelem(p, t);
			p.mode = Minhead;
			return;
		}
	Kend =>
		if(!isend(t, list of {Thead, Tbody, Thtml, Tbr}))
			return;
	}
	p.head = insertelem(p, synth("head"));
	reprocess(p, t, Minhead);
}

# §13.2.6.4.4
inhead(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		(ws, rest) := wssplit(t.data);
		insertchars(p, ws);
		if(rest == "")
			return;
		t = chartok(rest);
	Kcomment =>
		insertcomment(p, t.data, 0);
		return;
	Kdoctype =>
		return;
	Kstart =>
		case t.tag {
		Thtml =>
			inbody(p, t);
			return;
		Tbase or Tbasefont or Tbgsound or Tlink or Tmeta =>
			insertelem(p, t);
			pop(p);
			return;
		Ttitle =>
			rawtext(p, t, Srcdata);
			return;
		Tnoscript =>
			# scripting is disabled: noscript content is markup
			insertelem(p, t);
			p.mode = Minheadnoscript;
			return;
		Tnoframes or Tstyle =>
			rawtext(p, t, Srawtext);
			return;
		Tscript =>
			rawtext(p, t, Sscript);
			return;
		Ttemplate =>
			insertelem(p, t);
			marker(p);
			p.framesetok = 0;
			p.mode = Mintemplate;
			p.tmodes = Mintemplate :: p.tmodes;
			return;
		Thead =>
			return;
		}
	Kend =>
		case t.tag {
		Thead =>
			pop(p);
			p.mode = Mafterhead;
			return;
		Tbody or Thtml or Tbr =>
			;
		Ttemplate =>
			if(!stackhas(p, Ttemplate))
				return;
			genthorough(p);
			popto(p, Ttemplate);
			clearafe(p);
			p.tmodes = tl p.tmodes;
			resetmode(p);
			return;
		* =>
			return;
		}
	}
	pop(p);
	reprocess(p, t, Mafterhead);
}

# §13.2.6.4.5
inheadnoscript(p: ref P, t: ref Tok)
{
	case t.kind {
	Kdoctype =>
		return;
	Kchars =>
		(ws, rest) := wssplit(t.data);
		insertchars(p, ws);
		if(rest == "")
			return;
		t = chartok(rest);
	Kcomment =>
		inhead(p, t);
		return;
	Kstart =>
		case t.tag {
		Thtml =>
			inbody(p, t);
			return;
		Tbasefont or Tbgsound or Tlink or Tmeta or Tnoframes or Tstyle =>
			inhead(p, t);
			return;
		Thead or Tnoscript =>
			return;
		}
	Kend =>
		if(t.tag == Tnoscript) {
			pop(p);
			p.mode = Minhead;
			return;
		}
		if(t.tag != Tbr)
			return;
	}
	pop(p);
	reprocess(p, t, Minhead);
}

# §13.2.6.4.6
afterhead(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		(ws, rest) := wssplit(t.data);
		insertchars(p, ws);
		if(rest == "")
			return;
		t = chartok(rest);
	Kcomment =>
		insertcomment(p, t.data, 0);
		return;
	Kdoctype =>
		return;
	Kstart =>
		case t.tag {
		Thtml =>
			inbody(p, t);
			return;
		Tbody =>
			insertelem(p, t);
			p.framesetok = 0;
			p.mode = Minbody;
			return;
		Tframeset =>
			insertelem(p, t);
			p.mode = Minframeset;
			return;
		Tbase or Tbasefont or Tbgsound or Tlink or Tmeta or Tnoframes or Tscript or
		Tstyle or Ttemplate or Ttitle =>
			push(p, p.head);
			inhead(p, t);
			i := onstack(p, p.head);
			if(i >= 0)
				removeat(p, i);
			return;
		Thead =>
			return;
		}
	Kend =>
		case t.tag {
		Ttemplate =>
			inhead(p, t);
			return;
		Tbody or Thtml or Tbr =>
			;
		* =>
			return;
		}
	}
	insertelem(p, synth("body"));
	reprocess(p, t, Minbody);
}

# §13.2.6.4.7
inbody(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		s := dropnul(t.data);
		if(s == "")
			return;
		reconstruct(p);
		insertchars(p, s);
		if(!allws(s))
			p.framesetok = 0;
	Kcomment =>
		insertcomment(p, t.data, 0);
	Kdoctype =>
		;
	Keof =>
		if(p.tmodes != nil)
			intemplate(p, t);
		else
			p.stopped = 1;
	Kstart =>
		bodystart(p, t);
	Kend =>
		bodyend(p, t);
	}
}

bodystart(p: ref P, t: ref Tok)
{
	case t.tag {
	Thtml =>
		if(stackhas(p, Ttemplate))
			return;
		addattrs(p, p.stack[0], t);
	Tbase or Tbasefont or Tbgsound or Tlink or Tmeta or Tnoframes or Tscript or
	Tstyle or Ttemplate or Ttitle =>
		inhead(p, t);
	Tbody =>
		if(p.sp < 2 || htag(p, p.stack[1]) != Tbody || stackhas(p, Ttemplate))
			return;
		p.framesetok = 0;
		addattrs(p, p.stack[1], t);
	Tframeset =>
		if(p.sp < 2 || htag(p, p.stack[1]) != Tbody || !p.framesetok)
			return;
		p.d.remove(p.stack[1]);
		p.sp = 1;
		insertelem(p, t);
		p.mode = Minframeset;
	Taddress or Tarticle or Taside or Tblockquote or Tcenter or Tdetails or Tdialog or
	Tdir or Tdiv or Tdl or Tfieldset or Tfigcaption or Tfigure or Tfooter or
	Theader or Thgroup or Tmain or Tmenu or Tnav or Tol or Tp or Tsearch or
	Tsection or Tsummary or Tul =>
		closepinbutton(p);
		insertelem(p, t);
	Th1 or Th2 or Th3 or Th4 or Th5 or Th6 =>
		closepinbutton(p);
		if(int headings[curtag(p)])
			pop(p);
		insertelem(p, t);
	Tpre or Tlisting =>
		closepinbutton(p);
		insertelem(p, t);
		p.skiplf = 1;
		p.framesetok = 0;
	Tform =>
		tmpl := stackhas(p, Ttemplate);
		if(p.form != 0 && !tmpl)
			return;
		closepinbutton(p);
		n := insertelem(p, t);
		if(!tmpl)
			p.form = n;
	Tli =>
		p.framesetok = 0;
		for(k := p.sp-1; k >= 0; k--) {
			n := p.stack[k];
			nt := htag(p, n);
			if(nt == Tli) {
				genimplied(p, Tli);
				popto(p, Tli);
				break;
			}
			if(isspecial(p, n) && nt != Taddress && nt != Tdiv && nt != Tp)
				break;
		}
		closepinbutton(p);
		insertelem(p, t);
	Tdd or Tdt =>
		p.framesetok = 0;
		for(k := p.sp-1; k >= 0; k--) {
			n := p.stack[k];
			nt := htag(p, n);
			if(nt == Tdd || nt == Tdt) {
				genimplied(p, nt);
				popto(p, nt);
				break;
			}
			if(isspecial(p, n) && nt != Taddress && nt != Tdiv && nt != Tp)
				break;
		}
		closepinbutton(p);
		insertelem(p, t);
	Tplaintext =>
		closepinbutton(p);
		insertelem(p, t);
		p.state = Splaintext;
	Tbutton =>
		if(inscope(p, Tbutton, Sdefault)) {
			genimplied(p, Tnone);
			popto(p, Tbutton);
		}
		reconstruct(p);
		insertelem(p, t);
		p.framesetok = 0;
	Ta =>
		for(k := p.nafe-1; k >= 0 && p.afe[k].node != 0; k--)
			if(htag(p, p.afe[k].node) == Ta) {
				n := p.afe[k].node;
				adoption(p, ref Tok(Kend, "a", Ta, nil, 0, nil, nil, 0, 0, 0));
				if((i := afeindex(p, n)) >= 0)
					removeafe(p, i);
				if((i = onstack(p, n)) >= 0)
					removeat(p, i);
				break;
			}
		reconstruct(p);
		pushafe(p, insertelem(p, t), t);
	Tb or Tbig or Tcode or Tem or Tfont or Ti or Ts or Tsmall or Tstrike or
	Tstrong or Ttt or Tu =>
		reconstruct(p);
		pushafe(p, insertelem(p, t), t);
	Tnobr =>
		reconstruct(p);
		if(inscope(p, Tnobr, Sdefault)) {
			adoption(p, ref Tok(Kend, "nobr", Tnobr, nil, 0, nil, nil, 0, 0, 0));
			reconstruct(p);
		}
		pushafe(p, insertelem(p, t), t);
	Tapplet or Tmarquee or Tobject =>
		reconstruct(p);
		insertelem(p, t);
		marker(p);
		p.framesetok = 0;
	Ttable =>
		if(!p.d.quirks)
			closepinbutton(p);
		insertelem(p, t);
		p.framesetok = 0;
		p.mode = Mintable;
	Tarea or Tbr or Tembed or Timg or Tkeygen or Twbr =>
		reconstruct(p);
		insertelem(p, t);
		pop(p);
		p.framesetok = 0;
	Tinput =>
		reconstruct(p);
		n := insertelem(p, t);
		pop(p);
		if(lower(p.d.attr(n, "type")) != "hidden")
			p.framesetok = 0;
	Tparam or Tsource or Ttrack =>
		insertelem(p, t);
		pop(p);
	Thr =>
		closepinbutton(p);
		insertelem(p, t);
		pop(p);
		p.framesetok = 0;
	Timage =>
		t.name = "img";
		t.tag = Timg;
		dispatch(p, t);
	Ttextarea =>
		insertelem(p, t);
		p.skiplf = 1;
		p.state = Srcdata;
		p.endname = t.name;
		p.origmode = p.mode;
		p.framesetok = 0;
		p.mode = Mtext;
	Txmp =>
		closepinbutton(p);
		reconstruct(p);
		p.framesetok = 0;
		rawtext(p, t, Srawtext);
	Tiframe =>
		p.framesetok = 0;
		rawtext(p, t, Srawtext);
	Tnoembed =>
		rawtext(p, t, Srawtext);
	Tselect =>
		reconstruct(p);
		insertelem(p, t);
		p.framesetok = 0;
		case p.mode {
		Mintable or Mincaption or Mintablebody or Minrow or Mincell =>
			p.mode = Minselectintable;
		* =>
			p.mode = Minselect;
		}
	Toptgroup or Toption =>
		if(curtag(p) == Toption)
			pop(p);
		reconstruct(p);
		insertelem(p, t);
	Trb or Trtc =>
		if(inscope(p, Truby, Sdefault))
			genimplied(p, Tnone);
		insertelem(p, t);
	Trp or Trt =>
		if(inscope(p, Truby, Sdefault))
			genimplied(p, Trtc);
		insertelem(p, t);
	Tcaption or Tcol or Tcolgroup or Tframe or Thead or Ttbody or Ttd or Ttfoot or
	Tth or Tthead or Ttr =>
		;
	* =>
		if(t.name == "math" || t.name == "svg") {
			reconstruct(p);
			ns := MathML;
			if(t.name == "svg")
				ns = SVG;
			insertforeign(p, t, ns);
			return;
		}
		reconstruct(p);
		insertelem(p, t);
	}
}

addattrs(p: ref P, n: int, t: ref Tok)
{
	for(l := t.attrs; l != nil; l = tl l)
		if(!p.d.hasattr(n, (hd l).t0))
			p.d.setattr(n, (hd l).t0, (hd l).t1);
}

bodyend(p: ref P, t: ref Tok)
{
	case t.tag {
	Ttemplate =>
		inhead(p, t);
	Tbody =>
		if(inscope(p, Tbody, Sdefault))
			p.mode = Mafterbody;
	Thtml =>
		if(inscope(p, Tbody, Sdefault))
			reprocess(p, t, Mafterbody);
	Taddress or Tarticle or Taside or Tblockquote or Tbutton or Tcenter or
	Tdetails or Tdialog or Tdir or Tdiv or Tdl or Tfieldset or Tfigcaption or
	Tfigure or Tfooter or Theader or Thgroup or Tlisting or Tmain or Tmenu or
	Tnav or Tol or Tpre or Tsearch or Tsection or Tsummary or Tul =>
		if(!inscope(p, t.tag, Sdefault))
			return;
		genimplied(p, Tnone);
		popto(p, t.tag);
	Tform =>
		if(!stackhas(p, Ttemplate)) {
			n := p.form;
			p.form = 0;
			if(n == 0 || !nodeinscope(p, n, Sdefault))
				return;
			genimplied(p, Tnone);
			removeat(p, onstack(p, n));
		} else {
			if(!inscope(p, Tform, Sdefault))
				return;
			genimplied(p, Tnone);
			popto(p, Tform);
		}
	Tp =>
		if(!inscope(p, Tp, Sbutton))
			insertelem(p, synth("p"));
		closep(p);
	Tli =>
		if(!inscope(p, Tli, Slist))
			return;
		genimplied(p, Tli);
		popto(p, Tli);
	Tdd or Tdt =>
		if(!inscope(p, t.tag, Sdefault))
			return;
		genimplied(p, t.tag);
		popto(p, t.tag);
	Th1 or Th2 or Th3 or Th4 or Th5 or Th6 =>
		if(!headinginscope(p))
			return;
		genimplied(p, Tnone);
		while(p.sp > 0) {
			h := curtag(p);
			pop(p);
			if(int headings[h])
				break;
		}
	Ta or Tb or Tbig or Tcode or Tem or Tfont or Ti or Tnobr or Ts or Tsmall or
	Tstrike or Tstrong or Ttt or Tu =>
		if(!adoption(p, t))
			anyotherend(p, t);
	Tapplet or Tmarquee or Tobject =>
		if(!inscope(p, t.tag, Sdefault))
			return;
		genimplied(p, Tnone);
		popto(p, t.tag);
		clearafe(p);
	Tbr =>
		bodystart(p, synth("br"));
	* =>
		anyotherend(p, t);
	}
}

# §13.2.6.4.8
text(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		insertchars(p, t.data);
	Keof =>
		pop(p);
		p.state = Sdata;
		reprocess(p, t, p.origmode);
	Kend =>
		pop(p);
		p.state = Sdata;
		p.mode = p.origmode;
	}
}

# §13.2.6.4.9
intable(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		case curtag(p) {
		Ttable or Ttbody or Ttemplate or Ttfoot or Tthead or Ttr =>
			p.pendchars = "";
			p.pendnonws = 0;
			p.origmode = p.mode;
			reprocess(p, t, Mintabletext);
			return;
		}
	Kcomment =>
		insertcomment(p, t.data, 0);
		return;
	Kdoctype =>
		return;
	Keof =>
		inbody(p, t);
		return;
	Kstart =>
		case t.tag {
		Tcaption =>
			clearto(p, list of {Ttable, Ttemplate});
			marker(p);
			insertelem(p, t);
			p.mode = Mincaption;
			return;
		Tcolgroup =>
			clearto(p, list of {Ttable, Ttemplate});
			insertelem(p, t);
			p.mode = Mincolgroup;
			return;
		Tcol =>
			clearto(p, list of {Ttable, Ttemplate});
			insertelem(p, synth("colgroup"));
			reprocess(p, t, Mincolgroup);
			return;
		Ttbody or Ttfoot or Tthead =>
			clearto(p, list of {Ttable, Ttemplate});
			insertelem(p, t);
			p.mode = Mintablebody;
			return;
		Ttd or Tth or Ttr =>
			clearto(p, list of {Ttable, Ttemplate});
			insertelem(p, synth("tbody"));
			reprocess(p, t, Mintablebody);
			return;
		Ttable =>
			if(!inscope(p, Ttable, Stable))
				return;
			popto(p, Ttable);
			resetmode(p);
			dispatch(p, t);
			return;
		Tstyle or Tscript or Ttemplate =>
			inhead(p, t);
			return;
		Tinput =>
			if(lower(attrof(t, "type")) == "hidden") {
				insertelem(p, t);
				pop(p);
				return;
			}
		Tform =>
			if(stackhas(p, Ttemplate) || p.form != 0)
				return;
			p.form = insertelem(p, t);
			pop(p);
			return;
		}
	Kend =>
		case t.tag {
		Ttable =>
			if(!inscope(p, Ttable, Stable))
				return;
			popto(p, Ttable);
			resetmode(p);
			return;
		Tbody or Tcaption or Tcol or Tcolgroup or Thtml or Ttbody or Ttd or Ttfoot or
		Tth or Tthead or Ttr =>
			return;
		Ttemplate =>
			inhead(p, t);
			return;
		}
	}
	p.foster = 1;
	inbody(p, t);
	p.foster = 0;
}

attrof(t: ref Tok, name: string): string
{
	for(l := t.attrs; l != nil; l = tl l)
		if((hd l).t0 == name)
			return (hd l).t1;
	return nil;
}

# §13.2.6.4.10
intabletext(p: ref P, t: ref Tok)
{
	if(t.kind == Kchars) {
		s := dropnul(t.data);
		p.pendchars += s;
		if(!allws(s))
			p.pendnonws = 1;
		return;
	}
	if(p.pendnonws) {
		p.foster = 1;
		inbody(p, chartok(p.pendchars));
		p.foster = 0;
	} else
		insertchars(p, p.pendchars);
	p.pendchars = "";
	reprocess(p, t, p.origmode);
}

# §13.2.6.4.11
incaption(p: ref P, t: ref Tok)
{
	if(isend(t, Tcaption :: nil) ||
	   isstart(t, list of {Tcaption, Tcol, Tcolgroup, Ttbody, Ttd, Ttfoot, Tth, Tthead, Ttr}) ||
	   isend(t, Ttable :: nil)) {
		if(!inscope(p, Tcaption, Stable))
			return;
		genimplied(p, Tnone);
		popto(p, Tcaption);
		clearafe(p);
		p.mode = Mintable;
		if(t.kind == Kstart || t.tag == Ttable)
			dispatch(p, t);
		return;
	}
	if(isend(t, list of {Tbody, Tcol, Tcolgroup, Thtml, Ttbody, Ttd, Ttfoot, Tth, Tthead, Ttr}))
		return;
	inbody(p, t);
}

# §13.2.6.4.12
incolgroup(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		(ws, rest) := wssplit(t.data);
		insertchars(p, ws);
		if(rest == "")
			return;
		t = chartok(rest);
	Kcomment =>
		insertcomment(p, t.data, 0);
		return;
	Kdoctype =>
		return;
	Keof =>
		inbody(p, t);
		return;
	Kstart =>
		case t.tag {
		Thtml =>
			inbody(p, t);
			return;
		Tcol =>
			insertelem(p, t);
			pop(p);
			return;
		Ttemplate =>
			inhead(p, t);
			return;
		}
	Kend =>
		case t.tag {
		Tcolgroup =>
			if(curtag(p) != Tcolgroup)
				return;
			pop(p);
			p.mode = Mintable;
			return;
		Tcol =>
			return;
		Ttemplate =>
			inhead(p, t);
			return;
		}
	}
	if(curtag(p) != Tcolgroup)
		return;
	pop(p);
	reprocess(p, t, Mintable);
}

# §13.2.6.4.13
intablebody(p: ref P, t: ref Tok)
{
	ctx := list of {Ttbody, Ttfoot, Tthead, Ttemplate};
	if(isstart(t, Ttr :: nil)) {
		clearto(p, ctx);
		insertelem(p, t);
		p.mode = Minrow;
		return;
	}
	if(isstart(t, list of {Tth, Ttd})) {
		clearto(p, ctx);
		insertelem(p, synth("tr"));
		reprocess(p, t, Minrow);
		return;
	}
	if(isend(t, list of {Ttbody, Ttfoot, Tthead})) {
		if(!inscope(p, t.tag, Stable))
			return;
		clearto(p, ctx);
		pop(p);
		p.mode = Mintable;
		return;
	}
	if(isstart(t, list of {Tcaption, Tcol, Tcolgroup, Ttbody, Ttfoot, Tthead}) || isend(t, Ttable :: nil)) {
		if(!inscope(p, Ttbody, Stable) && !inscope(p, Tthead, Stable) && !inscope(p, Ttfoot, Stable))
			return;
		clearto(p, ctx);
		pop(p);
		reprocess(p, t, Mintable);
		return;
	}
	if(isend(t, list of {Tbody, Tcaption, Tcol, Tcolgroup, Thtml, Ttd, Tth, Ttr}))
		return;
	intable(p, t);
}

# §13.2.6.4.14
inrow(p: ref P, t: ref Tok)
{
	ctx := list of {Ttr, Ttemplate};
	if(isstart(t, list of {Tth, Ttd})) {
		clearto(p, ctx);
		insertelem(p, t);
		p.mode = Mincell;
		marker(p);
		return;
	}
	if(isend(t, Ttr :: nil)) {
		if(!inscope(p, Ttr, Stable))
			return;
		clearto(p, ctx);
		pop(p);
		p.mode = Mintablebody;
		return;
	}
	if(isstart(t, list of {Tcaption, Tcol, Tcolgroup, Ttbody, Ttfoot, Tthead, Ttr}) || isend(t, Ttable :: nil)) {
		if(!inscope(p, Ttr, Stable))
			return;
		clearto(p, ctx);
		pop(p);
		reprocess(p, t, Mintablebody);
		return;
	}
	if(isend(t, list of {Ttbody, Ttfoot, Tthead})) {
		if(!inscope(p, t.tag, Stable) || !inscope(p, Ttr, Stable))
			return;
		clearto(p, ctx);
		pop(p);
		reprocess(p, t, Mintablebody);
		return;
	}
	if(isend(t, list of {Tbody, Tcaption, Tcol, Tcolgroup, Thtml, Ttd, Tth}))
		return;
	intable(p, t);
}

# §13.2.6.4.15
incell(p: ref P, t: ref Tok)
{
	if(isend(t, list of {Ttd, Tth})) {
		if(!inscope(p, t.tag, Stable))
			return;
		genimplied(p, Tnone);
		popto(p, t.tag);
		clearafe(p);
		p.mode = Minrow;
		return;
	}
	if(isstart(t, list of {Tcaption, Tcol, Tcolgroup, Ttbody, Ttd, Ttfoot, Tth, Tthead, Ttr})) {
		if(!inscope(p, Ttd, Stable) && !inscope(p, Tth, Stable))
			return;
		closecell(p);
		dispatch(p, t);
		return;
	}
	if(isend(t, list of {Tbody, Tcaption, Tcol, Tcolgroup, Thtml}))
		return;
	if(isend(t, list of {Ttable, Ttbody, Ttfoot, Tthead, Ttr})) {
		if(!inscope(p, t.tag, Stable))
			return;
		closecell(p);
		dispatch(p, t);
		return;
	}
	inbody(p, t);
}

closecell(p: ref P)
{
	genimplied(p, Tnone);
	while(p.sp > 0) {
		c := curtag(p);
		pop(p);
		if(c == Ttd || c == Tth)
			break;
	}
	clearafe(p);
	p.mode = Minrow;
}

# §13.2.6.4.16
inselect(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		insertchars(p, dropnul(t.data));
	Kcomment =>
		insertcomment(p, t.data, 0);
	Kdoctype =>
		;
	Keof =>
		inbody(p, t);
	Kstart =>
		case t.tag {
		Thtml =>
			inbody(p, t);
		Toption =>
			if(curtag(p) == Toption)
				pop(p);
			insertelem(p, t);
		Toptgroup =>
			if(curtag(p) == Toption)
				pop(p);
			if(curtag(p) == Toptgroup)
				pop(p);
			insertelem(p, t);
		Thr =>
			if(curtag(p) == Toption)
				pop(p);
			if(curtag(p) == Toptgroup)
				pop(p);
			insertelem(p, t);
			pop(p);
		Tselect =>
			if(!inscope(p, Tselect, Sselect))
				return;
			popto(p, Tselect);
			resetmode(p);
		Tinput or Tkeygen or Ttextarea =>
			if(!inscope(p, Tselect, Sselect))
				return;
			popto(p, Tselect);
			resetmode(p);
			dispatch(p, t);
		Tscript or Ttemplate =>
			inhead(p, t);
		}
	Kend =>
		case t.tag {
		Toptgroup =>
			if(curtag(p) == Toption && p.sp > 1 && htag(p, p.stack[p.sp-2]) == Toptgroup)
				pop(p);
			if(curtag(p) == Toptgroup)
				pop(p);
		Toption =>
			if(curtag(p) == Toption)
				pop(p);
		Tselect =>
			if(!inscope(p, Tselect, Sselect))
				return;
			popto(p, Tselect);
			resetmode(p);
		Ttemplate =>
			inhead(p, t);
		}
	}
}

# §13.2.6.4.17
inselectintable(p: ref P, t: ref Tok)
{
	tags := list of {Tcaption, Ttable, Ttbody, Ttfoot, Tthead, Ttr, Ttd, Tth};
	if(isstart(t, tags)) {
		popto(p, Tselect);
		resetmode(p);
		dispatch(p, t);
		return;
	}
	if(isend(t, tags)) {
		if(!inscope(p, t.tag, Stable))
			return;
		popto(p, Tselect);
		resetmode(p);
		dispatch(p, t);
		return;
	}
	inselect(p, t);
}

# §13.2.6.4.18
intemplate(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars or Kcomment or Kdoctype =>
		inbody(p, t);
		return;
	Keof =>
		if(!stackhas(p, Ttemplate)) {
			p.stopped = 1;
			return;
		}
		popto(p, Ttemplate);
		clearafe(p);
		p.tmodes = tl p.tmodes;
		resetmode(p);
		dispatch(p, t);
		return;
	Kend =>
		if(t.tag == Ttemplate)
			inhead(p, t);
		return;
	}
	m: int;
	case t.tag {
	Tbase or Tbasefont or Tbgsound or Tlink or Tmeta or Tnoframes or Tscript or
	Tstyle or Ttemplate or Ttitle =>
		inhead(p, t);
		return;
	Tcaption or Tcolgroup or Ttbody or Ttfoot or Tthead =>
		m = Mintable;
	Tcol =>
		m = Mincolgroup;
	Ttr =>
		m = Mintablebody;
	Ttd or Tth =>
		m = Minrow;
	* =>
		m = Minbody;
	}
	p.tmodes = m :: tl p.tmodes;
	reprocess(p, t, m);
}

# §13.2.6.4.19
afterbody(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		(ws, rest) := wssplit(t.data);
		if(ws != "")
			inbody(p, chartok(ws));
		if(rest == "")
			return;
		t = chartok(rest);
	Kcomment =>
		insertcomment(p, t.data, p.stack[0]);
		return;
	Kdoctype =>
		return;
	Keof =>
		p.stopped = 1;
		return;
	Kstart =>
		if(t.tag == Thtml) {
			inbody(p, t);
			return;
		}
	Kend =>
		if(t.tag == Thtml) {
			p.mode = Mafterafterbody;
			return;
		}
	}
	reprocess(p, t, Minbody);
}

# §13.2.6.4.20, 21
inframeset(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		insertchars(p, onlyws(t.data));
	Kcomment =>
		insertcomment(p, t.data, 0);
	Keof =>
		p.stopped = 1;
	Kstart =>
		case t.tag {
		Thtml =>
			inbody(p, t);
		Tframeset =>
			insertelem(p, t);
		Tframe =>
			insertelem(p, t);
			pop(p);
		Tnoframes =>
			inhead(p, t);
		}
	Kend =>
		if(t.tag == Tframeset && curtag(p) != Thtml) {
			pop(p);
			if(curtag(p) != Tframeset)
				p.mode = Mafterframeset;
		}
	}
}

afterframeset(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		insertchars(p, onlyws(t.data));
	Kcomment =>
		insertcomment(p, t.data, 0);
	Keof =>
		p.stopped = 1;
	Kstart =>
		if(t.tag == Thtml)
			inbody(p, t);
		else if(t.tag == Tnoframes)
			inhead(p, t);
	Kend =>
		if(t.tag == Thtml)
			p.mode = Mafterafterframeset;
	}
}

# §13.2.6.4.22, 23
afterafterbody(p: ref P, t: ref Tok)
{
	case t.kind {
	Kcomment =>
		insertcomment(p, t.data, 1);
		return;
	Kdoctype =>
		inbody(p, t);
		return;
	Keof =>
		p.stopped = 1;
		return;
	Kchars =>
		(ws, rest) := wssplit(t.data);
		if(ws != "")
			inbody(p, chartok(ws));
		if(rest == "")
			return;
		t = chartok(rest);
	Kstart =>
		if(t.tag == Thtml) {
			inbody(p, t);
			return;
		}
	}
	reprocess(p, t, Minbody);
}

afterafterframeset(p: ref P, t: ref Tok)
{
	case t.kind {
	Kcomment =>
		insertcomment(p, t.data, 1);
	Kdoctype =>
		inbody(p, t);
	Keof =>
		p.stopped = 1;
	Kchars =>
		ws := onlyws(t.data);
		if(ws != "")
			inbody(p, chartok(ws));
	Kstart =>
		if(t.tag == Thtml)
			inbody(p, t);
		else if(t.tag == Tnoframes)
			inhead(p, t);
	}
}

# ---- foreign content (§13.2.6.5) ----

breakout := array[] of {
	"b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl",
	"dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "i",
	"img", "li", "listing", "menu", "meta", "nobr", "ol", "p", "pre", "ruby", "s",
	"small", "span", "strong", "strike", "sub", "sup", "table", "tt", "u", "ul", "var",
};

foreign(p: ref P, t: ref Tok)
{
	case t.kind {
	Kchars =>
		s := nulls(t.data, 16rFFFD);
		insertchars(p, s);
		if(!allws(s))
			p.framesetok = 0;
	Kcomment =>
		insertcomment(p, t.data, 0);
	Kdoctype =>
		;
	Kstart =>
		brk := 0;
		for(i := 0; i < len breakout; i++)
			if(breakout[i] == t.name)
				brk = 1;
		if(t.name == "font" && (attrof(t, "color") != nil || attrof(t, "face") != nil || attrof(t, "size") != nil))
			brk = 1;
		if(brk) {
			while(p.sp > 1) {
				n := cur(p);
				nd := p.d.nodes[n];
				if(nd.ns == HTML || mathtextip(nd) || htmlip(p, n))
					break;
				pop(p);
			}
			rules(p, t, p.mode);
			return;
		}
		insertforeign(p, t, p.d.nodes[cur(p)].ns);
	Kend =>
		n := cur(p);
		if(t.name == "script" && p.d.nodes[n].ns == SVG && p.d.nodes[n].name == "script") {
			pop(p);
			return;
		}
		for(k := p.sp-1; k > 0; k--) {
			n = p.stack[k];
			nd := p.d.nodes[n];
			if(lower(nd.name) == t.name) {
				p.sp = k;
				return;
			}
			if(nd.ns == HTML && k-1 >= 0 && p.d.nodes[p.stack[k-1]].ns == HTML) {
				rules(p, t, p.mode);
				return;
			}
			if(p.d.nodes[p.stack[k-1]].ns == HTML) {
				rules(p, t, p.mode);
				return;
			}
		}
	}
}

insertforeign(p: ref P, t: ref Tok, ns: int)
{
	name := t.name;
	attrs := t.attrs;
	if(ns == SVG) {
		name = svgname(name, svgtags);
		a: list of (string, string);
		for(l := attrs; l != nil; l = tl l)
			a = (svgname((hd l).t0, svgattrs), (hd l).t1) :: a;
		attrs = nil;
		for(; a != nil; a = tl a)
			attrs = hd a :: attrs;
	} else if(ns == MathML) {
		a: list of (string, string);
		for(l := attrs; l != nil; l = tl l)
			if((hd l).t0 == "definitionurl")
				a = ("definitionURL", (hd l).t1) :: a;
			else
				a = hd l :: a;
		attrs = nil;
		for(; a != nil; a = tl a)
			attrs = hd a :: attrs;
	}
	n := p.d.create(Element, name, ns);
	p.d.nodes[n].attrs = attrs;
	insert(p, n);
	if(t.selfclose)
		return;
	push(p, n);
}

# the SVG spelling of a lower-cased tag or attribute name, if it has one
svgname(s: string, tab: array of string): string
{
	lt := svglower(tab);
	for(i := 0; i < len tab; i++)
		if(lt[i] == s)
			return tab[i];
	return s;
}

# the tables lower-cased, once
svgtagsl, svgattrsl: array of string;

svglower(tab: array of string): array of string
{
	if(tab == svgtags) {
		if(svgtagsl == nil)
			svgtagsl = lowerall(tab);
		return svgtagsl;
	}
	if(svgattrsl == nil)
		svgattrsl = lowerall(tab);
	return svgattrsl;
}

lowerall(tab: array of string): array of string
{
	r := array[len tab] of string;
	for(i := 0; i < len tab; i++)
		r[i] = lower(tab[i]);
	return r;
}

svgtags := array[] of {
	"altGlyph", "altGlyphDef", "altGlyphItem", "animateColor", "animateMotion",
	"animateTransform", "clipPath", "feBlend", "feColorMatrix",
	"feComponentTransfer", "feComposite", "feConvolveMatrix",
	"feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feDropShadow",
	"feFlood", "feFuncA", "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur",
	"feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset",
	"fePointLight", "feSpecularLighting", "feSpotLight", "feTile",
	"feTurbulence", "foreignObject", "glyphRef", "linearGradient",
	"radialGradient", "textPath",
};

svgattrs := array[] of {
	"attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode",
	"clipPathUnits", "diffuseConstant", "edgeMode", "filterUnits", "glyphRef",
	"gradientTransform", "gradientUnits", "kernelMatrix", "kernelUnitLength",
	"keyPoints", "keySplines", "keyTimes", "lengthAdjust", "limitingConeAngle",
	"markerHeight", "markerUnits", "markerWidth", "maskContentUnits",
	"maskUnits", "numOctaves", "pathLength", "patternContentUnits",
	"patternTransform", "patternUnits", "pointsAtX", "pointsAtY", "pointsAtZ",
	"preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY",
	"repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures",
	"specularConstant", "specularExponent", "spreadMethod", "startOffset",
	"stdDeviation", "stitchTiles", "surfaceScale", "systemLanguage",
	"tableValues", "targetX", "targetY", "textLength", "viewBox", "viewTarget",
	"xChannelSelector", "yChannelSelector", "zoomAndPan",
};
