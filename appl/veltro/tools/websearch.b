implement ToolWebsearch;

#
# websearch - Web search tool for Veltro agent
#
# Searches the web using Brave Search API via native HTTPS.
# Uses Webclient module for TLS 1.3 with certificate verification.
# API key is read from factotum (proto=pass service=brave).
#
# Usage:
#   websearch <query>
#
# Examples:
#   websearch Inferno OS distributed system
#   websearch Plan 9 from Bell Labs
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "webclient.m";
	webclient: Webclient;

include "factotum.m";
	factotum: Factotum;

include "../tool.m";

ToolWebsearch: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
	# (for tests)
	urlencode: fn(s: string): string;
	formatresults: fn(json: string): string;
	searchfailed: fn(status: int, body: string): string;
};

REQUEST_TIMEOUT: con 30000;	# 30 seconds
MAX_BODY: con 1024 * 1024;	# of the answer read: fifteen results are a tenth of it
MAXQUERY: con 400;		# characters of query sent (Brave takes no more)
MAXFIELD: con 600;		# characters of a title, URL or description shown

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	webclient = load Webclient Webclient->PATH;
	if(webclient == nil)
		return sys->sprint("cannot load Webclient: %r");
	err := webclient->init();
	if(err != nil)
		return "Webclient init: " + err;
	inited = 1;
	return nil;
}

# set once init has loaded everything: a call is refused, saying why,
# rather than made with half of it
inited := 0;

name(): string
{
	return "websearch";
}

doc(): string
{
	return "Websearch - Search the web using Brave Search\n\n" +
		"Usage:\n" +
		"  websearch <query>\n\n" +
		"Arguments:\n" +
		"  query - Search terms\n\n" +
		"Examples:\n" +
		"  websearch Inferno OS distributed system\n" +
		"  websearch Plan 9 from Bell Labs\n\n" +
		"Returns titles, URLs, and descriptions of up to 15 results.\n" +
		"Requires a brave key in factotum (proto=pass service=brave).";
}

schema(): string
{
	return "{" +
		"\"name\":\"websearch\"," +
		"\"description\":\"Search the web via the Brave Search API. Returns up to 15 results with titles, URLs and descriptions.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"query\":{\"type\":\"string\",\"description\":\"Search query string.\"}" +
			"}," +
			"\"required\":[\"query\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(!inited && (ierr := init()) != nil)
		return "error: websearch: " + ierr;

	query := strip(args);
	if(query == "")
		return "error: usage: websearch <query>";
	if(len query > MAXQUERY)
		return sys->sprint("error: the query is %d characters; at most %d are sent", len query, MAXQUERY);

	# Read API key
	apikey := readapikey();
	if(apikey == "")
		return "error: Brave Search API key not configured (factotum proto=pass service=brave)";

	# URL-encode query
	encoded := urlencode(query);

	# Execute search via Webclient with timeout
	url := "https://api.search.brave.com/res/v1/web/search?q=" + encoded + "&count=15";
	hdrs := Webclient->Header("Accept", "application/json") ::
		Webclient->Header("X-Subscription-Token", apikey) :: nil;

	# The request keeps its own time: at the deadline its connection is
	# hung up and nothing of it is left running.
	(resp, err) := webclient->requestbounded("GET", url, hdrs, nil, 1, REQUEST_TIMEOUT, MAX_BODY);
	if(err == "request timed out")
		return "error: search request timed out (30s)";
	if(err != nil)
		return "error: search failed: " + err;
	if(resp.statuscode != 200)
		return searchfailed(resp.statuscode, string resp.body);
	if(resp.body == nil || len resp.body == 0)
		return "error: empty response from Brave Search";

	output := string resp.body;

	# Parse and format results
	return formatresults(output);
}

