implement Mdfmt;

#
# md/fmt: fmt(1) for Markdown. Fills each paragraph, list item and
# block quote of a Markdown text to a line length, and copies the
# rest (code, headings, tables, rules) as it is.
#
# What a block is comes from the parser Xenith's Render and Lucifer
# lay Markdown out with (rlayout(2)'s parsemdlines), not a grammar of
# its own, so md/fmt and what shows the text agree. A line is broken
# only where that parser would read the result as the same block:
# a word that would begin a list item, a heading or a quote at the
# start of a line stays on the line before.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "arg.m";

include "rlayout.m";
	rlayout: Rlayout;
	DocNode: import rlayout;

Mdfmt: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

length := 70;	# columns per output line
join := 1;	# can lines be joined?
maxtab := 8;

# a word, and how the line it ends (if it ends one) breaks
Word: adt {
	text:	string;
	sp:	string;	# the space after it on its line, as typed
	brk:	int;	# Bnone, or how the source broke the line after it
};

Bnone, Bhard, Bslash, Bline: con iota;	# no break; two spaces; a backslash; -j

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	arg := load Arg Arg->PATH;
	rlayout = load Rlayout Rlayout->PATH;
	if(rlayout == nil){
		sys->fprint(sys->fildes(2), "md/fmt: can't load %s: %r\n", Rlayout->PATH);
		raise "fail:load";
	}
	rlayout->init(nil);

	arg->init(args);
	arg->setusage("md/fmt [-j] [-l length] [file ...]");
	while((c := arg->opt()) != 0)
		case c {
		'j' =>
			join = 0;
		'w' or 'l' =>
			length = int arg->earg();
		* =>
			arg->usage();
		}
	args = arg->argv();
	if(length < 1){
		sys->fprint(sys->fildes(2), "md/fmt: bad line length\n");
		raise "fail:length";
	}
	arg = nil;

	err := "";
	bout := bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	if(args == nil)
		bout.puts(mdfmt(readall(sys->fildes(0))));
	else
		for(; args != nil; args = tl args){
			fd := sys->open(hd args, Sys->OREAD);
			if(fd == nil){
				sys->fprint(sys->fildes(2), "md/fmt: can't open %s: %r\n", hd args);
				err = "open";
				continue;
			}
			bout.puts(mdfmt(readall(fd)));
			if(tl args != nil)
				bout.putc('\n');
		}
	bout.flush();
	if(err != nil)
		raise "fail:"+err;
}

readall(fd: ref Sys->FD): string
{
	buf := array[8192] of byte;
	all := array[0] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0){
		a := array[len all + n] of byte;
		a[0:] = all;
		a[len all:] = buf[0:n];
		all = a;
	}
	return string all;
}

# A Markdown text, filled
mdfmt(text: string): string
{
	if(text == nil)
		return nil;
	nl := text[len text-1] == '\n';
	if(nl)
		text = text[0:len text-1];
	out := joinlines(fmtlines(splitlines(text), length));
	if(nl)
		out += "\n";
	return out;
}

# Each block of lines filled to width: what parsemdlines finds
# between one start and the next, less the blank lines after it
fmtlines(lines: array of string, width: int): array of string
{
	(doc, starts) := rlayout->parsemdlines(joinlines(lines));
	out: list of string;
	pos := 0;
	k := 0;
	for(; doc != nil; doc = tl doc){
		s := starts[k++];
		kind := (hd doc).kind;
		# a block quote is several blocks starting on one line
		while(tl doc != nil && k < len starts && starts[k] == s){
			doc = tl doc;
			k++;
		}
		e := len lines;
		if(k < len starts)
			e = starts[k];
		if(s < pos || s >= len lines)
			continue;
		for(; pos < s; pos++)
			out = blank(lines[pos]) :: out;
		while(e > s+1 && isblank(lines[e-1]))
			e--;
		b := fmtblock(kind, lines[s:e], width);
		for(i := 0; i < len b; i++)
			out = b[i] :: out;
		pos = e;
	}
	for(; pos < len lines; pos++)
		out = blank(lines[pos]) :: out;
	return revarray(out);
}

