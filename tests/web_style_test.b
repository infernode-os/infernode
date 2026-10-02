implement WebStyleTest;

#
# The cascade and computed values.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/html.m";
	html: Html;
include "web/css.m";
	css: Css;
include "web/style.m";
	style: Style;
	St, Styles, Env, Computed, Len: import style;

WebStyleTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_style_test.b";

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

Page: adt {
	d:	ref Doc;
	c:	ref Computed;
};

env: ref Env;

# Parse markup, apply its <style> elements, compute.
page(src: string): ref Page
{
	d := html->parsestring(src, "http://example.com/dir/page.html");
	s := Styles.new();
	for(n := 1; n < d.n; n++)
		if(d.nodes[n].kind == Dom->Element && d.nodes[n].tag == Dom->Tstyle)
			s.add(css->parse(d.textof(n)), Style->Author, d.url);
	return ref Page(d, style->compute(d, s, env));
}

# the style of the first element with this id
st(p: ref Page, id: string): ref St
{
	for(n := 1; n < p.d.n; n++)
		if(p.d.attr(n, "id") == id)
			return p.c.st[n];
	return nil;
}

px(l: Len): real
{
	if(l.kind != Style->Lpx)
		return -999.0;
	return l.px;
}

suffix(s, e: string): int
{
	return len s >= len e && s[len s - len e:] == e;
}

col(c: int): string
{
	return sys->sprint("%.8ux", c);
}

testDefaults(t: ref T)
{
	p := page("<div id=d><span id=s>x</span></div><h1 id=h>H</h1><p id=p>p</p><ul><li id=li>i</ul><table id=tb><tr><td id=td>c</table><b id=b>b</b><a id=a href=x>a</a><pre id=pre>x</pre>");
	t.asserteq(st(p, "d").display, Style->Dblock, "div is block");
	t.asserteq(st(p, "s").display, Style->Dinline, "span is inline");
	t.assert(st(p, "h").fontsize == 32.0, "h1 is 2em");
	t.asserteq(st(p, "h").weight, 700, "h1 is bold");
	t.assert(px(st(p, "p").mt) == 16.0, "p has 1em top margin");
	t.asserteq(st(p, "li").display, Style->Dlistitem, "li is list-item");
	t.asserteq(st(p, "tb").display, Style->Dtable, "table");
	t.asserteq(st(p, "td").display, Style->Dtablecell, "td");
	t.asserteq(st(p, "b").weight, 700, "b is bolder");
	t.assertseq(col(st(p, "a").color), "0000eeff", "link colour");
	t.asserteq(st(p, "a").decoration, Style->TDunder, "link underline");
	t.assertseq(hd st(p, "pre").family, "monospace", "pre monospace");
	t.asserteq(st(p, "pre").whitespace, Style->Wpre, "pre white-space");
	body := p.d.find(1, Dom->Tbody);
	t.assert(px(p.c.st[body].ml) == 8.0, "body margin 8px");
	head := p.d.find(1, Dom->Thead);
	t.asserteq(p.c.st[head].display, Style->Dnone, "head hidden");
}

testCascade(t: ref T)
{
	p := page("<style>" +
		"#a { color: red } .c { color: green } div { color: blue }" +
		".x { color: red } .x { color: green }" +
		".i { color: green !important } #i { color: red }" +
		"#s { color: red }" +
		"</style><div id=a class=c>1</div><div id=x class=x>2</div><div id=i class=i>3</div><div id=s style='color: green'>4</div>");
	t.assertseq(col(st(p, "a").color), "ff0000ff", "id beats class");
	t.assertseq(col(st(p, "x").color), "008000ff", "later wins");
	t.assertseq(col(st(p, "i").color), "008000ff", "important beats id");
	t.assertseq(col(st(p, "s").color), "008000ff", "style attribute beats id");
}

testLayers(t: ref T)
{
	p := page("<style>@layer base, theme;" +
		"@layer theme { #a { color: green } }" +
		"@layer base { #a { color: red } }" +
		"#b { color: green } @layer theme { #b { color: red } }" +
		"@layer base { #c { color: green !important } } #c { color: red !important }" +
		"</style><p id=a>a<p id=b>b<p id=c>c");
	t.assertseq(col(st(p, "a").color), "008000ff", "later layer wins");
	t.assertseq(col(st(p, "b").color), "008000ff", "unlayered beats layered");
	t.assertseq(col(st(p, "c").color), "008000ff", "important: earlier layer wins");
}