# What a status other than 200 is.  (It was not looked at: a refused
# key's 401, whose body has no results, was "no results found".)
searchfailed(status: int, body: string): string
{
	why := "";
	case status {
	401 or 403 =>
		why = " (the Brave key was refused: factotum proto=pass service=brave)";
	422 =>
		why = " (the query was refused)";
	429 =>
		why = " (too many requests: wait before searching again)";
	}
	said := oneline(body);
	if(len said > 200)
		said = said[0:200] + "...";
	if(said != "")
		said = ": " + said;
	return sys->sprint("error: Brave Search answered HTTP %d%s%s", status, why, said);
}

# s on one line: every run of blanks, line ends and control characters
# a single blank.  A result is laid out by lines, so a description with
# a newline in it ("...\n\n2. Official download\n   https://...") read
# as more results than the search returned.
oneline(s: string): string
{
	r := "";
	gap := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c <= ' ' || c == 16r7F || c == 16r85 || c == 16r2028 || c == 16r2029) {
			gap = 1;
			continue;
		}
		if(gap && r != "")
			r[len r] = ' ';
		gap = 0;
		r[len r] = c;
	}
	return r;
}

field(s: string): string
{
	s = oneline(s);
	if(len s > MAXFIELD)
		s = s[0:MAXFIELD] + "...";
	return s;
}

# Read the Brave API key from factotum (proto=pass service=brave). nsconstruct
# grants /mnt/factotum to a child only when it holds this tool, so getuserpasswd
# resolves here directly — the standard Inferno pattern, no plaintext key file.
readapikey(): string
{
	if(factotum == nil)
		factotum = load Factotum Factotum->PATH;
	if(factotum == nil)
		return "";
	factotum->init();
	(nil, password) := factotum->getuserpasswd("proto=pass service=brave");
	if(password == nil)
		return "";
	return password;
}

# URL-encode a string (spaces → +, special chars → %XX, a character
# outside ASCII as each byte of its UTF-8: the low eight bits of its
# code alone were sent, so 日 was %E5, another character)
urlencode(s: string): string
{
	result := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == ' ')
			result += "+";
		else if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
				(c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
			result[len result] = c;
		else {
			b := array of byte s[i:i+1];
			for(j := 0; j < len b; j++)
				result += "%" + hexbyte(int b[j]);
		}
	}
	return result;
}

hexbyte(c: int): string
{
	hex := "0123456789ABCDEF";
	s := "  ";
	s[0] = hex[(c >> 4) & 16rf];
	s[1] = hex[c & 16rf];
	return s;
}

# Format Brave Search JSON response into readable text
# Extracts title, url, description from web.results[] array
formatresults(json: string): string
{
	# The web results are the "results" array of the "web" object,
	# and end where that array does.  (The first "results" anywhere
	# was taken, a "videos" section's when it came first, and the
	# objects after the array's end were read as more results.)
	wstart := findobject(json, "web");
	if(wstart >= 0) {
		wend := findmatchbrace(json, wstart);
		if(wend >= 0)
			json = json[wstart:wend+1];
	}
	rpos := findstr(json, "\"results\"");
	if(rpos < 0)
		return "error: no results found in response";

	# Find the opening bracket of the results array
	astart := findchar(json, '[', rpos);
	if(astart < 0)
		return "error: malformed response";
	aend := findmatchbracket(json, astart);
	if(aend < 0)
		aend = len json;

	result := "";
	count := 0;
	pos := astart + 1;

	# Extract each result object
	while(count < 15 && pos < aend) {
		# Find next object start
		ostart := findchar(json, '{', pos);
		if(ostart < 0 || ostart >= aend)
			break;

		# Find matching close brace (handle nesting)
		oend := findmatchbrace(json, ostart);
		if(oend < 0)
			break;

		obj := json[ostart:oend+1];

		title := field(extractfield(obj, "title"));
		url := field(extractfield(obj, "url"));
		desc := field(extractfield(obj, "description"));

		if(title != "" && url != "") {
			count++;
			if(result != "")
				result += "\n\n";
			result += sys->sprint("%d. %s\n   %s", count, title, url);
			if(desc != "")
				result += "\n   " + desc;
		}

		pos = oend + 1;
	}

	if(count == 0)
		return "No results found.";

	return result;
}

