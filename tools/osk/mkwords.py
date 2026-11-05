#!/usr/bin/env python3
#
# mkwords.py — helper for tools/osk/mkwords.sh, which builds
# lib/osk/en.words (the on-screen keyboard's English lexicon).
# Run it with `python3 -I`; it imports only the standard library.
#
#   mkwords.py vocab FINALDIR MAXSIZE
#       The SCOWL word list `mk-list -v1 --accents=both en_US en_GB-ise
#       en_GB-ize MAXSIZE` would print: American and British spellings
#       both, -ise and -ize (english, special, american, variant_1,
#       british, british_z, british_variant_1; every sub-category, sizes
#       <= MAXSIZE; each accented word also without its accents),
#       reimplemented here rather than running the downloaded Perl.
#       Prints `word<TAB>size`, size the smallest SCOWL size the word is
#       in, UTF-8, sorted.
#
#   mkwords.py keys N VOCAB
#       The ngrams each word is counted as, `ngram<TAB>word`.  For N=1
#       the word itself.  For N=2 what Google's tokenizer made of it
#       (https://books.google.com/ngrams/info, "How does the Ngram
#       Viewer handle punctuation?"): a clitic split off ("it's" is
#       `it 's`, "John's" `John 's`, "I'm" `I 'm`, "they're" `they 're`),
#       a fused word split as the Penn Treebank does ("cannot" is
#       `can not`, "gonna" `gon na`), and a negation normalized: "don't"
#       is `do not`, "can't" `can not`, "won't" `will not`.  So a word
#       with n't is counted with its expansion, which the data cannot
#       tell from it; and "cannot" and "can't" both have `can not`.
#       The split forms (`do n't`) are counted too.  The 1-gram files
#       hold such a word whole only where the tokenizer missed it, a
#       fraction of a percent of its uses.
#
#   mkwords.py count KEYS MINYEAR MD5 SHA256 < shard.gz
#       Reads one gzipped Google Books Ngram shard on standard input,
#       checks its MD5 (Google's, from the object's x-goog-hash) and
#       SHA-256 (recorded in mkwords.sh), and prints `word<TAB>count`:
#       match_count summed over years >= MINYEAR for each KEYS ngram,
#       matched case-sensitively and whole, so an ngram with a
#       part-of-speech tag (`do_VERB n't`) is never one of them.
#       A SHA256 of `-` checks nothing and prints the digest to stderr.
#       Given VOCAB, PAIRS and MINPAIR too (a 2-gram shard), it also
#       writes to PAIRS `first<TAB>second<TAB>count` for each untagged
#       2-gram both of whose words are VOCAB words when lower-cased,
#       summed by lower-cased pair, from the lines with a count of at
#       least MINPAIR.  A clitic (`'s`, `n't`) is no VOCAB word, so `it
#       's` is no pair; a contraction the tokenizer left whole is one.
#
#   mkwords.py merge VOCAB MAXLINES KEEPSIZE COUNTS...
#       Sums the counts, gives a word with none a count of 1 if its
#       size is <= KEEPSIZE (else drops it), keeps the MAXLINES most
#       frequent, and prints `word<TAB>count` by count descending (then
#       by word), the counts scaled so the largest is 2147483647 (the
#       largest Limbo int) and none is below 1.
#
#   mkwords.py pairs WORDS MAXPAIRS MINPAIR PAIRS...
#       Sums count's pairs, keeps those whose words are both WORDS words
#       (the merged lexicon) when lower-cased, and prints the MAXPAIRS
#       most frequent, `first<TAB>second<TAB>count`, by first word and
#       then count descending, scaled as merge scales.

import hashlib
import os
import re
import sys
import unicodedata
import zlib

INTMAX = 2147483647

# mk-list's spelling categories for `-v1 en_US en_GB-ise en_GB-ize`.
CATEGORIES = ("english", "special", "american", "variant_1",
              "british", "british_z", "british_variant_1")

# mk-list's deaccent() table (ISO-8859-1 accented letters).
ACCENTED = "ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØÙÚÛÜÝàáâãäåçèéêëìíîïñòóôõöøùúûüýÿ"
PLAIN = "AAAAAACEEEEIIIINOOOOOOUUUUYaaaaaaceeeeiiiinoooooouuuuyy"
DEACCENT = str.maketrans(ACCENTED, PLAIN)

FILE_RE = re.compile(r"^(\w+)-([^.]+)\.(\d\d)")

