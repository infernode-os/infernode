#!/usr/bin/env python3
"""
tools/entropy/assess.py - SP 800-90B's assessment of a hardware
generator's bytes, as a board's rngassess boot gives them
(docs/ENTROPY-ASSESSMENT.md).

    assess.py [-n DIR] [-c CLAIM] [-b BOOTS] [-l BOOTLOG] [-d DUMPS] [-o REPORT] RAW [RAW...]

RAW is a file of #c/hwrandom bytes (rngdump -n 1000000 or more), one a
board; several RAW files are several boards (or several runs) and are
also checked against one another. BOOTS is /n/dos/rngboot.bin from a
restart collection: each boot's first 4096 bytes, one boot after
another, a thousand boots or more. CLAIM is the entropy a byte the
kernel assumes (os/port/random.c, 4).

What it does, each estimate NIST's own tool's (build-nist.sh):

  - the non-IID estimators (90B 6.3) on each RAW: H_original,
    H_bitstring, and their minimum, the entropy a byte to credit;
  - the IID tests (90B 5): if they pass, the IID estimate (6.3.1) too;
  - with BOOTS, the restart test (90B 3.1.4): the first 1000 bytes of
    each of the first 1000 boots as the 1000 x 1000 row dataset, at the
    entropy found above; and no two boots beginning with the same 32
    bytes;
  - across RAW files, no 32-byte block of one in another.

BOOTLOG is the restart collection's rngboot.log (taken from beside
BOOTS when not given), and DUMPS a file of the lines rngdump printed for
the RAW files: the board's own record of power and heat (#P/throttled,
#P/cputemp) for each boot and capture. They do not change the verdict,
which is about the bytes; a CONDITIONS line says whether any sample
was taken under under-voltage or throttling, or that nothing recorded
it, so that a result on a bad supply is not taken for a clean one.

It ends with one line a verdict: PASS when every RAW credits at least
CLAIM bits a byte, the restart test passes and nothing repeats; FAIL
otherwise, with the reasons. Exit status 0 for PASS, 1 for FAIL, 2 for
an error. A PASS says the generator behaved like an entropy source of
that rate in these samples. It does not say the source is what it
claims to be: output a block conditions (a hash, a DRBG) passes every
test whatever is beneath it. The document says which boards that is.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

ROWS = 1000
COLS = 1000
FIRST = 4096
BLOCK = 32


def nistdir(given):
    if given:
        return given
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run([os.path.join(here, "build-nist.sh")],
                       stdout=subprocess.PIPE, check=True, text=True)
    return r.stdout.strip().splitlines()[-1]


def run(cmd):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return r.returncode, r.stdout


def num(pat, text):
    m = re.search(pat, text)
    return float(m.group(1)) if m else None


def noniid(nist, path):
    rc, out = run([os.path.join(nist, "ea_non_iid"), path, "8"])
    h = num(r"min\(H_original, 8 X H_bitstring\):\s*([0-9.]+)", out)
    if h is None:
        raise RuntimeError("ea_non_iid on %s gave no estimate:\n%s" % (path, out[-2000:]))
    return {
        "H_original": num(r"H_original:\s*([0-9.]+)", out),
        "H_bitstring": num(r"H_bitstring:\s*([0-9.]+)", out),
        "H": h,
    }


def iid(nist, path):
    rc, out = run([os.path.join(nist, "ea_iid"), path, "8"])
    failed = re.findall(r"\*\* Failed ([^\n]*)", out)
    passed = not failed and "Passed IID permutation tests" in out
    h = num(r"min\(H_original, 8 X H_bitstring\):\s*([0-9.]+)", out)
    return {"passed": passed, "failed": failed, "H": h}


def restart(nist, boots, h, tmp):
    data = open(boots, "rb").read()
    n = len(data) // FIRST
    res = {"boots": n, "repeats": [], "ran": False}
    firsts = {}
    for i in range(n):
        k = data[i*FIRST:i*FIRST+BLOCK]
        if k in firsts:
            res["repeats"].append((firsts[k], i))
        else:
            firsts[k] = i
    if n < ROWS:
        return res
    rows = bytearray()
    for i in range(ROWS):
        rows += data[i*FIRST:i*FIRST+COLS]
    path = os.path.join(tmp, "rows.bin")
    open(path, "wb").write(rows)
    rc, out = run([os.path.join(nist, "ea_restart"), "-n", path, "8", "%.6f" % h])
    res["ran"] = True
    res["passed"] = "Validation Test Passed" in out
    res["H_r"] = num(r"H_r:\s*([0-9.]+)", out)
    res["H_c"] = num(r"H_c:\s*([0-9.]+)", out)
    res["H_min"] = num(r"min\(H_r, H_c, H_I\):\s*([0-9.]+)", out)
    res["out"] = out
    return res


Flags = {0: "under-voltage", 1: "arm-capped", 2: "throttled", 3: "soft-temp-limit"}


def health(path, key):
    """Records of #P/throttled and #P/cputemp in a file: rngboot.log's
    'throttled=0x... cputemp=...' lines, or rngdump's lines with
    throttled0/1 and cputemp0/1. Returns (records, flagged, temps):
    flagged maps each condition to the records that had it, now or since
    boot."""
    recs = 0
    flagged = {}
    temps = []
    for line in open(path, errors="replace"):
        f = dict(w.split("=", 1) for w in line.split() if "=" in w)
        words = [k for k in f if k.startswith("throttled")]
        if not words:
            continue
        recs += 1
        for k in words:
            v = f[k]
            if not v.startswith("0x"):
                continue
            n = int(v, 16)
            for bit, name in Flags.items():
                if n & (1 << bit) or n & (1 << (16 + bit)):
                    flagged.setdefault(name, set()).add(recs)
        for k in f:
            if k.startswith("cputemp"):
                try:
                    temps.append(float(f[k]))
                except ValueError:
                    pass
    return recs, flagged, temps


def conditions(say, label, path):
    if path is None or not os.path.exists(path):
        say("conditions (%s): not recorded" % label)
        return "%s: no record of power and heat" % label
    recs, flagged, temps = health(path, label)
    t = " (SoC %.1f to %.1f C)" % (min(temps), max(temps)) if temps else ""
    if recs == 0:
        say("conditions (%s): %s holds no records" % (label, path))
        return "%s: no record of power and heat" % label
    if not flagged:
        say("conditions (%s): %d records, no under-voltage or throttling%s" % (label, recs, t))
        return None
    parts = ["%s in %d" % (k, len(v)) for k, v in sorted(flagged.items())]
    say("conditions (%s): %d records: %s%s" % (label, recs, ", ".join(parts), t))
    return "%s: %s of %d records" % (label, ", ".join(parts), recs)


def crossrepeats(paths):
    seen = {}
    found = []
    for p in paths:
        d = open(p, "rb").read()
        for off in range(0, len(d) - BLOCK + 1, BLOCK):
            k = d[off:off+BLOCK]
            if k in seen and seen[k][0] != p:
                found.append((seen[k], (p, off)))
                if len(found) >= 5:
                    return found
            seen.setdefault(k, (p, off))
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-n", "--nist", help="directory of ea_non_iid, ea_iid, ea_restart")
    ap.add_argument("-c", "--claim", type=float, default=4.0, help="bits a byte the kernel assumes")
    ap.add_argument("-b", "--boots", help="a restart collection (rngboot.bin)")
    ap.add_argument("-l", "--bootlog", help="the restart collection's rngboot.log")
    ap.add_argument("-d", "--dumps", help="the lines rngdump printed for the RAW files")
    ap.add_argument("-o", "--report", help="write the report here as well")
    ap.add_argument("raw", nargs="+")
    a = ap.parse_args()

    lines = []
    def say(s=""):
        lines.append(s)
        print(s, flush=True)

    try:
        nist = nistdir(a.nist)
    except Exception as e:
        print("assess: cannot build NIST's tools: %s" % e, file=sys.stderr)
        return 2

    bad = []
    hmin = None
    for p in a.raw:
        size = os.path.getsize(p)
        say("== %s (%d bytes)" % (p, size))
        if size < 1000000:
            bad.append("%s: %d bytes; 90B asks for at least 1000000" % (p, size))
        try:
            ni = noniid(nist, p)
            ii = iid(nist, p)
        except Exception as e:
            print("assess: %s" % e, file=sys.stderr)
            return 2
        say("non-IID: H_original %.6f  H_bitstring %.6f  credit %.6f bits a byte"
            % (ni["H_original"], ni["H_bitstring"], ni["H"]))
        if ii["passed"]:
            say("IID tests: passed; IID estimate %s" % ("%.6f" % ii["H"] if ii["H"] is not None else "?"))
        else:
            say("IID tests: failed (%s): the source is not IID, the non-IID estimate stands"
                % "; ".join(ii["failed"]) if ii["failed"] else "IID tests: not passed")
        h = ni["H"]
        say("credited: %.6f bits a byte (claim %.1f)" % (h, a.claim))
        if h < a.claim:
            bad.append("%s: %.3f bits a byte is less than the %.1f the kernel assumes" % (p, h, a.claim))
        hmin = h if hmin is None else min(hmin, h)
        say()

    if len(a.raw) > 1:
        rep = crossrepeats(a.raw)
        if rep:
            for (p1, o1), (p2, o2) in rep:
                say("REPEAT: %s at %d is %s at %d" % (p1, o1, p2, o2))
            bad.append("a %d-byte block of one file is in another" % BLOCK)
        else:
            say("across files: no %d-byte block of one in another" % BLOCK)
        say()

    if a.boots:
        with tempfile.TemporaryDirectory() as tmp:
            r = restart(nist, a.boots, hmin, tmp)
        say("== restart: %s, %d boots" % (a.boots, r["boots"]))
        if os.path.getsize(a.boots) % FIRST:
            bad.append("%s is not whole boots of %d bytes" % (a.boots, FIRST))
        for i, j in r["repeats"][:10]:
            say("REPEAT: boot %d begins as boot %d did" % (j, i))
        if r["repeats"]:
            bad.append("%d boots begin with another boot's first %d bytes" % (len(r["repeats"]), BLOCK))
        else:
            say("no two boots begin with the same %d bytes" % BLOCK)
        if not r["ran"]:
            bad.append("%d boots; the restart test needs %d" % (r["boots"], ROWS))
        else:
            say("restart test at H_I %.6f: %s (H_r %s, H_c %s; min %s)" % (hmin,
                "passed" if r["passed"] else "FAILED",
                r.get("H_r"), r.get("H_c"), r.get("H_min")))
            if not r["passed"]:
                bad.append("SP 800-90B's restart test failed")
        say()

    cond = []
    c = conditions(say, "captures", a.dumps)
    if c:
        cond.append(c)
    if a.boots:
        log = a.bootlog or os.path.join(os.path.dirname(os.path.abspath(a.boots)), "rngboot.log")
        c = conditions(say, "boots", log)
        if c:
            cond.append(c)
    say("CONDITIONS: " + ("clean" if not cond else "; ".join(cond)))
    say()

    if bad:
        say("VERDICT: FAIL")
        for b in bad:
            say("  " + b)
    else:
        say("VERDICT: PASS: at least %.3f bits a byte credited; claim %.1f holds" % (hmin, a.claim))
    if a.report:
        open(a.report, "w").write("\n".join(lines) + "\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
