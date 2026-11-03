implement KbdecodeTest;

#
# kbdecode(2) and osklayout(2): the word list, the layouts, and what
# taps and strokes on each letters' layout are taken to mean -- a
# slip onto the next key, a letter missed, one doubled, two swapped,
# an apostrophe left out, all put right; a word in the list, a number,
# a single letter, left alone; a stroke through a word's keys read as
# the word on QWERTY, Dvorak and Colemak; the offsets learned kept.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	Rect, Point: import Draw;
include "testing.m";
	testing: Testing;
	T: import testing;
include "kbdecode.m";
	kbdecode: Kbdecode;
	Decoder, Lexicon, Touch, Cand, Key: import kbdecode;
include "osklayout.m";
	osklayout: Osklayout;
	Layout, Lkey: import osklayout;

KbdecodeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/kbdecode_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# a small word list, with counts as a large one's would be
words := array[] of {
	("the", 50000), ("hello", 900), ("help", 1200), ("held", 700),
	("keyboard", 300), ("far", 800), ("fat", 900), ("for", 30000),
	("don't", 3000), ("dont", 1), ("I", 40000), ("Dvorak", 40),
	("world", 2000), ("word", 1500), ("would", 6000), ("quick", 600),
	("brown", 500), ("fox", 300), ("jumps", 100), ("over", 7000),
	("lazy", 200), ("dog", 900), ("type", 800), ("typing", 300),
	("café", 50), ("is", 40000), ("it", 38000), ("in", 45000),
	("on", 30000), ("to", 48000), ("of", 49000), ("and", 47000),
	("what", 9000), ("when", 8000), ("where", 5000), ("there", 9000),
	("their", 7000), ("this", 20000), ("that", 25000), ("with", 22000),
	("about", 9000), ("think", 3000), ("thing", 2500), ("things", 2000),
	("good", 5000), ("great", 3000), ("really", 3500), ("people", 6000),
	("because", 5000), ("question", 1200), ("swipe", 40), ("finger", 300),
};

lexicon(): ref Lexicon
{
	l := Lexicon.new();
	for(i := 0; i < len words; i++){
		(w, c) := words[i];
		l.add(w, c);
	}
	return l;
}

layout(t: ref T, name: string): ref Layout
{
	(l, err) := Layout.read("/lib/osk/layouts/" + name);
	if(l == nil)
		t.fatal(err);
	# the keyboard's keys on an 800x480 screen
	l.place(Rect((0, 300), (800, 480)));
	return l;
}

# the centre of the key typing c
centre(l: ref Layout, c: int): Point
{
	for(i := 0; i < len l.rows; i++)
		for(j := 0; j < len l.rows[i]; j++){
			k := l.rows[i][j];
			if(k.kind == Osklayout->Kchar && k.c == c)
				return ((k.r.min.x + k.r.max.x)/2, (k.r.min.y + k.r.max.y)/2);
		}
	return (-1, -1);
}

# taps at the keys' centres for s, each moved by (dx, dy) in pixels
taps(l: ref Layout, s: string, dx, dy: int): array of Touch
{
	a := array[len s] of Touch;
	for(i := 0; i < len s; i++){
		p := centre(l, s[i]);
		a[i] = Touch(p.x + dx, p.y + dy, 0);
	}
	return a;
}

decoder(t: ref T, name: string): (ref Layout, ref Decoder)
{
	l := layout(t, name);
	return (l, Decoder.new(lexicon(), l.dkeys()));
}

best(c: array of ref Cand): string
{
	for(i := 0; i < len c; i++)
		if(!c[i].complete)
			return c[i].word;
	return "";
}

