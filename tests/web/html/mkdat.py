#!/usr/bin/env python3
#
# mkdat.py - regenerate tree.dat from corpus.txt, using html5lib (pip
# install html5lib) as the oracle.  Run from this directory:
#	python3 mkdat.py > tree.dat
# Then review the diff: html5lib predates some spec changes, and where it
# is wrong the expected tree is corrected by hand in extra.dat instead.
#
import re, sys, html5lib
from html5lib import treebuilders

def norm(s):
    out = []
    attrs = []
    def flush():
        attrs.sort()
        out.extend(a[1] for a in attrs)
        attrs.clear()
    for line in s.split("\n")[1:]:
        m = re.match(r"\|( +)(.*)", line)
        if not m:	# continuation of a multi-line text node
            out[-1] += "\n" + line
            continue
        depth = (len(m.group(1)) - 2) // 2
        body = m.group(2)
        body = re.sub(r"^<html ([^>]*)>$", r"<\1>", body)
        new = "| " + "  " * depth + body
        if re.match(r'^[^<"]*=', body) and not body.startswith("<"):
            attrs.append((body, new))
        else:
            flush()
            out.append(new)
    flush()
    return "\n".join(out)

p = html5lib.HTMLParser(tree=treebuilders.getTreeBuilder("dom"))
for line in open("corpus.txt", encoding="utf-8"):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    data = line.replace("\\n", "\n")
    tree = p.tree.testSerializer(p.parse(data))
    print("#data")
    print(data)
    print("#errors")
    print("#document")
    print(norm(tree))
    print()
