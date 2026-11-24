#!/usr/bin/env python3
"""InferNode's security advisories: check them, index them, file them.

Each advisory is a file docs/security-advisories/ISA-YYYY-NNN.md: a
header of "Key: value" lines, a blank line, then the text in Markdown.
The header says what GitHub's repository advisories want to know:

    Id:        ISA-2026-001, the file's own name
    Title:     one line, the advisory's summary
    Severity:  critical, high, medium or low
    CWE:       CWE-n ..., at least one
    Affected:  the releases affected, as GitHub writes a range
               ("< 0.11.0", ">= 0.2.0, < 0.10.0", "<= 0.12.0")
    Patched:   the first release with the fix, or "unreleased"
    Commits:   the commits that fix it, abbreviated hashes
    Changelog: the CHANGELOG.md section that described it ("0.11.0")
    GHSA:      the GitHub advisory's id once it is filed, else empty
    CVE:       a CVE id once one is assigned, else empty

    security-advisories.py check [--history]
        Every file is read and its header held to the rules above; the
        ids run from 001 with no gap; docs/SECURITY-ADVISORIES.md is
        what `index` would write.  With --history (a clone with its
        tags), each commit exists, each patched release's tag holds
        every one of its commits, and no release holds the commits of
        an advisory that says "unreleased".  Exit 1 on any fault.

    security-advisories.py index
        Writes docs/SECURITY-ADVISORIES.md from the files.

    security-advisories.py file [--repo owner/name] [--submit]
                                [--include-unreleased] [ID ...]
        Makes a draft repository advisory on GitHub for each advisory
        that has no GHSA yet (or those named).  Without --submit it
        prints what it would send and sends nothing.  With --submit it
        needs GITHUB_TOKEN (a token that may manage the repository's
        security advisories), skips any advisory GitHub already has a
        draft or advisory for (matched by its ISA id in the text),
        creates the rest as drafts, and writes each new GHSA id into
        its file.  It never publishes and never asks for a CVE: that is
        done by a person, on GitHub, after reading the draft.  An
        advisory whose fix is unreleased is left alone unless
        --include-unreleased is given, so nothing is drafted that
        names no release to update to.

SECADV_ROOT names another tree to read and SECADV_API another API to
send to (the test's copies and its fake GitHub).  Only the
standard library is used.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.environ.get("SECADV_ROOT") or \
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "docs", "security-advisories")
INDEX = os.path.join(ROOT, "docs", "SECURITY-ADVISORIES.md")
REPO = "infernode-os/infernode"
API = os.environ.get("SECADV_API") or "https://api.github.com"

KEYS = ["Id", "Title", "Severity", "CWE", "Affected", "Patched",
        "Commits", "Changelog", "GHSA", "CVE"]
SEVERITIES = ["critical", "high", "medium", "low"]
VERSION = r"\d+\.\d+\.\d+"
RANGE = re.compile(r"^(>= %s, )?(<|<=) %s$" % (VERSION, VERSION))
IDPAT = re.compile(r"^ISA-(\d{4})-(\d{3})$")
GHSAPAT = re.compile(r"^GHSA(-[23456789cfghjmpqrvwx]{4}){3}$")
CVEPAT = re.compile(r"^CVE-\d{4}-\d{4,}$")


class Advisory:
    def __init__(self, path):
        self.path = path
        self.fields = {}
        self.order = []
        self.body = ""
        self.faults = []
        self.read()

    def read(self):
        with open(self.path, encoding="utf-8") as f:
            text = f.read()
        head, sep, body = text.partition("\n\n")
        if not sep:
            self.faults.append("no blank line between header and text")
        for n, line in enumerate(head.split("\n"), 1):
            key, colon, value = line.partition(":")
            if not colon or key not in KEYS:
                self.faults.append("header line %d is not one of %s: %r"
                                   % (n, ", ".join(KEYS), line))
                continue
            if key in self.fields:
                self.faults.append("%s given twice" % key)
            self.fields[key] = value.strip()
            self.order.append(key)
        self.body = body.strip() + "\n"

    def get(self, key):
        return self.fields.get(key, "")

    def list(self, key):
        return self.get(key).split()

    def check(self):
        f = list(self.faults)
        for k in KEYS:
            if k not in self.fields:
                f.append("no %s line" % k)
        if self.order != [k for k in KEYS if k in self.fields]:
            f.append("header lines not in the order " + ", ".join(KEYS))
        name = os.path.basename(self.path)
        if not IDPAT.match(self.get("Id")):
            f.append("Id %r is not ISA-YYYY-NNN" % self.get("Id"))
        elif name != self.get("Id") + ".md":
            f.append("file is %s but its Id is %s" % (name, self.get("Id")))
        title = self.get("Title")
        if not title or len(title) > 200:
            f.append("Title is empty or longer than 200 characters")
        if self.get("Severity") not in SEVERITIES:
            f.append("Severity %r is not one of %s"
                     % (self.get("Severity"), ", ".join(SEVERITIES)))
        cwes = self.list("CWE")
        if not cwes or any(not re.match(r"^CWE-\d+$", c) for c in cwes):
            f.append("CWE %r is not one or more CWE-n" % self.get("CWE"))
        affected = self.get("Affected")
        if not RANGE.match(affected):
            f.append("Affected %r is not a range such as '< 0.11.0'"
                     % affected)
        patched = self.get("Patched")
        if patched == "unreleased":
            if not affected.startswith("<= ") and ", <= " not in affected:
                f.append("an unreleased fix's Affected ends with <= the"
                         " last release")
        elif re.match("^%s$" % VERSION, patched):
            if not affected.endswith("< " + patched) or "<=" in affected:
                f.append("Affected %r does not end '< %s'"
                         % (affected, patched))
        else:
            f.append("Patched %r is not a version or 'unreleased'" % patched)
        commits = self.list("Commits")
        if not commits or any(not re.match(r"^[0-9a-f]{9,40}$", c)
                              for c in commits):
            f.append("Commits %r are not abbreviated hashes"
                     % self.get("Commits"))
        if not re.match("^%s$" % VERSION, self.get("Changelog")):
            f.append("Changelog %r is not a version" % self.get("Changelog"))
        g = self.get("GHSA")
        if g and not GHSAPAT.match(g):
            f.append("GHSA %r is not a GHSA id" % g)
        c = self.get("CVE")
        if c and not CVEPAT.match(c):
            f.append("CVE %r is not a CVE id" % c)
        for h in ("## Summary", "## Impact", "## Fix", "## Workarounds"):
            if ("\n" + h + "\n") not in ("\n" + self.body):
                f.append("no %r section" % h)
        return f

    def setfield(self, key, value):
        with open(self.path, encoding="utf-8") as fd:
            text = fd.read()
        head, sep, rest = text.partition("\n\n")
        lines = head.split("\n")
        for i, line in enumerate(lines):
            if line.partition(":")[0] == key:
                lines[i] = ("%s: %s" % (key, value)).rstrip()
        with open(self.path, "w", encoding="utf-8") as fd:
            fd.write("\n".join(lines) + sep + rest)
        self.fields[key] = value


def advisories():
    names = sorted(n for n in os.listdir(DIR)
                   if n.startswith("ISA-") and n.endswith(".md"))
    return [Advisory(os.path.join(DIR, n)) for n in names]


def git(*args):
    r = subprocess.run(["git", "-C", ROOT] + list(args),
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def checkhistory(a):
    f = []
    commits = a.list("Commits")
    for c in commits:
        rc, _ = git("cat-file", "-e", c + "^{commit}")
        if rc != 0:
            f.append("commit %s is not in this clone" % c)
    if f:
        return f
    patched = a.get("Patched")
    if patched == "unreleased":
        for c in commits:
            _, tags = git("tag", "--contains", c, "--list", "v*")
            if tags:
                f.append("commit %s is in %s, yet the fix is said to be"
                         " unreleased" % (c, tags.split()[0]))
        return f
    tag = "v" + patched
    rc, _ = git("rev-parse", "-q", "--verify", tag + "^{commit}")
    if rc != 0:
        return ["no tag %s for Patched %s" % (tag, patched)]
    for c in commits:
        rc, _ = git("merge-base", "--is-ancestor", c, tag)
        if rc != 0:
            f.append("commit %s is not in %s" % (c, tag))
    return f


def indextext(advs):
    out = [INDEXHEAD]
    out.append("| Advisory | Severity | Affected | Fixed in | Summary | GHSA |")
    out.append("|---|---|---|---|---|---|")
    for a in advs:
        aid = a.get("Id")
        ghsa = a.get("GHSA")
        if ghsa:
            ghsa = "[%s](https://github.com/%s/security/advisories/%s)" % (
                ghsa, REPO, ghsa)
        if a.get("CVE"):
            ghsa = (ghsa + " " + a.get("CVE")).strip()
        patched = a.get("Patched")
        if patched != "unreleased":
            patched = "[%s](https://github.com/%s/releases/tag/v%s)" % (
                patched, REPO, patched)
        out.append("| [%s](security-advisories/%s.md) | %s | `%s` | %s | %s | %s |"
                   % (aid, aid, a.get("Severity"), a.get("Affected"),
                      patched, a.get("Title").replace("|", "\\|"), ghsa))
    out.append("")
    return "\n".join(out)


INDEXHEAD = """\
# Security advisories

