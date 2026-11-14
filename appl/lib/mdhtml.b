implement Mdhtml;

#
# Markdown to HTML, with Markdown.pl's rules (werc's formatter), and
# the fenced code blocks and ~~ of later dialects.
#
# Blocks: paragraphs, atx (#) and setext (=== ---) headings, rules,
# block quotes (nested, lazy lines taken), lists (* + - and 1.,
# nested by indentation, tight or loose), code indented four spaces
# or fenced with ``` or ~~~, and blocks of raw HTML (a line at the
# left margin opening a block-level element, to the next blank line;
# <pre>, <script>, <style> and <textarea> to their end tag; a comment
# to its end).  Inline: code spans, emphasis and strong emphasis
# (* and _, _ not inside a word), links and images, inline or by
# reference ([text][id], [text][], [text] with "[id]: url "title""
# lines anywhere), autolinks (<http://...>, <mailto:...>, <a@b>), raw
# inline HTML and entities passed through, backslash escapes, and a
# hard break for a line ending in two spaces.  & < > in text are
# escaped; nothing written as HTML is changed.
#
# What it is not: CommonMark.  Tables are not Markdown.pl's and are
# left as paragraphs; headings have no ids.
#

include "sys.m";
	sys: Sys;

include "mdhtml.m";

Ref: adt {
	id:	string;
	url:	string;
	title:	string;
};

Ctx: adt {
	refs:	list of ref Ref;
};

Bullet, Ordered: con 1+iota;

blocktags := array[] of {
	"address", "article", "aside", "blockquote", "center", "del", "details",
	"dialog", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure",
	"footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup",
	"hr", "iframe", "ins", "li", "main", "math", "menu", "nav", "noscript",
	"ol", "p", "pre", "script", "section", "style", "summary", "table",
	"tbody", "td", "textarea", "tfoot", "th", "thead", "tr", "ul", "video",
	"audio", "canvas", "object", "map",
};

init()
{
	sys = load Sys Sys->PATH;
}

html(text: string): string
{
	if(sys == nil)
		init();
	c := ref Ctx(nil);
	l := getrefs(c, splitlines(text));
	return blocks(c, l, 0);
}

# Lines, without their ends, tabs set to the next multiple of four
splitlines(text: string): array of string
{
	n := 1;
	for(i := 0; i < len text; i++)
		if(text[i] == '\n')
			n++;
	if(len text > 0 && text[len text - 1] == '\n')
		n--;
	a := array[n] of string;
	k := 0;
	s := 0;
	for(i = 0; i <= len text && k < n; i++){
		if(i == len text || text[i] == '\n'){
			a[k++] = detab(text[s:i]);
			s = i+1;
		}
	}
	return a;
}

detab(s: string): string
{
	if(len s > 0 && s[len s - 1] == '\r')
		s = s[0:len s - 1];
	for(i := 0; i < len s; i++)
		if(s[i] == '\t')
			break;
	if(i == len s)
		return s;
	t := s[0:i];
	for(; i < len s; i++){
		if(s[i] == '\t'){
			do
				t[len t] = ' ';
			while(len t % 4);
		}else
			t[len t] = s[i];
	}
	return t;
}

# The reference definitions, taken out: [id]: url "title"
getrefs(c: ref Ctx, l: array of string): array of string
{
	out := array[len l] of string;
	n := 0;
	infence := "";
	for(i := 0; i < len l; i++){
		s := l[i];
		ind := indent(s);
		if(ind < 4){
			f := fence(s[ind:]);
			if(infence != nil){
				if(f != nil && f[0] == infence[0] && len f >= len infence && isblank(s[ind+len f:]))
					infence = nil;
			}else if(f != nil)
				infence = f;
		}
		if(infence == nil && ind < 4 && (r := refdef(s[ind:])) != nil){
			if(r.title == nil && i+1 < len l){
				(t, ok) := titleonly(l[i+1]);
				if(ok){
					r.title = t;
					i++;
				}
			}
			c.refs = r :: c.refs;
			continue;
		}
		out[n++] = s;
	}
	return out[0:n];
}

