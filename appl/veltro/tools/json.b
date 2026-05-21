implement ToolJson;

#
# json - JSON query tool for Veltro agent
#
# Query JSON data using simple path expressions. Pure Limbo implementation
# with basic JSON parsing.
#
# Usage:
#   json <file> <path>              # Query file
#   json -d '<data>' <path>         # Query inline data
#
# Path syntax:
#   .key              Access object key
#   [N]               Access array index (0-indexed)
#   .key1.key2        Chain access
#   .key[0].name      Mixed access
#
# Examples:
#   json /tmp/data.json .name
#   json /tmp/data.json .users[0].email
#   json -d '{"x":1}' .x
#
# Output:
#   Returns the extracted value as a string.
#   For objects/arrays, returns JSON representation.
#

include "sys.m";
	sys: Sys;

include "draw.m";


include "string.m";
	str: String;

include "../tool.m";

ToolJson: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

# JSON value types
JNULL, JBOOL, JNUM, JSTR, JARR, JOBJ: con iota;

# JSON value
JValue: adt {
	typ:    int;
	num:    real;
	str:    string;
	bool:   int;
	arr:    list of ref JValue;
	obj:    list of (string, ref JValue);
};

# Parser state
JParser: adt {
	data: string;
	pos:  int;
};

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string
{
	return "json";
}

doc(): string
{
	return "Json - Query JSON data\n\n" +
		"Usage:\n" +
		"  json <file> <path>      # Query file\n" +
		"  json -d '<data>' <path> # Query inline data\n\n" +
		"Path Syntax:\n" +
		"  .key        - Access object key\n" +
		"  [N]         - Access array index (0-indexed)\n" +
		"  .key1.key2  - Chain access\n" +
		"  .key[0]     - Mixed access\n\n" +
		"Examples:\n" +
		"  json /tmp/data.json .name\n" +
		"  json /tmp/data.json .users[0].email\n" +
		"  json -d '{\"x\":1}' .x\n\n" +
		"Returns the extracted value or error message.";
}

schema(): string
{
	return "{" +
		"\"name\":\"json\"," +
		"\"description\":\"Query JSON data using a dot/bracket path expression. .key for object keys, [N] for array indices, chain freely (.users[0].email).\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"source\":{\"type\":\"string\",\"description\":\"Either a file path containing JSON, or '-d' followed by a single-quoted inline JSON literal.\"}," +
				"\"path\":{\"type\":\"string\",\"description\":\"Query path, e.g. .name or .users[0].email.\"}" +
			"}," +
			"\"required\":[\"source\",\"path\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	# Parse arguments
	args = strip(args);
	if(args == "")
		return "error: usage: json <file> <path> | json -d '<data>' <path>";

	data: string;
	path: string;

	# Check for -d flag (inline data)
	if(len args > 3 && args[0:3] == "-d ") {
		# Extract quoted data and path
		rest := strip(args[3:]);
		(data, path) = extractquoted(rest);
		if(data == "")
			return "error: usage: json -d '<data>' <path>";
		path = strip(path);
	} else {
		# File path and query path
		(n, argv) := sys->tokenize(args, " \t");
		if(n < 2)
			return "error: usage: json <file> <path>";

		file := hd argv;
		path = hd tl argv;

		# Read file
		err: string;
		(data, err) = readfile(file);
		if(err != nil)
			return "error: " + err;
	}

	# Parse JSON
	p := ref JParser(data, 0);
	(val, perr) := parsevalue(p);
	if(perr != nil)
		return "error: JSON parse error: " + perr;

	# Query with path
	(result, qerr) := query(val, path);
	if(qerr != nil)
		return "error: " + qerr;

	return stringify(result);
}

# Read file contents
readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return ("", sys->sprint("cannot open %s: %r", path));

	# Read entire file (up to reasonable limit)
	content := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		content += string buf[0:n];
	}

	return (content, nil);
}

# Extract quoted string and remainder
extractquoted(s: string): (string, string)
{
	if(len s == 0)
		return ("", "");

	quote := s[0];
	if(quote != '\'' && quote != '"')
		return ("", "");

	# Find closing quote
	for(i := 1; i < len s; i++) {
		if(s[i] == quote) {
			return (s[1:i], s[i+1:]);
		}
		if(s[i] == '\\' && i+1 < len s)
			i++;  # Skip escaped char
	}

	return ("", "");  # No closing quote
}

# JSON Parser

parsevalue(p: ref JParser): (ref JValue, string)
{
	skipws(p);
	if(p.pos >= len p.data)
		return (nil, "unexpected end of input");

	c := p.data[p.pos];

	case c {
	'n' =>
		return parsenull(p);
	't' or 'f' =>
		return parsebool(p);
	'"' =>
		return parsestring(p);
	'[' =>
		return parsearray(p);
	'{' =>
		return parseobject(p);
	'-' or '0' to '9' =>
		return parsenumber(p);
	}

	return (nil, sys->sprint("unexpected character '%c' at position %d", c, p.pos));
}

