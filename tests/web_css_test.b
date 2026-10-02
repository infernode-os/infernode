implement WebCssTest;

#
# CSS syntax: tokens, rules, nesting, selectors and specificity.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "web/css.m";
	css: Css;
	Tok, Decl, Rule, Sel, Sheet: import css;

WebCssTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_css_test.b";

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
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# "sel { decl; decl }" per style rule, one per line, flattening groups
dumprules(rs: array of ref Rule, pfx: string): string
{
	s := "";
	for(i := 0; i < len rs; i++)
		pick r := rs[i] {
		Style =>
			s += pfx;
			for(k := 0; k < len r.sels; k++) {
				if(k > 0)
					s += ", ";
				s += css->seltostring(r.sels[k]);
			}
			s += " {";
			for(k = 0; k < len r.decls; k++) {
				d := r.decls[k];
				s += " " + d.name + ":" + css->tostring(d.val);
				if(d.important)
					s += "!";
				s += ";";
			}
			s += " }\n";
		Media =>
			s += pfx + "@media " + css->tostring(r.cond) + "\n" + dumprules(r.rules, pfx + "  ");
		Supports =>
			s += pfx + "@supports " + css->tostring(r.cond) + "\n" + dumprules(r.rules, pfx + "  ");
		Layer =>
			s += pfx + "@layer";
			for(l := r.names; l != nil; l = tl l)
				s += " " + hd l;
			s += "\n" + dumprules(r.rules, pfx + "  ");
		Import =>
			s += pfx + "@import " + r.url + " " + css->tostring(r.cond) + "\n";
		Fontface =>
			s += pfx + "@font-face " + string len r.decls + "\n";
		Other =>
			s += pfx + "@" + r.name + "\n";
		Container =>
			s += pfx + "@container\n";
		}
	return s;
}

testTokens(t: ref T)
{
	v := css->tokenize("a.b #id 12px 50% -3.5e1 url( x.png ) \"s\\\"q\" rgb(1 2 3) [x=y] U+26 @media <!-- -->");
	t.assertseq(css->tostring(v), "a.b #id 12px 50% -35 url(x.png) \"s\"q\" rgb(1 2 3) [x=y] U+26 @media <!-- -->", "round trip");
	v = css->tokenize("/* c */\\31 23 \\@x");
	t.asserteq(v[0].kind, Css->Kident, "escaped ident");
	t.assertseq(v[0].s, "123", "escape value");
	v = css->tokenize("--x-y:1");
	t.asserteq(v[0].kind, Css->Kident, "custom property name");
	t.assertseq(v[0].s, "--x-y", "custom name");
	v = css->tokenize("1e3 .5 +.5");
	t.assert(v[0].n == 1000.0 && v[2].n == 0.5 && v[4].n == 0.5, "number forms");
}

testRules(t: ref T)
{
	s := css->parse("p { color: red; margin: 0 auto !important } /* x */ h1,h2{font-weight:700}");
	t.assertseq(dumprules(s.rules, ""), "p { color:red; margin:0 auto!; }\nh1, h2 { font-weight:700; }\n", "basic");
	s = css->parse("@media (min-width: 600px) { .a { x: 1 } } @supports (display: grid) { .b { y: 2 } }");
	t.assertseq(dumprules(s.rules, ""), "@media (min-width: 600px)\n  .a { x:1; }\n@supports (display: grid)\n  .b { y:2; }\n", "conditional");
	s = css->parse("@import url(a.css) screen; @import \"b.css\"; @layer base, util; @layer base { a { c: 1 } } @font-face { font-family: X; src: url(x.woff2) } @keyframes k { from { a: 1 } }");
	t.assertseq(dumprules(s.rules, ""), "@import a.css screen\n@import b.css \n@layer base util\n@layer base\n  a { c:1; }\n@font-face 2\n@keyframes\n", "at-rules");
	s = css->parse("a { color: red } b {{ broken } c { d: 1 }");
	t.assert(len s.rules >= 1, "recovers from junk");
	s = css->parse("p[ { x:1 } q { y: 2 }");
	t.assertseq(dumprules(s.rules, ""), "", "unclosed bracket swallows the rest");
	s = css->parse("@media screen { p { x: 1 } } q { --v: { a b }; w: var(--v) }");
	t.assertseq(dumprules(s.rules, ""), "@media screen\n  p { x:1; }\nq { --v:{ a b }; w:var(--v); }\n", "custom property with a block");
	s = css->parse("@scope (.card) { img { x: 1 } } @starting-style { p { y: 2 } } @scope { q { z: 3 } }");
	t.assertseq(dumprules(s.rules, ""), "@media \n  :is(.card) img { x:1; }\n@media \n  q { z:3; }\n", "scope and starting-style");
	s = css->parse("@import url( \"c.css\" );");
	t.assertseq(dumprules(s.rules, ""), "@import c.css \n", "import url with spaces");
	d := css->parsedecls("color: blue; background: url(a.png) no-repeat; ;; bogus; width: 10px !IMPORTANT");
	t.asserteq(len d, 3, "style attribute decls");
	t.assert(d[2].important, "important");
}

