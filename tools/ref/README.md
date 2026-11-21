# Rendering against references

Charon is judged by how pages look, against two kinds of reference.

**Acceptance: web-platform-tests reftests.** Each reftest names a
reference page that must render identically. `wptrun.py` renders both
in Charon at 800x600, compares pixels within the test's `<meta
name=fuzzy>`, and writes `summary.txt` (per directory), `results.txt`
(per test) and `index.html` (failures side by side, test vs reference;
`--chromium` adds Chromium's rendering of the test).

```sh
tools/ref/wpt-fetch.sh tmp/wptsrc        # the pinned commit, the suites and what they load
tools/ref/wptrun.py -j 4 tmp/wptsrc $(grep -v '^#' tools/ref/wpt-suites)
tools/ref/wptgate.py --flaky tools/ref/baseline/wpt-flaky.txt \
	tools/ref/baseline/wpt-results.txt.gz tmp/wpt/results.txt
```

**The gate.** WPT is pinned: `wpt-commit` is the commit, `wpt-suites`
the directories held to (about 14,000 reftests), `wpt-paths` what their
tests load, and `wpt-fetch.sh` checks out exactly that (by the commit's
hash, which git checks every object against).
`baseline/wpt-results.txt.gz` is a run at that commit; `wptgate.py`
fails when a test that passed there no longer does, unless
`baseline/wpt-flaky.txt` names it, and counts what newly passes.  It is
a ratchet: a commit that makes more pass moves the baseline up with
`wptgate.py --update baseline results.txt`, and a commit that loses one
either fixes it or says in `baseline/open-regressions.txt` why the test
was wrong to pass.  `.github/workflows/wpt.yml` runs it on every pull
request that touches the engine, and nightly; a failure keeps the run's
`index.html` and pictures as an artifact.  Moving the pin is a change of
its own: a new commit's results, compared with the old by `wptcmp.py`,
committed with the new hash.

Tests with any script are counted as `needs-js`, apart from the pass
rate, even when their pixels happen to match: Charon has no script
engine, and a pass without the script would be luck.  A pass whose
rendering is one flat colour is marked `blank` in `results.txt`: test
and reference showing nothing proves little, and when a fix makes such a
page draw something, the "regression" is a false pass coming to light.

`wptcmp.py before after` lists what changed between two runs, regressions
first, noting those that were blank passes.  `wptdiff.py wptroot test`
renders one test and its reference: test | reference | differences.
`wptserve.py wptroot` serves the tree as wptrun does (XHTML as XHTML,
`?pipe=status(N)`), for looking at tests by hand.

**Real sites, no network: the corpus.** `corpus.py` holds Charon to
real sites that need no site to answer: documentation and project sites
published as files (`corpus/sources`: Python's docs, Rust's book and
standard library, ECMA-262, Bootstrap's site), each fetched by a hash
(an archive's SHA-256, a git commit), served on the loopback at a root of
its own, the same bytes every run.  `corpus/pages` names the pages; each
is rendered at a laptop's and a phone's size and scored as `compare.py`'s
"layout" against Chromium's rendering, which is kept as its 8px cells
(`baseline/corpus/`, a few kilobytes a page), so a run needs no Chromium
and the reference does not move with Chromium's releases.
`baseline/corpus-scores.txt` holds the scores; `gate` fails a page that
moves further from Chromium than it by more than 0.01, and `--update`
moves it with the commit that earns it.  Each page is timed too (load
and layout, then paint), into `times.txt`, and held to
`baseline/corpus-times.txt` scaled by the run's total over its own (a
CI runner is not the machine the baseline was taken on): a page that
takes 1.6 times its share and 150 ms more fails.  `wpt.yml` runs it
after the reftests.

```sh
tools/ref/corpus.py fetch tmp/corpussrc       # by the pins: about 250 MB
tools/ref/corpus.py run tmp/corpussrc tmp/corpus
tools/ref/corpus.py gate tmp/corpus           # tmp/corpus/index.html: Charon beside the cells
tools/ref/corpus.py ref tmp/corpussrc         # Chromium's cells again (Playwright): when the pins change
```

**Real pages: Chromium.** `compare.py` renders a URL in headless Chromium
(scripts off, which is the fair comparison) and in Charon, and writes
`<n>.png`: Chromium | Charon | differences in red, with an exact and a
layout score (the share of 8px cells that differ, which forgives glyph
rasterisation but not misplaced boxes).

```sh
tools/ref/mirror.py &          # https://<host>/<path> as http://127.0.0.1:8780/<host>/<path>
tools/ref/compare.py -o /tmp/live http://127.0.0.1:8780/pypi.org/
```

`boxdiff.py url` lists the elements whose border boxes differ from
Chromium's, in document order: the first wrong one usually explains the
rest.  `acid2.py wptroot` checks Acid2 against Chromium.

The reference Chromium is given Charon's typefaces as Charon lays them
out (`fonts.conf`): Arial, Helvetica, sans-serif and the system stacks
as Liberation Sans, Times and serif as Liberation Serif (Charon draws
them with TeX Gyre Heros's and Termes's advances and Arial's and Times's
vertical metrics, which Liberation has both of; Heros itself gave
Chromium a taller line), the rest as DejaVu, as `appl/lib/web/fonts.b`
chooses them, so text width measures layout, not the choice of font.
Making the corpus's references needs the host's Liberation fonts
(`fonts-liberation`).

`mirror.py` fetches live sites on the host and caches them, rewriting
their URLs to point back at itself, so both browsers render the same
bytes and Charon, which fetches through webfs, needs no route to the
site. `--offline` replays only the cache.

Pieces: `shot.js` (Chromium, via Playwright), `p9img.py` (reads Inferno
images), `tests/charonbatch.b` (renders a list of pages in one emu).
