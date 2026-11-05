implement Dialspeech;

#
# dialspeech -- what was said to a telephone, as a number to dial.
# See module/dialspeech.m.
#

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "dialspeech.m";

init()
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
}

units := array[] of {
	"zero", "one", "two", "three", "four",
	"five", "six", "seven", "eight", "nine",
};
teens := array[] of {
	"ten", "eleven", "twelve", "thirteen", "fourteen",
	"fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
};
tens := array[] of {
	"", "", "twenty", "thirty", "forty",
	"fifty", "sixty", "seventy", "eighty", "ninety",
};

# words that say to place the call
callwords := array[] of {"call", "dial", "phone", "ring", "telephone"};

# the kinds of number, as said and as the address book has them
kindwords := array[] of {
	("mobile", "mobile"), ("cell", "mobile"), ("cellphone", "mobile"),
	("work", "work"), ("office", "work"), ("business", "work"),
	("home", "home"), ("house", "home"),
	("main", "main"),
};

# said around a name and not part of it
fillers := array[] of {
	"please", "at", "on", "the", "my", "her", "his", "their",
	"number", "phone", "now", "up", "to",
};

parse(text: string): ref Said
{
	said := ref Said(Nothing, 0, nil, nil, nil);
	words := tokens(str->tolower(text));
	if(words == nil)
		return said;
	for(i := 0; i < len callwords; i++)
		if(hd words == callwords[i]){
			said.call = 1;
			words = tl words;
			break;
		}
	# "call up" / "call to": up and to are fillers below
	if(words == nil)
		return said;

	if((n := number(words)) != nil){
		said.what = Number;
		said.number = n;
		return said;
	}

	# a name: what is left once the kind and the fillers are taken out
	name: list of string;
	for(l := words; l != nil; l = tl l){
		w := hd l;
		if(len w > 2 && w[len w - 2:] == "'s")
			w = w[0:len w - 2];
		if((k := kindof(w)) != nil && name != nil){
			said.kind = k;
			continue;
		}
		if(isfiller(w) && (name == nil || tl l == nil || allfill(tl l)))
			continue;
		name = w :: name;
	}
	if(name == nil)
		return said;
	s := "";
	for(; name != nil; name = tl name){
		if(s != "")
			s = " " + s;
		s = hd name + s;
	}
	said.what = Name;
	said.name = s;
	return said;
}

# The words of text: letters, digits and what a number is written
# with kept together; other punctuation is a space, an apostrophe
# kept (Sarah's).
tokens(text: string): list of string
{
	words: list of string;
	w := "";
	for(i := 0; i <= len text; i++){
		c := ' ';
		if(i < len text)
			c = text[i];
		case c {
		'a' to 'z' or '0' to '9' or '+' or '*' or '#' or '\'' or 16r80 to 16r10FFFF =>
			w[len w] = c;
		'-' or '(' or ')' or '.' =>
			# a number's punctuation: 555-1234, (555), 555.1234
			if(w != "" && isdigits(w) || c == '(' || c == ')')
				;
			else if(w != ""){
				words = w :: words;
				w = "";
			}
		* =>
			if(w != ""){
				words = w :: words;
				w = "";
			}
		}
	}
	r: list of string;
	for(; words != nil; words = tl words)
		r = hd words :: r;
	return r;
}

isdigits(w: string): int
{
	for(i := 0; i < len w; i++)
		if(!(w[i] >= '0' && w[i] <= '9' || w[i] == '+' || w[i] == '*' || w[i] == '#'))
			return 0;
	return len w > 0;
}

