implement Url;

include "sys.m";
	sys: Sys;

include "string.m";
	S: String;

include "url.m";

schemes = array[] of {
	NOSCHEME => "",
	HTTP => "http",
	HTTPS => "https",
	FTP => "ftp",
	FILE => "file",
	GOPHER => "gopher",
	MAILTO => "mailto",
	NEWS => "news",
	NNTP => "nntp",
	TELNET => "telnet",
	WAIS => "wais",
	PROSPERO => "prospero",
	JAVASCRIPT => "javascript",
	UNKNOWN => "unknown"
};

init()
{
	sys = load Sys Sys->PATH;
	S = load String String->PATH;
}

# To allow relative urls, only fill in specified pieces (don't apply defaults)
#  general syntax: <scheme>:<scheme-specific>
#  for IP schemes, <scheme-specific> is
#      //<user>:<passwd>@<host>:<port>/<path>?<query>#<fragment>
makeurl(surl: string): ref ParsedUrl
{
	scheme := NOSCHEME;
	user := "";
	passwd := "";
	host := "";
	port := "";
	pstart := "";
	path := "";
	query := "";
	frag := "";

	(sch, url) := split(surl, ":");
	if(url == "") {
		url = sch;
		sch = "";
	}
	else {
		(nil, x) := S->splitl(sch, "^-a-zA-Z0-9.+");
		if(x != nil) {
			url = surl;
			sch = "";
		}
		else {
			scheme = UNKNOWN;
			sch = S->tolower(sch);
			for(i := 0; i < len schemes; i++)
				if(schemes[i] == sch) {
					scheme = i;
					break;
				}
		}
	}
	if(scheme == MAILTO)
		path = url;
	else if (scheme == JAVASCRIPT)
		path = url;
	else {
		if(S->prefix("//", url)) {
			# the authority ends at the first / ? or # (RFC 3986
			# §3.2): https://example.com?q=1 is example.com's
			# path / with the query q=1
			netloc: string;
			(netloc, path) = S->splitl(url[2:], "/?#");
			if(path != "" && path[0] == '/')
				path = path[1:];
			pstart = "/";
			if(scheme == FILE)
				host = netloc;
			else {
				# A backslash is a slash to a browser and a letter
				# here: the two would name different hosts.
				for(k := 0; k < len netloc; k++)
					if(netloc[k] == '\\')
						return nil;
				# The name and password end at the last @, as a
				# browser and the check of where a URL may go
				# (publicnet's urlhost) both have it.  It was the
				# first, and http://a@b@c/ was the host "b@c".
				hp := netloc;
				for(k = len netloc - 1; k >= 0; k--)
					if(netloc[k] == '@'){
						(user, passwd) = split(netloc[0:k], ":");
						hp = netloc[k+1:];
						break;
					}
				if(hp != "" && hp[0] == '['){
					# an IPv6 address, in brackets because of its
					# colons: cut at the first of them, [::1]:8080 was
					# the host "[" and the port ":1]:8080"
					(host, port) = S->splitl(hp[1:], "]");
					if(port == "" || !v6ok(host))
						return nil;
					port = port[1:];
					if(port != ""){
						if(port[0] != ':')
							return nil;
						port = port[1:];
					}
				}else{
					(host, port) = split(hp, ":");
					if(!hostok(host))
						return nil;
				}
				if(!portok(port))
					return nil;
			}
		}
		else {
			if(S->prefix("/", url)) {
				pstart = "/";
				path = url[1:];
			}
			else
				path = url;
		}
		if(scheme == FILE) {
			if(host == "")
				host = "localhost";
		}
		else {
			(path, frag) = split(path, "#");
			(path, query) = split(path, "?");
		}
	}

	return ref ParsedUrl(scheme, 1, user, passwd, host, port, pstart, path, query, frag);
}

# A host is put into a dial string, a Host header and a question to the
# connection server by those who use this module.  One with a blank, a
# control character or dial's own separator in it is no host.
hostok(h: string): int
{
	for(i := 0; i < len h; i++){
		c := h[i];
		if(c <= ' ' || c == 16r7f || c == '!' || c == '[' || c == ']' || c == '@')
			return 0;
	}
	return 1;
}

