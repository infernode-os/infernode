implement MdhtmlTest;

#
# mdhtml(2): Markdown to HTML as Markdown.pl writes it, case by case;
# odd and large inputs answered without an exception or a hang, and
# the shapes that cost more than their length (nesting, marks that
# look ahead) held to it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "mdhtml.m";
	mdhtml: Mdhtml;

MdhtmlTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/mdhtml_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.error("an exception");
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# each case: Markdown, the HTML it makes
cases(t: ref T, c: array of (string, string))
{
	for(i := 0; i < len c; i++){
		(md, want) := c[i];
		got := mdhtml->html(md);
		if(got != want)
			t.error(sys->sprint("case %d:\n--- markdown\n%s\n--- want\n%s--- got\n%s", i, md, want, got));
	}
}

# htmlsafe: text that is not the page's author's.  html passed its
# HTML and any link through, so such text given to it was script in the
# page: there was no way to render a stranger's Markdown.  In what
# htmlsafe gives there is no tag of the writer's and no destination but
# http, https, mailto or a place with no scheme.
testSafe(t: ref T)
{
	c := array[] of {
	# what html passes through is text here
	("a <b>bold</b> <img src=x onerror=alert(1)>", "<p>a &lt;b&gt;bold&lt;/b&gt; &lt;img src=x onerror=alert(1)&gt;</p>\n"),
	("<script>alert(1)</script>\n\nafter", "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n<p>after</p>\n"),
	("<div onclick=\"x()\">\n*in*\n</div>\n", "<p>&lt;div onclick=\"x()\"&gt;\n<em>in</em>\n&lt;/div&gt;</p>\n"),
	("<!-- a comment -->", "<p>&lt;!-- a comment --&gt;</p>\n"),
	# a link goes to http, https, mailto, or nowhere else
	("[a](javascript:alert(1))", "<p>[a](javascript:alert(1))</p>\n"),
	("[a](JaVaScRiPt:alert(1))", "<p>[a](JaVaScRiPt:alert(1))</p>\n"),
	("[a](data:text/html,x)", "<p>[a](data:text/html,x)</p>\n"),
	("[a](vbscript:x) [b](file:///etc/passwd)", "<p>[a](vbscript:x) [b](file:///etc/passwd)</p>\n"),
	("![i](javascript:alert(1))", "<p>![i](javascript:alert(1))</p>\n"),
	("[a](java\\:script) [b](javascript&colon;alert(1)) [c](&#106;avascript:x)",
		"<p>[a](java\\:script) [b](javascript&colon;alert(1)) [c](&#106;avascript:x)</p>\n"),
	("[a][r]\n\n[r]: javascript:alert(1)\n", "<p>[a][r]</p>\n"),
	("<javascript:alert(1)> <ftp://h/f>", "<p>&lt;javascript:alert(1)&gt; &lt;ftp://h/f&gt;</p>\n"),
	# and those it does go to, as html has them
	("[a](http://h/p?x=1#f \"t\") [b](https://h) [c](mailto:u@h)",
		"<p><a href=\"http://h/p?x=1#f\" title=\"t\">a</a> <a href=\"https://h\">b</a> <a href=\"mailto:u@h\">c</a></p>\n"),
	("[a](/page) [b](sub/page.md) [c](#top) [d](//h/p) [e](?q=a:b)",
		"<p><a href=\"/page\">a</a> <a href=\"sub/page.md\">b</a> <a href=\"#top\">c</a> <a href=\"//h/p\">d</a> <a href=\"?q=a:b\">e</a></p>\n"),
	("![i](/pic.png) <http://h/> <u@h.org>",
		"<p><img src=\"/pic.png\" alt=\"i\" /> <a href=\"http://h/\">http://h/</a> <a href=\"mailto:u@h.org\">u@h.org</a></p>\n"),
	("[a][r]\n\n[r]: https://h/ \"T\"\n", "<p><a href=\"https://h/\" title=\"T\">a</a></p>\n"),
	# the rest of Markdown is as it was
	("# H\n\n* a\n* `<b>`\n\n> q **s**\n", "<h1>H</h1>\n<ul>\n<li>a</li>\n<li><code>&lt;b&gt;</code></li>\n</ul>\n<blockquote>\n<p>q <strong>s</strong></p>\n</blockquote>\n"),
	("a &amp; b &lt; c &copy;", "<p>a &amp; b &lt; c &copy;</p>\n"),
	};
	for(i := 0; i < len c; i++){
		(md, want) := c[i];
		got := mdhtml->htmlsafe(md);
		if(got != want)
			t.error(sys->sprint("case %d:\n--- markdown\n%s\n--- want\n%s--- got\n%s", i, md, want, got));
	}
	# and html still passes its author's HTML and links through
	t.assertseq(mdhtml->html("<b>x</b> [a](javascript:f())"), "<p><b>x</b> <a href=\"javascript:f()\">a</a></p>\n", "html is as it was");
	# whatever is written, nothing of it is a tag or an attribute
	hostile := array[] of {
		"<img src=x onerror=alert(1)>", "<svg/onload=alert(1)>", "<a href=\"javascript:x\">y</a>",
		"[x](javascript:alert(1) \"t\")", "[x]( javascript:alert(1))", "[x](<javascript:alert(1)>)",
		"[x](\tjavascript:alert(1))", "![x](data:image/svg+xml,<svg onload=alert(1)>)",
		"<iframe src=//evil>", "</p><script>x</script>", "<<script>script>", "[a](\"onmouseover=\"x)",
		"<a\nhref=javascript:x>", "<style>*{x:expression(1)}</style>", "<form action=//evil><input>",
	};
	for(i = 0; i < len hostile; i++){
		h := mdhtml->htmlsafe(hostile[i]);
		ok := 1;
		# every tag in it is one Markdown makes, and holds no script
		for(j := 0; j + 1 < len h; j++)
			if(h[j] == '<' && h[j+1] != '/'){
				k := j+1;
				while(k < len h && h[k] >= 'a' && h[k] <= 'z')
					k++;
				tag := h[j+1:k];
				if(tag != "p" && tag != "a" && tag != "img" && tag != "em" && tag != "strong" && tag != "code" && tag != "br")
					ok = 0;
				while(k < len h && h[k] != '>')
					k++;
				low := "";
				for(m := j; m < k; m++){
					ch := h[m];
					if(ch >= 'A' && ch <= 'Z')
						ch += 'a' - 'A';
					low[len low] = ch;
				}
				if(count(low, "javascript") + count(low, "data:") + count(low, " on") != 0)
					ok = 0;
			}
		t.assert(ok, sys->sprint("no tag or script of the writer's in %q -> %q", hostile[i], h));
	}
}