# Clitics the tokenizer splits off ("n't" before the others).
CLITICS = ("n't", "'s", "'m", "'re", "'ll", "'ve", "'d")

# What a negation's stem is in its expansion, where it is not itself.
NEGATED = {"ca": "can", "wo": "will", "sha": "shall"}

# Words it splits without an apostrophe.
FUSED = {
    "cannot": "can not",
    "gonna": "gon na",
    "gotta": "got ta",
    "wanna": "wan na",
    "gimme": "gim me",
    "lemme": "lem me",
}


def stdout():
    # UTF-8 whatever the locale says
    return open(sys.stdout.fileno(), "w", encoding="utf-8", newline="\n",
                closefd=False)


def die(msg):
    sys.stderr.write("mkwords.py: %s\n" % msg)
    sys.exit(1)


def vocab(finaldir, maxsize):
    maxsize = int(maxsize)
    best = {}
    for name in sorted(os.listdir(finaldir)):
        m = FILE_RE.match(name)
        if not m or m.group(1) not in CATEGORIES:
            continue
        size = int(m.group(3))
        if size > maxsize:
            continue
        with open(os.path.join(finaldir, name), encoding="iso-8859-1") as f:
            for line in f:
                w = line.rstrip("\n")
                if not w:
                    continue
                for v in (w, w.translate(DEACCENT)):
                    v = unicodedata.normalize("NFC", v)
                    if v not in best or size < best[v]:
                        best[v] = size
    out = stdout()
    for w in sorted(best):
        out.write("%s\t%d\n" % (w, best[w]))
    out.close()


def readvocab(path):
    sizes = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            w, s = line.rstrip("\n").split("\t")
            sizes[w] = int(s)
    return sizes


def split2(w):
    if w in FUSED:
        return [FUSED[w]]
    for c in CLITICS:
        if w.endswith(c) and len(w) > len(c):
            stem = w[:-len(c)]
            k = [stem + " " + c]
            if c == "n't":
                k.append(stem + " not")
                if stem in NEGATED:
                    k.append(NEGATED[stem] + " not")
            return k
    return []


def keys(n, vocabpath):
    out = stdout()
    for w in sorted(readvocab(vocabpath)):
        for k in ([w] if n == "1" else split2(w)):
            out.write("%s\t%s\n" % (k, w))
    out.close()


def count(keyspath, minyear, md5want, sha256want, pairvocab=None,
          pairpath=None, minpair=0):
    minyear = int(minyear)
    minpair = int(minpair)
    words = {}
    with open(keyspath, encoding="utf-8") as f:
        for line in f:
            k, w = line.rstrip("\n").split("\t")
            words.setdefault(k.encode("utf-8"), []).append(w)
    lower = None
    if pairvocab is not None:
        lower = set(w.lower().encode("utf-8") for w in readvocab(pairvocab))
    md5 = hashlib.md5()
    sha = hashlib.sha256()
    totals = {}
    pairs = {}
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    rest = b""
    inp = sys.stdin.buffer
    nbytes = 0

    def total(rec):
        # rec is year,match_count,volume_count fields, years ascending
        n = 0
        for f in reversed(rec.split(b"\t")):
            y, c, _ = f.split(b",")
            if int(y) < minyear:
                break
            n += int(c)
        return n

    def fold(t):
        lt = t.lower()
        if lt in lower or lt.isascii():
            return lt
        return t.decode("utf-8", "replace").lower().encode("utf-8")

    def lines(data):
        nonlocal rest
        parts = (rest + data).split(b"\n")
        rest = parts.pop()
        for line in parts:
            i = line.find(b"\t")
            tok = line[:i]
            n = -1
            if tok in words:
                n = total(line[i + 1:])
                if n:
                    totals[tok] = totals.get(tok, 0) + n
            if lower is None:
                continue
            j = tok.find(b" ")
            a = fold(tok[:j])
            if a not in lower:
                continue
            b = fold(tok[j + 1:])
            if b not in lower:
                continue
            if n < 0:
                n = total(line[i + 1:])
            if n >= minpair:
                k = a + b" " + b
                pairs[k] = pairs.get(k, 0) + n

    while True:
        chunk = inp.read(1 << 20)
        if not chunk:
            break
        nbytes += len(chunk)
        md5.update(chunk)
        sha.update(chunk)
        while chunk:
            lines(d.decompress(chunk))
            if d.eof:
                # another gzip member follows
                chunk = d.unused_data
                d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            else:
                chunk = b""
    if nbytes == 0:
        die("empty input")
    if md5.hexdigest() != md5want:
        die("md5 %s, want %s" % (md5.hexdigest(), md5want))
    if sha256want == "-":
        sys.stderr.write("sha256 %s\n" % sha.hexdigest())
    elif sha.hexdigest() != sha256want:
        die("sha256 %s, want %s" % (sha.hexdigest(), sha256want))
    # a broken transfer ends in part of a line: checked before it is read
    lines(d.flush())
    if rest:
        lines(b"\n")
    out = stdout()
    for tok in sorted(totals):
        for w in words[tok]:
            out.write("%s\t%d\n" % (w, totals[tok]))
    out.close()
    if pairpath is not None:
        with open(pairpath, "w", encoding="utf-8", newline="\n") as out:
            for k in sorted(pairs):
                a, b = k.decode("utf-8", "replace").split(" ")
                out.write("%s\t%s\t%d\n" % (a, b, pairs[k]))