refdef(s: string): ref Ref
{
	if(len s < 4 || s[0] != '[')
		return nil;
	e := 1;
	while(e < len s && s[e] != ']')
		e++;
	if(e >= len s || e == 1 || e+1 >= len s || s[e+1] != ':')
		return nil;
	id := normid(s[1:e]);
	i := skipsp(s, e+2);
	if(i >= len s)
		return nil;
	url: string;
	if(s[i] == '<'){
		j := i+1;
		while(j < len s && s[j] != '>')
			j++;
		if(j >= len s)
			return nil;
		url = s[i+1:j];
		i = j+1;
	}else{
		j := i;
		while(j < len s && s[j] != ' ')
			j++;
		url = s[i:j];
		i = j;
	}
	i = skipsp(s, i);
	if(i >= len s)
		return ref Ref(id, url, nil);
	(t, ok) := titleonly(s[i:]);
	if(!ok)
		return nil;
	return ref Ref(id, url, t);
}

# A line that is only a quoted title
titleonly(s: string): (string, int)
{
	s = trim(s);
	if(len s < 2)
		return (nil, 0);
	q := s[0];
	e := q;
	if(q == '(')
		e = ')';
	else if(q != '"' && q != '\'')
		return (nil, 0);
	if(s[len s - 1] != e)
		return (nil, 0);
	return (s[1:len s - 1], 1);
}

normid(s: string): string
{
	t := "";
	sp := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == ' ' || c == '\t' || c == '\n'){
			sp = 1;
			continue;
		}
		if(sp && len t > 0)
			t[len t] = ' ';
		sp = 0;
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		t[len t] = c;
	}
	return t;
}