parsenull(p: ref JParser): (ref JValue, string)
{
	if(p.pos + 4 <= len p.data && p.data[p.pos:p.pos+4] == "null") {
		p.pos += 4;
		return (ref JValue(JNULL, 0.0, "", 0, nil, nil), nil);
	}
	return (nil, "expected 'null'");
}

parsebool(p: ref JParser): (ref JValue, string)
{
	if(p.pos + 4 <= len p.data && p.data[p.pos:p.pos+4] == "true") {
		p.pos += 4;
		return (ref JValue(JBOOL, 0.0, "", 1, nil, nil), nil);
	}
	if(p.pos + 5 <= len p.data && p.data[p.pos:p.pos+5] == "false") {
		p.pos += 5;
		return (ref JValue(JBOOL, 0.0, "", 0, nil, nil), nil);
	}
	return (nil, "expected 'true' or 'false'");
}

parsenumber(p: ref JParser): (ref JValue, string)
{
	start := p.pos;

	# Optional minus
	if(p.pos < len p.data && p.data[p.pos] == '-')
		p.pos++;

	# Integer part
	if(p.pos >= len p.data)
		return (nil, "unexpected end in number");

	if(p.data[p.pos] == '0') {
		p.pos++;
	} else if(p.data[p.pos] >= '1' && p.data[p.pos] <= '9') {
		while(p.pos < len p.data && p.data[p.pos] >= '0' && p.data[p.pos] <= '9')
			p.pos++;
	} else {
		return (nil, "invalid number");
	}

	# Fractional part
	if(p.pos < len p.data && p.data[p.pos] == '.') {
		p.pos++;
		if(p.pos >= len p.data || p.data[p.pos] < '0' || p.data[p.pos] > '9')
			return (nil, "invalid number after decimal");
		while(p.pos < len p.data && p.data[p.pos] >= '0' && p.data[p.pos] <= '9')
			p.pos++;
	}

	# Exponent
	if(p.pos < len p.data && (p.data[p.pos] == 'e' || p.data[p.pos] == 'E')) {
		p.pos++;
		if(p.pos < len p.data && (p.data[p.pos] == '+' || p.data[p.pos] == '-'))
			p.pos++;
		if(p.pos >= len p.data || p.data[p.pos] < '0' || p.data[p.pos] > '9')
			return (nil, "invalid exponent");
		while(p.pos < len p.data && p.data[p.pos] >= '0' && p.data[p.pos] <= '9')
			p.pos++;
	}

	numstr := p.data[start:p.pos];
	num := real numstr;

	return (ref JValue(JNUM, num, numstr, 0, nil, nil), nil);
}

parsestring(p: ref JParser): (ref JValue, string)
{
	if(p.data[p.pos] != '"')
		return (nil, "expected '\"'");
	p.pos++;

	result := "";
	for(; p.pos < len p.data; p.pos++) {
		c := p.data[p.pos];
		if(c == '"') {
			p.pos++;
			return (ref JValue(JSTR, 0.0, result, 0, nil, nil), nil);
		}
		if(c == '\\') {
			p.pos++;
			if(p.pos >= len p.data)
				return (nil, "unexpected end in string escape");
			esc := p.data[p.pos];
			case esc {
			'"' or '\\' or '/' =>
				result[len result] = esc;
			'n' =>
				result[len result] = '\n';
			'r' =>
				result[len result] = '\r';
			't' =>
				result[len result] = '\t';
			'b' =>
				result[len result] = '\b';
			'f' =>
				result[len result] = '\f';
			'u' =>
				# Unicode escape - simplified handling
				if(p.pos + 4 >= len p.data)
					return (nil, "invalid unicode escape");
				# Just include as-is for now
				result += "\\u" + p.data[p.pos+1:p.pos+5];
				p.pos += 4;
			* =>
				return (nil, sys->sprint("invalid escape '\\%c'", esc));
			}
		} else {
			result[len result] = c;
		}
	}

	return (nil, "unterminated string");
}

parsearray(p: ref JParser): (ref JValue, string)
{
	if(p.data[p.pos] != '[')
		return (nil, "expected '['");
	p.pos++;

	arr: list of ref JValue;

	skipws(p);
	if(p.pos < len p.data && p.data[p.pos] == ']') {
		p.pos++;
		return (ref JValue(JARR, 0.0, "", 0, nil, nil), nil);
	}

	for(;;) {
		(val, err) := parsevalue(p);
		if(err != nil)
			return (nil, err);
		arr = val :: arr;

		skipws(p);
		if(p.pos >= len p.data)
			return (nil, "unexpected end in array");

		if(p.data[p.pos] == ']') {
			p.pos++;
			# Reverse list
			rev: list of ref JValue;
			for(; arr != nil; arr = tl arr)
				rev = hd arr :: rev;
			return (ref JValue(JARR, 0.0, "", 0, rev, nil), nil);
		}

		if(p.data[p.pos] != ',')
			return (nil, "expected ',' or ']' in array");
		p.pos++;
		skipws(p);
	}
}