# The number the words say, or nil if they are not all a number's.
number(words: list of string): string
{
	n := "";
	repeat := 1;	# "double", "triple": the next digit so many times
	prev := -1;	# the last single digit said, for "hundred"
	for(; words != nil; words = tl words){
		w := hd words;
		d := "";
		single := -1;
		case w {
		"oh" or "o" =>
			d = "0";
			single = 0;
		"double" =>
			repeat = 2;
			continue;
		"triple" =>
			repeat = 3;
			continue;
		"star" or "asterisk" =>
			d = "*";
		"pound" or "hash" or "hashtag" or "octothorpe" =>
			d = "#";
		"plus" =>
			if(n != "")
				return nil;
			n = "+";
			continue;
		"hundred" =>
			if(prev < 0)
				return nil;
			d = "00";
		"thousand" =>
			if(n == "")
				return nil;
			d = "000";
		"and" =>
			continue;
		* =>
			u, t: int;
			if(isdigits(w)){
				for(i := 0; i < len w; i++)
					if(w[i] == '+' && (i > 0 || n != ""))
						return nil;
				d = w;
			}else if((u = index(units, w)) >= 0){
				d = string u;
				single = u;
			}else if((t = index(teens, w)) >= 0)
				d = string (10 + t);
			else if((t = index(tens, w)) >= 2){
				# "twenty five" is 25, "twenty" alone 20
				if(tl words != nil && (u = index(units, hd tl words)) > 0){
					d = string (10*t + u);
					words = tl words;
				}else
					d = string (10*t);
			}else
				return nil;
		}
		for(; repeat > 0; repeat--)
			n += d;
		repeat = 1;
		prev = single;
	}
	if(n == "" || n == "+")
		return nil;
	return n;
}

index(a: array of string, w: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] != "" && a[i] == w)
			return i;
	return -1;
}

kindof(w: string): string
{
	for(i := 0; i < len kindwords; i++){
		(said, kind) := kindwords[i];
		if(w == said)
			return kind;
	}
	return nil;
}

isfiller(w: string): int
{
	for(i := 0; i < len fillers; i++)
		if(w == fillers[i])
			return 1;
	return 0;
}

allfill(l: list of string): int
{
	for(; l != nil; l = tl l){
		w := hd l;
		if(len w > 2 && w[len w - 2:] == "'s")
			w = w[0:len w - 2];
		if(!isfiller(w) && kindof(w) == nil)
			return 0;
	}
	return 1;
}

lookup(contacts: string, name, kind: string): (string, string, string, string)
{
	name = str->tolower(name);
	# every number of every contact the name could be, whole names
	# kept apart from names a word of which was said
	whole, word, part: list of (string, string, string);
	entries := 0;
	why := "";	# the book's own word on itself: "# contacts: ..."
	(nil, lines) := sys->tokenize(contacts, "\n");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(l == "")
			continue;
		if(l[0] == '#'){
			if(why == ""){
				why = l[1:];
				while(why != "" && why[0] == ' ')
					why = why[1:];
			}
			continue;
		}
		entries++;
		(nf, f) := sys->tokenize(l, "\t");
		if(nf < 3)
			continue;
		cname := hd f;
		ckind := hd tl f;
		cnum := hd tl tl f;
		lc := str->tolower(cname);
		e := (cname, ckind, cnum);
		if(lc == name)
			whole = e :: whole;
		else if(hasword(lc, name))
			word = e :: word;
		else if(contains(lc, name))
			part = e :: part;
	}
	c := whole;
	if(c == nil)
		c = word;
	if(c == nil)
		c = part;
	if(c == nil && entries == 0 && why != "")
		return (nil, nil, nil, why);	# no book: denied, not wired; say so
	if(c == nil)
		return (nil, nil, nil, "no contact called " + name);
	c = rev(c);

	# one person, or say which
	(first, nil, nil) := hd c;
	for(l := tl c; l != nil; l = tl l){
		(n, nil, nil) := hd l;
		if(n != first){
			others := first;
			for(m := tl c; m != nil; m = tl m){
				(o, nil, nil) := hd m;
				if(!contains(others, o))
					others += ", " + o;
			}
			return (nil, nil, nil, "which: " + others + "?");
		}
	}

	want := kind;
	if(want == nil)
		want = "mobile";
	for(l = c; l != nil; l = tl l){
		(n, k, num) := hd l;
		if(str->tolower(k) == want)
			return (num, n, k, nil);
	}
	if(kind != nil)
		return (nil, nil, nil, sys->sprint("no %s number for %s", kind, first));
	(n, k, num) := hd c;
	return (num, n, k, nil);
}

# whether name is a whole word (or words) of s
hasword(s, name: string): int
{
	for(i := 0; i + len name <= len s; i++)
		if(s[i:i+len name] == name &&
		   (i == 0 || s[i-1] == ' ') &&
		   (i + len name == len s || s[i+len name] == ' '))
			return 1;
	return 0;
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

rev(l: list of (string, string, string)): list of (string, string, string)
{
	r: list of (string, string, string);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