lookup(c: ref Ctx, id: string): ref Ref
{
	id = normid(id);
	for(l := c.refs; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

#
# Blocks
#

blocks(c: ref Ctx, l: array of string, tight: int): string
{
	out: list of string;
	n := len l;
	i := 0;
	while(i < n){
		s := l[i];
		if(isblank(s)){
			i++;
			continue;
		}
		ind := indent(s);
		t := s[ind:];

		if(ind >= 4){
			(h, j) := codeblock(l, i);
			out = h :: out;
			i = j;
			continue;
		}
		if((f := fence(t)) != nil){
			(h, j) := fenced(l, i, ind, f);
			out = h :: out;
			i = j;
			continue;
		}
		if(t[0] == '#'){
			out = atx(c, t) :: out;
			i++;
			continue;
		}
		if(ishr(t)){
			out = "<hr />\n" :: out;
			i++;
			continue;
		}
		if(t[0] == '>'){
			(h, j) := quote(c, l, i);
			out = h :: out;
			i = j;
			continue;
		}
		if(ind == 0 && (hb := htmlblock(l, i)) > i){
			out = rawlines(l[i:hb]) :: out;
			i = hb;
			continue;
		}
		(mk, nil, nil, nil) := listmarker(s);
		if(mk != 0){
			(h, j) := listblock(c, l, i);
			out = h :: out;
			i = j;
			continue;
		}

		# a paragraph, or the text of a setext heading
		j := i+1;
		for(; j < n; j++){
			u := l[j];
			if(isblank(u) || setext(u) != 0 || interrupts(u))
				break;
		}
		text := paratext(l[i:j]);
		if(j < n && (lev := setext(l[j])) != 0){
			out = sys->sprint("<h%d>%s</h%d>\n", lev, inline(c, text), lev) :: out;
			i = j+1;
			continue;
		}
		if(tight)
			out = inline(c, text) + "\n" :: out;
		else
			out = "<p>" + inline(c, text) + "</p>\n" :: out;
		i = j;
	}
	return join(out);
}

# A paragraph's lines as one text, their indents gone
paratext(l: array of string): string
{
	s := "";
	for(i := 0; i < len l; i++){
		if(i > 0)
			s[len s] = '\n';
		s += l[i][indent(l[i]):];
	}
	# a hard break at the end of a paragraph is no break
	return trimright(s);
}

# A line that ends a paragraph without a blank line before it
interrupts(u: string): int
{
	ind := indent(u);
	if(ind >= 4)
		return 0;
	t := u[ind:];
	if(t[0] == '>' || ishr(t) || fence(t) != nil)
		return 1;
	if(t[0] == '#'){
		k := 0;
		while(k < len t && t[k] == '#')
			k++;
		return k <= 6 && (k == len t || t[k] == ' ');
	}
	(mk, nil, nil, start) := listmarker(u);
	return mk == Bullet || (mk == Ordered && start == 1);
}

atx(c: ref Ctx, t: string): string
{
	lev := 0;
	while(lev < len t && t[lev] == '#' && lev < 6)
		lev++;
	s := trim(t[lev:]);
	e := len s;
	while(e > 0 && s[e-1] == '#')
		e--;
	if(e < len s && (e == 0 || s[e-1] == ' '))
		s = trim(s[0:e]);
	return sys->sprint("<h%d>%s</h%d>\n", lev, inline(c, s), lev);
}

# 1 if u underlines a first-level heading (===), 2 a second (---)
setext(u: string): int
{
	ind := indent(u);
	if(ind >= 4)
		return 0;
	t := trimright(u[ind:]);
	if(t == nil || (t[0] != '=' && t[0] != '-'))
		return 0;
	for(i := 0; i < len t; i++)
		if(t[i] != t[0])
			return 0;
	if(t[0] == '=')
		return 1;
	return 2;
}

ishr(t: string): int
{
	if(t == nil)
		return 0;
	c := t[0];
	if(c != '*' && c != '-' && c != '_')
		return 0;
	n := 0;
	for(i := 0; i < len t; i++){
		if(t[i] == c)
			n++;
		else if(t[i] != ' ')
			return 0;
	}
	return n >= 3;
}

# The fence a line opens with (``` or ~~~, or longer), or nil
fence(t: string): string
{
	if(len t < 3 || (t[0] != '`' && t[0] != '~'))
		return nil;
	k := 0;
	while(k < len t && t[k] == t[0])
		k++;
	if(k < 3)
		return nil;
	if(t[0] == '`')
		for(i := k; i < len t; i++)
			if(t[i] == '`')
				return nil;
	return t[0:k];
}

codeblock(l: array of string, i: int): (string, int)
{
	j := i;
	last := i;
	for(; j < len l; j++){
		if(isblank(l[j]))
			continue;
		if(indent(l[j]) < 4)
			break;
		last = j;
	}
	s := "<pre><code>";
	for(k := i; k <= last; k++)
		s += escape(unindent(l[k], 4)) + "\n";
	return (s + "</code></pre>\n", last+1);
}

fenced(l: array of string, i, ind: int, f: string): (string, int)
{
	info := trim(l[i][ind+len f:]);
	for(k := 0; k < len info; k++)
		if(info[k] == ' ')
			break;
	info = info[0:k];
	s := "<pre><code>";
	if(info != nil)
		s = "<pre><code class=\"language-" + escape(info) + "\">";
	j := i+1;
	for(; j < len l; j++){
		u := l[j];
		ui := indent(u);
		if(ui < 4){
			g := fence(u[ui:]);
			if(g != nil && g[0] == f[0] && len g >= len f && isblank(u[ui+len g:])){
				j++;
				break;
			}
		}
		s += escape(unindent(u, ind)) + "\n";
	}
	return (s + "</code></pre>\n", j);
}

quote(c: ref Ctx, l: array of string, i: int): (string, int)
{
	inner: list of string;
	j := i;
	for(; j < len l; j++){
		u := l[j];
		if(isblank(u)){
			k := j;
			while(k < len l && isblank(l[k]))
				k++;
			if(k < len l && indent(l[k]) < 4 && l[k][indent(l[k])] == '>'){
				for(; j < k; j++)
					inner = "" :: inner;
				j--;
				continue;
			}
			break;
		}
		ui := indent(u);
		if(ui < 4 && u[ui] == '>'){
			u = u[ui+1:];
			if(len u > 0 && u[0] == ' ')
				u = u[1:];
		}else if(j > i && (interrupts(u) && !(ui < 4 && u[ui] == '>')))
			break;
		inner = u :: inner;
	}
	return ("<blockquote>\n" + blocks(c, revarray(inner), 0) + "</blockquote>\n", j);
}

# Where a block of raw HTML starting at l[i] ends, or i if none does
htmlblock(l: array of string, i: int): int
{
	s := l[i];
	if(len s < 2 || s[0] != '<')
		return i;
	if(len s >= 4 && s[0:4] == "<!--"){
		for(j := i; j < len l; j++)
			if(contains(l[j], "-->"))
				return j+1;
		return len l;
	}
	k := 1;
	if(k < len s && s[k] == '/')
		k++;
	st := k;
	while(k < len s && (isalpha(s[k]) || (s[k] >= '0' && s[k] <= '9')))
		k++;
	if(k == st)
		return i;
	if(k < len s && s[k] != ' ' && s[k] != '>' && s[k] != '/')
		return i;
	tag := lower(s[st:k]);
	if(!isblocktag(tag))
		return i;
	if(st == 1 && (tag == "pre" || tag == "script" || tag == "style" || tag == "textarea")){
		for(j := i; j < len l; j++)
			if(contains(lower(l[j]), "</" + tag + ">"))
				return j+1;
		return len l;
	}
	for(j := i+1; j < len l; j++)
		if(isblank(l[j]))
			return j;
	return len l;
}

isblocktag(t: string): int
{
	for(i := 0; i < len blocktags; i++)
		if(blocktags[i] == t)
			return 1;
	return 0;
}

rawlines(l: array of string): string
{
	s := "";
	for(i := 0; i < len l; i++)
		s += l[i] + "\n";
	return s;
}

# A list item's marker on s: (Bullet or Ordered, the marker's
# indent, the column its text starts at, an ordered list's number),
# or 0
listmarker(s: string): (int, int, int, int)
{
	ind := indent(s);
	if(ind >= 4 || ind >= len s)
		return (0, 0, 0, 0);
	kind := 0;
	k := ind;
	start := 0;
	c := s[k];
	if(c == '*' || c == '+' || c == '-'){
		kind = Bullet;
		k++;
	}else if(c >= '0' && c <= '9'){
		while(k < len s && s[k] >= '0' && s[k] <= '9' && k - ind < 9){
			start = start*10 + s[k] - '0';
			k++;
		}
		if(k >= len s || s[k] != '.')
			return (0, 0, 0, 0);
		kind = Ordered;
		k++;
	}else
		return (0, 0, 0, 0);
	if(k == len s)
		return (kind, ind, k+1, start);
	if(s[k] != ' ')
		return (0, 0, 0, 0);
	sp := 0;
	while(k+sp < len s && s[k+sp] == ' ')
		sp++;
	if(k+sp == len s)
		return (kind, ind, k+1, start);
	if(sp > 4)
		sp = 1;
	return (kind, ind, k+sp, start);
}

listblock(c: ref Ctx, l: array of string, i: int): (string, int)
{
	(kind, nil, col, start) := listmarker(l[i]);
	items: list of array of string;
	cur: list of string;
	cur = after(l[i], col) :: nil;
	loose := 0;
	blanks := 0;
	j := i+1;
	for(; j < len l; j++){
		u := l[j];
		if(isblank(u)){
			blanks++;
			continue;
		}
		ui := indent(u);
		(k2, nil, col2, nil) := listmarker(u);
		if(k2 != 0 && ui < col && !ishr(u[ui:])){
			if(k2 != kind)
				break;
			if(blanks)
				loose = 1;
			items = revarray(cur) :: items;
			cur = after(u, col2) :: nil;
			col = col2;
			blanks = 0;
			continue;
		}
		if(blanks){
			if(ui < col && ui < 4)
				break;
			loose = 1;
			for(; blanks > 0; blanks--)
				cur = "" :: cur;
		}else if(ui < col && (ishr(u[ui:]) || (ui < 4 && (u[ui] == '#' || fence(u[ui:]) != nil))))
			break;
		cur = unindent(u, col) :: cur;
	}
	items = revarray(cur) :: items;

	s := "<ul>\n";
	e := "</ul>\n";
	if(kind == Ordered){
		s = "<ol>\n";
		if(start != 1)
			s = sys->sprint("<ol start=\"%d\">\n", start);
		e = "</ol>\n";
	}
	body: list of string;
	for(; items != nil; items = tl items){
		h := blocks(c, hd items, !loose);
		if(!loose)
			h = trimnl(h);
		body = "<li>" + h + "</li>\n" :: body;
	}
	return (s + join(rev(body)) + e, j);
}

# A list item's first line, from the column its text starts at
after(s: string, col: int): string
{
	if(col >= len s)
		return "";
	return s[col:];
}

#
# Inline
#

inline(c: ref Ctx, s: string): string
{
	o := "";
	n := len s;
	i := 0;
	while(i < n){
		ch := s[i];
		case ch {
		'\\' =>
			if(i+1 < n && isescapable(s[i+1])){
				o += escape(s[i+1:i+2]);
				i += 2;
				continue;
			}
		'`' =>
			(h, j) := codespan(s, i);
			o += h;
			i = j;
			continue;
		'*' or '_' =>
			(h, j) := emphasis(c, s, i);
			if(j > i){
				o += h;
				i = j;
				continue;
			}
			k := i;
			while(k < n && s[k] == ch)
				k++;
			o += s[i:k];
			i = k;
			continue;
		'~' =>
			if(i+1 < n && s[i+1] == '~' && i+2 < n && s[i+2] != ' '){
				e := findrun(s, i+2, '~', 2);
				if(e > 0){
					o += "<del>" + inline(c, s[i+2:e]) + "</del>";
					i = e+2;
					continue;
				}
			}
		'!' =>
			if(i+1 < n && s[i+1] == '['){
				(h, j) := link(c, s, i+1, 1);
				if(j > i+1){
					o += h;
					i = j;
					continue;
				}
			}
		'[' =>
			(h, j) := link(c, s, i, 0);
			if(j > i){
				o += h;
				i = j;
				continue;
			}
		'<' =>
			(h, j) := angle(s, i);
			o += h;
			i = j;
			continue;
		'&' =>
			if((j := entity(s, i)) > i){
				o += s[i:j];
				i = j;
				continue;
			}
			o += "&amp;";
			i++;
			continue;
		'>' =>
			o += "&gt;";
			i++;
			continue;
		'\n' =>
			k := len o;
			while(k > 0 && o[k-1] == ' ')
				k--;
			if(len o - k >= 2)
				o = o[0:k] + "<br />\n";
			else
				o[len o] = '\n';
			i++;
			continue;
		}
		o[len o] = ch;
		i++;
	}
	return o;
}

isescapable(c: int): int
{
	for(i := 0; i < len "\\`*_{}[]()#+-.!>~|<&\""; i++)
		if(c == "\\`*_{}[]()#+-.!>~|<&\""[i])
			return 1;
	return 0;
}

# A code span from a run of backticks at s[i]
codespan(s: string, i: int): (string, int)
{
	k := i;
	while(k < len s && s[k] == '`')
		k++;
	r := k - i;
	for(j := k; j < len s; ){
		if(s[j] != '`'){
			j++;
			continue;
		}
		e := j;
		while(e < len s && s[e] == '`')
			e++;
		if(e - j == r)
			return ("<code>" + escape(trim(s[k:j])) + "</code>", e);
		j = e;
	}
	return (s[i:k], k);
}

# Emphasis from a run of * or _ at s[i]; i if there is none
emphasis(c: ref Ctx, s: string, i: int): (string, int)
{
	ch := s[i];
	k := i;
	while(k < len s && s[k] == ch)
		k++;
	run := k - i;
	if(k >= len s || s[k] == ' ' || s[k] == '\n')
		return (nil, i);
	if(ch == '_' && i > 0 && isalnum(s[i-1]))
		return (nil, i);
	if(run > 3)
		return (nil, i);
	for(r := run; r >= 1; r--){
		e := findrun(s, k, ch, r);
		if(e < 0)
			continue;
		inner := inline(c, s[k:e]);
		lit := s[i:i+run-r];
		case r {
		3 =>	return (lit + "<strong><em>" + inner + "</em></strong>", e+3);
		2 =>	return (lit + "<strong>" + inner + "</strong>", e+2);
		* =>	return (lit + "<em>" + inner + "</em>", e+1);
		}
	}
	return (nil, i);
}

# Where a run of exactly r ch's closing emphasis begins, from s[i]:
# not after a blank, and for _ not before a letter or digit;
# code spans and escapes skipped
findrun(s: string, i: int, ch, r: int): int
{
	n := len s;
	for(j := i; j < n; ){
		c := s[j];
		if(c == '\\'){
			j += 2;
			continue;
		}
		if(c == '`'){
			(nil, e) := codespan(s, j);
			j = e;
			continue;
		}
		if(c != ch){
			j++;
			continue;
		}
		e := j;
		while(e < n && s[e] == ch)
			e++;
		if(e - j == r && j > i && s[j-1] != ' ' && s[j-1] != '\n' &&
		   (ch != '_' || e >= n || !isalnum(s[e])))
			return j;
		j = e;
	}
	return -1;
}

# A link or image whose text opens at s[i] ('['); i if none
link(c: ref Ctx, s: string, i: int, img: int): (string, int)
{
	n := len s;
	depth := 0;
	e := -1;
	for(j := i; j < n; j++){
		ch := s[j];
		if(ch == '\\'){
			j++;
			continue;
		}
		if(ch == '`'){
			(nil, k) := codespan(s, j);
			j = k-1;
			continue;
		}
		if(ch == '[')
			depth++;
		else if(ch == ']'){
			if(--depth == 0){
				e = j;
				break;
			}
		}
	}
	if(e < 0)
		return (nil, i);
	text := s[i+1:e];
	url, title: string;
	j = e+1;
	if(j < n && s[j] == '('){
		ok: int;
		(url, title, j, ok) = dest(s, j+1);
		if(!ok)
			return (nil, i);
	}else{
		k := j;
		if(k < n && (s[k] == ' ' || s[k] == '\n'))
			k++;
		id := text;
		if(k < n && s[k] == '['){
			m := k+1;
			while(m < n && s[m] != ']')
				m++;
			if(m >= n)
				return (nil, i);
			if(m > k+1)
				id = s[k+1:m];
			j = m+1;
		}
		r := lookup(c, id);
		if(r == nil)
			return (nil, i);
		(url, title) = (r.url, r.title);
	}
	t := "";
	if(title != nil)
		t = " title=\"" + attr(title) + "\"";
	if(img)
		return ("<img src=\"" + attr(url) + "\" alt=\"" + escape(plain(text)) + "\"" + t + " />", j);
	return ("<a href=\"" + attr(url) + "\"" + t + ">" + inline(c, text) + "</a>", j);
}

# A link's (destination "title"), from after its '('
dest(s: string, i: int): (string, string, int, int)
{
	n := len s;
	i = skipblank(s, i);
	url := "";
	if(i < n && s[i] == '<'){
		j := i+1;
		while(j < n && s[j] != '>' && s[j] != '\n')
			j++;
		if(j >= n || s[j] != '>')
			return (nil, nil, i, 0);
		url = s[i+1:j];
		i = j+1;
	}else{
		p := 0;
		j := i;
		for(; j < n; j++){
			c := s[j];
			if(c == ' ' || c == '\n')
				break;
			if(c == '\\' && j+1 < n){
				j++;
				continue;
			}
			if(c == '(')
				p++;
			else if(c == ')'){
				if(p == 0)
					break;
				p--;
			}
		}
		url = s[i:j];
		i = j;
	}
	i = skipblank(s, i);
	title: string;
	if(i < n && (s[i] == '"' || s[i] == '\'' || s[i] == '(')){
		q := s[i];
		if(q == '(')
			q = ')';
		# the last such quote before the closing ')': Markdown.pl's
		j := i+1;
		last := -1;
		for(; j < n; j++){
			if(s[j] == q)
				last = j;
			else if(s[j] == ')' && last >= 0 && isblank(s[last+1:j]))
				break;
		}
		if(last < 0)
			return (nil, nil, i, 0);
		title = s[i+1:last];
		i = skipblank(s, last+1);
	}
	if(i >= n || s[i] != ')')
		return (nil, nil, i, 0);
	return (url, title, i+1, 1);
}

# At a '<': an autolink, raw HTML, or a less-than sign
angle(s: string, i: int): (string, int)
{
	n := len s;
	j := i+1;
	while(j < n && s[j] != '>' && s[j] != ' ' && s[j] != '\n' && s[j] != '<')
		j++;
	if(j < n && s[j] == '>' && j > i+1){
		u := s[i+1:j];
		if(isurl(u))
			return ("<a href=\"" + attr(u) + "\">" + escape(u) + "</a>", j+1);
		if(isemail(u))
			return ("<a href=\"mailto:" + attr(u) + "\">" + escape(u) + "</a>", j+1);
	}
	if((e := htmltag(s, i)) > i)
		return (s[i:e], e);
	return ("&lt;", i+1);
}

isurl(u: string): int
{
	for(l := list of {"http://", "https://", "ftp://", "mailto:", "gopher://", "news:"}; l != nil; l = tl l)
		if(len u > len hd l && lower(u[0:len hd l]) == hd l)
			return 1;
	return 0;
}

isemail(u: string): int
{
	at := -1;
	for(i := 0; i < len u; i++){
		c := u[i];
		if(c == '@'){
			if(at >= 0)
				return 0;
			at = i;
		}else if(!(isalnum(c) || c == '.' || c == '-' || c == '_' || c == '+'))
			return 0;
	}
	return at > 0 && at < len u - 1 && contains(u[at:], ".");
}

# Where an HTML tag, closing tag or comment at s[i] ends; i if there is none
htmltag(s: string, i: int): int
{
	n := len s;
	if(i+3 < n && s[i+1:i+4] == "!--"){
		for(j := i+4; j+2 < n; j++)
			if(s[j:j+3] == "-->")
				return j+3;
		return i;
	}
	j := i+1;
	if(j < n && s[j] == '/')
		j++;
	if(j >= n || !isalpha(s[j]))
		return i;
	while(j < n && (isalnum(s[j]) || s[j] == '-' || s[j] == ':'))
		j++;
	if(j < n && s[j] != '>' && s[j] != '/' && s[j] != ' ' && s[j] != '\n')
		return i;
	q := 0;
	for(; j < n; j++){
		c := s[j];
		if(q){
			if(c == q)
				q = 0;
		}else if(c == '"' || c == '\'')
			q = c;
		else if(c == '<')
			return i;
		else if(c == '>')
			return j+1;
	}
	return i;
}

# Where an entity (&name; &#n; &#xh;) at s[i] ends; i if there is none
entity(s: string, i: int): int
{
	n := len s;
	j := i+1;
	if(j < n && s[j] == '#'){
		j++;
		hex := 0;
		if(j < n && (s[j] == 'x' || s[j] == 'X')){
			hex = 1;
			j++;
		}
		st := j;
		while(j < n && j - st < 8 && (s[j] >= '0' && s[j] <= '9' ||
		      hex && (s[j] >= 'a' && s[j] <= 'f' || s[j] >= 'A' && s[j] <= 'F')))
			j++;
		if(j == st)
			return i;
	}else{
		st := j;
		while(j < n && j - st < 32 && isalnum(s[j]))
			j++;
		if(j == st || !isalpha(s[st]))
			return i;
	}
	if(j < n && s[j] == ';')
		return j+1;
	return i;
}

# A link's text as plain text, for an image's alt
plain(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '*' || c == '_' || c == '`')
			continue;
		if(c == '\\' && i+1 < len s){
			i++;
			c = s[i];
		}
		t[len t] = c;
	}
	return t;
}

