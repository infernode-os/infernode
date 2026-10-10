#
# jsre.m - JavaScript regular expressions (ECMAScript 2025 §22.2):
# patterns parsed to a tree, in the three modes the flags select
# (legacy, with Annex B's extensions; u; v).
#
# Patterns are UTF-16, as JavaScript strings are; in u and v modes a
# surrogate pair is one character.
#
Jsre: module
{
	PATH:	con "/dis/lib/js/jsre.dis";

	# flags
	Fd, Fg, Fi, Fm, Fs, Fu, Fv, Fy: con 1 << iota;

	# assertions
	Abol, Aeol, Aword, Anotword: con iota;
	# class escapes
	Cdigit, Cnotdigit, Cspace, Cnotspace, Cword, Cnotword: con iota;
	# set operations (v mode)
	Ounion, Ointer, Osub: con iota;

	Re: adt {
		pick {
		Empty =>
		Char =>
			c:	int;		# a code point (u, v) or code unit
		Any =>
		Seq =>
			items:	array of ref Re;
		Alt =>
			alts:	array of ref Re;
		Group =>
			n:	int;		# capture number, from 1
			name:	string;	# or nil
			e:	ref Re;
		Mod =>
			add, rem:	int;	# (?ims-ims:...); both 0 for (?:...)
			e:	ref Re;
		Look =>
			behind, neg:	int;
			e:	ref Re;
		Assert =>
			kind:	int;
		Backref =>
			n:	int;		# or 0 with a name
			name:	string;
		Repeat =>
			min, max:	int;	# max -1: no limit
			greedy:	int;
			e:	ref Re;
		Class =>
			neg:	int;
			set:	ref Set;
		}
	};

	# a character class's contents
	Set: adt {
		op:	int;
		items:	array of ref Item;
	};

	Item: adt {
		pick {
		Range =>
			lo, hi:	int;
		Esc =>
			kind:	int;
		Prop =>
			neg:	int;
			name, value:	string;	# \p{name=value}, or \p{name} with value nil
		Nested =>
			neg:	int;
			set:	ref Set;
		Strs =>
			strs:	array of string;	# \q{...}
		}
	};

	Pattern: adt {
		re:	ref Re;
		flags:	int;
		ngroups:	int;
		names:	array of string;	# by capture number; names[0] unused
	};

	init:	fn();
	# the flags in s, or an error
	parseflags:	fn(s: string): (int, string);
	parse:	fn(pat: string, flags: int): (ref Pattern, string);
};
