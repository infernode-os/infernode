#!/usr/bin/env python3
#
# devletters.py -- the device letters (#c, #I, ...) every kernel and
# emulator in the tree uses, checked against docs/DEVICE-LETTERS.md.
#
#   tools/devletters.py --check     exit 1 if a rule below is broken
#   tools/devletters.py --builds    each build's devices and their letters
#
# A device is named by one character after '#', its Dev table's first
# member, and a kernel finds a device by that character alone: two in one
# build and one is unreachable. That happened: master's camera took #V
# while the multi-VM branch's VM device had it, and nothing noticed until
# the merge. The rules:
#
#   1. no letter twice in one build (a native devtab.c, or the dev section
#      of an emulator's config);
#   2. every device a build includes has its letter in the registry, with
#      that device's name in the row's "Here" column -- so a letter that
#      means two devices in different builds (#P: arch native, prof
#      hosted) is there only by being written down, both names;
#   3. a registry row marked "in use" names only devices that exist.
#
# The registry is the table in docs/DEVICE-LETTERS.md: one row per letter,
# the letter in backquotes in the first column, the devices here in the
# second as "name (native/hosted)", comma separated.
#
import glob, os, re, sys

ROOT = os.environ.get("ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
REGISTRY = os.path.join(ROOT, "docs", "DEVICE-LETTERS.md")

DEVRE = re.compile(r'^Dev\s+(\w+)\s*=\s*\{(.*?)\}', re.M | re.S)

def strip(s):
    return re.sub(r'/\*.*?\*/', '', re.sub(r'//[^\n]*', '', s), flags=re.S)

def tables(family):
    """{Dev table name: [(letter, devname, file)]} for os/ or emu/."""
    out = {}
    for f in sorted(glob.glob(os.path.join(ROOT, family, "**", "*.c"), recursive=True)):
        src = open(f, errors="replace").read()
        if "Dev" not in src:
            continue
        for m in DEVRE.finditer(src):
            body = strip(m.group(2))
            parts = [p.strip() for p in body.split(",")]
            if len(parts) < 2:
                continue
            ch, name = parts[0], parts[1]
            if ch.startswith("L'") or ch.startswith("'"):
                c = ch[ch.index("'")+1:ch.rindex("'")]
                c = bytes(c, "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8") if "\\" in c else c
            elif ch.lower().startswith("0x"):
                c = chr(int(ch, 16))
            else:	# a named constant: Devchar = 't'
                e = re.search(r'\b%s\s*=\s*L?\'([^\']+)\'' % re.escape(ch), src)
                if not e:
                    continue
                c = e.group(1)
            if name.startswith('"'):
                n = name.strip('"')
            else:	# static char Devname[] = "eia";
                e = re.search(r'\b%s\s*\[\]\s*=\s*"([^"]*)"' % re.escape(name), src)
                n = e.group(1) if e else name
            key = m.group(1)[:-6] if m.group(1).endswith("devtab") else m.group(1)
            out.setdefault(key, []).append((c, n, os.path.relpath(f, ROOT)))
    return out

def builds():
    """{build: (family, [Dev table names])}"""
    b = {}
    for f in sorted(glob.glob(os.path.join(ROOT, "os", "*", "devtab.c"))):
        src = strip(open(f).read())
        i = src.find("devtab[]")
        if i < 0:
            continue
        body = src[i:src.index("};", i)]
        b["native " + f.split(os.sep)[-2]] = ("os", [re.sub("devtab$", "", x) for x in re.findall(r'&(\w+)', body)])
    for f in sorted(glob.glob(os.path.join(ROOT, "emu", "*", "emu*"))):
        if not os.path.isfile(f) or f.endswith((".c", ".h", ".o")):
            continue
        devs, on = [], False
        for line in open(f, errors="replace"):
            if re.match(r'^dev\s*$', line):
                on = True
                continue
            if on and re.match(r'^\S', line):
                on = False
            if on and line.strip() and not line.strip().startswith("#"):
                devs.append(line.split()[0])
        if devs:
            b["hosted " + os.path.relpath(f, os.path.join(ROOT, "emu"))] = ("emu", devs)
    return b

def registry():
    """{letter: (set of device names, status)}"""
    reg = {}
    for line in open(REGISTRY, encoding="utf-8"):
        m = re.match(r'^\|\s*`([^`]+)`\s*\|([^|]*)\|(?:[^|]*\|){3}\s*([^|]*?)\s*\|', line)
        if not m:
            continue
        names = {re.sub(r'\s*\(.*', '', x).strip() for x in m.group(2).split(",") if x.strip()}
        reg[m.group(1)] = (names, m.group(3))
    return reg

def letters_of(tab, name, build):
    """the letter(s) the build's device <name> has; several files may define it"""
    return sorted({c for c, n, f in tab.get(name, [])})

def main():
    tab = {"os": tables("os"), "emu": tables("emu")}
    bl = builds()
    if "--builds" in sys.argv:
        for b, (fam, devs) in bl.items():
            print("%-24s %s" % (b, " ".join("#%s=%s" % ("/".join(letters_of(tab[fam], d, b)) or "?", d) for d in devs)))
        return 0
    reg = registry()
    bad = []
    used = {}	# letter -> {devname: [builds]}
    for b, (fam, devs) in bl.items():
        seen = {}
        for d in devs:
            ls = letters_of(tab[fam], d, b)
            if not ls:
                continue	# a config naming a device with no source here
            if len(ls) > 1:
                bad.append("%s: device %s has several letters in %s/: %s" % (b, d, fam, " ".join("#" + x for x in ls)))
            for c in ls:
                if c in seen and seen[c] != d:
                    bad.append("%s: #%s is both %s and %s -- one of them cannot be reached" % (b, c, seen[c], d))
                seen[c] = d
                used.setdefault(c, {}).setdefault(d, []).append(b)
    for c, devs in sorted(used.items()):
        if c not in reg:
            bad.append("#%s (%s) is not in docs/DEVICE-LETTERS.md" % (c, ", ".join(sorted(devs))))
            continue
        for d in devs:
            if d not in reg[c][0]:
                bad.append("#%s is %s in %s, and the registry does not say so (it lists %s)" %
                           (c, d, ", ".join(devs[d][:3]), ", ".join(sorted(reg[c][0])) or "nothing"))
    for c, (names, status) in sorted(reg.items()):
        if status == "in use":
            for n in names:
                if n not in used.get(c, {}):
                    bad.append("registry: #%s %s is marked in use, and no build has it" % (c, n))
    for line in bad:
        print("FAIL: " + line)
    if not bad:
        print("PASS: %d letters in use across %d builds, none twice in one build, all in the registry" % (len(used), len(bl)))
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
