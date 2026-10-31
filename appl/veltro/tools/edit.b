implement ToolEdit;

#
# edit - Edit file contents tool for Veltro agent
#
# Performs find/replace operations on file contents.
# Similar to sed s/old/new/ but safer - fails if old text not found or ambiguous.
#
# Usage:
#   Edit <path> <old> <new>       # Replace first occurrence
#   Edit <path> <old> <new> all   # Replace all occurrences
#
# Arguments must be quoted if they contain spaces.
# Use \n for newlines, \t for tabs.
#
# Examples:
#   Edit /tmp/test.txt "hello" "goodbye"
#   Edit /appl/veltro/veltro.b "MAX_STEPS: con 50" "MAX_STEPS: con 100"
#   Edit /tmp/test.txt "foo" "bar" all
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "string.m";
	str: String;

include "json.m";
	json: JSON;
	JValue: import json;

include "../tool.m";

ToolEdit: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load Bufio";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	json = load JSON JSON->PATH;
	if(json == nil)
		return "cannot load JSON";
	json->init(bufio);
	return nil;
}

name(): string
{
	return "edit";
}

doc(): string
{
	return "Edit - Edit file contents (find/replace)\n\n" +
		"Usage:\n" +
		"  Edit <path> <old> <new>       # Replace first occurrence\n" +
		"  Edit <path> <old> <new> all   # Replace all occurrences\n\n" +
		"Arguments:\n" +
		"  path - File to edit\n" +
		"  old  - Text to find (use quotes if contains spaces)\n" +
		"  new  - Replacement text (use quotes if contains spaces)\n" +
		"  all  - Optional: replace all occurrences\n\n" +
		"Use \\n for newlines, \\t for tabs.\n\n" +
		"Examples:\n" +
		"  Edit /tmp/test.txt \"hello\" \"goodbye\"\n" +
		"  Edit /appl/veltro/veltro.b \"MAX: con 50\" \"MAX: con 100\"\n" +
		"  Edit /tmp/test.txt \"foo\" \"bar\" all\n\n" +
		"Fails if old text not found. Without 'all', fails if multiple matches.";
}

schema(): string
{
	return "{" +
		"\"name\":\"edit\"," +
		"\"description\":\"Replace text in a file.  For one change give old and new; for several in the same file give edits, a list of {old, new}, in one call.  Each old must be the text exactly as it is in the file before this call, and match one place only (give more of the surrounding text if it is not unique, or all to change every place); changes in one call must not overlap.  Keep old as short as makes it unique.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"path\":{\"type\":\"string\",\"description\":\"File path to edit.\"}," +
				"\"old\":{\"type\":\"string\",\"description\":\"The text to find, exactly as it is in the file: line breaks as line breaks, without the line numbers read shows. Nothing in it is unescaped.\"}," +
				"\"new\":{\"type\":\"string\",\"description\":\"The text to put in its place, exactly as the file is to hold it: line breaks as line breaks. Nothing in it is unescaped.\"}," +
				"\"all\":{\"type\":\"string\",\"description\":\"Set to 'all' to replace every occurrence. Optional; default replaces only the one match.\"}," +
				"\"edits\":{\"type\":\"array\",\"description\":\"Several changes to this file, instead of old and new: each matched against the file as it was before the call.\",\"items\":{\"type\":\"object\",\"properties\":{\"old\":{\"type\":\"string\"},\"new\":{\"type\":\"string\"}},\"required\":[\"old\",\"new\"]}}" +
			"}," +
			"\"required\":[\"path\"]" +
		"}" +
	"}";
}

# One change: old found in the file as it was before the call.
Change: adt {
	old, new:	string;
	all:		int;
};

# Where a change falls in the file.
Span: adt {
	start, end:	int;
	new:		string;
	which:		int;	# the change's index, for errors
};

