implement Kbdecode;

#
# What was meant on a keyboard on a screen: module/kbdecode.m says
# what, kbdecode(2) how to tune it.  Costs are negative natural logs
# of probabilities, so they add, and lower is likelier.
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "math.m";
	math: Math;
include "kbdecode.m";

Big:	con 1.0e30;
Maxtap:	con 18.0;		# a tap this far (in cost) from a key is not on it
Nswipe:	con 64;			# a stroke's points, resampled

# a prefix in the search: a trie node, its cost, the edits made
St: adt {
	node:	int;
	cost:	real;
	edits:	int;
};

init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
}

#
# Characters
#

lower(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		return c + 'a' - 'A';
	if(c >= 16rC0 && c <= 16rDE && c != 16rD7)
		return c + 16r20;
	if(c == 16r2019 || c == 16r2018)	# ’ ‘
		return '\'';
	return c;
}

fold(c: int): int
{
	c = lower(c);
	if(c < 16rE0)
		return c;
	case c {
	16rE0 to 16rE5 =>	return 'a';
	16rE7 =>		return 'c';
	16rE8 to 16rEB =>	return 'e';
	16rEC to 16rEF =>	return 'i';
	16rF1 =>		return 'n';
	16rF2 to 16rF6 or 16rF8 =>	return 'o';
	16rF9 to 16rFC =>	return 'u';
	16rFD or 16rFF =>	return 'y';
	}
	return c;
}

isletter(c: int): int
{
	f := fold(c);
	if(f >= 'a' && f <= 'z')
		return 1;
	# other Latin-1 letters (æ, ð, þ, ß) a list may hold
	return c >= 16rDF && c <= 16rFF && c != 16rF7;
}

wordlike(w: string): int
{
	n := 0;
	for(i := 0; i < len w; i++){
		c := w[i];
		if(isletter(c))
			n++;
		else if(lower(c) != '\'')
			return 0;
	}
	return n > 0;
}

#
# The word list: a trie of lower-case words, each word's spellings
#

Lexicon.new(): ref Lexicon
{
	l := ref Lexicon;
	l.nnode = 0;
	n := 1<<12;
	l.ch = array[n] of int;
	l.kid = array[n] of int;
	l.sib = array[n] of int;
	l.term = array[n] of int;
	l.best = array[n] of int;
	l.ndepth = array[n] of int;
	l.nterm = 0;
	m := 1<<10;
	l.forms = array[m] of list of (string, int);
	l.count = array[m] of int;
	l.depth = array[m] of int;
	l.first = array[m] of int;
	l.last = array[m] of int;
	l.casing = array[m] of int;
	l.total = 0.0;
	newnode(l, 0, 0);	# the root
	return l;
}

newnode(l: ref Lexicon, c, depth: int): int
{
	if(l.nnode == len l.ch){
		n := 2 * len l.ch;
		l.ch = growi(l.ch, n);
		l.kid = growi(l.kid, n);
		l.sib = growi(l.sib, n);
		l.term = growi(l.term, n);
		l.best = growi(l.best, n);
		l.ndepth = growi(l.ndepth, n);
	}
	i := l.nnode++;
	l.ch[i] = c;
	l.kid[i] = -1;
	l.sib[i] = -1;
	l.term[i] = -1;
	l.best[i] = -1;
	l.ndepth[i] = depth;
	return i;
}

growi(a: array of int, n: int): array of int
{
	b := array[n] of int;
	b[0:] = a;
	return b;
}

newterm(l: ref Lexicon): int
{
	if(l.nterm == len l.count){
		n := 2 * len l.count;
		f := array[n] of list of (string, int);
		f[0:] = l.forms;
		l.forms = f;
		l.count = growi(l.count, n);
		l.depth = growi(l.depth, n);
		l.first = growi(l.first, n);
		l.last = growi(l.last, n);
		l.casing = growi(l.casing, n);
	}
	t := l.nterm++;
	l.forms[t] = nil;
	l.count[t] = 0;
	return t;
}

child(l: ref Lexicon, n, c: int): int
{
	for(k := l.kid[n]; k >= 0; k = l.sib[k])
		if(l.ch[k] == c)
			return k;
	return -1;
}