def merge(vocabpath, maxlines, keepsize, files):
    maxlines = int(maxlines)
    keepsize = int(keepsize)
    sizes = readvocab(vocabpath)
    totals = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            for line in f:
                w, n = line.rstrip("\n").split("\t")
                if w not in sizes:
                    die("%s: %r not in the vocabulary" % (path, w))
                totals[w] = totals.get(w, 0) + int(n)
    for w, s in sizes.items():
        if w not in totals and s <= keepsize:
            totals[w] = 1
    ranked = sorted(totals.items(), key=lambda kv: (-kv[1], kv[0]))[:maxlines]
    top = ranked[0][1]
    out = stdout()
    for w, n in ranked:
        if top > INTMAX:
            n = max(1, n * INTMAX // top)
        out.write("%s\t%d\n" % (w, n))
    out.close()
    sys.stderr.write("mkwords.py: %d words counted, %d kept, top raw count %d\n"
                     % (len(totals), len(ranked), top))


def pairs(wordspath, maxpairs, minpair, files):
    maxpairs = int(maxpairs)
    minpair = int(minpair)
    lower = set()
    with open(wordspath, encoding="utf-8") as f:
        for line in f:
            lower.add(line.split("\t")[0].lower())
    totals = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            for line in f:
                a, b, n = line.rstrip("\n").split("\t")
                if a in lower and b in lower:
                    k = (a, b)
                    totals[k] = totals.get(k, 0) + int(n)
    ranked = sorted(totals.items(), key=lambda kv: (-kv[1], kv[0]))[:maxpairs]
    top = ranked[0][1]
    cut = ranked[-1][1]
    # count dropped a shard's lines under minpair.  A pair has lines in
    # a few shards at most (one per case of its first word), so with
    # the last pair kept at 20 times minpair what was dropped changes
    # little and leaves out no pair that should be in.
    if cut < 20 * minpair:
        die("pair cutoff %d is under 20 times the shards' minimum %d"
            % (cut, minpair))
    out = stdout()
    for (a, b), n in sorted(ranked, key=lambda kv: (kv[0][0], -kv[1], kv[0][1])):
        if top > INTMAX:
            n = max(1, n * INTMAX // top)
        out.write("%s\t%s\t%d\n" % (a, b, n))
    out.close()
    sys.stderr.write("mkwords.py: %d pairs counted, %d kept, raw counts %d to %d\n"
                     % (len(totals), len(ranked), top, cut))


def main(argv):
    if len(argv) == 4 and argv[1] == "vocab":
        vocab(argv[2], argv[3])
    elif len(argv) == 4 and argv[1] == "keys" and argv[2] in ("1", "2"):
        keys(argv[2], argv[3])
    elif len(argv) == 6 and argv[1] == "count":
        count(argv[2], argv[3], argv[4], argv[5])
    elif len(argv) == 9 and argv[1] == "count":
        count(*argv[2:9])
    elif len(argv) >= 6 and argv[1] == "merge":
        merge(argv[2], argv[3], argv[4], argv[5:])
    elif len(argv) >= 6 and argv[1] == "pairs":
        pairs(argv[2], argv[3], argv[4], argv[5:])
    else:
        die("usage: vocab FINALDIR MAXSIZE | keys 1|2 VOCAB"
            " | count KEYS MINYEAR MD5 SHA256 [VOCAB PAIRS MINPAIR]"
            " | merge VOCAB MAXLINES KEEPSIZE COUNTS..."
            " | pairs WORDS MAXPAIRS MINPAIR PAIRS...")


if __name__ == "__main__":
    main(sys.argv)
