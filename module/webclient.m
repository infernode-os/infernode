#
# HTTPS/HTTP client module
#
Webclient: module {
	PATH: con "/dis/lib/webclient.dis";

	init: fn(): string;

	MAXBODY: con 64*1024*1024;	# a whole page's worth, images included

	Header: adt {
		name:	string;
		value:	string;
	};

	Response: adt {
		statuscode:	int;
		status:		string;
		headers:	list of Header;
		body:		array of byte;
		url:		string;		# the URL that answered, after redirects

		hdrval:	fn(r: self ref Response, name: string): string;
	};

	# An HTTP state store (RFC 6265): cookies set by responses, sent
	# with the requests they match.  One jar is one browsing session.
	Cookie: adt {
		name, value:	string;
		domain, path:	string;	# domain lower case, without a leading dot
		hostonly:	int;		# no Domain attribute: this host only
		expires:	int;		# seconds since the epoch; 0: the session
		secure, httponly:	int;
	};

	Jar: adt {
		cookies:	list of ref Cookie;
		lk:	chan of int;	# fetches share a jar: one at a time

		new:	fn(): ref Jar;
		header:	fn(j: self ref Jar, url: string): string;	# a Cookie: value, or nil
		set:	fn(j: self ref Jar, url, setcookie: string);	# from a Set-Cookie: value
		text:	fn(j: self ref Jar): string;	# one cookie per line (see add)
		add:	fn(j: self ref Jar, line: string): string;	# "domain path name=value expires secure httponly hostonly"
		clear:	fn(j: self ref Jar);
	};

	request:	fn(method, url: string, hdrs: list of Header,
			   body: array of byte): (ref Response, string);
	# Resolve and dial only validated public IPv4 destinations. Revalidates every
	# redirect and strips credential headers when the origin changes.
	requestpublic: fn(method, url: string, hdrs: list of Header,
			   body: array of byte): (ref Response, string);
	# request, keeping cookies in jar across redirects, and decoding a
	# gzip or deflate Content-Encoding (asked for by the caller's
	# Accept-Encoding header)
	requestjar:	fn(method, url: string, hdrs: list of Header,
			   body: array of byte, jar: ref Jar): (ref Response, string);
	# requestjar, reading a successful response's body only if its
	# Content-Type is one of types: an entry ending in / is a prefix
	# (text/), one beginning with + a suffix (+xml), any other the type
	# itself; a response with no Content-Type is any.  A body not read
	# is nil, and the connection is closed rather than kept.  No types:
	# every body is read.
	requesttypes:	fn(method, url: string, hdrs: list of Header,
			   body: array of byte, jar: ref Jar, types: list of string): (ref Response, string);
	get:		fn(url: string): (ref Response, string);
	post:		fn(url, contenttype: string,
			   body: array of byte): (ref Response, string);

	# TLS-integrated dial: connect TCP + TLS handshake
	tlsdial:	fn(addr, servername: string): (ref Sys->FD, string);
	# TLS on a connection already open (STARTTLS); fd is not to be used after
	tlsclient:	fn(fd: ref Sys->FD, servername: string): (ref Sys->FD, string);
};