fmtblock(kind: int, b: array of string, width: int): array of string
{
	case kind {
	Rlayout->Npara =>
		for(i := 0; i < len b; i++)
			if(verbatim(b[i]))
				return b;
		lead := leadws(b[0]);
		return fill(kind, b, lead, lead, width);
	Rlayout->Nbullet or Rlayout->Nnumber =>
		(first, hang) := marker(b[0]);
		return fill(kind, b, first, hang, width);
	Rlayout->Nblockquote =>
		return quote(b, width);
	}
	return b;	# code, headings, tables, rules
}

# Lines a paragraph is not filled with: HTML, and a link's reference
# definition, which are a line each
verbatim(line: string): int
{
	s := stripws(line);
	if(len s > 0 && s[0] == '<')
		return 1;
	if(len s > 0 && s[0] == '['){
		for(i := 1; i+1 < len s; i++)
			if(s[i] == ']' && s[i+1] == ':')
				return 1;
	}
	return 0;
}

# A list item's first line's prefix (its indent, marker and a task's
# box) and the indent that continues it, as wide
marker(line: string): (string, string)
{
	i := 0;
	while(i < len line && (line[i] == ' ' || line[i] == '\t'))
		i++;
	while(i < len line && line[i] != ' ' && line[i] != '\t')
		i++;
	while(i < len line && (line[i] == ' ' || line[i] == '\t'))
		i++;
	# a task list's [ ] or [x]
	if(i+3 < len line && line[i] == '[' && line[i+2] == ']' && line[i+3] == ' ')
		for(i += 3; i < len line && line[i] == ' '; i++)
			;
	first := line[0:i];
	hang := "";
	for(j := 0; j < len first; j++){
		if(first[j] == '\t')
			hang[len hang] = '\t';
		else
			hang[len hang] = ' ';
	}
	return (first, hang);
}

# A block quote: its lines less a level of >, filled as Markdown of
# their own, and quoted again
quote(b: array of string, width: int): array of string
{
	lead := leadws(b[0]);
	inner := array[len b] of string;
	for(i := 0; i < len b; i++){
		s := stripws(b[i]);
		if(len s > 0 && s[0] == '>')
			s = s[1:];
		if(len s > 0 && s[0] == ' ')
			s = s[1:];
		inner[i] = s;
	}
	w := width - cols(lead) - 2;
	if(w < 1)
		w = 1;
	inner = fmtlines(inner, w);
	out := array[len inner] of string;
	for(i = 0; i < len inner; i++){
		if(inner[i] == nil)
			out[i] = lead + ">";
		else
			out[i] = lead + "> " + inner[i];
	}
	return out;
}

# A paragraph or list item filled: its first line begins with first,
# the rest with hang. Where the parser would read a line as the start
# of another block, the line is not broken before that word; and if it
# cannot be helped, the block is left as it was.
fill(kind: int, b: array of string, first, hang: string, width: int): array of string
{
	words: list of ref Word;
	for(i := 0; i < len b; i++){
		line := b[i];
		if(i == 0)
			line = line[len first:];
		brk := Bnone;
		if(i < len b-1){
			n := len line;
			if(!join)
				brk = Bline;
			if(n >= 2 && line[n-2:] == "  " && !isblank(line))
				brk = Bhard;
			else if(n >= 1 && line[n-1] == '\\')
				brk = Bslash;
		}
		lw := splitwords(line);	# last first
		if(lw == nil)
			continue;
		(hd lw).brk = brk;
		(hd lw).sp = "";	# a line's end joined is a space
		r: list of ref Word;
		for(; lw != nil; lw = tl lw)
			r = hd lw :: r;
		for(; r != nil; r = tl r)
			words = hd r :: words;
	}
	if(words == nil)
		return b;
	w := array[len words] of ref Word;
	for(i = len w-1; words != nil; words = tl words)
		w[i--] = hd words;
	keep := array[len w] of {* => 0};	# 1: don't break before this word
	for(;;){
		(out, at) := greedy(w, keep, first, hang, width);
		bad := check(kind, out, leadws(first));
		if(bad < 0)
			return out;
		if(bad == 0 || bad >= len at || keep[at[bad]])
			return b;
		keep[at[bad]] = 1;
	}
}

