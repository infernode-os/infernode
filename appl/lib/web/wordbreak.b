implement Wordbreak;

#
# Thai is written without spaces between its words, and a line breaks
# between words, so where it may break comes from a dictionary.  This
# is ICU's ThaiBreakEngine (icu4c/source/common/dictbe.cpp), which is
# what a browser's line breaker uses: take the dictionary word that
# lets the most words follow it (looking three ahead), join what is
# not a word to the word before it, and never break before a mark.
#

include "sys.m";
	sys: Sys;

include "web/wordbreak.m";

dict: array of string;	# the words, in code point order
loaded := 0;

LOOKAHEAD: con 3;		# how many words in a row are good enough
ROOTCOMBINE: con 3;		# a non-word joins a word shorter than this before it
PREFIXCOMBINE: con 3;	# unless it begins like a word for this long
PAIYANNOI: con 16r0E2F;	# the elision mark
MAIYAMOK: con 16r0E46;	# the repetition mark
MINSPAN: con 4;		# letters enough for two words
MAXWORDS: con 20;		# the most words that begin at one place

# the words that begin at one place in the text, shortest first
Cand: adt {
	n:	int;		# how many
	prefix:	int;		# how far the text matched the start of a word
	off:	int;		# where they begin, or -1
	mark:	int;		# the one chosen
	cur:	int;		# the one being tried
	lens:	array of int;
};

pos := 0;	# where in the text we are, as ICU's text index

needs(c: int): int
{
	return c >= 16r0E01 && c <= 16r0E3A || c >= 16r0E40 && c <= 16r0E4E;
}

# a Thai mark: no break comes before one
ismark(c: int): int
{
	return c == 16r0E31 || c >= 16r0E34 && c <= 16r0E3A || c >= 16r0E47 && c <= 16r0E4E;
}

# a letter that may end a word, and one that may begin one
endword(c: int): int
{
	return needs(c) && c != 16r0E31 && !(c >= 16r0E40 && c <= 16r0E44);
}

beginword(c: int): int
{
	return c >= 16r0E01 && c <= 16r0E2E || c >= 16r0E40 && c <= 16r0E44;
}

readdict(): int
{
	if(loaded)
		return dict != nil;
	sys = load Sys Sys->PATH;
	fd := sys->open(DICT, Sys->OREAD);
	if(fd != nil) {
		(ok, d) := sys->fstat(fd);
		if(ok == 0 && d.length > big 0) {
			buf := array[int d.length] of byte;
			n := 0;
			while(n < len buf) {
				r := sys->read(fd, buf[n:], len buf - n);
				if(r <= 0)
					break;
				n += r;
			}
			s := string buf[0:n];
			nw := 0;
			for(i := 0; i < len s; i++)
				if(s[i] == '\n')
					nw++;
			a := array[nw+1] of string;
			k := 0;
			for(i = 0; i < len s; ) {
				j := i;
				while(j < len s && s[j] != '\n')
					j++;
				if(j > i && s[i] != '#')
					a[k++] = s[i:j];
				i = j+1;
			}
			dict = a[0:k];
		}
	}
	loaded = 1;
	return dict != nil;
}

# the first word in [lo, hi), all of which begin with the same k
# letters, whose letter k is c or after it (after it, if past)
bound(lo, hi, k, c, past: int): int
{
	while(lo < hi) {
		m := (lo + hi) / 2;
		w := dict[m];
		x := -1;
		if(len w > k)
			x = w[k];
		if(x < c || past && x == c)
			lo = m+1;
		else
			hi = m;
	}
	return lo;
}

# the words of s that begin at p and end by e (ICU's matches())
matches(s: string, p, e: int, lens: array of int): (int, int)
{
	lo := 0;
	hi := len dict;
	n := 0;
	k := 0;
	while(p+k < e) {
		c := s[p+k];
		lo = bound(lo, hi, k, c, 0);
		hi = bound(lo, hi, k, c, 1);
		k++;
		if(lo >= hi)
			break;
		if(len dict[lo] == k) {
			if(n < len lens)
				lens[n++] = k;
			if(hi - lo == 1)
				break;	# no longer word begins so
		}
	}
	return (n, k);
}

