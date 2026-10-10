#
# js.m - a JavaScript realm.
#
# Each loaded instance of the module is one realm: its global object,
# built-ins, heap and job queue live in the instance's globals, so a
# host makes another realm by loading the module again.  A realm runs
# on one thread at a time.
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

	# end the realm, freeing what it holds (its functions refer back to
	# the module instance, so it would otherwise wait for the collector)
	shutdown:	fn();
};
