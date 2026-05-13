implement Mailparse;

#
# Pure parsers extracted from mail9p so they can be exercised
# independently of a running IMAP server. No I/O, no state.
#

include "sys.m";
	sys: Sys;

include "string.m";
	str: String;

include "imap.m";

include "mailparse.m";

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(str == nil)
		str = load String String->PATH;
}

ensureloaded()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(str == nil)
		str = load String String->PATH;
}

parseflagswrite(s: string): (int, int, int, string)
{
	ensureloaded();
	(nil, toks) := sys->tokenize(s, " \t\r\n");
	if(toks == nil)
		return (0, 0, 0, "no flags");

	# Decide replace-vs-diff by the first token's leading sign.
	first := hd toks;
	diffmode := len first > 0 && (first[0] == '+' || first[0] == '-');

	add := 0;
	remove := 0;
	replace := 0;
	for(; toks != nil; toks = tl toks) {
		t := hd toks;
		if(len t == 0)
			continue;
		signed := t[0] == '+' || t[0] == '-';
		if(diffmode != signed)
			return (0, 0, 0, "mix of signed and bare flags");
		bits := 0;
		flagname := t;
		if(signed)
			flagname = t[1:];
		case flagname {
		"\\Seen" or "Seen" =>
			bits = Imap->FSEEN;
		"\\Answered" or "Answered" =>
			bits = Imap->FANSWERED;
		"\\Flagged" or "Flagged" =>
			bits = Imap->FFLAGGED;
		"\\Deleted" or "Deleted" =>
			bits = Imap->FDELETED;
		"\\Draft" or "Draft" =>
			bits = Imap->FDRAFT;
		* =>
			return (0, 0, 0, "unknown flag: " + flagname);
		}
		if(signed) {
			if(t[0] == '+')
				add |= bits;
			else
				remove |= bits;
		} else {
			replace |= bits;
		}
	}
	if(diffmode)
		return (add, remove, -1, nil);
	return (0, 0, replace, nil);
}

splitbody(raw: string): string
{
	for(i := 0; i + 1 < len raw; i++) {
		if(raw[i] == '\n' && raw[i+1] == '\n')
			return raw[i+2:];
		if(i + 3 < len raw && raw[i] == '\r' && raw[i+1] == '\n' &&
		   raw[i+2] == '\r' && raw[i+3] == '\n')
			return raw[i+4:];
	}
	return "";
}

hasheaderfield(body, field: string): int
{
	ensureloaded();
	fl := str->tolower(field);
	for(start := 0; start < len body; ) {
		i := start;
		while(i < len body && body[i] != '\n')
			i++;
		line := body[start:i];
		if(len line > 0 && line[len line - 1] == '\r')
			line = line[0:len line - 1];
		if(line == "")
			return 0;	# header section ended
		if(len line >= len field && str->tolower(line[0:len field]) == fl)
			return 1;
		start = i + 1;
	}
	return 0;
}

bodyhasblankline(body: string): int
{
	for(i := 0; i + 1 < len body; i++) {
		if(body[i] == '\n' && body[i+1] == '\n')
			return 1;
		if(i + 3 < len body && body[i] == '\r' && body[i+1] == '\n' &&
		   body[i+2] == '\r' && body[i+3] == '\n')
			return 1;
	}
	return 0;
}

extractheader(body, field: string): string
{
	ensureloaded();
	fl := str->tolower(field);
	for(start := 0; start < len body; ) {
		i := start;
		while(i < len body && body[i] != '\n')
			i++;
		line := body[start:i];
		if(len line > 0 && line[len line - 1] == '\r')
			line = line[0:len line - 1];
		if(line == "")
			return "";	# end of headers
		if(len line >= len field && str->tolower(line[0:len field]) == fl) {
			v := line[len field:];
			j := 0;
			while(j < len v && (v[j] == ' ' || v[j] == '\t'))
				j++;
			return v[j:];
		}
		start = i + 1;
	}
	return "";
}

parseaddrlist(s: string): list of string
{
	out: list of string;
	start := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == ',') {
			out = trimaddr(s[start:i]) :: out;
			start = i + 1;
		}
	}
	if(start < len s)
		out = trimaddr(s[start:]) :: out;
	# Reverse
	rev: list of string;
	for(; out != nil; out = tl out)
		rev = hd out :: rev;
	return rev;
}

trimaddr(s: string): string
{
	# Trim whitespace.
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t'))
		j--;
	s = s[i:j];
	# If there's a `<...>`, pull out the inside.
	lt := -1;
	gt := -1;
	for(k := 0; k < len s; k++) {
		if(s[k] == '<') lt = k;
		else if(s[k] == '>') gt = k;
	}
	if(lt >= 0 && gt > lt)
		return s[lt+1:gt];
	return s;
}

strtobig(s: string): big
{
	if(len s == 0)
		return big -1;
	v := big 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return big -1;
		v = v * big 10 + big (c - '0');
	}
	return v;
}