testBlocks(t: ref T)
{
	cases(t, array[] of {
	("hello", "<p>hello</p>\n"),
	("one\ntwo\n\nthree\n", "<p>one\ntwo</p>\n<p>three</p>\n"),
	("# One\n## Two ##\n###### Six", "<h1>One</h1>\n<h2>Two</h2>\n<h6>Six</h6>\n"),
	("Title\n=====\n\nSub\n---\n", "<h1>Title</h1>\n<h2>Sub</h2>\n"),
	("a\n\n---\n\n* * *\n", "<p>a</p>\n<hr />\n<hr />\n"),
	("    x < y\n    z\n\n    w\n\nafter", "<pre><code>x &lt; y\nz\n\nw\n</code></pre>\n<p>after</p>\n"),
	("```c\nint *p;\n```\n", "<pre><code class=\"language-c\">int *p;\n</code></pre>\n"),
	("~~~\n# not\n~~~", "<pre><code># not\n</code></pre>\n"),
	("> a\nlazy\n>\n> b", "<blockquote>\n<p>a\nlazy</p>\n<p>b</p>\n</blockquote>\n"),
	("> > deep", "<blockquote>\n<blockquote>\n<p>deep</p>\n</blockquote>\n</blockquote>\n"),
	("text\n# head", "<p>text</p>\n<h1>head</h1>\n"),
	("line  \nnext", "<p>line<br />\nnext</p>\n"),
	("\tcode", "<pre><code>code\n</code></pre>\n"),
	});
}

testLists(t: ref T)
{
	cases(t, array[] of {
	("* a\n* b\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"),
	("- a\n\n- b\n", "<ul>\n<li><p>a</p>\n</li>\n<li><p>b</p>\n</li>\n</ul>\n"),
	("1. one\n2. two", "<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n"),
	("3. three", "<ol start=\"3\">\n<li>three</li>\n</ol>\n"),
	("* a\n    * b\n    * c\n* d", "<ul>\n<li>a\n<ul>\n<li>b</li>\n<li>c</li>\n</ul></li>\n<li>d</li>\n</ul>\n"),
	("* a\n  * b", "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul></li>\n</ul>\n"),
	("* a\ncontinued", "<ul>\n<li>a\ncontinued</li>\n</ul>\n"),
	("* a\n\n    more\n\nafter", "<ul>\n<li><p>a</p>\n<p>more</p>\n</li>\n</ul>\n<p>after</p>\n"),
	("intro:\n* x", "<p>intro:</p>\n<ul>\n<li>x</li>\n</ul>\n"),
	("* a\n1. b", "<ul>\n<li>a</li>\n</ul>\n<ol>\n<li>b</li>\n</ol>\n"),
	("*not a list*", "<p><em>not a list</em></p>\n"),
	});
}