testInherit(t: ref T)
{
	p := page("<style>#o { color: red; border: 2px solid; padding: 3px; font-size: 20px }" +
		"#k { border: inherit; padding: inherit } #u { color: initial } #v { color: unset }</style>" +
		"<div id=o><p id=i>x</p><p id=k>k</p><p id=u>u</p><p id=v>v</p></div>");
	t.assertseq(col(st(p, "i").color), "ff0000ff", "colour inherits");
	t.asserteq(st(p, "i").bt, 0, "border does not inherit");
	t.assert(st(p, "i").fontsize == 20.0, "font-size inherits");
	t.asserteq(st(p, "k").bt, 2, "border: inherit");
	t.assert(px(st(p, "k").pl) == 3.0, "padding: inherit");
	t.assertseq(col(st(p, "u").color), "000000ff", "initial");
	t.assertseq(col(st(p, "v").color), "ff0000ff", "unset inherits an inherited property");
	t.assertseq(col(st(p, "o").bct), "ff0000ff", "border colour is currentcolor");
}

testUnits(t: ref T)
{
	p := page("<style>html { font-size: 10px } #a { font-size: 2em; width: 3em; height: 2rem }" +
		"#b { width: 50vw; height: 10vh; margin-left: calc(100% - 20px); padding-top: calc(2 * 3px + 1em) }" +
		"#c { width: min(50%, 300px); height: clamp(10px, 5vw, 40px); font-size: 150% }" +
		"#d { width: 1in; height: 12pt; line-height: 1.5; letter-spacing: 0.1em }</style>" +
		"<div id=a>a</div><div id=b>b</div><div id=c>c</div><div id=d>d</div>");
	a := st(p, "a");
	t.assert(a.fontsize == 20.0, "2em of 10px");
	t.assert(px(a.width) == 60.0, "3em uses own font size");
	t.assert(px(a.height) == 20.0, "2rem");
	b := st(p, "b");
	t.assert(px(b.width) == 512.0, "50vw");
	t.assert(px(b.height) == 76.8, "10vh");
	t.assert(b.ml.kind == Style->Lpx && b.ml.pct == 100.0 && b.ml.px == -20.0, "calc(100% - 20px)");
	t.assert(px(b.pt) == 16.0, "calc(2 * 3px + 1em)");
	c := st(p, "c");
	t.asserteq(c.width.kind, Style->Lcalc, "min() with % is deferred");
	t.assert(c.width.resolve(400.0) == 200.0, "min(50% of 400, 300)");
	t.assert(c.width.resolve(1000.0) == 300.0, "min(50% of 1000, 300)");
	t.assert(px(c.height) == 40.0, "clamp(10, 51.2, 40)");
	t.assert(c.fontsize == 15.0, "150% font size");
	d := st(p, "d");
	t.assert(px(d.width) == 96.0, "1in");
	t.assert(px(d.height) == 16.0, "12pt");
	t.asserteq(d.lineheight.kind, Style->Lnum, "unitless line-height");
	t.assert(d.letterspacing == 1.0, "0.1em letter-spacing");
}

testVars(t: ref T)
{
	p := page("<style>:root { --main: green; --w: 10px; --a: var(--b); --b: var(--a) }" +
		"#a { color: var(--main); width: calc(var(--w) * 3) }" +
		"#b { --main: blue } #b2 { color: var(--main) }" +
		"#c { color: var(--nope, green) } #d { color: red; color: var(--a) }" +
		"#e { --x: 5px; margin: var(--x) var(--x) }</style>" +
		"<div id=a>a</div><div id=b><p id=b2>b</p></div><div id=c>c</div><div id=d>d</div><div id=e>e</div>");
	t.assertseq(col(st(p, "a").color), "008000ff", "var()");
	t.assert(px(st(p, "a").width) == 30.0, "var() in calc");
	t.assertseq(col(st(p, "b2").color), "0000ffff", "custom properties inherit");
	t.assertseq(col(st(p, "c").color), "008000ff", "fallback");
	t.assertseq(col(st(p, "d").color), "000000ff", "cycle: invalid at computed time, unset");
	t.assert(px(st(p, "e").mr) == 5.0, "var() in a shorthand");
}

