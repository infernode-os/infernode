#!/usr/bin/env python3
# mkimagerjson.py -- the Raspberry Pi Imager subitem file for a release's
# Pi card images.
#
# Usage:
#     tools/mkimagerjson.py [--template FILE] [--repo OWNER/NAME] VERSION DATE IMAGE.xz...
#
#     VERSION   the release's version, as in its file names (0.9.1)
#     DATE      its date, YYYY-MM-DD
#     IMAGE.xz  infernode-VERSION-BOARD.img.xz, one per board; each is read
#               whole, compressed and not, for its sizes and SHA-256s
#     --template FILE
#               the entry as reviewed (default
#               docs/store/rpi-imager/os_list_infernode.json): its items'
#               descriptions, devices, init_format and the rest are kept as
#               they are; only the version, URL, dates, sizes and hashes are
#               the release's
#     --repo    where the release is (default infernode-os/infernode)
#
# Writes the file to stdout. The release job attaches it to each release, so
#
#     https://github.com/infernode-os/infernode/releases/latest/download/os_list_infernode.json
#
# is always the latest release's -- which is the URL Raspberry Pi has, and why
# a release never needs the entry edited by hand. An item's board is the one
# its template URL names (-rpi3bplus.img.xz, -rpi4b.img.xz); a board with no
# image given, or an image no item is for, is refused, not left stale.
#
# Exit status: 0 written; 1 refused; 2 usage.
import hashlib, json, lzma, os, re, sys

def die(msg):
    sys.stderr.write("mkimagerjson: %s\n" % msg)
    sys.exit(1)

def measure(path):
    """(download size, download sha256, extract size, extract sha256) of an .img.xz."""
    dl = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            dl.update(b)
    ex, n = hashlib.sha256(), 0
    with lzma.open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            ex.update(b)
            n += len(b)
    return os.path.getsize(path), dl.hexdigest(), n, ex.hexdigest()

def main():
    args = sys.argv[1:]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    template = os.path.join(root, "docs/store/rpi-imager/os_list_infernode.json")
    repo = "infernode-os/infernode"
    while args and args[0].startswith("--"):
        if len(args) < 2:
            sys.exit(2)
        if args[0] == "--template":
            template = args[1]
        elif args[0] == "--repo":
            repo = args[1]
        else:
            sys.stderr.write("usage: mkimagerjson.py [--template FILE] [--repo OWNER/NAME] VERSION DATE IMAGE.xz...\n")
            sys.exit(2)
        args = args[2:]
    if len(args) < 3:
        sys.stderr.write("usage: mkimagerjson.py [--template FILE] [--repo OWNER/NAME] VERSION DATE IMAGE.xz...\n")
        sys.exit(2)
    version, date, images = args[0], args[1], args[2:]
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        die("date %r is not YYYY-MM-DD" % date)

    byboard = {}
    for p in images:
        m = re.fullmatch(r"infernode-(.+)-(rpi[0-9a-z]+)\.img\.xz", os.path.basename(p))
        if m is None or m.group(1) != version:
            die("%s is not infernode-%s-<board>.img.xz" % (p, version))
        byboard[m.group(2)] = p

    items = json.load(open(template))["os_list"]
    out, used = [], set()
    for it in items:
        m = re.search(r"-(rpi[0-9a-z]+)\.img\.xz$", it.get("url", ""))
        if m is None:
            die("a template item's url names no board: %r" % it.get("url"))
        board = m.group(1)
        if board not in byboard:
            die("no image for the %s item" % board)
        used.add(board)
        dlsize, dlsha, exsize, exsha = measure(byboard[board])
        it = dict(it)
        it["name"] = re.sub(r"^InferNode \S+ \(", "InferNode %s (" % version, it["name"])
        it["url"] = "https://github.com/%s/releases/download/v%s/infernode-%s-%s.img.xz" % (repo, version, version, board)
        it["release_date"] = date
        it["extract_size"], it["extract_sha256"] = exsize, exsha
        it["image_download_size"], it["image_download_sha256"] = dlsize, dlsha
        out.append(it)
    extra = set(byboard) - used
    if extra:
        die("no template item for %s" % ", ".join(sorted(extra)))
    json.dump({"os_list": out}, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")

main()