testInline(t: ref T)
{
	cases(t, array[] of {
	("*em* _em_ **st** __st__ ***both***", "<p><em>em</em> <em>em</em> <strong>st</strong> <strong>st</strong> <strong><em>both</em></strong></p>\n"),
	("*a **b** c*", "<p><em>a <strong>b</strong> c</em></p>\n"),
	("snake_case_name and 2 * 3 * 4", "<p>snake_case_name and 2 * 3 * 4</p>\n"),
	("`a < *b*` and ``x ` y``", "<p><code>a &lt; *b*</code> and <code>x ` y</code></p>\n"),
	("\\*lit\\* \\_x\\_ \\\\", "<p>*lit* _x_ \\</p>\n"),
	("a & b &amp; c &#169; &copy; < > d", "<p>a &amp; b &amp; c &#169; &copy; &lt; &gt; d</p>\n"),
	("[werc](http://werc.cat-v.org/ \"The werc\")", "<p><a href=\"http://werc.cat-v.org/\" title=\"The werc\">werc</a></p>\n"),
	("[*e*](a?x=1&y=\"2\")", "<p><a href=\"a?x=1&amp;y=&quot;2&quot;\"><em>e</em></a></p>\n"),
	("[rel](docs/setup) [paren](f(x))", "<p><a href=\"docs/setup\">rel</a> <a href=\"f(x)\">paren</a></p>\n"),
	("![a *cat*](/c.png \"T\")", "<p><img src=\"/c.png\" alt=\"a cat\" title=\"T\" /></p>\n"),
	("[one][x], [Two][], [three] [3] and [x]\n\n[x]: /x\n[two]: <http://two/> \"T2\"\n  [3]: /3\n\t'three'", "<p><a href=\"/x\">one</a>, <a href=\"http://two/\" title=\"T2\">Two</a>, <a href=\"/3\" title=\"three\">three</a> and <a href=\"/x\">x</a></p>\n"),
	("[nope] and [no][ref]", "<p>[nope] and [no][ref]</p>\n"),
	("<http://a.b/?q=1&r=2> <me@x.org>", "<p><a href=\"http://a.b/?q=1&amp;r=2\">http://a.b/?q=1&amp;r=2</a> <a href=\"mailto:me@x.org\">me@x.org</a></p>\n"),
	("a <b class=\"x\">bold</b> <!-- c --> 1 < 2", "<p>a <b class=\"x\">bold</b> <!-- c --> 1 &lt; 2</p>\n"),
	("~~gone~~", "<p><del>gone</del></p>\n"),
	("# Mixed *emph* `code`", "<h1>Mixed <em>emph</em> <code>code</code></h1>\n"),
	});
}

testHTML(t: ref T)
{
	cases(t, array[] of {
	("<div class=\"x\">\n*not md*\n</div>\n\n*md*", "<div class=\"x\">\n*not md*\n</div>\n<p><em>md</em></p>\n"),
	("<pre>\n\n  keep\n\n</pre>\nafter", "<pre>\n\n  keep\n\n</pre>\n<p>after</p>\n"),
	("<!--\nhidden\n-->\ntext", "<!--\nhidden\n-->\n<p>text</p>\n"),
	("<table><tr><td>a</td></tr></table>", "<table><tr><td>a</td></tr></table>\n"),
	("<span>inline</span> text", "<p><span>inline</span> text</p>\n"),
	("<script>\nx = 1 < 2;\n\ny();\n</script>", "<script>\nx = 1 < 2;\n\ny();\n</script>\n"),
	});
}

testEscape(t: ref T)
{
	t.assertseq(mdhtml->escape("<a href=\"x\">&</a>"), "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;", "escape");
	t.assertseq(mdhtml->escape("plain"), "plain", "nothing to escape");
}

