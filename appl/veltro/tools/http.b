implement ToolHttp;

#
# http - HTTP client tool for Veltro agent
#
# Performs HTTP requests and returns response body.
# Uses Webclient module for HTTP/HTTPS with native TLS 1.3.
# DNS resolution via Inferno's connection server.
#
# Usage:
#   http GET <url>                    # GET request
#   http POST <url> <body>            # POST request
#   http PUT <url> <body>             # PUT request
#   http PATCH <url> <body>           # PATCH request
#   http DELETE <url>                 # DELETE request
#   http HEAD <url>                   # HEAD request (status and headers only)
#
# Examples:
#   http GET http://example.com/api
#   http GET https://api.github.com/
#   http POST http://localhost:8080/data '{"key": "value"}'
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "publicnet.m";
	publicnet: Publicnet;

include "webclient.m";
	webclient: Webclient;

include "../tool.m";

ToolHttp: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

REQUEST_TIMEOUT: con 30000;	# 30 seconds, redirects and body included
# The most of a response that is read: what is returned goes into a
# model's context, and this is already more than one holds (webfetch and
# payfetch read as much).
MAX_BODY: con 512 * 1024;

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
		return "cannot load Webclient";
	err := webclient->init();
	if(err != nil)
		return "Webclient init: " + err;
	publicnet = load Publicnet Publicnet->PATH;
	if(publicnet == nil)
		return "cannot load Publicnet";
	publicnet->init();
	inited = 1;
	return nil;
}

# set once init has loaded everything: a call is refused, saying why,
# rather than made with half of it
inited := 0;

name(): string
{
	return "http";
}

doc(): string
{
	return "Http - HTTP/HTTPS client\n\n" +
		"Usage:\n" +
		"  http GET <url>              # GET request\n" +
		"  http POST <url> <body>      # POST request\n" +
		"  http PUT <url> <body>       # PUT request\n" +
		"  http PATCH <url> <body>     # PATCH request\n" +
		"  http DELETE <url>           # DELETE request\n" +
		"  http HEAD <url>             # HEAD request: the status line, then the headers\n\n" +
		"Arguments:\n" +
		"  url  - Full URL (http:// or https://)\n" +
		"  body - Request body (for POST/PUT/PATCH), sent as written\n\n" +
		"Examples:\n" +
		"  http GET http://example.com/api\n" +
		"  http GET https://api.github.com/\n" +
		"  http POST http://localhost:8080/data '{\"key\": \"value\"}'\n\n" +
		"HTTP and HTTPS use native TLS 1.3 with certificate verification.\n" +
		"Hostnames are resolved via Inferno's connection server.\n" +
		"Only public addresses are reached. A request is given 30 seconds,\n" +
		"and only the first 512KB of a response is read (the result says\n" +
		"when there was more). A status of 400 or above is reported as\n" +
		"\"error: HTTP <status>\" followed by the response.";
}

schema(): string
{
	return "{" +
		"\"name\":\"http\"," +
		"\"description\":\"Make an HTTP/HTTPS request. TLS 1.3 with certificate verification.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"method\":{\"type\":\"string\",\"description\":\"HTTP method: GET, POST, PUT, PATCH, DELETE, HEAD.\"}," +
				"\"url\":{\"type\":\"string\",\"description\":\"Full URL including scheme, e.g. https://api.example.com/v1/x.\"}," +
				"\"body\":{\"type\":\"string\",\"description\":\"Request body. Required for POST/PUT/PATCH; omit otherwise.\"}" +
			"}," +
			"\"required\":[\"method\",\"url\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(!inited && (ierr := init()) != nil)
		return "error: http: " + ierr;

	# Parse arguments
	(n, argv) := sys->tokenize(args, " \t");
	if(n < 2)
		return "error: usage: http <METHOD> <url> [body]";

	method := str->toupper(hd argv);
	argv = tl argv;
	url := hd argv;
	argv = tl argv;

	# The body is the rest of the arguments as written.  (It was the
	# rest's words joined by single blanks: what was sent was not what
	# was asked for wherever the body had two blanks, a tab or a newline.)
	body := "";
	if(argv != nil)
		body = stripquotes(restafter(args, 2));

	# Validate method
	case method {
	"GET" or "POST" or "PUT" or "DELETE" or "HEAD" or "PATCH" =>
		;
	* =>
		return "error: unsupported HTTP method: " + method;
	}

	# Validate URL scheme
	lurl := str->tolower(url);
	if(!hasprefix(lurl, "http://") && !hasprefix(lurl, "https://"))
		return "error: invalid URL: must start with http:// or https://";

	# SSRF protection: block requests to internal/private network addresses
	host := extracthost(url);
	if(isblocked(host))
		return "error: requests to internal/private network addresses are not allowed";

	# Build headers
	hdrs: list of Webclient->Header;
	hdrs = Webclient->Header("User-Agent", "Veltro/1.0") :: hdrs;
	if(body != "")
		hdrs = Webclient->Header("Content-Type", "application/json") :: hdrs;

	# Build request body
	reqbody: array of byte;
	if(body != "")
		reqbody = array of byte body;

	# Execute request.  It keeps its own time and limit: there was no
	# deadline here at all, so a server that accepted and said nothing
	# held the agent's turn until the user cancelled it.
	(resp, err) := webclient->requestbounded(method, url, hdrs, reqbody, 1, REQUEST_TIMEOUT, MAX_BODY);
	if(err == "request timed out")
		return "error: request timed out (30s)";
	if(err != nil)
		return "error: " + err;

	# For HEAD, the status line and the headers (the status was left
	# out: a 404 and a 200 read the same)
	if(method == "HEAD") {
		result := resp.status;
		for(h := resp.headers; h != nil; h = tl h) {
			hdr := hd h;
			result += "\n" + hdr.name + ": " + hdr.value;
		}
		if(resp.statuscode >= 400)
			return "error: " + result;
		return result;
	}

	text := string resp.body;
	if(resp.truncated)
		text += "\n[the response is longer: only its first 512KB were read]";

	# For error status, include status line
	if(resp.statuscode >= 400)
		return sys->sprint("error: HTTP %d\n%s", resp.statuscode, text);

	# A response that begins as a failed call does ("error:") is said to
	# be the response, so that it is not read as this tool failing.
	if(len text >= 6 && str->tolower(text[0:6]) == "error:")
		return sys->sprint("HTTP %d, the response:\n%s", resp.statuscode, text);
	return text;
}

# s after its first n words, less the blanks before it
restafter(s: string, n: int): string
{
	i := 0;
	for(; n > 0; n--) {
		while(i < len s && (s[i] == ' ' || s[i] == '\t'))
			i++;
		while(i < len s && s[i] != ' ' && s[i] != '\t')
			i++;
	}
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	return s[i:];
}

# Strip surrounding quotes
stripquotes(s: string): string
{
	if(len s < 2)
		return s;
	if((s[0] == '"' && s[len s - 1] == '"') ||
	   (s[0] == '\'' && s[len s - 1] == '\''))
		return s[1:len s - 1];
	return s;
}

# The URL host extractor and the SSRF blocklist live in publicnet,
# the same module that re-checks the address at dial time. Local
# copies of these two functions drifted apart across the fetch
# tools; there is now one definition.
extracthost(url: string): string
{
	return publicnet->urlhost(url);
}

isblocked(host: string): int
{
	return publicnet->hostblocked(host);
}

# Check if string has prefix
hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}