# Words set greedily into lines; and the word each line begins with
greedy(w: array of ref Word, keep: array of int, first, hang: string, width: int): (array of string, array of int)
{
	lines: list of string;
	starts: list of int;
	cur := first + w[0].text;
	col := cols(cur);
	starts = 0 :: starts;
	for(k := 1; k < len w; k++){
		p := w[k-1];
		sp := p.sp;
		if(sp == nil)
			sp = " ";
		# a gap counts one column: a typed double space a line's end
		# took is a single one when filled again, and must break the
		# same way
		if(p.brk != Bnone || (!keep[k] && col+1+cols(w[k].text) > width)){
			if(p.brk == Bhard)
				cur += "  ";
			lines = cur :: lines;
			starts = k :: starts;
			cur = hang + w[k].text;
			col = cols(cur);
		}else{
			cur += sp + w[k].text;
			col += 1 + cols(w[k].text);
		}
	}
	lines = cur :: lines;
	return (revarray(lines), revints(starts));
}

# -1 if the lines parse as one block of the kind; else the line that
# begins another, or 0 if the first does not begin one of the kind
check(kind: int, out: array of string, lead: string): int
{
	l := array[len out] of string;
	for(i := 0; i < len out; i++){
		if(len out[i] >= len lead && out[i][0:len lead] == lead)
			l[i] = out[i][len lead:];
		else
			l[i] = out[i];
	}
	(doc, starts) := rlayout->parsemdlines(joinlines(l));
	if(doc == nil || (hd doc).kind != kind || starts[0] != 0)
		return 1;
	for(i = 1; i < len starts; i++)
		if(starts[i] != 0)
			return starts[i];
	return -1;
}

# A line's words, last first; a code span is one word, its spaces as
# they are. Backticks with none to close them on the line are text.
splitwords(line: string): list of ref Word
{
	return splitw(line, 1);
}

splitw(line: string, spans: int): list of ref Word
{
	words: list of ref Word;
	w := "";
	tick := 0;	# backticks the open code span began with, or 0
	open := 0;	# where it opened, and the words before it
	before: list of ref Word;
	for(i := 0; i < len line; ){
		c := line[i];
		if(c == '`' && spans){
			n := 0;
			o := i;
			while(i < len line && line[i] == '`'){
				w[len w] = '`';
				n++;
				i++;
			}
			if(tick == 0){
				tick = n;
				open = o - len w + n;	# the word holding it starts here
				before = words;
			}else if(n == tick)
				tick = 0;
			continue;
		}
		if(tick == 0 && (c == ' ' || c == '\t')){
			sp := "";
			for(; i < len line && (line[i] == ' ' || line[i] == '\t'); i++)
				sp[len sp] = line[i];
			if(w != nil)
				words = ref Word(w, sp, Bnone) :: words;
			w = "";
			continue;
		}else
			w[len w] = c;
		i++;
	}
	if(tick != 0){
		# no span after all: from its word on, words as any are
		rest := splitw(line[open:], 0);
		r: list of ref Word;
		for(; rest != nil; rest = tl rest)
			r = hd rest :: r;
		for(words = before; r != nil; r = tl r)
			words = hd r :: words;
		return words;
	}
	if(w != nil)
		words = ref Word(w, "", Bnone) :: words;
	return words;
}

leadws(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	return s[0:i];
}

stripws(s: string): string
{
	return s[len leadws(s):];
}

isblank(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] != ' ' && s[i] != '\t' && s[i] != '\r')
			return 0;
	return 1;
}

blank(s: string): string
{
	if(isblank(s))
		return "";
	return s;
}

cols(s: string): int
{
	n := 0;
	for(i := 0; i < len s; i++){
		if(s[i] == '\t'){
			n += maxtab;
			n -= n%maxtab;
		}else
			n++;
	}
	return n;
}

splitlines(text: string): array of string
{
	n := 1;
	for(i := 0; i < len text; i++)
		if(text[i] == '\n')
			n++;
	a := array[n] of string;
	k := 0;
	s := 0;
	for(i = 0; i < len text; i++)
		if(text[i] == '\n'){
			a[k++] = text[s:i];
			s = i+1;
		}
	a[k] = text[s:];
	return a;
}

joinlines(a: array of string): string
{
	s := "";
	for(i := 0; i < len a; i++){
		if(i > 0)
			s += "\n";
		s += a[i];
	}
	return s;
}

revarray(l: list of string): array of string
{
	a := array[len l] of string;
	for(i := len a-1; l != nil; l = tl l)
		a[i--] = hd l;
	return a;
}

revints(l: list of int): array of int
{
	a := array[len l] of int;
	for(i := len a-1; l != nil; l = tl l)
		a[i--] = hd l;
	return a;
}