Lexicon.add(l: self ref Lexicon, w: string, count: int)
{
	if(count <= 0 || !wordlike(w))
		return;
	path := array[len w + 1] of int;
	n := 0;
	path[0] = 0;
	for(i := 0; i < len w; i++){
		c := lower(w[i]);
		k := child(l, n, c);
		if(k < 0){
			k = newnode(l, c, i+1);
			l.sib[k] = l.kid[n];
			l.kid[n] = k;
		}
		n = k;
		path[i+1] = n;
	}
	t := l.term[n];
	if(t < 0){
		t = newterm(l);
		l.term[n] = t;
		l.depth[t] = len w;
		l.first[t] = -1;
		l.last[t] = -1;
		for(i = 0; i < len w; i++){
			f := fold(w[i]);
			if(f == '\'')
				continue;
			if(l.first[t] < 0)
				l.first[t] = f;
			l.last[t] = f;
		}
	}
	# the spellings, merged
	fl: list of (string, int);
	found := 0;
	for(fs := l.forms[t]; fs != nil; fs = tl fs){
		(s, c) := hd fs;
		if(s == w){
			c += count;
			found = 1;
		}
		fl = (s, c) :: fl;
	}
	if(!found)
		fl = (w, count) :: fl;
	l.forms[t] = fl;
	l.casing[t] = casingof(fl);
	l.chars = nil;		# made again when next wanted
	if(l.count[t] > 16r7fffffff - count)
		l.count[t] = 16r7fffffff;
	else
		l.count[t] += count;
	l.total += real count;
	for(i = 0; i <= len w; i++){
		p := path[i];
		b := l.best[p];
		if(b < 0 || l.count[b] < l.count[t])
			l.best[p] = t;
	}
}

casingof(fl: list of (string, int)): int
{
	c := 2;
	for(; fl != nil; fl = tl fl){
		(s, nil) := hd fl;
		if(s == lowers(s))
			return 0;
		if(len s == 1 || lowers(s[1:]) == s[1:])
			c = 1;
	}
	return c;
}

# A letter's index in the letters' model: a-z, the apostrophe, any
# other, a word's end (and start)
Nch:	con 29;
chix(c: int): int
{
	f := fold(c);
	if(f >= 'a' && f <= 'z')
		return f - 'a';
	if(f == '\'')
		return 26;
	return 27;
}

# the letters' model: a letter after a letter, from the words' shapes
# (each word once, its spellings as one), add-one smoothed
charmodel(l: ref Lexicon)
{
	n := array[Nch*Nch] of {* => 1.0};
	for(t := 0; t < l.nterm; t++){
		w := l.spelling(t);
		p := 28;
		for(i := 0; i < len w; i++){
			c := chix(w[i]);
			n[p*Nch + c] += 1.0;
			p = c;
		}
		n[p*Nch + 28] += 1.0;
	}
	l.chars = array[Nch*Nch] of real;
	for(p := 0; p < Nch; p++){
		sum := 0.0;
		for(c := 0; c < Nch; c++)
			sum += n[p*Nch + c];
		for(c = 0; c < Nch; c++)
			l.chars[p*Nch + c] = -math->log(n[p*Nch + c] / sum);
	}
}

# what w costs as a string of letters, by the letters' model
charcost(l: ref Lexicon, w: string): real
{
	if(l.chars == nil)
		charmodel(l);
	c := 0.0;
	p := 28;
	for(i := 0; i < len w; i++){
		x := chix(w[i]);
		c += l.chars[p*Nch + x];
		p = x;
	}
	return c + l.chars[p*Nch + 28];
}

Lexicon.read(l: self ref Lexicon, path: string, weight: int): string
{
	if(bufio == nil)
		init();
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return sys->sprint("%s: %r", path);
	while((s := b.gets('\n')) != nil){
		if(s[0] == '#' || s[0] == '\n')
			continue;
		(nf, f) := sys->tokenize(s, " \t\r\n");
		if(nf < 1)
			continue;
		c := 1;
		if(nf > 1)
			c = int hd tl f;
		r := real c * real weight;
		if(r > 2.1e9)
			r = 2.1e9;
		l.add(hd f, int r);
	}
	return nil;
}

findterm(l: ref Lexicon, w: string): int
{
	n := 0;
	for(i := 0; i < len w && n >= 0; i++)
		n = child(l, n, lower(w[i]));
	if(n < 0)
		return -1;
	return l.term[n];
}

Lexicon.lookup(l: self ref Lexicon, w: string): int
{
	t := findterm(l, w);
	if(t < 0)
		return 0;
	return l.count[t];
}

lowers(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		r[i] = lower(s[i]);
	return r;
}