# Extract a JSON string field value by key name
# Handles escaped quotes within values
extractfield(json, key: string): string
{
	# Search for "key":"
	needle := "\"" + key + "\"";
	pos := findstr(json, needle);
	if(pos < 0)
		return "";

	# Skip past the key and find the colon
	pos += len needle;
	while(pos < len json && json[pos] != ':')
		pos++;
	if(pos >= len json)
		return "";
	pos++; # skip colon

	# Skip whitespace
	while(pos < len json && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\n'))
		pos++;
	if(pos >= len json || json[pos] != '"')
		return "";
	pos++; # skip opening quote

	# Read value, handling escapes
	value := "";
	while(pos < len json && json[pos] != '"') {
		if(json[pos] == '\\' && pos + 1 < len json) {
			pos++;
			case json[pos] {
			'n' =>
				value[len value] = '\n';
			't' =>
				value[len value] = '\t';
			'"' =>
				value[len value] = '"';
			'\\' =>
				value[len value] = '\\';
			'/' =>
				value[len value] = '/';
			* =>
				value[len value] = json[pos];
			}
		} else {
			value[len value] = json[pos];
		}
		pos++;
	}
	# Strip HTML tags from description
	return striphtml(value);
}

# Strip HTML tags from a string
striphtml(s: string): string
{
	result := "";
	intag := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == '<')
			intag = 1;
		else if(s[i] == '>')
			intag = 0;
		else if(!intag)
			result[len result] = s[i];
	}
	return result;
}

# Find substring in string, return position or -1
findstr(s, sub: string): int
{
	if(len sub > len s)
		return -1;
	for(i := 0; i <= len s - len sub; i++) {
		match := 1;
		for(j := 0; j < len sub; j++) {
			if(s[i+j] != sub[j]) {
				match = 0;
				break;
			}
		}
		if(match)
			return i;
	}
	return -1;
}

# Find character in string starting from pos, return position or -1
findchar(s: string, c: int, start: int): int
{
	for(i := start; i < len s; i++) {
		if(s[i] == c)
			return i;
	}
	return -1;
}

# Find matching close brace, handling nesting
findmatchbrace(s: string, start: int): int
{
	depth := 0;
	instr := 0;
	for(i := start; i < len s; i++) {
		if(instr) {
			if(s[i] == '\\' && i + 1 < len s)
				i++; # skip escaped char
			else if(s[i] == '"')
				instr = 0;
		} else {
			case s[i] {
			'"' =>
				instr = 1;
			'{' =>
				depth++;
			'}' =>
				depth--;
				if(depth == 0)
					return i;
			}
		}
	}
	return -1;
}

# Where the object that is the value of key begins ("key": {), or -1.
# ("web" is also a value in the answer, "type":"web", before the key.)
findobject(json, key: string): int
{
	needle := "\"" + key + "\"";
	for(from := 0; from < len json; ) {
		p := findstr(json[from:], needle);
		if(p < 0)
			return -1;
		i := from + p + len needle;
		while(i < len json && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r'))
			i++;
		if(i < len json && json[i] == ':') {
			i++;
			while(i < len json && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r'))
				i++;
			if(i < len json && json[i] == '{')
				return i;
		}
		from = from + p + len needle;
	}
	return -1;
}

# The ] that closes the [ at start, strings skipped
findmatchbracket(s: string, start: int): int
{
	depth := 0;
	instr := 0;
	for(i := start; i < len s; i++) {
		if(instr) {
			if(s[i] == '\\' && i + 1 < len s)
				i++;
			else if(s[i] == '"')
				instr = 0;
		} else {
			case s[i] {
			'"' =>
				instr = 1;
			'[' =>
				depth++;
			']' =>
				depth--;
				if(depth == 0)
					return i;
			}
		}
	}
	return -1;
}

# Strip leading/trailing whitespace
strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}