#
# Strings
#

escape(s: string): string
{
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '&' || c == '<' || c == '>' || c == '"')
			break;
	}
	if(i == len s)
		return s;
	t := s[0:i];
	for(; i < len s; i++){
		case s[i] {
		'&' =>	t += "&amp;";
		'<' =>	t += "&lt;";
		'>' =>	t += "&gt;";
		'"' =>	t += "&quot;";
		* =>	t[len t] = s[i];
		}
	}
	return t;
}

# An attribute's value: as escape, but an entity already written kept
attr(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '\\' && i+1 < len s && isescapable(s[i+1])){
			i++;
			c = s[i];
		}else if(c == '&' && (e := entity(s, i)) > i){
			t += s[i:e];
			i = e-1;
			continue;
		}
		case c {
		'&' =>	t += "&amp;";
		'<' =>	t += "&lt;";
		'>' =>	t += "&gt;";
		'"' =>	t += "&quot;";
		* =>	t[len t] = c;
		}
	}
	return t;
}

join(l: list of string): string
{
	n := 0;
	for(p := l; p != nil; p = tl p)
		n++;
	a := array[n] of string;
	for(; l != nil; l = tl l)
		a[--n] = hd l;
	s := "";
	for(i := 0; i < len a; i++)
		s += a[i];
	return s;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revarray(l: list of string): array of string
{
	n := 0;
	for(p := l; p != nil; p = tl p)
		n++;
	a := array[n] of string;
	for(; l != nil; l = tl l)
		a[--n] = hd l;
	return a;
}

indent(s: string): int
{
	i := 0;
	while(i < len s && s[i] == ' ')
		i++;
	return i;
}

unindent(s: string, n: int): string
{
	i := 0;
	while(i < n && i < len s && s[i] == ' ')
		i++;
	return s[i:];
}

isblank(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] != ' ' && s[i] != '\t')
			return 0;
	return 1;
}

skipsp(s: string, i: int): int
{
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	return i;
}

skipblank(s: string, i: int): int
{
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	return i;
}

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	return trimright(s[i:]);
}

trimright(s: string): string
{
	e := len s;
	while(e > 0 && (s[e-1] == ' ' || s[e-1] == '\t' || s[e-1] == '\n'))
		e--;
	return s[0:e];
}

trimnl(s: string): string
{
	if(len s > 0 && s[len s - 1] == '\n')
		return s[0:len s - 1];
	return s;
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			break;
	if(i == len s)
		return s;
	t := s;
	for(; i < len t; i++)
		if(t[i] >= 'A' && t[i] <= 'Z')
			t[i] += 'a' - 'A';
	return t;
}

isalpha(c: int): int
{
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z';
}

isalnum(c: int): int
{
	return isalpha(c) || c >= '0' && c <= '9' || c >= 16r80;
}