Lexicon.spelling(l: self ref Lexicon, t: int): string
{
	best := "";
	bc := -1;
	for(fs := l.forms[t]; fs != nil; fs = tl fs){
		(s, c) := hd fs;
		if(s == lowers(s))
			return s;
		if(c > bc){
			best = s;
			bc = c;
		}
	}
	return best;
}

lmcost(l: ref Lexicon, t: int): real
{
	tot := l.total;
	if(tot < 1.0)
		tot = 1.0;
	return -math->log((real l.count[t] + 1.0) / tot);
}

# the word's cost given the word before: its commonness after that word
# and overall, mixed
ctxcost(d: ref Decoder, t: int): real
{
	if(!d.ctxon || t >= len d.ctx)
		return lmcost(d.lex, t);
	tot := d.lex.total;
	if(tot < 1.0)
		tot = 1.0;
	p := (1.0 - d.context) * (real d.lex.count[t] + 1.0) / tot + d.context * d.ctx[t];
	return -math->log(p);
}

Lexicon.readpairs(l: self ref Lexicon, path: string): string
{
	if(bufio == nil)
		init();
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return sys->sprint("%s: %r", path);
	if(l.pairs == nil || len l.pairs < l.nterm){
		l.pairs = array[l.nterm] of list of (int, int);
		l.pairtot = array[l.nterm] of {* => 0.0};
	}
	while((s := b.gets('\n')) != nil){
		(nf, f) := sys->tokenize(s, "\t\r\n");
		if(nf < 3)
			continue;
		a := findterm(l, hd f);
		c := findterm(l, hd tl f);
		n := int hd tl tl f;
		if(a < 0 || c < 0 || n <= 0)
			continue;
		l.pairs[a] = (c, n) :: l.pairs[a];
		l.pairtot[a] += real n;
	}
	return nil;
}

# a word's cost as the decoder weighs it: its commonness, and its case
wordcost(d: ref Decoder, t: int): real
{
	c := d.lmweight * ctxcost(d, t);
	case d.lex.casing[t] {
	1 =>
		if(d.lex.depth[t] > 1)	# I is no proper noun
			c += d.proper;
	2 =>
		if(d.lex.depth[t] > 1)
			c += d.acronym;
	}
	return c;
}

#
# The decoder
#

Decoder.new(lex: ref Lexicon, keys: array of Key): ref Decoder
{
	if(sys == nil)
		init();
	d := ref Decoder;
	d.lex = lex;
	# tuned against tests/osk_accuracy_test.b's simulated typist, on
	# words and noise of their own (not those its bounds are checked on)
	d.sigma = 0.38;
	d.lmweight = 0.55;
	d.omit = 4.2;
	d.insert = 6.5;
	d.swap = 3.2;
	d.completion = 1.2;
	d.oov = 1.05;
	d.oovbase = 3.5;
	d.proper = 1.5;
	d.acronym = 4.0;
	d.margin = 2.0;
	d.validmargin = 3.5;
	d.context = 0.5;
	d.ctxon = 0;
	d.beam = 160;
	d.ssigma = 0.07;
	d.lsigma = 0.35;
	d.esigma = 0.45;
	d.slmweight = 0.25;
	d.gen = 0;
	d.offx = array[0] of real;
	d.offy = array[0] of real;
	d.nlearn = array[0] of int;
	d.setkeys(keys);
	return d;
}

Decoder.setkeys(d: self ref Decoder, keys: array of Key)
{
	# what was learned stays with the character, whatever the keys'
	# new size: it is in key sizes
	ox := array[256] of {* => 0.0};
	oy := array[256] of {* => 0.0};
	on := array[256] of {* => 0};
	i: int;
	if(d.keys != nil)
		for(i = 0; i < len d.keys; i++){
			c := d.keys[i].c;
			if(c >= 0 && c < 256 && i < len d.nlearn){
				ox[c] = d.offx[i];
				oy[c] = d.offy[i];
				on[c] = d.nlearn[i];
			}
		}
	d.keys = keys;
	d.keyof = array[256] of {* => -1};
	d.offx = array[len keys] of {* => 0.0};
	d.offy = array[len keys] of {* => 0.0};
	d.nlearn = array[len keys] of {* => 0};
	for(i = 0; i < len keys; i++){
		c := fold(keys[i].c);
		if(c >= 0 && c < 256){
			if(d.keyof[c] < 0)
				d.keyof[c] = i;
			d.offx[i] = ox[c];
			d.offy[i] = oy[c];
			d.nlearn[i] = on[c];
		}
	}
	d.tlen = nil;
}