testShorthands(t: ref T)
{
	p := page("<style>#a { margin: 1px 2px 3px } #b { border: thick dashed blue; border-left: 0 }" +
		"#c { background: red url(i.png) no-repeat center / cover } #d { font: italic bold 20px/30px Georgia, serif }" +
		"#e { display: flex; flex: 2 } #f { inset: 5px; border-radius: 4px 8px } #g { list-style: square inside }" +
		"#h { padding-inline: 4px 6px; margin-block-start: 7px }</style>" +
		"<div id=a></div><div id=b></div><div id=c></div><div id=d></div><div id=e><p id=e1>x</p></div>" +
		"<div id=f></div><ul id=g></ul><div id=h></div>");
	a := st(p, "a");
	t.assert(px(a.mt) == 1.0 && px(a.mr) == 2.0 && px(a.mb) == 3.0 && px(a.ml) == 2.0, "margin: 3 values");
	b := st(p, "b");
	t.assert(b.bt == 5 && b.bst == Style->Bdashed && b.bl == 0, "border, then border-left");
	t.assertseq(col(b.bcr), "0000ffff", "border colour");
	c := st(p, "c");
	t.assertseq(col(c.bgcolor), "ff0000ff", "background colour");
	t.assert(c.bg != nil && c.bg[0].img != nil && c.bg[0].img.s == "http://example.com/dir/i.png", "image, absolute");
	t.asserteq(c.bg[0].rx, Style->Rnorepeat, "no-repeat");
	t.assert(c.bg[0].sizex.px == -1.0, "cover");
	d := st(p, "d");
	t.assert(d.fontsize == 20.0 && d.weight == 700 && d.fontstyle == Style->FSitalic, "font shorthand");
	t.assert(px(d.lineheight) == 30.0, "font line-height");
	t.assertseq(hd d.family, "georgia", "font family");
	e := st(p, "e1");
	t.assert(st(p, "e").display == Style->Dflex, "display flex");
	f := st(p, "f");
	t.assert(px(f.top) == 5.0 && px(f.left) == 5.0, "inset");
	t.assert(px(f.rtl) == 4.0 && px(f.rtr) == 8.0 && px(f.rbr) == 4.0, "border-radius");
	g := st(p, "g");
	t.assert(g.liststyle == "square" && g.listinside, "list-style");
	h := st(p, "h");
	t.assert(px(h.pl) == 4.0 && px(h.pr) == 6.0 && px(h.mt) == 7.0, "logical properties");
	t.assert(e.grow == 0.0, "flex item default grow");
	p = page("<style>#x { flex: 2 } #y { flex: none } #z { flex: 1 1 100px }</style><div style=display:flex><i id=x>x</i><i id=y>y</i><i id=z>z</i></div>");
	x := st(p, "x");
	t.assert(x.grow == 2.0 && x.shrink == 1.0 && x.basis.kind == Style->Lpx && x.basis.pct == 0.0, "flex: 2");
	t.asserteq(x.display, Style->Dblock, "flex items are blockified");
	y := st(p, "y");
	t.assert(y.grow == 0.0 && y.shrink == 0.0 && y.basis.kind == Style->Lauto, "flex: none");
	t.assert(px(st(p, "z").basis) == 100.0, "flex basis");
}

testColors(t: ref T)
{
	for(l := list of {
		("green", "008000ff"), ("#0f0", "00ff00ff"), ("#00ff0080", "00ff0080"),
		("rgb(0 128 0)", "008000ff"), ("rgba(0, 128, 0, 0.5)", "00800080"),
		("rgb(0% 50% 0% / 50%)", "00800080"), ("hsl(120deg 100% 25%)", "008000ff"),
		("hsl(120, 100%, 25%)", "008000ff"), ("hwb(120 0% 50%)", "008000ff"),
		("transparent", "00000000"), ("rebeccapurple", "663399ff"),
		("oklch(51.975% 0.17686 142.495)", "008000ff"), ("lab(46.2775% -47.5621 48.5837)", "008000ff"),
		("color-mix(in srgb, red, blue)", "800080ff"), ("Canvas", "ffffffff")}; l != nil; l = tl l) {
		(in, want) := hd l;
		(ok, c) := style->color(css->tokenize(in));
		t.assert(ok, "parses: " + in);
		t.assertseq(col(c), want, in);
	}
	(ok, nil) := style->color(css->tokenize("rgb(1 2)"));
	t.assert(!ok, "too few channels");
	(ok, nil) = style->color(css->tokenize("rgb(0 0 0 0 0)"));
	t.assert(!ok, "too many channels");
	(ok, nil) = style->color(css->tokenize("rgba(0, 0, 0, .5, 1)"));
	t.assert(!ok, "too many channels, legacy");
}

