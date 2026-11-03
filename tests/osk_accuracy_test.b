implement OskAccuracyTest;

#
# How well wm/osk's decoder (kbdecode(2)) reads a typist, on each
# letters' layout: a simulated typist types the words of
# tests/osk/phrases.txt, and what the decoder makes of it is counted.
#
# The typist, tapping: each tap lands about the key's centre, spread as
# a finger spreads (a Gaussian, 0.20 of a key each way) and a little
# low (0.08 of a key: a finger lands below what it aims at); now and
# then a letter is missed, a key beside it tapped as well, or two
# letters swapped -- together about the 8% of letters Gboard's typists
# get wrong (Ouyang et al. 2017).  An apostrophe is not typed where
# the letters have no key for it, as on a phone.  Swiping: a stroke
# through the word's keys, each corner off by 0.25 of a key and cut a
# little, a point every few pixels.
#
# Counted, per layout: the words the taps spell as typed (the
# literal), the words right after the decoder has put them right, the
# words typed right that it changed (false corrections: what makes a
# keyboard feel broken, so the bound is tight), and strokes read as
# their word first, or among the first three.  The bounds are below
# (Min*, Max*): a change that makes typing worse fails here.
#
# Takes a minute or two under -c1; -v prints the counts.  Skips with
# no word list (lib/osk/en.words).
#

include "sys.m";
	sys: Sys;
include "draw.m";
	Rect, Point: import Draw;
include "math.m";
	math: Math;
include "rand.m";
	rand: Rand;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "testing.m";
	testing: Testing;
	T: import testing;
include "kbdecode.m";
	kbdecode: Kbdecode;
	Decoder, Lexicon, Touch, Cand, Key: import kbdecode;
include "osklayout.m";
	osklayout: Osklayout;
	Layout, Lkey: import osklayout;

OskAccuracyTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/osk_accuracy_test.b";

# the bounds, in percent of words
MinCorrected:	con 92.0;	# right after correction (tapping)
MaxFalse:	con 1.5;	# typed right, changed
MinGain:	con 6.0;	# corrected beats the literal by this much
MinSwipe1:	con 75.0;	# a stroke read as its word, first
MinSwipe3:	con 88.0;	# among the first three

# the typist
Sigma:		con 0.20;
Low:		con 0.08;
Pomit:		con 10;		# per thousand letters
Pextra:		con 8;
Pswap:		con 8;
Swobble:	con 0.25;

Maxwords:	con 2500;	# words a layout is tried on (tapping)
Maxswipes:	con 900;

passed := 0;
failed := 0;
skipped := 0;

lex: ref Lexicon;
words: array of string;
starts: array of int;		# 1 where a sentence starts
usecontext := 1;		# -nocontext: no word before
params: list of (string, real);	# -p name=value: a decoder's tunable, for a sweep
only := "";			# -l layout
maxwords := Maxwords;		# -n words
which := 3;			# 1 tapping, 2 swiping (-t, -s)
seed := 1;			# -seed n: the typist's noise
offset := 0;			# -o n: the words from the nth

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

uniform(): real
{
	return (real rand->rand(1<<30) + 0.5) / real (1<<30);
}

gauss(): real
{
	# Box-Muller
	return math->sqrt(-2.0 * math->log(uniform())) * math->cos(2.0 * Math->Pi * uniform());
}

lower(w: string): string
{
	r := w;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
}

readwords(t: ref T)
{
	b := bufio->open("/tests/osk/phrases.txt", Bufio->OREAD);
	if(b == nil)
		t.fatal(sys->sprint("phrases: %r"));
	l: list of (string, int);
	n := 0;
	while((s := b.gets('\n')) != nil){
		if(s[0] == '#')
			continue;
		(nil, ws) := sys->tokenize(s, " \t\n");
		st := 1;
		for(; ws != nil; ws = tl ws){
			l = (hd ws, st) :: l;
			st = 0;
			n++;
		}
	}
	words = array[n] of string;
	starts = array[n] of int;
	for(; l != nil; l = tl l){
		--n;
		(words[n], starts[n]) = hd l;
	}
}

layout(t: ref T, name: string): ref Layout
{
	(l, err) := Layout.read("/lib/osk/layouts/" + name);
	if(l == nil)
		t.fatal(err);
	# a Raspberry Pi's 7" screen, 800x480: its keys (osk's sizes)
	l.place(Rect((0, 303), (800, 475)));
	return l;
}

