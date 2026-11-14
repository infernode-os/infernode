#!/usr/bin/env python3
#
# tests/host/werc/wiki_check.py PORT WORKDIR
#
# The host's half of tests/host/charon_werc_test.sh, against httpd(8)
# with wikifs at /wiki (-w /wiki):
#
#   1. Charon's edit form is open (WORKDIR/conflict-ready): another
#      writer changes the page, then WORKDIR/conflict-go lets Charon
#      submit its now stale form.
#   2. Once Charon is done (WORKDIR/charon-done), from outside: two
#      edits in one second both shown at once and both in the history
#      under names of their own (wikifs's cache kept the first, a host
#      file's version being its mtime in seconds); an edit of a stale
#      version refused to werror.html and not shown; the same edit sent
#      twice taken once; what anyone may write kept out of the markup
#      (a link's URL, a javascript: link, a title, </textarea>); timings.
#
# Prints PASS:/FAIL: lines; exits with the number failed.
#

import html.parser, http.client, os, re, statistics, sys, time, urllib.parse

PORT = int(sys.argv[1])
W = sys.argv[2]
fails = 0


def check(ok, what):
    global fails
    print(("PASS: " if ok else "FAIL: ") + what, flush=True)
    if not ok:
        fails += 1


def req(method, path, body=None, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    c.request(method, path, body=body, headers=headers or {})
    r = c.getresponse()
    b = r.read()
    c.close()
    return r.status, {k.lower(): v for k, v in r.getheaders()}, b


def version(name):
    st, hd, b = req("GET", "/wiki/%s/edit.html" % name)
    m = re.search(rb'name="version" value="(\d+)"', b)
    return m.group(1).decode() if m else "0"


def post(title, ver, text, author="host"):
    form = urllib.parse.urlencode({"title": title, "version": ver, "author": author, "text": text})
    st, hd, b = req("POST", "/magic/wikipost", form, {"Content-Type": "application/x-www-form-urlencoded"})
    return st, hd.get("location", "")


def page(name, f="index.html"):
    return req("GET", "/wiki/%s/%s" % (name, f))[2].decode("utf-8", "replace")


def words(html):
    # wiki2html sets a paragraph a word to a line
    return " ".join(html.split())


def attrs(text):
    # every (tag, attribute, value) an HTML parser finds
    found = []

    class P(html.parser.HTMLParser):
        def handle_starttag(self, tag, a):
            found.extend((tag, k, v or "") for k, v in a)
    P().feed(text)
    return found


def scripted(text):
    # an event handler, or a link to script
    return [(t, k, v) for t, k, v in attrs(text)
            if k.startswith("on") or k == "href" and v.strip().lower().startswith("javascript:")]


def waitfile(f, secs):
    t = time.time() + secs
    while time.time() < t:
        if os.path.exists(os.path.join(W, f)):
            return True
        time.sleep(0.1)
    return False


# 1. the other writer, while Charon's form is open
if waitfile("conflict-ready", 120):
    st, loc = post("made in charon", version("made_in_charon"), "The other writer's edit.\n")
    check(st == 303 and loc.endswith("/made_in_charon/index.html"), "the other writer's edit taken (%d %s)" % (st, loc))
else:
    check(False, "Charon never opened its edit form")
open(os.path.join(W, "conflict-go"), "w").close()

if not waitfile("charon-done", 180):
    check(False, "Charon did not finish")

# 2. from outside
T, N = "my first wiki page", "my_first_wiki_page"
v0 = version(N)
post(T, v0, "First of two in a second.\n")
v1 = version(N)
post(T, v1, "Second of two in a second.\n")
p = page(N)
check("Second of two in a second." in words(p), "two edits in one second: the second is shown at once")
check(v1 != v0 and version(N) != v1, "each edit is a version of its own (%s, %s, %s)" % (v0, v1, version(N)))
names = re.findall(r'<li><a href="([^"]+)">', page(N, "history.html"))
check(len(names) == len(set(names)) and len(names) >= 3, "the history's versions have names of their own (%d)" % len(names))

st, loc = post(T, v0, "An edit of a stale version.\n")
check(st == 303 and loc.endswith("/%s/werror.html" % N), "an edit of a stale version: 303 to werror.html (%d %s)" % (st, loc))
check("Second of two" in words(page(N)) and "stale version" not in words(page(N)), "and it is not shown")
check("conflicting write" in page(N, "history.html"), "it is in the history as a conflicting write")
cur = version(N)
post(T, cur, "Sent twice.\n")
st, loc = post(T, cur, "Sent twice.\n")
check(st == 303 and loc.endswith("/index.html"), "the same edit sent twice is taken, not a conflict (%d %s)" % (st, loc))
check(page(N, "history.html").count("conflicting write") == 1, "and makes no second conflict")

hostile = ('Links [click | x" onmouseover="alert(1)] [js | javascript:alert(2)] '
           '[page"/onmouseover="alert(3)] [ok | https://example.com/a?b=1&c=2] '
           '</textarea><script>alert(4)</script>\n')
time.sleep(1.1)  # a second of its own: the checks below stand apart from the cache's
post(T, version(N), hostile)
p = page(N)
check(scripted(p) == [], "a link's URL stays inside its attribute, and no javascript: link is made %s" % scripted(p))
check('href="https://example.com/a?b=1&amp;c=2"' in p, "a good link is made, escaped")
check("<script>" not in p, "text is not markup")
e = page(N, "edit.html")
check("<script>" not in e and e.count("</textarea>") == 1 and "&lt;/textarea&gt;&lt;script&gt;" in e,
      "</textarea> in the text stays in the edit form's textarea")
st, loc = post('t" autofocus onfocus="alert(5)', "0", "x\n")
m = re.search(r"/wiki/([^/]+)/", loc)
e = page(m.group(1), "edit.html") if m else ""
check(m and ("input", "value", 't" autofocus onfocus="alert(5)') in attrs(e) and scripted(e) == [],
      "a title stays inside the edit form's value")

for f in ("", "create.html", "1/", "wiki_syntax/"):
    st, hd, b = req("GET", "/wiki/" + f)
    check(st == 200, "/wiki/%s answers 200 (%d)" % (f, st))


def rate(path, n=150):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    ts = []
    for i in range(n):
        if i and i % 90 == 0:
            c.close()
            c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
        t = time.perf_counter()
        c.request("GET", path)
        r = c.getresponse()
        r.read()
        ts.append((time.perf_counter() - t) * 1000)
        if r.status != 200:
            return None
    c.close()
    return statistics.median(ts), max(ts)


for path in ("/", "/docs/setup-guide", "/pub/style/style.css", "/wiki/1/index.html"):
    r = rate(path)
    if r is None:
        check(False, "GET %s" % path)
        continue
    med, mx = r
    print("TIME: %s median %.1f ms, max %.1f ms" % (path, med, mx))
    # generous: a regression to seconds, not a slow machine
    check(med < 250, "GET %s median under 250 ms" % path)

sys.exit(fails)