exec(args: string): string
{
	if(sys == nil)
		init();

	changes: list of ref Change;
	path: string;
	if(len args > 3 && args[0:3] == "-j ") {
		# Several changes: a native call's arguments, JSON, with the
		# path in front (as the approval gate reads it).
		rest: string;
		(path, rest) = parseone(args[3:]);
		err: string;
		(changes, err) = parsechanges(rest);
		if(err != nil)
			return "error: " + err;
	} else {
		# -r: old and new are the text itself (a native call's, already
		# decoded), not to be unescaped again.
		raw := 0;
		if(len args > 3 && args[0:3] == "-r ") {
			raw = 1;
			args = args[3:];
		}
		old, new: string;
		all: int;
		(path, old, new, all) = parseargs(args);
		if(path == "")
			return "error: usage: Edit <path> <old> <new> [all]";
		if(old == "")
			return "error: no search text specified";
		# Process escape sequences
		if(!raw) {
			old = unescape(old);
			new = unescape(new);
		}
		changes = ref Change(old, new, all) :: nil;
	}
	if(path == "")
		return "error: no path given";

	# Check if path is under a read-only bound namespace
	roerr := checkreadonly(path);
	if(roerr != nil)
		return roerr;

	# Read file
	content := readfile(path);
	if(content == nil)
		return sys->sprint("error: cannot read %s: %r", path);

	(newtext, replaced, loose, err) := apply(string content, changes, path);
	if(err != nil)
		return "error: " + err;

	# Write back
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("error: cannot write %s: %r", path);

	data := array of byte newtext;
	n := sys->write(fd, data, len data);
	if(n != len data)
		return sys->sprint("error: partial write to %s", path);

	r := sys->sprint("replaced %d occurrence(s) in %s", replaced, path);
	if(loose)
		r += " (matched allowing for the read tool's line numbers, trailing blanks, " +
			"or curly quotes and dashes)";
	return r;
}

# The changes of a JSON argument object: "edits", a list of {old, new,
# all}; or old and new themselves.
parsechanges(js: string): (list of ref Change, string)
{
	bio := bufio->aopen(array of byte js);
	if(bio == nil)
		return (nil, "cannot read arguments");
	(jv, jerr) := json->readjson(bio);
	if(jerr != nil || jv == nil)
		return (nil, "arguments are not JSON: " + jerr);
	changes: list of ref Change;
	ev := jv.get("edits");
	if(ev != nil) {
		pick ea := ev {
		Array =>
			for(i := len ea.a - 1; i >= 0; i--) {
				(c, err) := onechange(ea.a[i], i);
				if(err != nil)
					return (nil, err);
				changes = c :: changes;
			}
		String =>
			# A list sent as a string of JSON, as some models do.
			return parsechanges("{\"edits\":" + ea.s + "}");
		* =>
			return (nil, "edits must be a list of {old, new}");
		}
	}
	if(jv.get("old") != nil) {
		(c, err) := onechange(jv, -1);
		if(err != nil)
			return (nil, err);
		changes = c :: changes;
	}
	if(changes == nil)
		return (nil, "no change given: send old and new, or edits");
	return (changes, nil);
}

onechange(jv: ref JValue, i: int): (ref Change, string)
{
	old := jstr(jv, "old");
	if(old == "") {
		if(i < 0)
			return (nil, "no search text specified");
		return (nil, sys->sprint("edits[%d] has no old text", i));
	}
	all := jstr(jv, "all");
	return (ref Change(old, jstr(jv, "new"), all == "all" || all == "true" || all == "1"), nil);
}

jstr(jv: ref JValue, key: string): string
{
	v := jv.get(key);
	if(v == nil)
		return "";
	pick sv := v {
	String =>
		return sv.s;
	True =>
		return "true";
	}
	return v.text();
}