keyof(dk: array of Key, c: int): int
{
	for(i := 0; i < len dk; i++)
		if(dk[i].c == c)
			return i;
	return -1;
}

# the taps the typist makes for w
typist(dk: array of Key, w: string): array of Touch
{
	tps: list of Touch;
	n := 0;
	lw := lower(w);
	for(i := 0; i < len lw; i++){
		c := kbdecode->fold(lw[i]);
		k := keyof(dk, c);
		if(k < 0)
			continue;	# no key: not typed
		r := rand->rand(1000);
		if(r < Pomit)
			continue;
		if(r < Pomit + Pswap && i+1 < len lw && keyof(dk, kbdecode->fold(lw[i+1])) >= 0){
			tps = tap(dk, keyof(dk, kbdecode->fold(lw[i+1]))) :: tps;
			tps = tap(dk, k) :: tps;
			n += 2;
			i++;
			continue;
		}
		tps = tap(dk, k) :: tps;
		n++;
		if(r >= Pomit + Pswap && r < Pomit + Pswap + Pextra){
			# a key beside it, as well
			tps = tap(dk, nearby(dk, k)) :: tps;
			n++;
		}
	}
	a := array[n] of Touch;
	for(; tps != nil; tps = tl tps)
		a[--n] = hd tps;
	return a;
}

tap(dk: array of Key, k: int): Touch
{
	key := dk[k];
	x := real key.x + (gauss() * Sigma) * real key.w;
	y := real key.y + (gauss() * Sigma + Low) * real key.h;
	return Touch(int x, int y, 0);
}

nearby(dk: array of Key, k: int): int
{
	best := k;
	bd := 1<<30;
	start := rand->rand(len dk);
	for(j := 0; j < len dk; j++){
		i := (start + j) % len dk;
		if(i == k)
			continue;
		dx := dk[i].x - dk[k].x;
		dy := dk[i].y - dk[k].y;
		d := dx*dx + dy*dy;
		if(d < bd){
			bd = d;
			best = i;
		}
	}
	return best;
}

# the typist's stroke for w
stroke(dk: array of Key, w: string): array of Touch
{
	lw := lower(w);
	corners: list of (real, real);
	nc := 0;
	last := -1;
	for(i := 0; i < len lw; i++){
		k := keyof(dk, kbdecode->fold(lw[i]));
		if(k < 0 || k == last)
			continue;
		last = k;
		key := dk[k];
		x := real key.x + gauss() * Swobble * real key.w;
		y := real key.y + (gauss() * Swobble + Low) * real key.h;
		corners = (x, y) :: corners;
		nc++;
	}
	c := array[nc] of (real, real);
	for(; corners != nil; corners = tl corners)
		c[--nc] = hd corners;
	pts: list of Touch;
	n := 0;
	for(i = 0; i+1 < len c; i++){
		(x0, y0) := c[i];
		(x1, y1) := c[i+1];
		d := math->sqrt((x1-x0)*(x1-x0) + (y1-y0)*(y1-y0));
		steps := int (d / 8.0) + 1;
		for(j := 0; j < steps; j++){
			f := real j / real steps;
			pts = Touch(int (x0 + f*(x1-x0)), int (y0 + f*(y1-y0)), 0) :: pts;
			n++;
		}
	}
	if(len c > 0){
		(x, y) := c[len c - 1];
		pts = Touch(int x, int y, 0) :: pts;
		n++;
	}
	a := array[n] of Touch;
	for(; pts != nil; pts = tl pts)
		a[--n] = hd pts;
	# corners cut: each point the mean of it and its neighbours
	b := array[len a] of Touch;
	for(i = 0; i < len a; i++){
		lo := i - 2;
		hi := i + 2;
		if(lo < 0) lo = 0;
		if(hi >= len a) hi = len a - 1;
		sx := 0;
		sy := 0;
		for(j := lo; j <= hi; j++){
			sx += a[j].x;
			sy += a[j].y;
		}
		b[i] = Touch(sx / (hi-lo+1), sy / (hi-lo+1), 0);
	}
	return b;
}

pct(n, d: int): real
{
	if(d == 0)
		return 0.0;
	return 100.0 * real n / real d;
}