Decoder.setcontext(d: self ref Decoder, prev: string)
{
	for(; d.ctxset != nil; d.ctxset = tl d.ctxset)
		d.ctx[hd d.ctxset] = 0.0;
	d.ctxon = 0;
	lex := d.lex;
	if(prev == nil || lex.pairs == nil)
		return;
	a := findterm(lex, prev);
	if(a < 0 || a >= len lex.pairs || lex.pairs[a] == nil || lex.pairtot[a] <= 0.0)
		return;
	if(d.ctx == nil || len d.ctx < lex.nterm)
		d.ctx = array[lex.nterm] of {* => 0.0};
	for(l := lex.pairs[a]; l != nil; l = tl l){
		(c, n) := hd l;
		d.ctx[c] = real n / lex.pairtot[a];
		d.ctxset = c :: d.ctxset;
	}
	d.ctxon = 1;
}

# scratch arrays as big as the trie
scratch(d: ref Decoder)
{
	n := d.lex.nnode;
	if(d.stamp == nil || len d.stamp < n){
		d.stamp = array[n] of {* => 0};
		d.sbest = array[n] of real;
		d.sedit = array[n] of int;
		d.gen = 0;
	}
	if(d.tlen == nil || len d.tlen < d.lex.nterm)
		d.tlen = array[d.lex.nterm] of {* => -1.0};
}

keyofc(d: ref Decoder, c: int): int
{
	f := fold(c);
	if(f < 0 || f >= 256)
		return -1;
	return d.keyof[f];
}

tapcost(d: ref Decoder, t: Touch, c: int): real
{
	if(t.c != 0){
		if(fold(t.c) == fold(c))
			return 0.0;
		return Big;
	}
	k := keyofc(d, c);
	if(k < 0)
		return Big;
	key := d.keys[k];
	w := real key.w;
	h := real key.h;
	if(w < 1.0)
		w = 1.0;
	if(h < 1.0)
		h = 1.0;
	dx := (real t.x - real key.x) / w - d.offx[k];
	dy := (real t.y - real key.y) / h - d.offy[k];
	return (dx*dx + dy*dy) / (2.0 * d.sigma * d.sigma);
}

# the key a touch is nearest (its learned centre), or -1
nearest(d: ref Decoder, t: Touch): int
{
	bk := -1;
	bd := Big;
	for(k := 0; k < len d.keys; k++){
		key := d.keys[k];
		w := real key.w;
		h := real key.h;
		if(w < 1.0)
			w = 1.0;
		if(h < 1.0)
			h = 1.0;
		dx := (real t.x - real key.x) / w - d.offx[k];
		dy := (real t.y - real key.y) / h - d.offy[k];
		e := dx*dx + dy*dy;
		if(e < bd){
			bd = e;
			bk = k;
		}
	}
	return bk;
}

Decoder.literal(d: self ref Decoder, t: array of Touch): string
{
	s := "";
	for(i := 0; i < len t; i++){
		if(t[i].c != 0){
			s[len s] = t[i].c;
			continue;
		}
		k := nearest(d, t[i]);
		if(k >= 0)
			s[len s] = d.keys[k].c;
	}
	return s;
}

Decoder.literalcost(d: self ref Decoder, t: array of Touch): real
{
	lit := d.literal(t);
	c := 0.0;
	for(i := 0; i < len t && i < len lit; i++)
		c += tapcost(d, t[i], lit[i]);
	tm := findterm(d.lex, lit);
	if(tm >= 0)
		return c + wordcost(d, tm);
	# a word the list does not have: as likely as its letters' shape
	return c + d.lmweight * (d.oovbase + d.oov * charcost(d.lex, lit));
}

maxedits(n: int): int
{
	if(n <= 1)
		return 0;
	if(n <= 3)
		return 1;
	return 2;
}

