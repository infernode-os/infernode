#!/usr/bin/env python3
#
# tests/host/werc/check.py: a werc site through wercfs(4) and httpd(8),
# over HTTP.  Run by tests/host/werc_test.sh, which makes the site and
# starts the server:
#
#   check.py PORT SITEDIR WERCFS-STDERR
#
# Each check prints PASS: or FAIL:; the exit status is the failures.
#

import http.client, os, re, sys, threading, time

PORT = int(sys.argv[1])
SITE = sys.argv[2]
ERRS = sys.argv[3]
fails = 0

def check(ok, what, detail=""):
    global fails
    if ok:
        print("PASS: " + what)
    else:
        fails += 1
        print("FAIL: " + what + (": " + detail if detail else ""))
    sys.stdout.flush()

def get(path, method="GET", headers=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=20)
    c.request(method, path, headers=headers or {})
    r = c.getresponse()
    body = r.read()
    c.close()
    return r.status, {k.lower(): v for k, v in r.getheaders()}, body

def page(path):
    st, h, b = get(path)
    return st, h, b.decode("utf-8", "replace")

def article(html):
    m = re.search(r"<article>\n(.*)</article>", html, re.S)
    return m.group(1) if m else ""

def menu(html):
    m = re.search(r'<nav id="side-bar">\s*<div>\n(.*?)        </div>', html, re.S)
    return m.group(1) if m else ""

def title(html):
    m = re.search(r"<title>(.*?)</title>", html)
    return m.group(1) if m else None

# --- the home page: index.md in the master template
st, h, html = page("/")
check(st == 200, "/ is 200", str(st))
check(h.get("content-type", "").startswith("text/html"), "/ is text/html (index.html)", h.get("content-type"))
check(html.startswith("<!DOCTYPE HTML>\n<html>\n<head>"), "a page begins as werc's headers.tpl")
check(html.rstrip().endswith("</body></html>"), "a page ends with werc's $res_tail")
check(title(html) == "Home Page", "a .md's title is its === line", repr(title(html)))
check('<h1><a href="/">Test Site <span id="headerSubTitle">it\'s a subtitle</span></a></h1>' in html,
      "siteTitle and siteSubTitle from _werc/config (quotes, '' and a comment)")
check("WRONG" not in html, "an assignment inside braces is not taken")
check('<meta name="description" content="a site for the test">' in html, "meta_description")
check('href="/_werc/pub/style.css"' in html, "the site's style sheet linked, as it has one")
check('href="/pub/style/style.css"' in html, "werc's style sheet linked")
check('<div class="site-footer">site footer</div>' in html and "werc footer" not in html,
      "footer.inc: the site's, before werc's")
check('<div class="master-top">master top bar</div>' in html and "werc top bar" not in html,
      "top_bar.inc: $masterSite's, before werc's")
a = article(html)
check("<h1>Home Page</h1>" in a and "<em>in</em>" in a, "the body is the Markdown made HTML", a[:200])
check('<a href="docs/setup-guide">the guide</a>' in a and '<img src="/img.png" alt="a cat" />' in a,
      "links and images")
check("<ul>\n<li>one</li>\n<li>two</li>\n</ul>" in a, "a list")
check(h.get("content-length") == str(len(html.encode())), "a page has its length",
      "%s vs %d" % (h.get("content-length"), len(html.encode())))
etag = h.get("etag")
check(etag is not None and h.get("last-modified") is not None, "a page has an ETag and Last-Modified")

m = menu(html)
check(m.startswith('<p class="sideBarTitle">Pages:</p>\n<ul>\n'), "sideBarNavTitle heads the menu", m[:80])
want = ["/about", "/both", "/both/", "/deep/", "/docs/", "/hello", "/list/", "/notes", "/pub/"]
links = re.findall(r'<li><a href="([^"]*)"', m)
check(links == want, "the menu: the root's pages and directories (pub/ too, as werc's), sorted", repr(links))
check("/secret" not in m and "_draft" not in m and "index" not in m and "hidden" not in m and "img" not in m,
      "the menu leaves out conf_hide_paths, _ and . names, index and files that are not pages")