# The file with every change made, how many places were changed, and
# whether any was matched loosely; or why nothing was.
apply(text: string, changes: list of ref Change, path: string): (string, int, int, string)
{
	spans: list of ref Span;
	loose := 0;
	nth := 0;
	multi := tl changes != nil;
	for(cl := changes; cl != nil; cl = tl cl) {
		c := hd cl;
		which := "";
		if(multi)
			which = sys->sprint("edits[%d]: ", nth);
		(found, how) := find(text, c.old);
		new := c.new;
		if(found == nil) {
			# The read tool's line numbers, copied with the text.
			(sold, ok) := unnumber(c.old);
			if(ok) {
				(found, how) = find(text, sold);
				(snew, nok) := unnumber(new);
				if(nok)
					new = snew;
				if(found != nil)
					how = 1;
			}
		}
		if(found == nil)
			return (nil, 0, 0, which + notfound(text, c.old, path));
		if(tl found != nil && !c.all)
			return (nil, 0, 0, sys->sprint("%s'%s' found %d times in %s: give more of the " +
				"text around it so it matches one place (or all to replace every one)",
				which, show(c.old), len found, path));
		loose |= how;
		for(; found != nil; found = tl found) {
			(st, en) := hd found;
			spans = ref Span(st, en, new, nth) :: spans;
			if(!c.all)
				break;
		}
		nth++;
	}

	# In the file's order; no two may overlap.
	a := array[len spans] of ref Span;
	i := 0;
	for(; spans != nil; spans = tl spans)
		a[i++] = hd spans;
	for(i = 1; i < len a; i++)
		for(j := i; j > 0 && a[j].start < a[j-1].start; j--)
			(a[j], a[j-1]) = (a[j-1], a[j]);
	for(i = 1; i < len a; i++)
		if(a[i].start < a[i-1].end)
			return (nil, 0, 0, sys->sprint("edits[%d] and edits[%d] overlap in %s: " +
				"make them one edit, or edit places that do not overlap",
				a[i-1].which, a[i].which, path));

	out := "";
	at := 0;
	for(i = 0; i < len a; i++) {
		out += text[at:a[i].start] + a[i].new;
		at = a[i].end;
	}
	out += text[at:];
	return (out, len a, loose, nil);
}

# Every place old is in text, as (start, end), and whether it was
# matched loosely: exactly first, then as text that differs only in
# trailing blanks, curly quotes, Unicode dashes and no-break spaces.
find(text, old: string): (list of (int, int), int)
{
	exact: list of (int, int);
	n := len old;
	for(i := 0; i + n <= len text; ) {
		if(text[i:i+n] == old) {
			exact = (i, i + n) :: exact;
			i += n;
		} else
			i++;
	}
	if(exact != nil)
		return (rev(exact), 0);

	(nt, at) := normalise(text);
	(no, nil) := normalise(old);
	if(no == "")
		return (nil, 0);
	m := len no;
	loose: list of (int, int);
	for(i = 0; i + m <= len nt; ) {
		if(nt[i:i+m] == no) {
			loose = (at[i], at[i+m-1] + 1) :: loose;
			i += m;
		} else
			i++;
	}
	return (rev(loose), 1);
}

rev(l: list of (int, int)): list of (int, int)
{
	r: list of (int, int);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# s with trailing blanks dropped and look-alike characters made plain,
# and for each of its characters, where it was in s.
normalise(s: string): (string, array of int)
{
	out := "";
	at := array[len s + 1] of int;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == ' ' || c == '\t') {
			j := i;
			while(j < len s && (s[j] == ' ' || s[j] == '\t'))
				j++;
			if(j == len s || s[j] == '\n') {
				i = j - 1;
				continue;
			}
		}
		case c {
		16r2018 or 16r2019 or 16r201A or 16r201B =>
			c = '\'';
		16r201C or 16r201D or 16r201E or 16r201F =>
			c = '"';
		16r2010 or 16r2011 or 16r2012 or 16r2013 or 16r2014 or 16r2015 =>
			c = '-';
		16r00A0 or 16r2007 or 16r202F =>
			c = ' ';
		}
		at[len out] = i;
		out[len out] = c;
	}
	return (out, at);
}