Decoder.taps(d: self ref Decoder, t: array of Touch, n: int): array of ref Cand
{
	nt := len t;
	if(nt == 0 || n <= 0)
		return nil;
	scratch(d);
	lex := d.lex;
	me := maxedits(nt);
	level := array[nt+2] of list of ref St;
	level[0] = ref St(0, 0.0, 0) :: nil;
	cands: list of ref Cand;
	for(i := 0; i <= nt; i++){
		# this level's prefixes, each node once at its least cost,
		# with the letters of the word passed over (omitted)
		d.gen++;
		g := d.gen;
		uniq: list of int;
		for(l := level[i]; l != nil; l = tl l){
			s := hd l;
			if(d.stamp[s.node] != g){
				d.stamp[s.node] = g;
				d.sbest[s.node] = s.cost;
				d.sedit[s.node] = s.edits;
				uniq = s.node :: uniq;
			}else if(s.cost < d.sbest[s.node]){
				d.sbest[s.node] = s.cost;
				d.sedit[s.node] = s.edits;
			}
		}
		level[i] = nil;
		work := uniq;
		while(work != nil){
			nd := hd work;
			work = tl work;
			c0 := d.sbest[nd];
			e0 := d.sedit[nd];
			for(k := lex.kid[nd]; k >= 0; k = lex.sib[k]){
				c := c0;
				e := e0;
				if(lex.ch[k] == '\'')
					c += 0.4;	# a word's apostrophe, untyped: dont, don't
				else{
					c += d.omit;
					e++;
				}
				if(e > me)
					continue;
				if(d.stamp[k] != g){
					d.stamp[k] = g;
					d.sbest[k] = c;
					d.sedit[k] = e;
					uniq = k :: uniq;
					work = k :: work;
				}else if(c < d.sbest[k]){
					d.sbest[k] = c;
					d.sedit[k] = e;
					work = k :: work;
				}
			}
		}
		# the beam
		nu := 0;
		for(ul := uniq; ul != nil; ul = tl ul)
			nu++;
		sts := array[nu] of ref St;
		j := 0;
		for(ul = uniq; ul != nil; ul = tl ul){
			nd := hd ul;
			sts[j++] = ref St(nd, d.sbest[nd], d.sedit[nd]);
		}
		sortst(sts);
		if(len sts > d.beam)
			sts = sts[0:d.beam];
		if(i == nt){
			cands = finals(d, sts);
			break;
		}
		tp := t[i];
		for(j = 0; j < len sts; j++){
			s := sts[j];
			# a letter of the word, tapped
			for(k := lex.kid[s.node]; k >= 0; k = lex.sib[k]){
				tc := tapcost(d, tp, lex.ch[k]);
				if(tc < Maxtap)
					level[i+1] = ref St(k, s.cost + tc, s.edits) :: level[i+1];
			}
			if(s.edits >= me)
				continue;
			# a tap that is none of the word's
			level[i+1] = ref St(s.node, s.cost + d.insert, s.edits+1) :: level[i+1];
			# two letters tapped in turn, swapped
			if(i+1 < nt){
				tq := t[i+1];
				for(k1 := lex.kid[s.node]; k1 >= 0; k1 = lex.sib[k1]){
					c1 := tapcost(d, tq, lex.ch[k1]);
					if(c1 >= Maxtap)
						continue;
					for(k2 := lex.kid[k1]; k2 >= 0; k2 = lex.sib[k2]){
						if(lex.ch[k2] == lex.ch[k1])
							continue;
						c2 := tapcost(d, tp, lex.ch[k2]);
						if(c2 < Maxtap)
							level[i+2] = ref St(k2, s.cost + c1 + c2 + d.swap, s.edits+1) :: level[i+2];
					}
				}
			}
		}
	}
	return bestcands(cands, n);
}

# the words the prefixes left at the end make: the words they are,
# and the commonest words they begin
finals(d: ref Decoder, sts: array of ref St): list of ref Cand
{
	lex := d.lex;
	cs: list of ref Cand;
	for(j := 0; j < len sts; j++){
		s := sts[j];
		t := lex.term[s.node];
		if(t >= 0)
			cs = ref Cand(lex.spelling(t), s.cost + wordcost(d, t), 0) :: cs;
		b := lex.best[s.node];
		if(b >= 0 && b != t){
			extra := lex.depth[b] - lex.ndepth[s.node];
			c := s.cost + d.completion * real extra + wordcost(d, b);
			cs = ref Cand(lex.spelling(b), c, 1) :: cs;
		}
	}
	return cs;
}