parseobject(p: ref JParser): (ref JValue, string)
{
	if(p.data[p.pos] != '{')
		return (nil, "expected '{'");
	p.pos++;

	obj: list of (string, ref JValue);

	skipws(p);
	if(p.pos < len p.data && p.data[p.pos] == '}') {
		p.pos++;
		return (ref JValue(JOBJ, 0.0, "", 0, nil, nil), nil);
	}

	for(;;) {
		skipws(p);
		if(p.pos >= len p.data || p.data[p.pos] != '"')
			return (nil, "expected string key in object");

		(keyval, kerr) := parsestring(p);
		if(kerr != nil)
			return (nil, kerr);
		key := keyval.str;

		skipws(p);
		if(p.pos >= len p.data || p.data[p.pos] != ':')
			return (nil, "expected ':' after key");
		p.pos++;

		(val, verr) := parsevalue(p);
		if(verr != nil)
			return (nil, verr);

		obj = (key, val) :: obj;

		skipws(p);
		if(p.pos >= len p.data)
			return (nil, "unexpected end in object");

		if(p.data[p.pos] == '}') {
			p.pos++;
			# Reverse list
			rev: list of (string, ref JValue);
			for(; obj != nil; obj = tl obj)
				rev = hd obj :: rev;
			return (ref JValue(JOBJ, 0.0, "", 0, nil, rev), nil);
		}

		if(p.data[p.pos] != ',')
			return (nil, "expected ',' or '}' in object");
		p.pos++;
	}
}

skipws(p: ref JParser)
{
	while(p.pos < len p.data) {
		c := p.data[p.pos];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r')
			p.pos++;
		else
			break;
	}
}

# Query JSON value with path

query(val: ref JValue, path: string): (ref JValue, string)
{
	if(val == nil)
		return (nil, "null value");

	path = strip(path);
	if(path == "" || path == ".")
		return (val, nil);

	# Parse path components
	i := 0;
	current := val;

	while(i < len path && current != nil) {
		if(path[i] == '.') {
			i++;
			if(i >= len path)
				return (current, nil);

			# Extract key name
			start := i;
			while(i < len path && path[i] != '.' && path[i] != '[')
				i++;
			key := path[start:i];

			if(current.typ != JOBJ)
				return (nil, sys->sprint("cannot access .%s on non-object", key));

			# Find key in object
			found := 0;
			for(o := current.obj; o != nil; o = tl o) {
				(k, v) := hd o;
				if(k == key) {
					current = v;
					found = 1;
					break;
				}
			}
			if(!found)
				return (nil, sys->sprint("key '%s' not found", key));

		} else if(path[i] == '[') {
			i++;
			# Extract index
			start := i;
			while(i < len path && path[i] >= '0' && path[i] <= '9')
				i++;
			if(i == start || i >= len path || path[i] != ']')
				return (nil, "invalid array index syntax");

			idx := int path[start:i];
			i++;  # Skip ']'

			if(current.typ != JARR)
				return (nil, "cannot index non-array");

			# Find element at index
			j := 0;
			for(a := current.arr; a != nil; a = tl a) {
				if(j == idx) {
					current = hd a;
					break;
				}
				j++;
			}
			if(j < idx)
				return (nil, sys->sprint("index %d out of range", idx));

		} else {
			return (nil, sys->sprint("unexpected character '%c' in path", path[i]));
		}
	}

	return (current, nil);
}

# Stringify JSON value

stringify(val: ref JValue): string
{
	if(val == nil)
		return "null";

	case val.typ {
	JNULL =>
		return "null";
	JBOOL =>
		if(val.bool)
			return "true";
		return "false";
	JNUM =>
		# Use original string if available
		if(val.str != "")
			return val.str;
		return sys->sprint("%g", val.num);
	JSTR =>
		return "\"" + escape(val.str) + "\"";
	JARR =>
		result := "[";
		first := 1;
		for(a := val.arr; a != nil; a = tl a) {
			if(!first)
				result += ", ";
			first = 0;
			result += stringify(hd a);
		}
		return result + "]";
	JOBJ =>
		result := "{";
		first := 1;
		for(o := val.obj; o != nil; o = tl o) {
			(k, v) := hd o;
			if(!first)
				result += ", ";
			first = 0;
			result += "\"" + escape(k) + "\": " + stringify(v);
		}
		return result + "}";
	}

	return "null";
}

escape(s: string): string
{
	result := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		case c {
		'"' =>
			result += "\\\"";
		'\\' =>
			result += "\\\\";
		'\n' =>
			result += "\\n";
		'\r' =>
			result += "\\r";
		'\t' =>
			result += "\\t";
		* =>
			result[len result] = c;
		}
	}
	return result;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}