# what was between an IPv6 address's brackets
v6ok(h: string): int
{
	if(h == "")
		return 0;
	for(i := 0; i < len h; i++){
		c := h[i];
		if(!(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F' || c == ':' || c == '.'))
			return 0;
	}
	return 1;
}

# a port is a number, or not given
portok(p: string): int
{
	if(len p > 5)
		return 0;
	for(i := 0; i < len p; i++)
		if(p[i] < '0' || p[i] > '9')
			return 0;
	return 1;
}

hascolon(h: string): int
{
	for(i := 0; i < len h; i++)
		if(h[i] == ':')
			return 1;
	return 0;
}

ParsedUrl.tostring(u: self ref ParsedUrl) : string
{
	if (u == nil)
		return nil;

	ans := "";
	if(u.scheme > 0 && u.scheme < len schemes)
		ans = schemes[u.scheme] + ":";
	if(u.host != "") {
		ans = ans + "//";
		if(u.user != "") {
			ans = ans + u.user;
			if(u.passwd != "")
				ans = ans + ":" + u.passwd;
			ans = ans + "@";
		}
		if(hascolon(u.host))
			ans = ans + "[" + u.host + "]";
		else
			ans = ans + u.host;
		if(u.port != "")
			ans = ans + ":" + u.port;
	}
	ans = ans + u.pstart + u.path;
	if(u.query != "")
		ans = ans + "?" + u.query;
	if(u.frag != "")
		ans = ans + "#" + u.frag;
	return ans;
}

ParsedUrl.makeabsolute(u: self ref ParsedUrl, b: ref ParsedUrl)
{
#	The following is correct according to RFC 1808, but is violated
#	by various extant web pages.

	if(u == nil || b == nil)
		return;
	if(u.scheme != NOSCHEME && u.scheme != HTTP)
		return;
	# "http:page" is taken as relative, for the pages that write it, but
	# only to a base that is http: against an https base it took the
	# base's host, port, name and password for a request in the clear.
	if(u.scheme != NOSCHEME && u.scheme != b.scheme)
		return;

	if(u.host == "" && u.path == "" && u.pstart == "" && u.query == "" && u.frag == "") {
		u.scheme = b.scheme;
		u.user = b.user;
		u.passwd = b.passwd;
		u.host = b.host;
		u.port = b.port;
		u.path = b.path;
		u.pstart = b.pstart;
		u.query = b.query;
		u.frag = b.frag;
		return;
	}
	if(u.scheme == NOSCHEME)
		u.scheme = b.scheme;
	if(u.host != "")
		return;
	u.user = b.user;
	u.passwd = b.passwd;
	u.host = b.host;
	u.port = b.port;
	if(u.pstart == "/")
		return;
	u.pstart = "/";
	if(u.path == "") {
		u.path = b.path;
		if(u.query == "")
			u.query = b.query;
	}
	else {
		(p1,nil) := S->splitr(b.path, "/");
		u.path = canonize(p1 + u.path);
	}
}

# Like splitl, but assume one char match, and omit that from second part.
# If c doesn't appear in s, the return is (s, "").
split(s, c: string) : (string, string)
{
	(a,b) := S->splitl(s, c);
	if(b != "")
		b = b[1:];
	return (a,b);
}

# remove ./ and ../ from s
canonize(s: string): string
{
	(base, file) := S->splitr(s, "/");
	# a last part that is . or .. is one of them too: it was added as it
	# stood, and "a/b/.." came out as "a/b/.."
	if(file == "." || file == ".."){
		base = s;
		file = "";
	}
	(nil, path) := sys->tokenize(base, "/");
	revpath : list of string = nil;
	for(p := path; p != nil; p = tl p) {
		if(hd p == "..") {
			if(revpath != nil)
				revpath = tl revpath;
		}
		else if(hd p != ".")
			revpath = (hd p) :: revpath;
	}
	while(revpath != nil && hd revpath == "..")
		revpath = tl revpath;
	ans := "";
	if(revpath != nil) {
		ans = hd revpath;
		revpath = tl revpath;
		while(revpath != nil) {
			ans = (hd revpath) + "/" + ans;
			revpath = tl revpath;
		}
	}
	if (ans != nil)
		ans += "/";
	ans += file;
	return ans;
}