# the n best, a word once (its best), best first
bestcands(cs: list of ref Cand, n: int): array of ref Cand
{
	m := 0;
	for(l := cs; l != nil; l = tl l)
		m++;
	a := array[m] of ref Cand;
	m = 0;
	for(l = cs; l != nil; l = tl l)
		a[m++] = hd l;
	sortcand(a);
	r := array[n] of ref Cand;
	k := 0;
	for(i := 0; i < len a && k < n; i++){
		dup := 0;
		for(j := 0; j < k; j++)
			if(r[j].word == a[i].word){
				dup = 1;
				break;
			}
		if(!dup)
			r[k++] = a[i];
	}
	return r[0:k];
}

sortst(a: array of ref St)
{
	# shell sort: small arrays, no recursion
	n := len a;
	for(gap := n/2; gap > 0; gap /= 2)
		for(i := gap; i < n; i++){
			x := a[i];
			j := i;
			for(; j >= gap && a[j-gap].cost > x.cost; j -= gap)
				a[j] = a[j-gap];
			a[j] = x;
		}
}

sortcand(a: array of ref Cand)
{
	n := len a;
	for(gap := n/2; gap > 0; gap /= 2)
		for(i := gap; i < n; i++){
			x := a[i];
			j := i;
			for(; j >= gap && a[j-gap].cost > x.cost; j -= gap)
				a[j] = a[j-gap];
			a[j] = x;
		}
}

hasdigitorsym(s: string): int
{
	for(i := 0; i < len s; i++)
		if(!isletter(s[i]) && lower(s[i]) != '\'')
			return 1;
	return 0;
}

Decoder.correct(d: self ref Decoder, t: array of Touch, c: array of ref Cand): string
{
	lit := d.literal(t);
	if(lit == nil || hasdigitorsym(lit))
		return nil;
	# a word the list has, in the list's case ("i" is "I")
	tm := findterm(d.lex, lit);
	fix: string;
	if(tm >= 0){
		sp := d.lex.spelling(tm);
		# I, and a name's capital (Dvorak); not an abbreviation's
		# (OT) or a short name's (Te), which are rarely what is meant
		if(sp != lit && lowers(sp) == lit && (sp == "I" || d.lex.casing[tm] == 1 && len sp >= 4))
			fix = sp;
	}
	if(len lit < 2)
		return fix;
	best: ref Cand;
	for(i := 0; i < len c; i++)
		if(!c[i].complete){
			best = c[i];
			break;
		}
	if(best == nil || lowers(best.word) == lowers(lit))
		return fix;
	margin := d.margin;
	if(tm >= 0)
		margin = d.validmargin;
	if(best.cost + margin < d.literalcost(t))
		return best.word;
	return fix;
}

#
# Swipes
#

Pt: adt {
	x, y:	real;
};

# the mean key's size, the unit a stroke is measured in
unit(d: ref Decoder): (real, real)
{
	sw := 0.0;
	sh := 0.0;
	n := 0;
	for(i := 0; i < len d.keys; i++){
		c := fold(d.keys[i].c);
		if(c >= 'a' && c <= 'z'){
			sw += real d.keys[i].w;
			sh += real d.keys[i].h;
			n++;
		}
	}
	if(n == 0 || sw < 1.0 || sh < 1.0)
		return (1.0, 1.0);
	return (sw / real n, sh / real n);
}

# a word's template, through its keys' centres in key units; nil if a
# letter of it has no key
template(d: ref Decoder, t: int, uw, uh: real): array of Pt
{
	lex := d.lex;
	w := lex.spelling(t);
	pts := array[len w] of Pt;
	n := 0;
	lastk := -1;
	for(i := 0; i < len w; i++){
		c := fold(w[i]);
		if(c == '\'')
			continue;
		k := keyofc(d, c);
		if(k < 0)
			return nil;
		if(k == lastk)
			continue;	# a doubled letter is one key
		lastk = k;
		pts[n++] = Pt(real d.keys[k].x / uw, real d.keys[k].y / uh);
	}
	return pts[0:n];
}

pathlen(p: array of Pt): real
{
	l := 0.0;
	for(i := 1; i < len p; i++)
		l += dist(p[i-1], p[i]);
	return l;
}

dist(a, b: Pt): real
{
	dx := a.x - b.x;
	dy := a.y - b.y;
	return math->sqrt(dx*dx + dy*dy);
}