# --- a page in a directory: the menu to it, the directory's config
st, h, html = page("/docs/setup-guide")
check(st == 200 and h.get("content-type", "").startswith("text/html"), "a page with no extension is text/html (-T)",
      "%d %s" % (st, h.get("content-type")))
check(title(html) == "docs - setup guide", "a title from the path, as werc makes it", repr(title(html)))
check('<span id="headerSubTitle">docs subtitle</span>' in html and "Test Site" in html,
      "a directory's _werc/config over the root's (a list assigned)")
m = menu(html)
check('<li><a href="/docs/" class="thisPage">&raquo;<i> docs/</i></a></li>\n<li><ul>\n'
      '<li><a href="/docs/setup-guide" class="thisPage">&raquo;<i> setup guide</i></a></li>\n</ul></li>' in m,
      "the menu opens the page's directory, the path marked thisPage", m)
check("<code>wercfs</code>" in article(html), "the page's body")

st, h, html = page("/deep/er/most")
m = menu(html)
check(m.count("<li><ul>") == 2 and m.count("</ul></li>") == 2 and 'href="/deep/er/most" class="thisPage"' in m,
      "the menu nested two deep and closed", m)

st, h, html = page("/docs/")
check(st == 200 and title(html) == "Docs" and "the docs" in article(html), "a directory's index.md at its /")

# --- html and txt pages
st, h, html = page("/hello")
check(title(html) == "Hello Title", "a .html's title is its <title>", repr(title(html)))
check(article(html) == "<p>hello body</p>", "a .html's body is what is inside its <body>", repr(article(html)))
st, h, html = page("/notes")
check(article(html) == "<pre>\na &lt; b &amp; c\n</pre>\n" and title(html) == "notes",
      "a .txt is escaped in <pre>, titled by its path", repr(article(html)))
st, h, html = page("/about")
check("<pre><code>code &lt; here\n</code></pre>" in article(html) and title(html) == "about", "about: code block, title from the path")

# --- a directory with no index: werc's listing, with _header.md and _footer.md
st, h, html = page("/list/")
a = article(html)
want = ('<p>the list <em>header</em></p>\n'
        '<h1 class="dir-list-head"> / list</h1> <ul class="dir-list">\n'
        '<li><a href="a">a</a></li>\n<li><a href="b">b</a></li>\n<li><a href="raw.dat">raw.dat</a></li>\n</ul>\n'
        '<p>the list footer</p>\n')
check(a == want, "a directory with no index listed, between _header.md and _footer.md", repr(a))
check(title(html) == "list", "a listing's title from its path", repr(title(html)))
st, h, b = get("/list")
check(st == 301 and h.get("location") == "/list/", "a directory without its / is redirected", "%d %s" % (st, h.get("location")))
st, h, html = page("/both")
check(st == 301, "a directory and a page of one name: the directory", str(st))
st, h, html = page("/both/")
check("the directory" in article(html), "the directory's index")

# --- files as they are
st, h, b = get("/about.md")
check(st == 200 and b == open(SITE + "/about.md", "rb").read() and h.get("content-type", "").startswith("text/markdown"),
      "a page's source as it is", "%d %s" % (st, h.get("content-type")))
st, h, b = get("/img.png")
check(st == 200 and b == open(SITE + "/img.png", "rb").read() and h.get("content-type") == "image/png", "an image as it is")
st, h, b = get("/img.png", headers={"Range": "bytes=10-19"})
check(st == 206 and b == open(SITE + "/img.png", "rb").read()[10:20], "a range of a file", str(st))
st, h, b = get("/pub/style/style.css")
check(st == 200 and b == b"body { color: black }\n", "pub/ falls back to werc's pub/", "%d %r" % (st, b))
st, h, b = get("/pub/site.txt")
check(st == 200 and b == b"site pub\n", "pub/ is the site's first", str(st))
st, h, b = get("/_werc/pub/style.css")
check(st == 200 and b == b"site { }\n", "_werc/pub/ is served", str(st))
st, h, b = get("/_werc/")
check(st in (403, 404), "_werc/ is not listed", str(st))
for p in ["/_werc/config", "/_werc/lib/footer.inc", "/docs/_werc/config", "/.hidden.md", "/.hidden",
          "/nothing", "/docs/nothing", "/index", "/list/_nothing", "/img.png/x"]:
    st, h, b = get(p)
    check(st == 404, "not found: " + p, str(st))
