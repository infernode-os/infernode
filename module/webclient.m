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
		truncated:	int;		# the body is its first bytes: it was longer than the caller's limit (or MAXBODY)

		hdrval:	fn(r: self ref Response, name: string): string;
	};

	# An HTTP state store (RFC 6265): cookies set by responses, sent
	# with the requests they match.  One jar is one browsing session.
	# set() takes what RFC 6265 §5.3 and its revision (6265bis) let a
	# response set: no control characters; a Domain the host is, or
	# ends in, that is not a name sites are registered under (one
	# label; co.uk, com.au and their like; a short list of others and
	# of hosting services: there is no Public Suffix List here, so a
	# registry not among them is not known for one); no Secure cookie
	# from a URL that is not https, and none that would replace or
	# shadow one; __Secure- and __Host- names as they promise.  A
	# Secure cookie is in header() only for an https URL.
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
	# request (public: requestpublic) for a caller that will not wait for
	# ever or take whatever comes: the whole exchange, redirects and body
	# included, is over within ms milliseconds, and no more than maxbody
	# bytes of body are kept (Response.truncated says when there were
	# more).  At the deadline the answer is "request timed out" and the
	# connection is hung up, so nothing goes on behind the caller's back.
	# ms 0: no deadline; maxbody 0: MAXBODY.
	requestbounded: fn(method, url: string, hdrs: list of Header,
			   body: array of byte, public, ms, maxbody: int): (ref Response, string);
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

	# TLS-integrated dial: connect TCP + TLS handshake.  The fd is one
	# end of a pipe carried to and from the connection.  When the
	# server closes, or the connection fails, a read of it returns 0;
	# after the next write, reads return 0 and writes fail as on a
	# closed pipe.  Dropping the fd closes the connection.
	tlsdial:	fn(addr, servername: string): (ref Sys->FD, string);
	# TLS on a connection already open (STARTTLS); fd is not to be used after
	tlsclient:	fn(fd: ref Sys->FD, servername: string): (ref Sys->FD, string);
};
