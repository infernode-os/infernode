#!/usr/bin/env python3
"""wptgate.py - fail if a web-platform-tests reftest that passed no longer does.

    tools/ref/wptgate.py [--flaky FILE] [--update] baseline results.txt

baseline is tools/ref/baseline/wpt-results.txt.gz (gzip or plain), the
results of tools/ref/wptrun.py at the WPT commit tools/ref/wpt-commit
names; results.txt is a run's.  A test that passed in the baseline and
does not now is a regression, and the gate fails, unless --flaky names
it (a line per test path; # comments): a test whose result changes from
one identical run to the next proves nothing either way.

A regression that was a blank pass (test and reference one flat colour)
is listed but does not fail the gate: such a pass proves little, and a
fix that makes the page draw something brings it to light.  A test the
baseline has and the run does not is a failure too: the run was not
the same.

What newly passes is counted.  --update writes results.txt over the
baseline (as gzip), for a commit that changes what passes: the gate is
a ratchet, and the baseline is moved up with the fix that earns it.
"""
import argparse, gzip, sys


def load(path):
    opener = gzip.open if path.endswith('.gz') else open
    res, blank = {}, set()
    with opener(path, 'rt') as f:
        for line in f:
            fs = line.split()
            if len(fs) < 2:
                continue
            res[fs[1]] = fs[0]
            if fs[0] == 'PASS' and 'blank' in fs[2:]:
                blank.add(fs[1])
    return res, blank


def flaky(path):
    out = set()
    if path:
        for line in open(path):
            line = line.split('#')[0].strip()
            if line:
                out.add(line.split()[0])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--flaky')
    ap.add_argument('--update', action='store_true')
    ap.add_argument('baseline')
    ap.add_argument('results')
    a = ap.parse_args()
    base, baseblank = load(a.baseline)
    now, _ = load(a.results)
    skip = flaky(a.flaky)

    lost = sorted(t for t, s in base.items() if s == 'PASS' and now.get(t, 'MISSING') != 'PASS')
    hard = [t for t in lost if t not in skip and t not in baseblank and t in now]
    soft = [t for t in lost if t not in skip and t in baseblank and t in now]
    missing = sorted(t for t in base if t not in now)
    won = sorted(t for t, s in now.items() if s == 'PASS' and base.get(t) != 'PASS')
    pb = sum(1 for s in base.values() if s == 'PASS')
    pn = sum(1 for s in now.values() if s == 'PASS')
    print('wpt: pass %d -> %d of %d (%+d): %d newly passing, %d regressions, %d former blank passes failing, %d flaky ignored, %d missing'
          % (pb, pn, len(now), pn - pb, len(won), len(hard), len(soft), len([t for t in lost if t in skip]), len(missing)))
    for t in hard:
        print('REGRESSION %s %s' % (now[t], t))
    for t in soft:
        print('BLANKPASS-LOST %s %s' % (now[t], t))
    for t in missing[:50]:
        print('MISSING %s' % t)
    if len(missing) > 50:
        print('MISSING ... %d more' % (len(missing) - 50))
    if a.update:
        with open(a.results) as f, gzip.open(a.baseline, 'wt') as g:
            g.writelines(sorted(f, key=lambda l: (l.split()[1:2], l)))
        print('wpt: baseline updated: %s' % a.baseline)
        return 0
    if hard or missing:
        print('wpt: FAIL: a test that passed does not (tools/ref/wptdiff.py shows one)')
        return 1
    if won:
        print('wpt: %d more pass than the baseline: move it up with --update in the commit that earns it' % len(won))
    return 0


if __name__ == '__main__':
    sys.exit(main())
