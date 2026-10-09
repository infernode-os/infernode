#
# charonfs.m - a browsing session as files, at /mnt/charon.
#
#	ctl	write: open <url> | back | forward | reload | stop |
#		  follow <n> | click <node> | set <node> <value> |
#		  submit <form> [<node>] | size <w>x<h> | width <w> | scroll <y> |
#		  images on|click | fonts web|system | effects on|off (page(2)'s
#		  settings) | loadimages (every image on this page) |
#		  save (the settings, as the user's defaults)
#	url	the current URL
#	title	the document's title
#	status	loading <url> | done | error <msg>
#	text	the rendered text, in reading order, one block per line
#	links	<n> <url> <text>, one per line
#	forms	<form> <node> <kind> <name> <value> [checked], one field per line;
#		  a select's options follow it, as "\toption <value> <label> [selected]"
#	find	write: text to look for; read: the lines of text containing it
#	image	the viewport, rendered, as an image(6)
#	event	one line per event, "loading <url>", "done <url>",
#		  "error <msg>", "stopped", or "update" (a form changed),
#		  from when it was opened; reads block
#	dom/<n>/	tag attrs text style box children
#	settings	the engine's settings, a line each, as ctl takes them
#
# A file's contents are taken when it is opened, so a reader sees one
# page even if another loads while it reads.
#
Charonfs: module
{
	PATH:	con "/dis/lib/web/charonfs.dis";

	init:	fn(): string;
	# serve s, mounted at mountpt; returns once it is mounted.
	# b is the (initialised) Browser instance s came from.
	serve:	fn(b: Browser, s: ref Browser->Session, d: ref Draw->Display, mountpt: string): string;
	# Post the session as #s<spec>/fs (or fs.N if that is taken) so a
	# process in another name space can mount it; returns the name.
	post:	fn(spec: string): (string, string);
	SPEC:	con "charon";
};
