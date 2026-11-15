#!/usr/bin/env python3
"""Take out of Flawfinder's SARIF what is not a finding in this tree.

Flawfinder matches names.  Code scanning then tracks each match as an
alert, counts one as new whenever its line changes, comments on the pull
request for it, and fails the check when its level is error.  Some of
what it matches here is wrong by construction, and came back on every
pull request that touched such a line:

  below the level asked for
        The workflow runs flawfinder --minlevel 2, and the SARIF writer
        does not apply it: levels 0 and 1 (strlen, read, strncpy, a
        constant format) are written all the same.  Dropped by rank.

  buffer/strecpy
        Flawfinder's rule is for SVR4 libgen's strecpy, which copies
        with escapes expanded and no bound (level 4, an error).  This
        tree's strecpy is lib9's: strecpy(to, end, from) is given the end
        of its buffer and cannot write past it.  It is what the tree
        uses in place of strcpy.

  buffer/getwd
        lib9's getwd(buf, size) takes the buffer's size (and half the
        matches are "#undef getwd").

  race/access, where the line calls no access()
        An array named access (dev.c's table of permission bits) is not
        a call to access(2).

  buffer/char
        A fixed-size array's declaration.  Every such array in C
        matches; it says nothing has gone wrong, and the copy that could
        overflow one is what the other rules are for.

Everything else stays: strcpy, strcat, sprintf, the scanf and printf
families with a format that is not constant, memcpy, atoi, open, getenv,
srand, access() itself, system and exec, temporary files.  A match on
one of those that has been read and is safe is marked where it is, as
the tree does:  /* Flawfinder: ignore -- the reason */

The text report the workflow also makes is not filtered: every match is
still there to read.

usage: flawfinder-filter.py [-n] file.sarif [out.sarif]
       -n  say what would be dropped and change nothing
"""
import json
import re
import sys

MINRANK = 0.4		# level 2 of 5, the workflow's --minlevel

# rule name -> why it is not a finding here
NOTHERE = {
	"buffer/strecpy": "lib9's strecpy is given the end of its buffer",
	"buffer/getwd": "lib9's getwd is given the buffer's size",
	"buffer/char": "a declaration, not a use",
}


def rulename(result, names):
	n = names.get(result.get("ruleId"))
	if n:
		return n
	# the message begins "category/name:"
	m = re.match(r"([a-z]+/[A-Za-z_0-9]+):", result.get("message", {}).get("text", ""))
	return m.group(1) if m else ""


def snippet(result):
	try:
		return result["locations"][0]["physicalLocation"]["region"]["snippet"]["text"]
	except (KeyError, IndexError, TypeError):
		return ""


def why(result, names):
	"""The reason a result is dropped, or None to keep it."""
	name = rulename(result, names)
	if name in NOTHERE:
		return name + ": " + NOTHERE[name]
	if name == "race/access" and not re.search(r"\baccess\s*\(", snippet(result)):
		return "race/access: no call to access() on the line"
	rank = result.get("rank")
	if isinstance(rank, (int, float)) and rank < MINRANK - 1e-9:
		return "below the level asked for (--minlevel 2)"
	return None


def main(argv):
	dry = False
	if argv and argv[0] == "-n":
		dry = True
		argv = argv[1:]
	if len(argv) not in (1, 2):
		sys.stderr.write(__doc__)
		return 2
	src = argv[0]
	dst = argv[1] if len(argv) == 2 else src
	with open(src) as f:
		sarif = json.load(f)
	dropped = {}
	kept = 0
	for run in sarif.get("runs", []):
		rules = run.get("tool", {}).get("driver", {}).get("rules", [])
		names = {r.get("id"): r.get("name", "") for r in rules}
		keep = []
		for r in run.get("results", []):
			w = why(r, names)
			if w is None:
				keep.append(r)
			else:
				dropped[w] = dropped.get(w, 0) + 1
		kept += len(keep)
		run["results"] = keep
	if not dry:
		with open(dst, "w") as f:
			json.dump(sarif, f, indent=1)
			f.write("\n")
	print("flawfinder-filter: %d results kept, %d dropped%s" % (kept, sum(dropped.values()), " (nothing written)" if dry else ""))
	for w in sorted(dropped):
		print("  %4d  %s" % (dropped[w], w))
	return 0


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
