#!/usr/bin/env python3
"""
Card acceptance: what is on the board's card is what the build produced.

The kernel carries a shell and a few utilities; everything else the
system runs is loaded from the card's dis, lib, fonts and icons trees.
Nothing else checks those. A module that is missing, stale, or present
under the wrong name fails only when something asks for it, which for
most modules is never during a battery or a soak -- seventeen were
unreachable under their real names on the bench card for sixteen days
(a long-name entry lost: lib/mailparse.dis listed as mail~155.dis) and
the first thing to notice was this comparison.

So: checksum every file under each tree on the card (md5sum on the
board, one console session per tree), checksum the same trees in the
build, and compare by NAME and by SUM.

  mis-named   on the card under a FAT short alias (NAME~N.EXT) with the
              sum of a build file that is missing under its own name
  missing     in the build, not on the card
  stale       on both, different sums
  extra       on the card only; reported, not failed (a card may carry
              local files, and the board writes some itself)
  folded      an upper-case name that fits 8.3 lists in lower case; noted

Run it after writing a card and before a soak. --fix prints the board
commands that would repair what it found; it changes nothing itself.

Usage: card.py --board 192.168.1.104 --root /path/to/infernode [--trees dis,lib] [--fix]
"""
import hashlib, os, re, sys
from board import Board, args

CARD = "/n/dos"
# built on the card's behalf but not from these trees, or written by the board
IGNORE = re.compile(r"^dis/stage/|\.sbl$|/\.|^lib/ndb/local$")

def build_sums(root, tree):
    out = {}
    top = os.path.join(root, tree)
    for d, _, files in os.walk(top):
        for f in files:
            p = os.path.join(d, f)
            rel = os.path.relpath(p, root)
            if IGNORE.search(rel) or os.path.islink(p) and not os.path.exists(p):
                continue
            out[rel] = hashlib.md5(open(p, "rb").read()).hexdigest()
    return out

def card_sums(b, tree):
    # du -an names every file beneath a directory; md5sum complains about
    # the directories among them, and that goes nowhere
    text = b.sh("cd %s" % CARD,
                "md5sum `{du -an %s | sed 's/^[0-9]*[ \t]*//'} > /tmp/cardsums >[2] /dev/null; echo CARDSUMS-''DONE" % tree,
                wait=2.0, until="CARDSUMS-DONE")
    if "CARDSUMS-DONE" not in text:
        return None
    text = b.sh("cat /tmp/cardsums; echo CARDSUMS-''END", "rm -f /tmp/cardsums", wait=2.0, until="CARDSUMS-END")
    out = {}
    for l in text.replace("\r", "").splitlines():
        m = re.match(r"^([0-9a-f]{32})\s+(\S.*)$", l)
        if m and not IGNORE.search(m.group(2)):
            out[m.group(2)] = m.group(1)
    return out

def main():
    ap = args(__doc__.split("\n")[1])
    ap.add_argument("--root", default=os.environ.get("ROOT", os.getcwd()), help="the built tree the card should match")
    ap.add_argument("--trees", default="dis,lib,fonts,icons")
    ap.add_argument("--fix", action="store_true", help="print the board commands that would repair the card")
    a = ap.parse_args()
    b = Board(a.board, token_file=a.token, serial_log=a.serial_log)
    fixes = []
    for tree in a.trees.split(","):
        want = build_sums(a.root, tree)
        if not want:
            b.skip("%s: compared with the build" % tree, "no %s in %s" % (tree, a.root))
            continue
        have = card_sums(b, tree)
        if not b.check(have is not None and len(have) > 0, "%s: the card's files could be read and summed" % tree):
            continue
        missing = sorted(set(want) - set(have))
        extra = sorted(set(have) - set(want))
        stale = sorted(f for f in want if f in have and want[f] != have[f])
        # an extra file with a short-alias name and a missing file's sum is that file, mis-named
        bysum = {}
        for f in missing:
            bysum.setdefault(want[f], []).append(f)
        misnamed = [(f, bysum[have[f]][0]) for f in extra
                    if "~" in os.path.basename(f) and have[f] in bysum and os.path.dirname(bysum[have[f]][0]) == os.path.dirname(f)]
        for alias, real in misnamed:
            missing.remove(real); extra.remove(alias)
        # FAT keeps a name that fits 8.3 in upper case in the short entry alone,
        # and dossrv reads it back in lower case: README.pgw is there, and answers
        # to either spelling, but lists as readme.pgw. Not a fault of the card.
        folded = [(x, m) for m in missing for x in extra if x.lower() == m.lower() and have[x] == want[m]]
        for x, m in folded:
            missing.remove(m); extra.remove(x)
        show = lambda l: ", ".join(l[:6]) + (" ... %d in all" % len(l) if len(l) > 6 else "")
        b.check(not misnamed, "%s: every file answers to its own name (%d files)" % (tree, len(want)),
                show(["%s is there as %s" % (r, os.path.basename(al)) for al, r in misnamed]))
        b.check(not missing, "%s: nothing the build has is missing from the card" % tree, show(missing))
        b.check(not stale, "%s: nothing on the card differs from the build" % tree, show(stale))
        if folded:
            print("note: %s: %d listed in lower case (8.3 names): %s" % (tree, len(folded), show([x for x, _ in folded])), flush=True)
        if extra:
            print("note: %s: %d on the card only: %s" % (tree, len(extra), show(extra)), flush=True)
        for alias, real in misnamed:
            fixes.append("rm %s/%s" % (CARD, alias))
        for f in [r for _, r in misnamed] + missing + stale:
            fixes.append("cp SRC/%s %s/%s" % (f, CARD, f))
    if a.fix and fixes:
        print("# with the build mounted at SRC:")
        print("\n".join(fixes))
    sys.exit(0 if b.summary() else 1)

if __name__ == "__main__":
    main()