<!-- Written by tools/security-advisories.py index; edit the advisories in
     docs/security-advisories/, not this file. -->

Vulnerabilities fixed in InferNode releases that someone running an
affected release should know about: what was wrong, who could use it,
what the fix changed, and what to do. Each fix was found by the
project's own reviews, red-team campaigns and fuzzing, not reported from
outside; each came with a regression test, and the advisory names the
commits that fixed it.

This is a selection. Every release's **Security** section in
[CHANGELOG.md](../CHANGELOG.md) lists all of its security changes,
including hardening and the many smaller fixes that are not listed
here. An advisory is written for a fix that, on its own, let someone
outside a boundary InferNode claims (the network, a confined agent, a
Limbo program, another user) read, write, run or forge what it should
not.

Only the latest release, and the one before it for six months, gets
fixes ([SECURITY.md](../SECURITY.md)). Releases are not patched in
place: the fix for every advisory below is to install the release that
has it, or a later one. Where an advisory says *unreleased*, the fix is
on `master` and in no release yet.

Each advisory is also filed as a GitHub Security Advisory (GHSA) where
the GHSA column has one; the files here are the record they are made
from. To report a vulnerability, see [SECURITY.md](../SECURITY.md).
"""


def cmd_check(args):
    history = "--history" in args
    advs = advisories()
    bad = 0
    if not advs:
        print("security-advisories: no advisories in %s" % DIR)
        return 1
    seen = {}
    for n, a in enumerate(advs, 1):
        faults = a.check()
        m = IDPAT.match(a.get("Id"))
        if m:
            if int(m.group(2)) != n:
                faults.append("Id %s is out of sequence (expected %03d)"
                              % (a.get("Id"), n))
        if a.get("Title") in seen:
            faults.append("same Title as %s" % seen[a.get("Title")])
        seen[a.get("Title")] = a.get("Id")
        if history and not faults:
            faults += checkhistory(a)
        for f in faults:
            print("%s: %s" % (os.path.relpath(a.path, ROOT), f))
        bad += len(faults)
    try:
        with open(INDEX, encoding="utf-8") as fd:
            current = fd.read()
    except OSError:
        current = None
    if current != indextext(advs):
        print("%s: not what `security-advisories.py index` writes; run it"
              % os.path.relpath(INDEX, ROOT))
        bad += 1
    if bad:
        print("security-advisories: %d fault(s)" % bad)
        return 1
    print("security-advisories: %d advisories%s, index current"
          % (len(advs), ", history checked" if history else ""))
    return 0


def cmd_index(args):
    advs = advisories()
    with open(INDEX, "w", encoding="utf-8") as fd:
        fd.write(indextext(advs))
    print("wrote %s (%d advisories)" % (os.path.relpath(INDEX, ROOT),
                                        len(advs)))
    return 0


def payload(a, repo):
    links = []
    for c in a.list("Commits"):
        links.append("- https://github.com/%s/commit/%s" % (repo, c))
    patched = a.get("Patched")
    refs = ["", "## References", ""]
    if patched != "unreleased":
        refs.append("- Release: https://github.com/%s/releases/tag/v%s"
                    % (repo, patched))
    refs.append("- Changelog: https://github.com/%s/blob/master/CHANGELOG.md"
                " (%s, Security)" % (repo, a.get("Changelog")))
    refs.append("- Advisory record: https://github.com/%s/blob/master/"
                "docs/security-advisories/%s.md" % (repo, a.get("Id")))
    refs.append("- Fix commits:")
    refs += ["  " + l for l in links]
    body = a.body.rstrip() + "\n" + "\n".join(refs) + \
        "\n\nInferNode advisory id: %s\n" % a.get("Id")
    return {
        "summary": a.get("Title"),
        "description": body,
        "severity": a.get("Severity"),
        "cwe_ids": a.list("CWE"),
        "vulnerabilities": [{
            "package": {"ecosystem": "other", "name": "infernode"},
            "vulnerable_version_range": a.get("Affected"),
            "patched_versions": None if patched == "unreleased" else patched,
            "vulnerable_functions": [],
        }],
    }


def request(method, url, token, data=None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("User-Agent", "infernode-security-advisories")
    if data is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(data).encode()
    with urllib.request.urlopen(req, data) as r:
        link = r.headers.get("Link", "")
        return json.loads(r.read() or b"null"), link


def existing(repo, token):
    """The ISA ids GitHub already has an advisory or draft for."""
    have = {}
    url = "%s/repos/%s/security-advisories?per_page=100" % (API, repo)
    while url:
        page, link = request("GET", url, token)
        for adv in page:
            for m in re.finditer(r"ISA-\d{4}-\d{3}",
                                 (adv.get("description") or "")):
                have[m.group(0)] = adv.get("ghsa_id")
        m = re.search(r'<([^>]+)>; rel="next"', link)
        url = m.group(1) if m else None
    return have


def cmd_file(args):
    repo = REPO
    submit = False
    unreleased = False
    ids = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--repo":
            i += 1
            repo = args[i]
        elif a == "--submit":
            submit = True
        elif a == "--include-unreleased":
            unreleased = True
        elif IDPAT.match(a):
            ids.append(a)
        else:
            print("usage: security-advisories.py file [--repo owner/name]"
                  " [--submit] [--include-unreleased] [ISA-YYYY-NNN ...]")
            return 2
        i += 1
    advs = advisories()
    for a in advs:
        if a.check():
            print("security-advisories: %s has faults; run check first"
                  % a.get("Id"))
            return 1
    known = {a.get("Id") for a in advs}
    for x in ids:
        if x not in known:
            print("security-advisories: no advisory %s" % x)
            return 1
    todo = []
    for a in advs:
        if ids and a.get("Id") not in ids:
            continue
        if a.get("GHSA"):
            print("%s: already filed as %s" % (a.get("Id"), a.get("GHSA")))
            continue
        if a.get("Patched") == "unreleased" and not unreleased:
            print("%s: fix unreleased; skipped (--include-unreleased to"
                  " draft it anyway)" % a.get("Id"))
            continue
        todo.append(a)
    if not submit:
        for a in todo:
            print("=== %s: would create a draft advisory in %s"
                  % (a.get("Id"), repo))
            print(json.dumps(payload(a, repo), indent=2))
        print("security-advisories: %d draft(s) not sent (dry run; add"
              " --submit)" % len(todo))
        return 0
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("security-advisories: --submit needs GITHUB_TOKEN")
        return 1
    try:
        have = existing(repo, token)
    except urllib.error.HTTPError as e:
        print("security-advisories: listing %s's advisories: %s %s"
              % (repo, e.code, e.read().decode(errors="replace")[:300]))
        return 1
    made = 0
    for a in todo:
        aid = a.get("Id")
        if aid in have:
            print("%s: GitHub has it already as %s; recorded" % (aid, have[aid]))
            if have[aid]:
                a.setfield("GHSA", have[aid])
            continue
        try:
            adv, _ = request("POST", "%s/repos/%s/security-advisories"
                             % (API, repo), token, payload(a, repo))
        except urllib.error.HTTPError as e:
            print("%s: refused: %s %s" % (aid, e.code,
                  e.read().decode(errors="replace")[:500]))
            return 1
        a.setfield("GHSA", adv["ghsa_id"])
        made += 1
        print("%s: draft %s %s" % (aid, adv["ghsa_id"], adv.get("html_url", "")))
    if made:
        cmd_index([])
    print("security-advisories: %d draft(s) made; review and publish them on"
          " GitHub, then commit the GHSA ids written into the files" % made)
    return 0


def main():
    cmds = {"check": cmd_check, "index": cmd_index, "file": cmd_file}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        print(__doc__.split("\n\n")[0])
        print("usage: security-advisories.py check [--history] | index |"
              " file [--repo owner/name] [--submit] [--include-unreleased]"
              " [ISA-YYYY-NNN ...]")
        return 2
    return cmds[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