testMedia(t: ref T)
{
	p := page("<style>#a { color: red } @media (min-width: 600px) { #a { color: green } }" +
		"@media (width >= 1200px) { #a { color: red } } @media screen and (orientation: landscape) { #b { color: green } }" +
		"@media print { #b { color: red } } @media (400px <= width <= 1100px) { #c { color: green } }" +
		"@media not all and (monochrome) { #d { color: green } }" +
		"@supports (display: grid) { #e { color: green } } @supports (display: nonsense) { #e { color: red } }" +
		"@supports not (frobnicate: 1) { #f { color: green } } @supports selector(:has(a)) { #g { color: green } }</style>" +
		"<p id=a>a<p id=b>b<p id=c>c<p id=d>d<p id=e>e<p id=f>f<p id=g>g");
	for(l := list of {"a", "b", "c", "d", "e", "f", "g"}; l != nil; l = tl l)
		t.assertseq(col(st(p, hd l).color), "008000ff", "media/supports " + hd l);
}

testSelectors(t: ref T)
{
	p := page("<style>.p:has(> .c) { color: green } li:nth-child(2n+1) { color: green }" +
		"#out:has(.a .b) { color: red } #in:has(.a .b) { color: green }" +
		":is(#x, #y) > b { color: green } a[href$='.pdf' i] { color: green } p:not(.n) + p { color: green }" +
		"input:checked { color: green } div:empty { color: green } .q:first-of-type { color: green }" +
		".nest { color: red; & > .k { color: green } }</style>" +
		"<div class=p id=h><span class=c>x</span></div><ul><li id=l1>1<li id=l2>2<li id=l3>3</ul>" +
		"<div id=y><b id=yb>b</b></div><a id=pdf href=a.PDF>p</a><p>1</p><p id=sib>2</p>" +
		"<input id=cb type=checkbox checked><div id=em></div><span class=q id=q1></span>" +
		"<div class=a><div id=out><div class=b></div></div></div><div id=in><div class=a><div class=b></div></div></div>" +
		"<div class=nest><i class=k id=k>k</i></div>");
	t.assertseq(col(st(p, "h").color), "008000ff", ":has(> .c)");
	t.assertseq(col(st(p, "l1").color), "008000ff", "nth-child odd 1");
	t.assertseq(col(st(p, "l2").color), "000000ff", "nth-child odd 2");
	t.assertseq(col(st(p, "l3").color), "008000ff", "nth-child odd 3");
	t.assertseq(col(st(p, "yb").color), "008000ff", ":is() >");
	t.assertseq(col(st(p, "pdf").color), "008000ff", "attribute suffix, case-insensitive");
	t.assertseq(col(st(p, "sib").color), "008000ff", ":not() +");
	t.assertseq(col(st(p, "cb").color), "008000ff", ":checked");
	t.assertseq(col(st(p, "em").color), "008000ff", ":empty");
	t.assertseq(col(st(p, "q1").color), "008000ff", ":first-of-type");
	t.assertseq(col(st(p, "k").color), "008000ff", "nesting");
	t.assertseq(col(st(p, "in").color), "008000ff", ":has() with a descendant combinator");
	t.assert(col(st(p, "out").color) != "ff0000ff", ":has() anchors at the element");
	# HTML compares some attribute values without case (type, dir, ...), others with
	p = page("<style>input[type=text] { color: green } div[dir=RTL] { color: green } span[title=Hi] { color: red }</style>" +
		"<input id=t type=TEXT><div id=d dir=rtl></div><span id=s title=hi></span>");
	t.assertseq(col(st(p, "t").color), "008000ff", "[type=text] matches type=TEXT");
	t.assertseq(col(st(p, "d").color), "008000ff", "[dir=RTL] matches dir=rtl");
	t.assertseq(col(st(p, "s").color), "000000ff", "[title=Hi] does not match title=hi");
}