# Text whose every line carries the read tool's line number ("   12\t"),
# without them; and whether it did.
unnumber(s: string): (string, int)
{
	out := "";
	any := 0;
	start := 0;
	for(i := 0; i <= len s; i++) {
		if(i < len s && s[i] != '\n')
			continue;
		line := s[start:i];
		start = i + 1;
		if(line != "") {
			j := 0;
			while(j < len line && line[j] == ' ')
				j++;
			k := j;
			while(k < len line && line[k] >= '0' && line[k] <= '9')
				k++;
			if(k == j || k >= len line || line[k] != '\t')
				return (s, 0);
			line = line[k+1:];
			any = 1;
		}
		out += line;
		if(i < len s)
			out += "\n";
	}
	return (out, any);
}

# Why old was not found, and where to look.
notfound(text, old, path: string): string
{
	msg := sys->sprint("'%s' not found in %s", show(old), path);
	# The line of the file most like old's first line, by its words.
	first := old;
	for(i := 0; i < len old; i++)
		if(old[i] == '\n') {
			first = old[0:i];
			break;
		}
	first = trim(first);
	if(len first >= 4) {
		lineno := 1;
		start := 0;
		for(i = 0; i <= len text; i++) {
			if(i < len text && text[i] != '\n')
				continue;
			line := trim(text[start:i]);
			if(line == first || (len line >= 4 && contains(line, first))) {
				return msg + sys->sprint(".  Its first line is at line %d: '%s'.  The rest " +
					"differs: read the lines there again and send old as they are",
					lineno, show(line));
			}
			start = i + 1;
			lineno++;
		}
	}
	return msg + ".  Read the file again: it may not say what you remember";
}

trim(s: string): string
{
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	while(len s > 0 && (s[len s-1] == ' ' || s[len s-1] == '\t' || s[len s-1] == '\r'))
		s = s[0:len s-1];
	return s;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# Text for an error message: escaped, and not too long.
show(s: string): string
{
	s = escape(s);
	if(len s > 200)
		s = s[0:200] + "...";
	return s;
}

# Parse edit arguments: path, old, new, all flag
parseargs(s: string): (string, string, string, int)
{
	path := "";
	old := "";
	new := "";
	all := 0;

	# Parse path
	(path, s) = parseone(s);
	if(path == "")
		return ("", "", "", 0);

	# Parse old text
	(old, s) = parseone(s);
	if(old == "")
		return (path, "", "", 0);

	# Parse new text
	(new, s) = parseone(s);

	# Check for 'all' flag
	(flag, nil) := parseone(s);
	if(flag == "all")
		all = 1;

	return (path, old, new, all);
}

# Parse one argument, handling quotes
parseone(s: string): (string, string)
{
	# Skip leading whitespace
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;

	if(i >= len s)
		return ("", "");

	# Check for quoted string
	if(s[i] == '"' || s[i] == '\'') {
		quote := s[i];
		i++;
		start := i;
		# Handle escaped quotes
		result := "";
		while(i < len s) {
			if(s[i] == '\\' && i + 1 < len s && s[i+1] == quote) {
				result += s[start:i];
				result[len result] = quote;
				i += 2;
				start = i;
				continue;
			}
			if(s[i] == quote)
				break;
			i++;
		}
		result += s[start:i];
		if(i < len s)
			i++;
		return (result, s[i:]);
	}

	# Unquoted argument
	start := i;
	while(i < len s && s[i] != ' ' && s[i] != '\t')
		i++;
	return (s[start:i], s[i:]);
}

# Process escape sequences
unescape(s: string): string
{
	result := "";
	i := 0;
	while(i < len s) {
		if(s[i] == '\\' && i + 1 < len s) {
			case s[i+1] {
			'n' =>
				result[len result] = '\n';
			't' =>
				result[len result] = '\t';
			'r' =>
				result[len result] = '\r';
			'\\' =>
				result[len result] = '\\';
			'"' =>
				result[len result] = '"';
			'\'' =>
				result[len result] = '\'';
			* =>
				result[len result] = s[i+1];
			}
			i += 2;
		} else {
			result[len result] = s[i];
			i++;
		}
	}
	return result;
}

# Escape string for display
escape(s: string): string
{
	result := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		case c {
		'\n' =>
			result += "\\n";
		'\t' =>
			result += "\\t";
		'\r' =>
			result += "\\r";
		* =>
			result[len result] = c;
		}
	}
	return result;
}