# the decoder, with any tunables the command line set
newdecoder(dk: array of Key): ref Decoder
{
	d := Decoder.new(lex, dk);
	for(p := params; p != nil; p = tl p){
		(n, v) := hd p;
		case n {
		"sigma" =>	d.sigma = v;
		"lmweight" =>	d.lmweight = v;
		"omit" =>	d.omit = v;
		"insert" =>	d.insert = v;
		"swap" =>	d.swap = v;
		"completion" =>	d.completion = v;
		"oov" =>	d.oov = v;
		"oovbase" =>	d.oovbase = v;
		"margin" =>	d.margin = v;
		"validmargin" =>	d.validmargin = v;
		"context" =>	d.context = v;
		"proper" =>	d.proper = v;
		"acronym" =>	d.acronym = v;
		"beam" =>	d.beam = int v;
		"ssigma" =>	d.ssigma = v;
		"lsigma" =>	d.lsigma = v;
		"esigma" =>	d.esigma = v;
		"slmweight" =>	d.slmweight = v;
		* =>	raise "fail:unknown tunable " + n;
		}
	}
	return d;
}

# the word before word i, as the typist meant it, if in its sentence
setcontext(d: ref Decoder, i: int)
{
	if(!usecontext || i == 0 || starts[i])
		d.setcontext(nil);
	else
		d.setcontext(meant(lower(words[i-1])));
}

# the word as meant, as the decoder could know it: a possessive the
# list does not have ("agent's") is right as the plural ("agents")
meant(w: string): string
{
	if(lex.lookup(w) > 0)
		return w;
	r := "";
	for(i := 0; i < len w; i++)
		if(w[i] != '\'')
			r[len r] = w[i];
	if(lex.lookup(r) > 0)
		return r;
	return w;
}

tapping(t: ref T, name: string)
{
	l := layout(t, name);
	dk := l.dkeys();
	d := newdecoder(dk);
	rand->init(seed);
	n := 0;
	lit := 0;
	right := 0;
	typedright := 0;
	falsec := 0;
	inv := 0;
	invright := 0;
	oovn := 0;
	oovright := 0;
	for(i := offset; i < len words && n < maxwords; i++){
		w := lower(words[i]);
		setcontext(d, i);
		tp := typist(dk, w);
		if(len tp == 0)
			continue;
		n++;
		s := d.literal(tp);
		got := d.correct(tp, d.taps(tp, 6));
		if(got == nil)
			got = s;
		want := meant(w);
		ok := lower(got) == want || lower(got) == w;
		if(s == w)
			lit++;
		if(ok)
			right++;
		if(lex.lookup(want) > 0){
			inv++;
			if(ok)
				invright++;
		}else{
			oovn++;
			if(ok)
				oovright++;
		}
		if(!ok && testing->getverbose())
			t.log(sys->sprint("%s: %q typed %q, made %q", name, want, s, got));
		if(s == w){
			typedright++;
			if(!ok)
				falsec++;
		}
	}
	pl := pct(lit, n);
	pc := pct(right, n);
	pf := pct(falsec, typedright);
	t.log(sys->sprint("%s tapping: %d words, literal %.1f%%, corrected %.1f%%, false corrections %.2f%% (%d of %d typed right)",
		name, n, pl, pc, pf, falsec, typedright));
	sys->print("osk_accuracy: %s tapping: literal %.1f%% corrected %.1f%% false %.2f%% inlist %.1f%% notinlist %.1f%%\n",
		name, pl, pc, pf, pct(invright, inv), pct(oovright, oovn));
	t.assert(pc >= MinCorrected, sys->sprint("%s: %.1f%% right after correction, at least %.1f%%", name, pc, MinCorrected));
	t.assert(pf <= MaxFalse, sys->sprint("%s: %.2f%% of words typed right changed, at most %.1f%%", name, pf, MaxFalse));
	t.assert(pc - pl >= MinGain, sys->sprint("%s: correction gains %.1f points, at least %.1f", name, pc - pl, MinGain));
}