testBackgrounds(t: ref T)
{
	p := page("<style>#a { background-image: url(a.png), url(b.png); background-size: cover; background-repeat: no-repeat, repeat-x }" +
		"#b { background-size: 10px; background-image: url(c.png), url(d.png) }</style><p id=a>a<p id=b>b");
	a := st(p, "a");
	t.asserteq(len a.bg, 2, "the image list sets the layer count");
	t.assert(a.bg[1].img != nil, "second image kept");
	t.asserteq(a.bg[1].sizex.kind, Style->Lcontent, "size repeats over the layers");
	t.asserteq(a.bg[1].rx, Style->Rrepeat, "second repeat");
	t.asserteq(a.bg[1].ry, Style->Rnorepeat, "second repeat-x");
	b := st(p, "b");
	t.asserteq(len b.bg, 2, "image after size");
	t.assert(b.bg[0].img != nil && b.bg[1].img != nil, "both images");
	t.asserteq(b.bg[1].sizex.kind, Style->Lpx, "earlier size kept for both");
	p = page("<div id=g style='background: linear-gradient(green, green) 25px 10px / 30px 40px no-repeat round, red'></div>");
	g := st(p, "g");
	# the colour is the last layer's, whose image is none: two layers
	t.assert(len g.bg == 2 && g.bg[0].img != nil && g.bg[0].img.kind == Css->Kfunction && g.bg[1].img == nil && col(g.bgcolor) == "ff0000ff",
		sys->sprint("a gradient layer and the colour: %d layers, colour %s", len g.bg, col(g.bgcolor)));
	t.assert(px(g.bg[0].posx) == 25.0 && px(g.bg[0].posy) == 10.0, sys->sprint("gradient position %g %g", px(g.bg[0].posx), px(g.bg[0].posy)));
	t.assert(px(g.bg[0].sizex) == 30.0 && px(g.bg[0].sizey) == 40.0, sys->sprint("gradient size %g %g", px(g.bg[0].sizex), px(g.bg[0].sizey)));
	t.assert(g.bg[0].rx == Style->Rnorepeat && g.bg[0].ry == Style->Rround, "no-repeat round");
	p = page("<div id=u style='background: url(a.png) 25px 10px / 30px 40px no-repeat, url(b.png)'></div><div id=v style='background: linear-gradient(green, green) 25px 10px'></div>");
	u := st(p, "u");
	t.assert(len u.bg == 2 && suffix(u.bg[0].img.s, "a.png") && px(u.bg[0].posx) == 25.0 && px(u.bg[0].sizey) == 40.0, sys->sprint("two layers in order, position and size: %d layers, first %s, %g %g", len u.bg, u.bg[0].img.s, px(u.bg[0].posx), px(u.bg[0].sizey)));
	t.assert(px(st(p, "v").bg[0].posx) == 25.0, sys->sprint("gradient alone position %g", px(st(p, "v").bg[0].posx)));
}

testHints(t: ref T)
{
	p := page("<body bgcolor=ffeedd text=red><table id=t width=200 cellspacing=4 cellpadding=3><tr><td id=c bgcolor=green align=center>x</table>" +
		"<img id=i src=x width=100 height=50%><font id=f color=blue size=5>f</font>");
	t.assertseq(col(p.c.st[p.d.find(1, Dom->Tbody)].bgcolor), "ffeeddff", "body bgcolor, bare hex");
	tb := st(p, "t");
	t.assert(px(tb.width) == 200.0 && tb.spacingx == 4.0, "table width, cellspacing");
	c := st(p, "c");
	t.assertseq(col(c.bgcolor), "008000ff", "td bgcolor");
	t.assert(px(c.pt) == 3.0, "cellpadding");
	t.asserteq(c.align, Style->Acenter, "td align");
	i := st(p, "i");
	t.assert(px(i.width) == 100.0 && i.height.pct == 50.0, "img width/height");
	f := st(p, "f");
	t.assertseq(col(f.color), "0000ffff", "font color");
	t.assert(f.fontsize == 24.0, "font size=5");
	p = page("<style>p { color: green }</style><p id=p style='color: red' bgcolor=red>x");
	t.assertseq(col(st(p, "p").color), "ff0000ff", "style attribute beats sheet");
	p = page("<table border=0 cellpadding=0 cellspacing=0><tr><td id=z>x</table>");
	z := st(p, "z");
	t.assert(px(z.pt) == 0.0 && px(z.pl) == 0.0, sys->sprint("cellpadding=0 beats the UA padding: %g", px(z.pt)));
	t.assert(z.bt == 0 && z.bl == 0, sys->sprint("border=0: no cell border: %d", z.bt));
	p = page("<p dir=rtl id=r>x<bdo dir=ltr id=o>y</bdo><span id=s style='unicode-bidi: embed'>z</span></p>");
	t.assert(st(p, "r").dirrtl && st(p, "r").unicodebidi == Style->UBisolate, "dir=rtl: direction and isolation");
	t.assert(!st(p, "o").dirrtl && st(p, "o").unicodebidi == Style->UBisolateoverride,
		sys->sprint("bdo overrides: rtl %d ub %d", st(p, "o").dirrtl, st(p, "o").unicodebidi));
	t.asserteq(st(p, "s").unicodebidi, Style->UBembed, "unicode-bidi: embed");
	p = page("<style>p { margin: 0; color: red } #r { margin-top: revert; color: revert } .f { align-content: safe center; justify-content: unsafe end }</style><p id=r>x<div class=f id=f></div>");
	t.assert(px(st(p, "r").mt) == 16.0, sys->sprint("margin: revert restores the UA margin: %g", px(st(p, "r").mt)));
	t.assertseq(col(st(p, "r").color), "000000ff", "color: revert with no UA value is unset (inherited)");
	t.asserteq(st(p, "f").safe, 1, "safe recorded for align-content only");
	t.asserteq(st(p, "f").aligncontent, Style->ALcenter, "safe center is center");
	p = page("<div id=a style='transform: translateX(100%)'></div><div id=b style='transform: translate(10px, 2em) rotate(45deg)'></div><div id=c style='transform: none'></div>");
	t.assert(st(p, "a").translated && st(p, "a").tx.pct == 100.0 && st(p, "a").ty.px == 0.0, "translateX(100%): a percentage of the box's width");
	t.assert(st(p, "b").translated && px(st(p, "b").tx) == 10.0 && px(st(p, "b").ty) == 32.0, sys->sprint("translate(10px, 2em) with a rotate: %g %g", px(st(p, "b").tx), px(st(p, "b").ty)));
	t.assert(!st(p, "c").translated, "transform: none");
}