# Read entire file.
# Handles synthetic/9P files that report zero stat length by using
# incremental reads.
readfile(path: string): array of byte
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return nil;

	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;

	# Synthetic/9P files may report length 0; use incremental reads
	if(int d.length == 0){
		CHUNK: con 8192;
		buf := array[CHUNK] of byte;
		total := 0;
		for(;;){
			if(total >= len buf){
				nb := array[len buf * 2] of byte;
				nb[0:] = buf;
				buf = nb;
			}
			n := sys->read(fd, buf[total:], len buf - total);
			if(n <= 0)
				break;
			total += n;
		}
		if(total == 0)
			return nil;
		return buf[0:total];
	}

	data := array[int d.length] of byte;
	n := sys->read(fd, data, len data);
	if(n < 0)
		return nil;

	return data[0:n];
}

# Permit the private workspace or the most-specific explicit rw grant.
checkreadonly(path: string): string
{
	perr := validatepath(path);
	if(perr != nil)
		return "error: invalid path: " + perr;

	tmp := "/tmp/veltro/scratch";
	if(len path >= len tmp && path[0:len tmp] == tmp &&
	   (len path == len tmp || path[len tmp] == '/'))
		return nil;

	fd := sys->open("/tool/paths", Sys->OREAD);
	if(fd == nil)
		return "error: cannot verify writable path grants";
	buf := array[65536] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return "error: cannot read writable path grants";
	if(n == len buf)
		return "error: writable path grants exceed limit";
	raw := string buf[0:n];

	bestlen := -1;
	bestperm := "";
	i := 0;
	while(i < len raw) {
		j := i;
		while(j < len raw && raw[j] != '\n')
			j++;
		line := raw[i:j];
		i = j + 1;
		if(line == "")
			continue;

		sp := -1;
		for(k := len line - 1; k > 0; k--)
			if(line[k] == ' ') { sp = k; break; }
		if(sp < 0)
			continue;
		bpath := line[0:sp];
		perm := line[sp+1:];
		if((perm == "ro" || perm == "rw") && len bpath > bestlen &&
		   len path >= len bpath && path[0:len bpath] == bpath &&
		   (len path == len bpath || path[len bpath] == '/')) {
			bestlen = len bpath;
			bestperm = perm;
		}
	}
	if(bestperm == "rw")
		return nil;
	if(bestperm == "ro")
		return sys->sprint("error: %s is read-only", path);
	return sys->sprint("error: %s is not covered by an rw path grant", path);
}

# Reject path forms whose lexical spelling can escape a namespace grant.
validatepath(path: string): string
{
	if(path == nil || len path == 0)
		return "empty path";
	if(path[0] != '/')
		return "path must be absolute";
	for(i := 0; i < len path; i++)
		if(path[i] == ' ' || path[i] == '\n' || path[i] == '\r' ||
		   path[i] == '\t' || path[i] == ',' || path[i] == '=')
			return "path contains control delimiter";
	start := 1;
	for(i = 1; i <= len path; i++) {
		if(i == len path || path[i] == '/') {
			comp := path[start:i];
			if(comp == "")
				return "empty path component";
			if(comp == "." || comp == "..")
				return "dot path component";
			start = i + 1;
		}
	}
	return nil;
}