resample(p: array of Pt, n: int): array of Pt
{
	r := array[n] of Pt;
	if(len p == 0)
		return nil;
	if(len p == 1){
		for(i := 0; i < n; i++)
			r[i] = p[0];
		return r;
	}
	total := pathlen(p);
	if(total <= 0.0){
		for(i := 0; i < n; i++)
			r[i] = p[0];
		return r;
	}
	step := total / real (n-1);
	r[0] = p[0];
	k := 1;
	acc := 0.0;		# distance along the path to p[j-1]
	j := 1;
	for(k = 1; k < n-1; k++){
		target := step * real k;
		while(j < len p-1 && acc + dist(p[j-1], p[j]) < target){
			acc += dist(p[j-1], p[j]);
			j++;
		}
		seg := dist(p[j-1], p[j]);
		f := 0.0;
		if(seg > 0.0)
			f = (target - acc) / seg;
		if(f > 1.0)
			f = 1.0;
		r[k] = Pt(p[j-1].x + f*(p[j].x - p[j-1].x), p[j-1].y + f*(p[j].y - p[j-1].y));
	}
	r[n-1] = p[len p-1];
	return r;
}

# the shape: centred, scaled to a unit box
normalise(p: array of Pt): array of Pt
{
	n := len p;
	cx := 0.0;
	cy := 0.0;
	minx := Big;
	miny := Big;
	maxx := -Big;
	maxy := -Big;
	for(i := 0; i < n; i++){
		cx += p[i].x;
		cy += p[i].y;
		if(p[i].x < minx) minx = p[i].x;
		if(p[i].x > maxx) maxx = p[i].x;
		if(p[i].y < miny) miny = p[i].y;
		if(p[i].y > maxy) maxy = p[i].y;
	}
	cx /= real n;
	cy /= real n;
	s := maxx - minx;
	if(maxy - miny > s)
		s = maxy - miny;
	if(s < 1.0e-6)
		s = 1.0;
	r := array[n] of Pt;
	for(i = 0; i < n; i++)
		r[i] = Pt((p[i].x - cx)/s, (p[i].y - cy)/s);
	return r;
}

# the keys (letters) nearest a point, within reach
startkeys(d: ref Decoder, p: Pt, uw, uh: real): array of int
{
	near := array[256] of {* => 0};
	best := array[3] of {* => -1};
	bd := array[3] of {* => Big};
	for(k := 0; k < len d.keys; k++){
		c := fold(d.keys[k].c);
		if(c < 'a' || c > 'z')
			continue;
		e := dist(p, Pt(real d.keys[k].x / uw, real d.keys[k].y / uh));
		if(e > 1.6)
			continue;
		for(i := 0; i < 3; i++)
			if(e < bd[i]){
				for(j := 2; j > i; j--){
					bd[j] = bd[j-1];
					best[j] = best[j-1];
				}
				bd[i] = e;
				best[i] = c;
				break;
			}
	}
	for(i := 0; i < 3; i++)
		if(best[i] >= 0)
			near[best[i]] = 1;
	return near;
}