testPseudo(t: ref T)
{
	p := page("<style>#q::before { content: '<'; color: green } #q::after { content: none } #r::after { content: attr(x) }</style><p id=q>q<p id=r x=1>r");
	q := p.d.find(1, Dom->Tp);
	t.assert(p.c.before[q] != nil, "::before generated");
	t.assertseq(col(p.c.before[q].color), "008000ff", "::before style");
	t.assert(p.c.after[q] == nil, "content: none generates nothing");
}

testDump(t: ref T)
{
	p := page("<div id=a style='width: 50%; margin: 0 auto'>x</div>");
	s := style->dump(st(p, "a"));
	t.assert(index(s, "display block\n") >= 0, "dump display");
	t.assert(index(s, "width 50%\n") >= 0, "dump width");
	t.assert(index(s, "margin 0px auto 0px auto\n") >= 0, "dump margin: " + s);
}

index(s, t: string): int
{
	for(i := 0; i+len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}

testURLs(t: ref T)
{
	b := "http://a/b/c/d;p?q";
	for(l := list of {
		("g", "http://a/b/c/g"), ("./g", "http://a/b/c/g"), ("g/", "http://a/b/c/g/"),
		("/g", "http://a/g"), ("//g", "http://g"), ("?y", "http://a/b/c/d;p?y"),
		("g?y", "http://a/b/c/g?y"), ("#s", "http://a/b/c/d;p?q#s"), ("../g", "http://a/b/g"),
		("../..", "http://a/"), ("../../g", "http://a/g"), ("https://x/y", "https://x/y"),
		("data:image/png;base64,AA", "data:image/png;base64,AA")}; l != nil; l = tl l) {
		(r, want) := hd l;
		t.assertseq(style->resolveurl(b, r), want, r);
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	dom = load Dom Dom->PATH;
	html = load Html Html->PATH;
	css = load Css Css->PATH;
	style = load Style Style->PATH;
	if(testing == nil || html == nil || css == nil || style == nil) {
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:load";
	}
	testing->init();
	env = ref Env(1024, 768, 1.0, 0, 0, 0, 0, 0, 0);
	html->init();
	css->init();
	if((err := style->init()) != nil) {
		sys->fprint(sys->fildes(2), "style: %s\n", err);
		raise "fail:init";
	}
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Defaults", testDefaults);
	run("Cascade", testCascade);
	run("Layers", testLayers);
	run("Inherit", testInherit);
	run("Units", testUnits);
	run("Vars", testVars);
	run("Shorthands", testShorthands);
	run("Colors", testColors);
	run("Media", testMedia);
	run("Selectors", testSelectors);
	run("Backgrounds", testBackgrounds);
	run("Hints", testHints);
	run("Pseudo", testPseudo);
	run("Dump", testDump);
	run("URLs", testURLs);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