# Anything at all: an answer, not an exception or a hang
testNoHarm(t: ref T)
{
	odd := array[] of {
		"", "\n\n\n", "*", "**", "***", "****x****", "[", "]", "[]()", "[a](", "![",
		"<", "<a", "<a href=\"", "<!--", "`", "``x`", "&", "&#;", "&#x;", "\\",
		"* ", "1.", "1. ", "> ", ">", "#", "#######", "```", "~~~\n", "    ",
		"* a\n\n\n\n", "- [ ] task", "[x]:", "[x]: ", "a\r\nb\r\n", "\t\t*\ta",
		"_a_b_", "__a_", "*a _b* c_", "[a [b] c](d)", "[a](b \"c)", "[a](<b)",
		"<div>\n", "<pre>\nnever closed", "> * a\n> * b", "* > q", "1) x",
		"\u00e9t\u00e9 *caf\u00e9* \u20ac",
	};
	for(i := 0; i < len odd; i++)
		mdhtml->html(odd[i]);
	# a large document, quickly
	s := "";
	for(i = 0; i < 2000; i++)
		s += sys->sprint("## %d\n\nSome *text* with [a link](/p%d) and `code`.\n\n* item\n* item\n\n", i, i);
	t0 := sys->millisec();
	h := mdhtml->html(s);
	ms := sys->millisec() - t0;
	t.log(sys->sprint("%d bytes of Markdown in %d ms, %d of HTML", len s, ms, len h));
	t.assert(ms < 20000, "a 2000-section document within 20 s");
	t.assert(len h > len s, "it was all written");
}

rep(s: string, n: int): string
{
	b := array of byte s;
	a := array[n * len b] of byte;
	for(i := 0; i < n; i++)
		a[i*len b:] = b;
	return string a;
}

count(s, sub: string): int
{
	n := 0;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub){
			n++;
			i += len sub - 1;
		}
	return n;
}

# Text that is anyone's who can write a page.  Each level of a quote, a
# list or a link's text kept a copy of what was left of the line, so
# 40K of "> " was "out of memory" at 512MB; and a mark that looks
# ahead for its pair (a star, a bracket, a quote, a comment) looked to
# the end of the text from each one.  Each of these is answered, in a
# time that goes with its length.
testHostile(t: ref T)
{
	N: con 20000;
	shapes := array[] of {
		("quotes nested 20000 deep", rep("> ", N) + "x\n"),
		("lists nested 20000 deep", rep("- ", N) + "x\n"),
		("ordered lists nested 20000 deep", rep("1. ", N) + "x\n"),
		("quotes and lists nested in turn", rep("> - ", N) + "x\n"),
		("links nested 20000 deep", rep("[", N) + "x" + rep("](u)", N)),
		("images nested 20000 deep", rep("![", N) + "x" + rep("](u)", N)),
		("20000 brackets opened", rep("[", N)),
		("20000 brackets opened and closed, a reference defined", "[r]: /u\n\n" + rep("[", N) + rep("]", N)),
		("20000 links with no end to their destination", rep("[a](", N)),
		("20000 links with no end to their title", rep("[a](u \"t ", N)),
		("20000 links to a reference that is not there", "[r]: /u\n\n" + rep("[a][b] ", N)),
		("20000 stars that open and never close", rep("*a ", N)),
		("20000 double stars", rep("**a ", N)),
		("20000 underscores", rep("_a ", N)),
		("a line of 60000 stars", rep("*", 3*N)),
		("emphasis nested 20000 deep", rep("*a **b ", N/2) + rep("c** c* ", N/2)),
		("20000 strike-throughs never closed", rep("~~a ", N)),
		("20000 comments never closed", rep("<!-- ", N)),
		("20000 tags never closed", rep("<a ", N)),
		("backticks in runs that never pair", rep("`a ``b ```c ", N/2) + "````"),
		("20000 hard breaks", rep("a  \n", N)),
		("20000 entities that are none", rep("&a ", N)),
	};
	total := 0;
	for(i := 0; i < len shapes; i++){
		(what, text) := shapes[i];
		t0 := sys->millisec();
		h := "";
		{
			h = mdhtml->html(text);
		} exception e {
		"*" =>
			t.error(what + ": " + e);
			continue;
		}
		ms := sys->millisec() - t0;
		total += ms;
		t.log(sys->sprint("%s: %d bytes in %d ms, %d of HTML", what, len text, ms, len h));
		t.assert(ms < 5000, sys->sprint("%s: %d bytes within 5 s (%d ms)", what, len text, ms));
		t.assert(len h > 0, what + ": answered");
	}
	t.log(sys->sprint("all: %d ms", total));

	# what is nested deeper than 32 is the text it is
	h := mdhtml->html(rep("> ", 100) + "x <b> y\n");
	t.asserteq(count(h, "<blockquote>"), 32, "quotes nested 100 deep: 32 of them");
	t.asserteq(count(h, "</blockquote>"), 32, "each closed");
	t.assert(count(h, "&gt; &gt; ") > 0 && count(h, "x &lt;b&gt; y") == 1, "and the rest the text it is, escaped");
	h = mdhtml->html(rep("- ", 100) + "x\n");
	t.asserteq(count(h, "<ul>"), 32, "lists nested 100 deep: 32 of them");
	h = mdhtml->html(rep("[", 100) + "x <b>" + rep("](u)", 100));
	t.asserteq(count(h, "<a href"), 32, "links nested 100 deep: 32 of them");
	t.assert(count(h, "&lt;b&gt;") == 1 && count(h, "[[[") > 0, "and the rest the text it is, escaped");
	h = mdhtml->html(rep("> ", 31) + "*x*\n");
	t.asserteq(count(h, "<blockquote>") * 10 + count(h, "<p><em>x</em></p>"), 311, "quotes nested 31 deep are all quotes");
	h = mdhtml->html(rep("[", 30) + "*x*" + rep("](u)", 30));
	t.asserteq(count(h, "<a href") * 10 + count(h, "<em>x</em>"), 301, "links nested 30 deep are all links");
}