Decoder.swipe(d: self ref Decoder, path: array of Touch, n: int): array of ref Cand
{
	if(len path < 2 || n <= 0)
		return nil;
	scratch(d);
	lex := d.lex;
	(uw, uh) := unit(d);
	u := array[len path] of Pt;
	for(i := 0; i < len path; i++)
		u[i] = Pt(real path[i].x / uw, real path[i].y / uh);
	lu := pathlen(u);
	if(lu < 0.5)
		return nil;
	ur := resample(u, Nswipe);
	us := normalise(ur);
	sk := startkeys(d, ur[0], uw, uh);
	ek := startkeys(d, ur[Nswipe-1], uw, uh);

	# the location's weights: the ends count most
	alpha := array[Nswipe] of real;
	asum := 0.0;
	mid := real (Nswipe-1) / 2.0;
	for(i = 0; i < Nswipe; i++){
		a := real i - mid;
		if(a < 0.0)
			a = -a;
		alpha[i] = 1.0 + a / mid;
		asum += alpha[i];
	}

	top := array[n] of ref Cand;
	ntop := 0;
	for(t := 0; t < lex.nterm; t++){
		f := lex.first[t];
		l := lex.last[t];
		if(f < 0 || f >= 256 || l < 0 || l >= 256 || !sk[f] || !ek[l])
			continue;
		if(lex.depth[t] < 2)
			continue;
		tln := d.tlen[t];
		tmpl: array of Pt;
		if(tln < 0.0){
			tmpl = template(d, t, uw, uh);
			if(tmpl == nil || len tmpl < 2)
				tln = -2.0;
			else
				tln = pathlen(tmpl);
			d.tlen[t] = tln;
		}
		if(tln == -2.0)
			continue;
		dl := lu - tln;
		if(dl < 0.0)
			dl = -dl;
		if(dl > 2.0 + 0.45*tln)
			continue;
		lm := d.slmweight * ctxcost(d, t);
		case lex.casing[t] {
		1 =>	lm += d.proper;
		2 =>	lm += d.acronym;
		}
		# a cheap bound before the comparison: the word alone
		if(ntop == n && lm >= top[n-1].cost)
			continue;
		if(tmpl == nil)
			tmpl = template(d, t, uw, uh);
		tr := resample(tmpl, Nswipe);
		ts := normalise(tr);
		ds := 0.0;
		for(i = 0; i < Nswipe; i++)
			ds += dist(us[i], ts[i]);
		ds /= real Nswipe;
		# SHARK2's location: nothing while each stays within a key's
		# reach of the other (a tunnel round the template), else how far
		# apart they are, point by point, the ends counting most
		dloc := 0.0;
		if(!intunnel(ur, tr) || !intunnel(tr, ur)){
			for(i = 0; i < Nswipe; i++)
				dloc += alpha[i] * dist(ur[i], tr[i]);
			dloc /= asum;
		}
		# where a stroke begins and ends is where it is aimed most
		# carefully: the keys there count for themselves
		e0 := dist(ur[0], tr[0]);
		e1 := dist(ur[Nswipe-1], tr[Nswipe-1]);
		de := (e0*e0 + e1*e1) / (2.0*d.esigma*d.esigma);
		cost := ds*ds/(2.0*d.ssigma*d.ssigma) + dloc*dloc/(2.0*d.lsigma*d.lsigma) + de + lm;
		if(ntop == n && cost >= top[n-1].cost)
			continue;
		c := ref Cand(lex.spelling(t), cost, 0);
		# into the sorted few
		j := ntop;
		if(ntop < n)
			ntop++;
		else
			j = n-1;
		while(j > 0 && top[j-1].cost > cost){
			top[j] = top[j-1];
			j--;
		}
		top[j] = c;
	}
	return top[0:ntop];
}

# every point of p within Reach of some point of q
Reach: con 0.5;
intunnel(p, q: array of Pt): int
{
	r2 := Reach * Reach;
	for(i := 0; i < len p; i++){
		near := 0;
		for(j := 0; j < len q; j++){
			dx := p[i].x - q[j].x;
			dy := p[i].y - q[j].y;
			if(dx*dx + dy*dy <= r2){
				near = 1;
				break;
			}
		}
		if(!near)
			return 0;
	}
	return 1;
}

#
# Learning where a typist's touches land
#

Decoder.learn(d: self ref Decoder, c: int, t: Touch)
{
	if(t.c != 0)
		return;
	k := keyofc(d, c);
	if(k < 0)
		return;
	key := d.keys[k];
	if(key.w < 1 || key.h < 1)
		return;
	dx := (real t.x - real key.x) / real key.w;
	dy := (real t.y - real key.y) / real key.h;
	if(dx < -0.9 || dx > 0.9 || dy < -0.9 || dy > 0.9)
		return;		# not near enough to be this key's
	n := d.nlearn[k] + 1;
	eta := 1.0 / real (n + 4);	# a mean at first, then slowly moving
	if(eta < 0.04)
		eta = 0.04;
	d.offx[k] = clamp(d.offx[k] + eta*(dx - d.offx[k]), 0.35);
	d.offy[k] = clamp(d.offy[k] + eta*(dy - d.offy[k]), 0.35);
	d.nlearn[k] = n;
}

clamp(v, m: real): real
{
	if(v > m)
		return m;
	if(v < -m)
		return -m;
	return v;
}

Decoder.offsets(d: self ref Decoder): string
{
	s := "";
	for(k := 0; k < len d.keys; k++)
		if(d.nlearn[k] > 0)
			s += sys->sprint("%d %.4f %.4f %d\n", d.keys[k].c, d.offx[k], d.offy[k], d.nlearn[k]);
	return s;
}

Decoder.setoffsets(d: self ref Decoder, s: string)
{
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf < 4)
			continue;
		c := int hd f;
		k := keyofc(d, c);
		if(k < 0)
			continue;
		d.offx[k] = clamp(real hd tl f, 0.35);
		d.offy[k] = clamp(real hd tl tl f, 0.35);
		d.nlearn[k] = int hd tl tl tl f;
	}
}