swiping(t: ref T, name: string)
{
	l := layout(t, name);
	dk := l.dkeys();
	d := newdecoder(dk);
	rand->init(seed + 1);
	n := 0;
	top1 := 0;
	top3 := 0;
	for(i := offset; i < len words && n < maxwords * Maxswipes / Maxwords; i++){
		w := lower(words[i]);
		if(len w < 2 || lex.lookup(w) == 0)
			continue;	# a word not in the list cannot be swiped
		setcontext(d, i);
		s := stroke(dk, w);
		if(len s < 2)
			continue;	# one key: a tap
		n++;
		c := d.swipe(s, 3);
		for(j := 0; j < len c; j++)
			if(lower(c[j].word) == w){
				if(j == 0)
					top1++;
				top3++;
				break;
			}
		if((len c == 0 || lower(c[0].word) != w) && testing->getverbose()){
			g := "";
			for(j = 0; j < len c; j++)
				g += " " + c[j].word;
			t.log(sys->sprint("%s: stroke for %q read as%s", name, w, g));
		}
	}
	p1 := pct(top1, n);
	p3 := pct(top3, n);
	t.log(sys->sprint("%s swiping: %d words, first %.1f%%, among three %.1f%%", name, n, p1, p3));
	sys->print("osk_accuracy: %s swiping: first %.1f%% three %.1f%%\n", name, p1, p3);
	t.assert(p1 >= MinSwipe1, sys->sprint("%s: %.1f%% of strokes read first, at least %.1f%%", name, p1, MinSwipe1));
	t.assert(p3 >= MinSwipe3, sys->sprint("%s: %.1f%% among the first three, at least %.1f%%", name, p3, MinSwipe3));
}

testQwertyTap(t: ref T) { tapping(t, "qwerty"); }
testDvorakTap(t: ref T) { tapping(t, "dvorak"); }
testColemakTap(t: ref T) { tapping(t, "colemak"); }
testQwertySwipe(t: ref T) { swiping(t, "qwerty"); }
testDvorakSwipe(t: ref T) { swiping(t, "dvorak"); }
testColemakSwipe(t: ref T) { swiping(t, "colemak"); }

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	rand = load Rand Rand->PATH;
	bufio = load Bufio Bufio->PATH;
	testing = load Testing Testing->PATH;
	kbdecode = load Kbdecode Kbdecode->PATH;
	osklayout = load Osklayout Osklayout->PATH;
	if(testing == nil || kbdecode == nil || osklayout == nil || rand == nil || math == nil || bufio == nil){
		sys->fprint(sys->fildes(2), "osk_accuracy_test: cannot load a module: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	kbdecode->init();
	osklayout->init();
	for(a := tl args; a != nil; a = tl a)
		case hd a {
		"-v" =>	testing->verbose(1);
		"-nocontext" =>	usecontext = 0;
		"-t" =>	which = 1;
		"-s" =>	which = 2;
		"-l" =>	a = tl a; if(a != nil) only = hd a;
		"-n" =>	a = tl a; if(a != nil) maxwords = int hd a;
		"-seed" =>	a = tl a; if(a != nil) seed = int hd a;
		"-o" =>	a = tl a; if(a != nil) offset = int hd a;
		"-p" =>
			a = tl a;
			if(a != nil){
				(nil, f) := sys->tokenize(hd a, "=");
				if(len f == 2)
					params = (hd f, real hd tl f) :: params;
			}
		}
	lex = Lexicon.new();
	if((err := lex.read("/lib/osk/en.words", 1)) != nil){
		sys->print("osk_accuracy_test: no word list (%s)\n", err);
		raise "skip:no word list";
	}
	if(usecontext && (err = lex.readpairs("/lib/osk/en.pairs")) != nil){
		sys->print("osk_accuracy_test: no word pairs (%s): no context\n", err);
		usecontext = 0;
	}
	t := testing->newTsrc("Phrases", SRCFILE);
	readwords(t);
	if(which & 1){
		if(only == nil || only == "qwerty") run("QwertyTap", testQwertyTap);
		if(only == nil || only == "dvorak") run("DvorakTap", testDvorakTap);
		if(only == nil || only == "colemak") run("ColemakTap", testColemakTap);
	}
	if(which & 2){
		if(only == nil || only == "qwerty") run("QwertySwipe", testQwertySwipe);
		if(only == nil || only == "dvorak") run("DvorakSwipe", testDvorakSwipe);
		if(only == nil || only == "colemak") run("ColemakSwipe", testColemakSwipe);
	}
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
