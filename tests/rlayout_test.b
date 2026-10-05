implement RlayoutTest;

#
# The markdown parser Render (and Lucifer's presentation views) lay
# out from (appl/xenith/render/rlayout.b):
#   - a table's column alignments come from its separator row
#   - outer pipes delimit a row; they are not empty columns
#   - emphasis nests: bold italic is bold around italic, and the text
#     inside bold or italic is parsed again
#   - a backslash makes punctuation literal
#   - a link's text may hold brackets, as a badge's image does
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "rlayout.m";
	rlayout: Rlayout;
	DocNode: import rlayout;

RlayoutTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/rlayout_test.b";

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

# The one block a document parses to
block(t: ref T, md: string, kind: int): ref DocNode
{
	doc := rlayout->parsemd(md);
	if(len doc != 1)
		t.fatal(sys->sprint("%d blocks, want 1", len doc));
	n := hd doc;
	if(n.kind != kind)
		t.fatal(sys->sprint("block kind %d, want %d", n.kind, kind));
	return n;
}

aligns(n: ref DocNode): string
{
	if(n.children == nil)
		return nil;
	return (hd n.children).text;
}

testTableOuterPipes(t: ref T)
{
	n := block(t, "| Face | Size |\n|:-----|-----:|\n| Go | 14 |\n", Rlayout->Ntable);
	t.asserteq(n.aux, 2, "outer pipes are not columns");
	t.assertseq(aligns(n), "lr", "alignments from :-- and --:");
	t.assertseq(n.text, "| Face | Size |\n| Go | 14 |", "rows, without the separator");
}

testTableBare(t: ref T)
{
	n := block(t, "a | b | c\n---|:-:|---\nx | y | z", Rlayout->Ntable);
	t.asserteq(n.aux, 3, "three columns");
	t.assertseq(aligns(n), "lcl", "alignments, centre from :-:");
}

testBoldItalic(t: ref T)
{
	p := block(t, "***x***", Rlayout->Npara);
	b := hd p.children;
	t.asserteq(b.kind, Rlayout->Nbold, "outside is bold");
	i := hd b.children;
	t.asserteq(i.kind, Rlayout->Nitalic, "inside is italic");
	t.assertseq((hd i.children).text, "x", "the text");
}

testNestedEmphasis(t: ref T)
{
	p := block(t, "**a *b* c**", Rlayout->Npara);
	b := hd p.children;
	t.asserteq(b.kind, Rlayout->Nbold, "bold");
	kids := b.children;
	t.asserteq(len kids, 3, "bold holds text, italic, text");
	if(len kids != 3)
		return;
	t.assertseq((hd kids).text, "a ", "text before");
	kids = tl kids;
	t.asserteq((hd kids).kind, Rlayout->Nitalic, "italic inside bold");
	t.assertseq((hd tl kids).text, " c", "text after");
}

testEscape(t: ref T)
{
	p := block(t, "L\\* 92\\_100", Rlayout->Npara);
	t.asserteq(len p.children, 1, "one text run, no emphasis");
	t.assertseq((hd p.children).text, "L* 92_100", "backslash makes punctuation literal");
}

testBadgeLink(t: ref T)
{
	p := block(t, "[![CI](https://x/badge.svg)](https://x/ci) after", Rlayout->Npara);
	l := hd p.children;
	t.asserteq(l.kind, Rlayout->Nlink, "a link around the image");
	t.assertseq((hd l.children).text, "CI", "the image shows its alt text");
	t.assertseq((hd tl p.children).text, " after", "text after the link");
}

testNestedList(t: ref T)
{
	doc := rlayout->parsemd("- a\n  - b\n    - c\n- d\n");
	t.asserteq(len doc, 4, "four items");
	if(len doc != 4)
		return;
	levels := "";
	for(; doc != nil; doc = tl doc)
		levels += string (hd doc).aux;
	t.assertseq(levels, "0120", "levels by indent");
}

testSetext(t: ref T)
{
	h := block(t, "Title\n=====\n", Rlayout->Nheading);
	t.asserteq(h.aux, 1, "=== is the first level");
	h = block(t, "Sub\n---\n", Rlayout->Nheading);
	t.asserteq(h.aux, 2, "--- is the second level");
}

testQuoteDepth(t: ref T)
{
	doc := rlayout->parsemd("> outer\n>> inner\n");
	t.asserteq(len doc, 2, "a paragraph each");
	if(len doc == 2)
		t.asserteq((hd tl doc).aux, 2, ">> nests");
}

testStrikeAndAutolink(t: ref T)
{
	p := block(t, "~~gone~~ <https://go.dev>", Rlayout->Npara);
	t.asserteq((hd p.children).kind, Rlayout->Nstrike, "~~ strikes");
	l := hd tl tl p.children;
	t.asserteq(l.kind, Rlayout->Nlink, "<url> links");
	t.assertseq((hd l.children).text, "https://go.dev", "showing the url");
}

testEscapedPipe(t: ref T)
{
	n := block(t, "| a | b |\n|---|---|\n| `x \\| y` | z |\n", Rlayout->Ntable);
	t.asserteq(n.aux, 2, "the escaped pipe does not split the cell");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	rlayout = load Rlayout Rlayout->PATH;
	if(rlayout == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Rlayout->PATH);
		raise "fail:cannot load rlayout";
	}
	rlayout->init(nil);

	run("TableOuterPipes", testTableOuterPipes);
	run("TableBare", testTableBare);
	run("BoldItalic", testBoldItalic);
	run("NestedEmphasis", testNestedEmphasis);
	run("Escape", testEscape);
	run("BadgeLink", testBadgeLink);
	run("NestedList", testNestedList);
	run("Setext", testSetext);
	run("QuoteDepth", testQuoteDepth);
	run("StrikeAndAutolink", testStrikeAndAutolink);
	run("EscapedPipe", testEscapedPipe);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
