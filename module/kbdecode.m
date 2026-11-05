#
# kbdecode -- what was meant on a keyboard on a screen.
#
# A touch keyboard's keys are where its touches land only roughly: a
# finger is wide, lands below what it aims at, and slips onto the next
# key.  This module turns touches into words.  It knows nothing of how
# a keyboard is drawn or where it is: it is given the keys (a character
# and a rectangle each) and a word list, and answers with the words
# most likely meant, best first, each with its cost (a negative log
# probability: lower is likelier).
#
# Two kinds of input:
#
#	taps	one touch per character.  Each touch is scored against
#		the keys by a Gaussian around each key's centre (plus the
#		offset learned for it), and the words are searched for
#		in a trie, tap by tap, keeping the likeliest few hundred
#		prefixes (a beam).  A word may have a letter more or less
#		than the touches, or two swapped, at a cost.  The cost of
#		a word adds how common it is (the word list's counts).
#		Goodman et al. 2002; the costs are AOSP LatinIME's shape.
#
#	swipe	one stroke through a word's letters.  Each word's
#		template is the line through its keys' centres; the
#		stroke and the template, both resampled to the same
#		number of points, are compared by shape (each scaled to
#		a unit box) and by place, and the words are pruned first
#		by the keys the stroke begins and ends on and by length.
#		SHARK2 (Kristensson and Zhai 2004).  The templates come
#		from the keys, so any layout -- Dvorak's, Colemak's --
#		works without training.
#
# Words are matched without regard to case or accents (é is typed
# with e's key); what case to give the word chosen is the caller's.
#
Kbdecode: module
{
	PATH:	con "/dis/lib/kbdecode.dis";

	init:	fn();

	# A key: the character it types (lower case) and where it is, its
	# centre and size, in the caller's units (screen pixels).
	Key: adt {
		c:	int;
		x, y:	int;
		w, h:	int;
	};

	# A touch: where it landed, or, when c is not 0, a character typed
	# exactly (from another layer of keys, a long press), which only
	# that character matches.
	Touch: adt {
		x, y:	int;
		c:	int;
	};

	# A candidate word.  complete is 1 when it is longer than what was
	# typed (a completion, offered but never put in for the typist).
	Cand: adt {
		word:	string;
		cost:	real;
		complete:	int;
	};

	# A word list: the words, and how often each is used.
	Lexicon: adt {
		nnode:	int;
		ch:	array of int;	# the trie: a node's character,
		kid:	array of int;	# its first child,
		sib:	array of int;	# its next sibling,
		term:	array of int;	# the word ending here (or -1),
		best:	array of int;	# and the commonest word below it
		nterm:	int;
		forms:	array of list of (string, int);	# a word's spellings and counts
		count:	array of int;	# a word's count, all spellings
		depth:	array of int;	# its length in the trie
		ndepth:	array of int;	# a node's depth
		total:	real;		# the sum of the counts
		first:	array of int;	# a word's first and last letters,
		last:	array of int;	# for the swipe's pruning
		chars:	array of real;	# a letter after a letter: what a word
					# not in the list costs (its shape)
		casing:	array of int;	# a word's: 0 a lower-case spelling,
					# 1 a capital first only, 2 all capitals
		pairs:	array of list of (int, int);	# by a word: the words after it, how often
		pairtot:	array of real;

		new:	fn(): ref Lexicon;
		# "word<tab>count" lines (blank or # lines skipped); each
		# count multiplied by weight.  Returns nil or an error.
		read:	fn(l: self ref Lexicon, path: string, weight: int): string;
		add:	fn(l: self ref Lexicon, word: string, count: int);
		# the word's count (any case, accents as written), 0 if not there
		lookup:	fn(l: self ref Lexicon, word: string): int;
		# "first<tab>second<tab>count" lines: how often a word follows
		# another, for setcontext.  Pairs of words not in the list are
		# left out.  Returns nil or an error.
		readpairs:	fn(l: self ref Lexicon, path: string): string;
		# the spelling to show for a word matched (its trie node):
		# the lower-case spelling if the list has one, else the
		# commonest ("I", "Dvorak")
		spelling:	fn(l: self ref Lexicon, term: int): string;
	};

	Decoder: adt {
		lex:	ref Lexicon;
		keys:	array of Key;
		keyof:	array of int;	# a folded character's key, or -1
		offx:	array of real;	# per key: the learned offset of its
		offy:	array of real;	# touches, in key widths and heights
		nlearn:	array of int;
		tlen:	array of real;	# per word: its template's length (swipe)
		stamp:	array of int;	# per trie node: search scratch
		sbest:	array of real;
		sedit:	array of int;
		gen:	int;

		# tunable; new sets the defaults (kbdecode(2))
		sigma:	real;		# a tap's spread, in key sizes
		lmweight:	real;	# how much a word's commonness counts
		omit:	real;		# a letter of the word not tapped
		insert:	real;		# a tap that is no letter of the word
		swap:	real;		# two letters tapped in turn swapped
		completion:	real;	# per letter beyond the taps
		oov:	real;		# a word not in the list: its letters (x their cost),
		oovbase:	real;	# and for being one
		proper:	real;		# a word spelt only with a capital, typed in
		acronym:	real;	# lower case; one only in capitals
		context:	real;	# how much the word before counts (0 to 1)
		ctx:	array of real;	# per word: how likely after the word before
		ctxset:	list of int;
		ctxon:	int;
		margin:	real;		# how much likelier a word must be than
		validmargin:	real;	# what was typed to replace it: a typing
					# not in the list, and one that is
		beam:	int;

		ssigma:	real;		# swipe: spread of the shape, of the place,
		lsigma:	real;
		esigma:	real;		# of where it begins and ends
		slmweight:	real;

		new:	fn(lex: ref Lexicon, keys: array of Key): ref Decoder;
		setkeys:	fn(d: self ref Decoder, keys: array of Key);
		# the word typed before the one being decoded (nil: none, a
		# sentence's start): the words that follow it count for more
		setcontext:	fn(d: self ref Decoder, prev: string);

		# the n likeliest words for these taps, best first
		taps:	fn(d: self ref Decoder, t: array of Touch, n: int): array of ref Cand;
		# the characters of the keys nearest the taps
		literal:	fn(d: self ref Decoder, t: array of Touch): string;
		# what the literal costs as typed (a word not in the list
		# costs oov per letter)
		literalcost:	fn(d: self ref Decoder, t: array of Touch): real;
		# the word to put in for these taps in place of what they
		# spell, or nil to leave it
		correct:	fn(d: self ref Decoder, t: array of Touch, c: array of ref Cand): string;
		# the n likeliest words for a stroke through these points
		swipe:	fn(d: self ref Decoder, path: array of Touch, n: int): array of ref Cand;

		# a touch meant for the key typing c: learn where its
		# touches land
		learn:	fn(d: self ref Decoder, c: int, t: Touch);
		# the learned offsets as text ("c dx dy n" lines), and back
		offsets:	fn(d: self ref Decoder): string;
		setoffsets:	fn(d: self ref Decoder, s: string);
	};

	# lower case, accents taken off (the character a key types for it)
	fold:	fn(c: int): int;
	# 1 if the word is a word the list can hold: letters and apostrophes
	wordlike:	fn(w: string): int;
};