testNesting(t: ref T)
{
	s := css->parse(".p { color: red; & .c { x: 1 } > .d { y: 2 } &:hover { z: 3 } .e & { w: 4 } a:hover { v: 5 } color: blue; @media (x) { u: 6 } }");
	want := ".p { color:red; }\n" +
		":is(.p) .c { x:1; }\n" +
		":is(.p) > .d { y:2; }\n" +
		":is(.p):hover { z:3; }\n" +
		".e :is(.p) { w:4; }\n" +
		":is(.p) a:hover { v:5; }\n" +
		".p { color:blue; }\n" +
		"@media (x)\n  .p { u:6; }\n";
	t.assertseq(dumprules(s.rules, ""), want, "nesting");
	s = css->parse(".a { .b { .c { x: 1 } } }");
	t.assertseq(dumprules(s.rules, ""), ":is(:is(.a) .b) .c { x:1; }\n", "deep nesting");
}

sel(s: string): ref Sel
{
	l := css->parsesels(s);
	if(l == nil)
		return nil;
	return l[0];
}

spec(s: string): string
{
	x := sel(s);
	if(x == nil)
		return "invalid";
	return sys->sprint("%d,%d,%d", x.spec>>20, (x.spec>>10)&1023, x.spec&1023);
}

testSelectors(t: ref T)
{
	for(l := list of {
		("div", "div"),
		("A > B + C ~ D E", "a > b + c ~ d e"),
		("*.x#y[z][a=b][c~='d e' i]", "*.x#y[z][a=\"b\"][c~=\"d e\" i]"),
		("p::before", "p::before"),
		("p:before", "p::before"),
		("a:not(.b, #c):is(.d):where(e)", "a:not(.b, #c):is(.d):where(e)"),
		(":has(> img, + p)", ":has(> img, + p)"),
		("p[lang|=en]", "p[lang|=\"en\"]"),
		("li:nth-child(2n+1 of .x)", "li:nth-child(2n+1 of .x)"),
		("svg|rect", "rect"),
		("& .x", ":root .x")} ; l != nil; l = tl l) {
		(in, want) := hd l;
		x := sel(in);
		if(x == nil)
			t.error("invalid: " + in);
		else
			t.assertseq(css->seltostring(x), want, in);
	}
	for(bad := list of {"", "a..b", "p::before .x", "[=x]", ":nth-child(x)", ":not()", "a >", "##x", ":unknown-fn(x)", "a:-moz-focusring", "p:hoverx"}; bad != nil; bad = tl bad)
		t.assert(css->parsesels(hd bad) == nil, "should be invalid: " + hd bad);
	t.assert(len css->parsesels(":is(.a, ::-moz-x, .b)") == 1, "forgiving :is");
}

testSpecificity(t: ref T)
{
	t.assertseq(spec("*"), "0,0,0", "*");
	t.assertseq(spec("li"), "0,0,1", "li");
	t.assertseq(spec("ul li"), "0,0,2", "ul li");
	t.assertseq(spec("ul ol+li"), "0,0,3", "ul ol+li");
	t.assertseq(spec("h1 + *[rel=up]"), "0,1,1", "attr");
	t.assertseq(spec("ul ol li.red"), "0,1,3", "class");
	t.assertseq(spec("li.red.level"), "0,2,1", "two classes");
	t.assertseq(spec("#x34y"), "1,0,0", "id");
	t.assertseq(spec("#s12:not(FOO)"), "1,0,1", ":not");
	t.assertseq(spec(".foo :is(.bar, #baz)"), "1,1,0", ":is takes max");
	t.assertseq(spec(":where(#a) p"), "0,0,1", ":where is zero");
	t.assertseq(spec("p::before"), "0,0,2", "pseudo-element");
	t.assertseq(spec(":nth-child(2n of #a)"), "1,1,0", "nth-child of");
}

testAnB(t: ref T)
{
	for(l := list of {("odd", 2, 1), ("even", 2, 0), ("3", 0, 3), ("n", 1, 0), ("-n+3", -1, 3),
			("2n+1", 2, 1), ("2n-1", 2, -1), ("+5n", 5, 0), ("-2n + 4", -2, 4)}; l != nil; l = tl l) {
		(in, a, b) := hd l;
		x := sel(":nth-child(" + in + ")");
		if(x == nil) {
			t.error("invalid an+b: " + in);
			continue;
		}
		s := x.parts[0][0];
		t.assert(s.a == a && s.b == b, sys->sprint("%s: got %dn%+d", in, s.a, s.b));
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	css = load Css Css->PATH;
	if(testing == nil || css == nil) {
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:load";
	}
	testing->init();
	css->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Tokens", testTokens);
	run("Rules", testRules);
	run("Nesting", testNesting);
	run("Selectors", testSelectors);
	run("Specificity", testSpecificity);
	run("AnB", testAnB);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
