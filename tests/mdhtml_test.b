implement MdhtmlTest;

#
# mdhtml(2): Markdown to HTML as Markdown.pl writes it, case by case;
# odd and large inputs answered without an exception or a hang.
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

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