for p in ["/escape", "/escape.md", "/escape2", "/escape2.txt", "/escapedir/", "/escapedir/outside.md"]:
    st, h, b = get(p)
    check(st == 404 and b"outside the site" not in b, "a host symlink out of the site is not followed: " + p, str(st))
st, h, html = page("/")
check("outside the site" not in html and "escape" not in menu(html), "nor in an included file, nor listed in the menu", menu(html)[:300])
st, h, html = page("/secret")
check(st == 200 and title(html) == "Secret", "a conf_hide_paths page is only out of the menu: still served")
st, h, html = page("/_draft")
check(st == 200, "an _ page is out of the menu, and served (werc does)", str(st))

# --- the HTTP a page gets, being a file of known length
st, h, html = page("/")
etag = h.get("etag")
st, h2, b = get("/", headers={"If-None-Match": etag})
check(st == 304, "If-None-Match with a page's ETag: 304", str(st))
st, h2, b = get("/", headers={"Range": "bytes=0-14"})
check(st == 206 and b == b"<!DOCTYPE HTML>", "a range of a page", "%d %r" % (st, b))
st, h2, b = get("/", method="HEAD")
check(st == 200 and b == b"" and h2.get("content-length") == h.get("content-length"), "HEAD of a page")
st, h3, b = get("/docs/setup-guide")
docetag = h3.get("etag")

# --- an edit, a new page, a page removed: seen at the next request
time.sleep(1.2)
with open(SITE + "/index.md", "a") as f:
    f.write("\nAn *edit*.\n")
st, h2, html = page("/")
check("<em>edit</em>" in html, "an edit is seen at the next request")
check(h2.get("etag") != etag, "an edit changes the page's ETag")
st, h2, b = get("/", headers={"If-None-Match": etag})
check(st == 200, "the old ETag no longer matches", str(st))
st, h3, b = get("/docs/setup-guide")
check(h3.get("etag") == docetag, "a page not changed keeps its ETag")
time.sleep(1.2)
with open(SITE + "/zebra.md", "w") as f:
    f.write("new\n")
st, h2, html = page("/about")
check('href="/zebra"' in menu(html), "a new page is in the menu at once")
st, h2, html = page("/zebra")
check(st == 200 and "<p>new</p>" in article(html), "a new page is served")
os.remove(SITE + "/zebra.md")
st, h2, html = page("/about")
check('href="/zebra"' not in menu(html), "a removed page leaves the menu")
st, h2, html = page("/zebra")
check(st == 404, "a removed page is not found", str(st))
time.sleep(1.2)
with open(SITE + "/docs/_werc/config", "w") as f:
    f.write("siteSubTitle='changed'\n")
st, h2, html = page("/docs/setup-guide")
check('<span id="headerSubTitle">changed</span>' in html, "a changed _werc/config is seen")

# --- many at once
results = []
def worker(i):
    try:
        for p in ["/", "/docs/setup-guide", "/hello", "/img.png", "/list/"]:
            st, h, b = get(p)
            results.append(st == 200 and int(h.get("content-length", "-1")) == len(b))
    except Exception as e:
        results.append(False)
ts = [threading.Thread(target=worker, args=(i,)) for i in range(30)]
for t in ts: t.start()
for t in ts: t.join()
check(len(results) == 150 and all(results), "30 clients at once, five requests each", "%d of %d" % (sum(results), len(results)))

# --- what was not taken was said, once
time.sleep(0.5)
err = open(ERRS).read() if os.path.exists(ERRS) else ""
check("not taken" in err and "conf_enable_blog" in err, "rc not taken is reported on stderr", err[:300])
check("siteTitle='WRONG'" in err, "an assignment in braces is reported, not taken")
check(err.count("conf_enable_blog") == 1, "each once", str(err.count("conf_enable_blog")))

print("check.py: %d failed" % fails)
sys.exit(min(fails, 100))
