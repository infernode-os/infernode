#
# jscheck.m - the early errors of a parsed program that need more than
# the grammar (ECMAScript 2025, the Early Errors sections of §14-16):
# names declared twice, break and continue with nowhere to go, super
# and new.target out of place, private names no class declares.
#
Jscheck: module
{
	PATH:	con "/dis/lib/js/jscheck.dis";

	init:	fn();
	# nil if the program is valid, else (where, what)
	check:	fn(prog: ref Jsparse->Node): (int, string);
};