testLexicon(t: ref T)
{
	l := lexicon();
	t.asserteq(l.lookup("hello"), 900, "a word's count");
	t.asserteq(l.lookup("HELLO"), 900, "found whatever its case");
	t.asserteq(l.lookup("helo"), 0, "a word not in it");
	t.asserteq(l.lookup("hel"), 0, "a prefix is not a word");
	t.assertseq(l.spelling(findt(l, "i")), "I", "I is spelt I");
	t.assertseq(l.spelling(findt(l, "dvorak")), "Dvorak", "a proper noun keeps its capital");
	l.add("Hello", 5);
	t.assertseq(l.spelling(findt(l, "hello")), "hello", "the lower-case spelling, when there is one");
	t.asserteq(kbdecode->wordlike("don't"), 1, "an apostrophe is in a word");
	t.asserteq(kbdecode->wordlike("abc1"), 0, "a digit is not");
	t.asserteq(kbdecode->fold('É'), 'e', "É is typed with e");
}

findt(l: ref Lexicon, w: string): int
{
	n := 0;
	for(i := 0; i < len w && n >= 0; i++){
		c := w[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		k := l.kid[n];
		for(; k >= 0; k = l.sib[k])
			if(l.ch[k] == c)
				break;
		n = k;
	}
	if(n < 0)
		return -1;
	return l.term[n];
}

testLayouts(t: ref T)
{
	for(names := "qwerty" :: "dvorak" :: "colemak" :: nil; names != nil; names = tl names){
		l := layout(t, hd names);
		t.asserteq(len l.rows, 4, hd names + ": four rows");
		n := 0;
		dk := l.dkeys();
		i: int;
		for(c := 'a'; c <= 'z'; c++)
			for(i = 0; i < len dk; i++)
				if(dk[i].c == c){
					n++;
					break;
				}
		t.asserteq(n, 26, hd names + ": every letter has a key");
		# every key is inside the keyboard and none overlaps the next
		for(i = 0; i < len l.rows; i++)
			for(j := 0; j < len l.rows[i]; j++){
				k := l.rows[i][j];
				t.assert(k.r.min.x >= 0 && k.r.max.x <= 800 && k.r.min.y >= 300 && k.r.max.y <= 480,
					sys->sprint("%s: key %d,%d inside", hd names, i, j));
				if(j > 0)
					t.assert(l.rows[i][j-1].r.max.x <= k.r.min.x, hd names + ": keys in a row do not overlap");
			}
		# the key at a key's centre is that key; a gap belongs to a key
		p := centre(l, 'a');
		k := l.keyat(p);
		t.assert(k != nil && k.c == 'a', hd names + ": keyat at a's centre");
		t.assert(l.keyat(Point(1, p.y)) != nil, hd names + ": the end of a short row is a key's");
	}
	t.assertseq(layout(t, "dvorak").rows[1][0].name, nil, "dvorak's home row starts with a letter");
	t.asserteq(layout(t, "dvorak").rows[1][0].c, 'a', "dvorak's home row starts with a");
	t.asserteq(layout(t, "dvorak").rows[1][2].c, 'e', "dvorak's e is under the left middle finger");
	t.asserteq(layout(t, "colemak").rows[1][3].c, 't', "colemak's t is on its home row");
	for(names = "symbols" :: "more" :: nil; names != nil; names = tl names){
		(l, err) := Layout.read("/lib/osk/layouts/" + hd names);
		t.assert(l != nil, hd names + " parses: " + err);
	}
	(nil, err) := Layout.parse("bad", "row a bogus b\n");
	t.assert(err != nil, "an unknown key word is refused");
	(nil, err) = Layout.parse("bad", "row a:0 b\n");
	t.assert(err != nil, "a key no wide is refused");
	a := osklayout->alternates("e\téè\n# a comment\na\tà\n");
	t.asserteq(len a, 2, "the alternates' lines");
}

# the word put in for taps (or what they spell, when nothing is)
corrected(d: ref Decoder, tp: array of Touch): string
{
	c := d.taps(tp, 6);
	w := d.correct(tp, c);
	if(w == nil)
		return d.literal(tp);
	return w;
}

testTaps(t: ref T)
{
	for(names := "qwerty" :: "dvorak" :: "colemak" :: nil; names != nil; names = tl names){
		(l, d) := decoder(t, hd names);
		n := hd names + ": ";
		t.assertseq(best(d.taps(taps(l, "hello", 0, 0), 4)), "hello", n + "taps on a word's keys");
		t.assertseq(corrected(d, taps(l, "hello", 0, 0)), "hello", n + "a word typed right is left");
		t.assertseq(corrected(d, taps(l, "the", 0, 0)), "the", n + "the");
		t.assertseq(corrected(d, taps(l, "teh", 0, 0)), "the", n + "two letters swapped");
		t.assertseq(corrected(d, taps(l, "keybard", 0, 0)), "keyboard", n + "a letter missed");
		t.assertseq(corrected(d, taps(l, "helllo", 0, 0)), "hello", n + "a letter doubled");
		t.assertseq(corrected(d, taps(l, "dont", 0, 0)), "don't", n + "an apostrophe not typed");
		t.assertseq(corrected(d, taps(l, "far", 0, 0)), "far", n + "a word in the list is left");
		t.assertseq(corrected(d, taps(l, "i", 0, 0)), "I", n + "i is I");
		t.assertseq(corrected(d, taps(l, "dvorak", 0, 0)), "Dvorak", n + "a proper noun's capital");
		t.assertseq(corrected(d, taps(l, "cafe", 0, 0)), "café", n + "an accent not typed");
		t.assertseq(corrected(d, taps(l, "x", 0, 0)), "x", n + "a single letter is left");
		# a slip onto the next key: each letter of "quick" landed on the
		# key to its right's near half
		(nil, kw) := keysize(l);
		sl := taps(l, "quick", kw*55/100, 0);
		t.assert(d.literal(sl) != "quick", n + "the slip is off the keys (" + d.literal(sl) + ")");
		t.assertseq(corrected(d, sl), "quick", n + "a slip onto the keys beside put right");
		# a word not in the list, typed on its keys, is left as typed
		t.assertseq(corrected(d, taps(l, "zxq", 0, 0)), "zxq", n + "no word near: left");
	}
	(l, d) := decoder(t, "qwerty");
	tp := taps(l, "abc", 0, 0);
	tp = array[] of {tp[0], tp[1], tp[2], Touch(0, 0, '1')};
	t.assertseq(d.correct(tp, d.taps(tp, 4)), nil, "a word with a digit is left");
	# completions are offered, never put in
	c := d.taps(taps(l, "keyb", 0, 0), 6);
	comp := 0;
	for(i := 0; i < len c; i++)
		if(c[i].word == "keyboard" && c[i].complete)
			comp = 1;
	t.assert(comp, "keyboard offered for keyb");
	t.assertseq(corrected(d, taps(l, "keyb", 0, 0)), "keyb", "but not put in for it");
}

keysize(l: ref Layout): (int, int)
{
	k := l.rows[0][0];
	return (k.r.max.y - k.r.min.y, int (real (k.r.max.x - k.r.min.x) / k.width));
}

# a stroke through s's keys: the centres, a point every few pixels
# between, moved a little
stroke(l: ref Layout, s: string, wobble: int): array of Touch
{
	pts: list of Touch;
	n := 0;
	for(i := 0; i+1 < len s; i++){
		a := centre(l, s[i]);
		b := centre(l, s[i+1]);
		steps := 8;
		for(j := 0; j < steps; j++){
			x := a.x + (b.x - a.x)*j/steps;
			y := a.y + (b.y - a.y)*j/steps;
			if(j % 2)
				y += wobble;
			else
				y -= wobble;
			pts = Touch(x, y, 0) :: pts;
			n++;
		}
	}
	e := centre(l, s[len s - 1]);
	pts = Touch(e.x, e.y, 0) :: pts;
	n++;
	a := array[n] of Touch;
	for(; pts != nil; pts = tl pts)
		a[--n] = hd pts;
	return a;
}

testSwipe(t: ref T)
{
	for(names := "qwerty" :: "dvorak" :: "colemak" :: nil; names != nil; names = tl names){
		(l, d) := decoder(t, hd names);
		n := hd names + ": ";
		# the word, first; or, where the layout makes another stroke
		# much the same (Dvorak's world and would: o to r passes over
		# u), among the first three, the commoner first
		for(ws := "hello" :: "world" :: "keyboard" :: "people" :: "question" :: "typing" :: "really" :: nil; ws != nil; ws = tl ws){
			c := d.swipe(stroke(l, hd ws, 4), 4);
			got := "";
			if(len c > 0)
				got = c[0].word;
			if(got != hd ws)
				for(i := 0; i < len c; i++)
					t.log(sys->sprint("%s: %s %.3f", hd ws, c[i].word, c[i].cost));
			if(hd names == "dvorak" && hd ws == "world")
				t.assert(intop(c, hd ws, 3), n + "a stroke through world: among the first three");
			else
				t.assertseq(got, hd ws, n + "a stroke through " + hd ws);
		}
		c := d.swipe(stroke(l, "realy", 4), 4);	# the doubled l is one key
		t.assert(intop(c, "really", 1), n + "a doubled letter, one key");
		t.assert(len d.swipe(array[] of {Touch(10, 400, 0)}, 4) == 0, n + "a point is no stroke");
	}
}

intop(c: array of ref Cand, w: string, n: int): int
{
	for(i := 0; i < len c && i < n; i++)
		if(c[i].word == w)
			return 1;
	return 0;
}

testLearn(t: ref T)
{
	(l, d) := decoder(t, "qwerty");
	p := centre(l, 'e');
	(kh, kw) := keysize(l);
	for(i := 0; i < 40; i++)
		d.learn('e', Touch(p.x + kw/5, p.y + kh/4, 0));
	s := d.offsets();
	t.assert(s != nil, "offsets learned");
	(l2, d2) := decoder(t, "qwerty");
	l2 = nil;
	d2.setoffsets(s);
	t.assertseq(d2.offsets(), s, "the offsets read back as written");
	# a touch at e's learned place is e, even where r would be nearer
	q := Touch(p.x + kw*45/100, p.y + kh/4, 0);
	t.assertseq(d.literal(array[] of {q}), "e", "the learned centre decides the key");
	d.learn('e', Touch(p.x + 3*kw, p.y, 0));	# far off: not e's
	t.assertseq(d.offsets(), d2.offsets(), "a touch far from the key teaches nothing");
}

testWordList(t: ref T)
{
	l := Lexicon.new();
	err := l.read("/lib/osk/en.words", 1);
	if(err != nil)
		t.skip("no word list: " + err);
	t.assert(l.nterm > 20000, sys->sprint("a word list of %d words", l.nterm));
	for(ws := "the" :: "keyboard" :: "don't" :: "it's" :: "I" :: "people" :: nil; ws != nil; ws = tl ws)
		t.assert(l.lookup(hd ws) > 0, hd ws + " is in it");
	t.asserteq(l.lookup("teh"), 0, "teh is not");
	t.assert(l.lookup("the") > l.lookup("keyboard"), "the is commoner than keyboard");
	t0 := sys->millisec();
	q := layout(t, "dvorak");
	d := Decoder.new(l, q.dkeys());
	for(i := 0; i < 20; i++)
		d.taps(taps(q, "keyboard", 0, 0), 6);
	ms := (sys->millisec() - t0) / 20;
	t.log(sys->sprint("a word of 8 taps decodes in %dms", ms));
	t0 = sys->millisec();
	for(i = 0; i < 5; i++)
		d.swipe(stroke(q, "keyboard", 4), 4);
	t.log(sys->sprint("a stroke decodes in %dms", (sys->millisec() - t0) / 5));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	kbdecode = load Kbdecode Kbdecode->PATH;
	osklayout = load Osklayout Osklayout->PATH;
	if(testing == nil || kbdecode == nil || osklayout == nil){
		sys->fprint(sys->fildes(2), "kbdecode_test: cannot load a module: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	kbdecode->init();
	osklayout->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	run("Lexicon", testLexicon);
	run("Layouts", testLayouts);
	run("Taps", testTaps);
	run("Swipe", testSwipe);
	run("Learn", testLearn);
	run("WordList", testWordList);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
