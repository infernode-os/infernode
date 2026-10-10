#
# js.m - a JavaScript realm.
#
# Each loaded instance of the module is one realm: its global object,
# built-ins, heap and job queue live in the instance's globals, so a
# host makes another realm by loading the module again.  A realm runs
# on one thread at a time.
#
# A host that shows web pages runs each page's realm with page()
# (which needs web/dom.m included first).  page() runs the realm and returns when the page is closed.  It first
# confines its process (§6.1): a new process group, a namespace that
# holds nothing but the grants, no file descriptors but standard error,
# and no devices.  What the page's scripts can reach is what is granted
# there: /mnt/web, the network, normally.  The document itself is
# shared with the host, which lays it out and draws it; the host's
# functions in Host run on the realm's thread, so they must not need a
# file the confined namespace lacks.
#
# Each task (a script, a timer, an event) runs with the host's lock
# held, so that the host never lays out a document half changed.
#
Js: module
{
	PATH:	con "/dis/lib/js/js.dis";

	# make the realm; nil, or why it could not be made
	init:	fn(): string;

	# run a script, then its jobs: (the completion value shown as
	# a string, nil) or (nil, the uncaught exception shown as a string)
	evalscript:	fn(src, name: string): (string, string);

	# run a module (and those it imports), then the jobs: as evalscript
	evalmodule:	fn(src, url: string): (string, string);

	# how modules are found: from a referrer's URL and a specifier, the
	# module's URL and source, or an error (the default: files)
	setloader:	fn(l: ref fn(referrer, specifier: string): (string, string, string));

	# where print and console output go (the default: standard output)
	setoutput:	fn(out: ref fn(s: string));

	# give the realm test262's host object, $262
	test262:	fn();

	# a web page's realm: run until the page is closed; nil, or why it failed
	page:	fn(h: ref Host): string;

	Host: adt {
		id:	int;		# the host's name for the page, given to each function
		doc:	ref Dom->Doc;
		url:	string;		# the document's address
		events:	chan of ref Event;	# from the host; Quit ends the page
		# (where in the realm's namespace, what is bound there, writable)
		grants:	list of (string, string, int);
		# around each task
		lock:	ref fn(id: int);
		unlock:	ref fn(id: int);
		# after a task that changed the document (called unlocked)
		changed:	ref fn(id: int);
		# called with the lock held: the document laid out as it now is
		box:	ref fn(id, n: int): (int, int, int, int, int);	# (shown, x, y, width, height), page coordinates
		computed:	ref fn(id, n: int, prop: string): string;	# a property's computed value
		media:	ref fn(id: int, query: string): int;	# a media query matches
		# selectors: whether node n matches (-1: not a valid selector);
		# the elements under root that match, in document order (one if not all)
		match:	ref fn(id, n: int, sel: string): int;
		select:	ref fn(id, root: int, sel: string, all: int): (int, list of int);
		# markup parsed as the body of a document of its own
		parse:	ref fn(id: int, markup: string): ref Dom->Doc;
		viewport:	ref fn(id: int): (int, int, int, int);	# width, height, scroll x, scroll y
		# called unlocked
		navigate:	ref fn(id: int, url: string, replace: int);
		scroll:	ref fn(id, x, y: int);
		console:	ref fn(id: int, s: string);	# console output, a line at a time
	};

	Event: adt {
		pick {
		Click =>		# button 1 on node n; the reply is 1 if a handler prevented the default action
			node:	int;
			x, y:	int;	# page coordinates
			reply:	chan of int;
		Input =>		# a form control's value was changed by the user (the document has the new value)
			node:	int;
			reply:	chan of int;
		Submit =>		# form submitted, by submitter (0 for none); reply as Click
			form:	int;
			submitter:	int;
			reply:	chan of int;
		Key =>		# a key typed into node n (0: the document)
			node:	int;
			key:	int;
			reply:	chan of int;
		Resize =>
		Scroll =>
		Quit =>
		}
	};

	# end the realm, freeing what it holds (its functions refer back to
	# the module instance, so it would otherwise wait for the collector)
	shutdown:	fn();
};