candidates(w: ref Cand, s: string, e: int): int
{
	start := pos;
	if(start != w.off) {
		w.off = start;
		(w.n, w.prefix) = matches(s, start, e, w.lens);
	}
	if(w.n > 0)
		pos = start + w.lens[w.n-1];
	else
		pos = start;
	w.cur = w.n-1;
	w.mark = w.cur;
	return w.n;
}

accept(w: ref Cand): int
{
	pos = w.off + w.lens[w.mark];
	return w.lens[w.mark];
}

backup(w: ref Cand): int
{
	if(w.cur > 0) {
		w.cur--;
		pos = w.off + w.lens[w.cur];
		return 1;
	}
	return 0;
}

breaks(s: string): array of byte
{
	i := 0;
	while(i < len s && !needs(s[i]))
		i++;
	if(i == len s || !readdict())
		return nil;
	brk := array[len s] of {* => byte 0};
	words := array[LOOKAHEAD] of ref Cand;
	while(i < len s) {
		e := i;
		while(e < len s && needs(s[e]))
			e++;
		if(e - i > MINSPAN) {
			for(k := 0; k < LOOKAHEAD; k++)
				words[k] = ref Cand(0, 0, -1, 0, 0, array[MAXWORDS] of int);
			divide(s, i, e, words, brk);
		}
		i = e;
		while(i < len s && !needs(s[i]))
			i++;
	}
	return brk;
}

# ThaiBreakEngine::divideUpDictionaryRange over s[rs:re]
divide(s: string, rs, re: int, words: array of ref Cand, brk: array of byte)
{
	found := 0;
	last := -1;
	pos = rs;
	while(pos < re) {
		cur := pos;
		wlen := 0;
		w := words[found % LOOKAHEAD];
		n := candidates(w, s, re);
		if(n == 1) {
			wlen = accept(w);
			found++;
		} else if(n > 1) {
			# the one that lets the most words follow it
			if(pos < re) {
				best:
				do {
					w1 := words[(found+1) % LOOKAHEAD];
					if(candidates(w1, s, re) > 0) {
						w.mark = w.cur;
						if(pos >= re)
							break best;
						do {
							if(candidates(words[(found+2) % LOOKAHEAD], s, re) > 0) {
								w.mark = w.cur;
								break best;
							}
						} while(backup(w1));
					}
				} while(backup(w));
			}
			wlen = accept(w);
			found++;
		}

		# not a word next: join it to the word before, unless that
		# is long or it looks like the start of a word itself
		uc := 0;
		if(pos < re && wlen < ROOTCOMBINE) {
			w = words[found % LOOKAHEAD];
			if(candidates(w, s, re) <= 0 && (wlen == 0 || w.prefix < PREFIXCOMBINE)) {
				remaining := re - (cur + wlen);
				chars := 0;
				for(;;) {
					pc := s[pos++];
					chars++;
					if(--remaining <= 0)
						break;
					uc = s[pos];
					if(endword(pc) && beginword(uc)) {
						nc := candidates(words[(found+1) % LOOKAHEAD], s, re);
						pos = cur + wlen + chars;
						if(nc > 0)
							break;
					}
				}
				if(wlen <= 0)
					found++;
				wlen += chars;
			} else
				pos = cur + wlen;
		}

		# never stop before a mark
		while(pos < re && ismark(s[pos])) {
			pos++;
			wlen++;
		}

		# the elision and repetition marks end the word before them
		if(pos < re && wlen > 0) {
			w = words[found % LOOKAHEAD];
			if(candidates(w, s, re) <= 0 && ((uc = s[pos]) == PAIYANNOI || uc == MAIYAMOK)) {
				if(uc == PAIYANNOI) {
					if(s[pos-1] != PAIYANNOI && s[pos-1] != MAIYAMOK) {
						pos++;
						wlen++;
						if(pos < len s)
							uc = s[pos];
						else
							uc = -1;
					}
				}
				if(uc == MAIYAMOK) {
					if(s[pos-1] != MAIYAMOK) {
						pos++;
						wlen++;
					}
				}
			} else
				pos = cur + wlen;
		}

		if(wlen > 0) {
			last = cur + wlen;
			if(last < re)
				brk[last] = byte 1;
		}
	}
}