# What is looked for and not found is not looked for again from
# further on: only where it could not have been found there either.
testLookahead(t: ref T)
{
	cases(t, array[] of {
	("*a *b* c", "<p><em>a *b</em> c</p>\n"),
	("*a b *c d* e", "<p><em>a b *c d</em> e</p>\n"),
	("*a b **c d** e", "<p>*a b <strong>c d</strong> e</p>\n"),
	("**a *b* **c d** e", "<p><strong>a <em>b</em> **c d</strong> e</p>\n"),
	("**a *b* c** d **e", "<p><strong>a <em>b</em> c</strong> d **e</p>\n"),
	("_a _b_ c *d* _e", "<p><em>a _b</em> c <em>d</em> _e</p>\n"),
	("~~a ~~b~~ c", "<p><del>a ~~b</del> c</p>\n"),
	("[a [b](u) c", "<p>[a <a href=\"u\">b</a> c</p>\n"),
	("[a](u \"t [b](v \"w\") c", "<p><a href=\"u\" title=\"t [b](v &quot;w\">a</a> c</p>\n"),
	("[a](u \"t [b](v 'w') c", "<p>[a](u \"t <a href=\"v\" title=\"w\">b</a> c</p>\n"),
	("x <!-- a <!-- b --> c", "<p>x <!-- a <!-- b --> c</p>\n"),
	("x <!-- a <!-- b <i>c</i>", "<p>x &lt;!-- a &lt;!-- b <i>c</i></p>\n"),
	("` a `` b ` c `` d ```", "<p><code>a `` b</code> c `` d ```</p>\n"),
	# a star's pair looked for across a code span that a tag's quotes
	# hide from the text: looked for afresh from inside it
	("*x <a href='`'> *y* `z", "<p>*x <a href='`'> <em>y</em> `z</p>\n"),
	("a  \nb          \nc", "<p>a<br />\nb<br />\nc</p>\n"),
	});
}

# A definition is not taken out of what is not Markdown: a block of
# raw HTML, the code of a fence that opens a list's item.
testRefsNotInCode(t: ref T)
{
	cases(t, array[] of {
	("<pre>\n[x]: http://a\n</pre>\n\n[y][x]\n",
		"<pre>\n[x]: http://a\n</pre>\n<p>[y][x]</p>\n"),
	("- ```\n  [x]: http://b\n  ```\n\n[y][x]\n",
		"<ul>\n<li><pre><code>[x]: http://b\n</code></pre></li>\n</ul>\n<p>[y][x]</p>\n"),
	("> ```\n> [x]: http://c\n> ```\n\n[y][x]\n\n[z]: http://d\n\n[w][z]\n",
		"<blockquote>\n<pre><code>[x]: http://c\n</code></pre>\n</blockquote>\n<p>[y][x]</p>\n<p><a href=\"http://d\">w</a></p>\n"),
	("<div>\ntext\n</div>\n\n[x]: http://e\n\n[y][x]\n",
		"<div>\ntext\n</div>\n<p><a href=\"http://e\">y</a></p>\n"),
	});
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	mdhtml = load Mdhtml Mdhtml->PATH;
	if(testing == nil || mdhtml == nil){
		sys->fprint(sys->fildes(2), "cannot load: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	mdhtml->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Blocks", testBlocks);
	run("Lists", testLists);
	run("Inline", testInline);
	run("HTML", testHTML);
	run("Escape", testEscape);
	run("NoHarm", testNoHarm);
	run("Hostile", testHostile);
	run("Lookahead", testLookahead);
	run("RefsNotInCode", testRefsNotInCode);
	run("Safe", testSafe);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
