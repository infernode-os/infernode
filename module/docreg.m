#
# Docreg - the kinds of document Xenith shows, and their engines
#
# The kinds are a table, /lib/xenith/doctypes; reading it loads
# nothing. An engine (docengine(2)) is loaded the first time a
# document of its kind is opened, and kept for the next.
#

Docreg: module
{
	PATH:	con "/dis/xenith/docreg.dis";
	TABLE:	con "/lib/xenith/doctypes";

	Binary, Source: con iota;

	Kind: adt {
		name:	string;		# pdf, image, markdown, ...
		class:	int;		# Binary or Source
		engine:	string;		# the engine's module path
		exts:	list of string;	# with their dots, in lower case
		magic:	list of array of byte;
	};

	init:	fn(d: ref Draw->Display);

	# The kind of document a file is, by its name and the bytes it
	# begins with (head, which may be nil), or nil if it is not one.
	kind:	fn(name: string, head: array of byte): ref Kind;

	# The kind of that name
	kindof:	fn(name: string): ref Kind;

	# Its engine, loaded and initialised the first time
	engine:	fn(k: ref Kind): (Docengine, string);

	# The engines loaded so far, by path
	loaded:	fn(): list of string;
};
