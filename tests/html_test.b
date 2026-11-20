implement HtmlTest;

#
# Tests for the HTML module (html.m)
#
# Covers: lex, attrvalue, globalattr, isbreak, lex2string,
#         tag constants, character set handling
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "html.m";
	html: HTML;
	Lex: import html;

include "testing.m";
	testing: Testing;
	T: import testing;

HtmlTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/html_test.b";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# ── Basic lexing ─────────────────────────────────────────────────────────────

testLexSimple(t: ref T)
{
	data := array of byte "<html><body>hello</body></html>";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "lex returned tokens");
	t.assert(len tokens > 0, "lex non-empty");
	t.log(sys->sprint("token count: %d", len tokens));
}

testLexParagraph(t: ref T)
{
	data := array of byte "<p>Hello World</p>";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "lex paragraph not nil");

	# Should have: <p>, text, </p>
	foundP := 0;
	foundText := 0;
	for(i := 0; i < len tokens; i++) {
		if(tokens[i].tag == HTML->Tp)
			foundP++;
		if(tokens[i].tag == HTML->Data)
			foundText++;
	}
	t.assert(foundP > 0, "found <p> tag");
	t.assert(foundText > 0, "found text data");
}

testLexEmpty(t: ref T)
{
	data := array of byte "";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens == nil || len tokens == 0, "lex empty input");
}

# ── Attribute parsing ────────────────────────────────────────────────────────

testLexAttributes(t: ref T)
{
	data := array of byte "<a href=\"http://example.com\" class=\"link\">click</a>";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "lex with attrs not nil");

	# Find the <a> tag and check attributes
	for(i := 0; i < len tokens; i++) {
		if(tokens[i].tag == HTML->Ta) {
			(found, val) := html->attrvalue(tokens[i].attr, "href");
			t.assert(found != 0, "href attribute found");
			t.assertseq(val, "http://example.com", "href value");

			(found, val) = html->attrvalue(tokens[i].attr, "class");
			t.assert(found != 0, "class attribute found");
			t.assertseq(val, "link", "class value");

			(found, nil) = html->attrvalue(tokens[i].attr, "missing");
			t.assert(found == 0, "missing attribute not found");
			return;
		}
	}
	t.error("no <a> tag found");
}

# ── globalattr ───────────────────────────────────────────────────────────────

testGlobalattr(t: ref T)
{
	data := array of byte "<html><body id=\"main\"><p>text</p></body></html>";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "lex for globalattr not nil");

	(found, val) := html->globalattr(tokens, HTML->Tbody, "id");
	t.assert(found != 0, "globalattr found body id");
	t.assertseq(val, "main", "globalattr body id value");
}

# ── isbreak ──────────────────────────────────────────────────────────────────

testIsbreak(t: ref T)
{
	data := array of byte "<p>text</p><br><hr>";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "lex for isbreak not nil");

	# Find <br> and check isbreak
	for(i := 0; i < len tokens; i++) {
		if(tokens[i].tag == HTML->Tbr) {
			t.assert(html->isbreak(tokens, i) != 0, "br is break");
			return;
		}
	}
	t.log("no <br> tag found (may be parser-dependent)");
}

# ── lex2string ───────────────────────────────────────────────────────────────

testLex2string(t: ref T)
{
	data := array of byte "<b>bold</b>";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "lex for lex2string not nil");

	for(i := 0; i < len tokens; i++) {
		s := html->lex2string(tokens[i]);
		t.assertnotnil(s, sys->sprint("lex2string token %d", i));
		t.log(sys->sprint("token[%d]: %s", i, s));
	}
}

# ── Tag constants ────────────────────────────────────────────────────────────

testTagConstants(t: ref T)
{
	# Verify key tag constants are distinct
	t.assert(HTML->Ta != HTML->Tb, "Ta != Tb");
	t.assert(HTML->Tp != HTML->Tdiv, "Tp != Tdiv");
	t.assert(HTML->Thtml != HTML->Tbody, "Thtml != Tbody");
	t.assert(HTML->Data != HTML->Notfound, "Data != Notfound");
	t.assert(HTML->RBRA != HTML->Data, "RBRA != Data");
}

# ── Character set handling ───────────────────────────────────────────────────

testUTF8(t: ref T)
{
	data := array of byte "<p>Hello</p>";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "UTF8 lex not nil");

	# Check text content
	for(i := 0; i < len tokens; i++) {
		if(tokens[i].tag == HTML->Data) {
			t.assertnotnil(tokens[i].text, "UTF8 text content");
			return;
		}
	}
}

# ── What a page chooses ──────────────────────────────────────────────────────

lexer(data: array of byte, pidc: chan of int, done: chan of array of ref Lex)
{
	pidc <-= sys->pctl(0, nil);
	a: array of ref Lex;
	{
		a = html->lex(data, HTML->UTF8, 0);
	} exception {
	"*" =>
		a = nil;
	}
	done <-= a;
}

lextimer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# the tokens of data, given 20 seconds; (nil, 0) if the lexer did not return
lexin(data: array of byte): (array of ref Lex, int)
{
	pidc := chan of int;
	done := chan[1] of array of ref Lex;
	spawn lexer(data, pidc, done);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn lextimer(tc, 20000);
	alt{
	a := <-done =>
		return (a, 1);
	<-tc =>
		fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "kill");
		return (nil, 0);
	}
}

withbyte(s: string, b: array of byte): array of byte
{
	a := array of byte s;
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# A page that ends in the middle of a character: the lexer was given no
# bytes for it and never moved past it, adding to its text for ever.
testCutCharacter(t: ref T)
{
	cuts := array[] of {
		array[] of {byte 16re2},
		array[] of {byte 16re2, byte 16r82},
		array[] of {byte 16rf0, byte 16r9f, byte 16r9a},
		array[] of {byte 16rc3},
	};
	for(i := 0; i < len cuts; i++){
		(a, ok) := lexin(withbyte("abc", cuts[i]));
		if(!ok){
			t.error(sys->sprint("text ending in %d bytes of a character: the lexer did not return", len cuts[i]));
			continue;
		}
		t.asserteq(len a, 1, "text ending in part of a character is one token");
		if(len a == 1){
			t.asserteq(a[0].tag, HTML->Data, "and it is text");
			want := "abc";
			for(k := 0; k < len cuts[i]; k++)
				want[len want] = 16rFFFD;
			t.assertseq(a[0].text, want, "the text before it, and a bad character for each byte");
		}

		(a, ok) = lexin(withbyte("<a href=x", cuts[i]));
		if(!ok){
			t.error("an attribute's value ending in part of a character: the lexer did not return");
			continue;
		}
		t.assert(len a == 1 && a[0].tag == HTML->Ta, "an attribute's value ending in part of a character is one tag");

		(a, ok) = lexin(withbyte("<a href=\"x", cuts[i]));
		if(!ok){
			t.error("a quoted value ending in part of a character: the lexer did not return");
			continue;
		}
		t.assert(len a == 1 && a[0].tag == HTML->Ta, "a quoted value ending in part of a character is one tag");
	}
	# in the middle of the page it was always one bad character
	(a, ok) := lexin(array[] of {byte 'a', byte 16re2, byte 'b'});
	t.assert(ok && len a == 1 && a[0].text == "a�b", "part of a character with text after it");
}

onetext(t: ref T, src, want, what: string)
{
	(a, ok) := lexin(array of byte src);
	if(!ok){
		t.error(what + ": the lexer did not return");
		return;
	}
	got := "";
	for(i := 0; i < len a; i++){
		if(a[i].tag != HTML->Data){
			t.error(sys->sprint("%s: a token that is not text (tag %d)", what, a[i].tag));
			return;
		}
		got += a[i].text;
	}
	t.assertseq(got, want, what);
}

# A character given by number: the digits are the page's.
testNumericEntity(t: ref T)
{
	onetext(t, "a&#60;b", "a<b", "&#60;");
	onetext(t, "a&#233;b", "aéb", "&#233;");
	# 2^32+60 wrapped to 60, and 2^32+233 to 233
	onetext(t, "a&#4294967356;b", "a&#4294967356;b", "a number past 32 bits is no character");
	onetext(t, "a&#4294967529;b", "a&#4294967529;b", "another");
	onetext(t, "a&#99999999999999999999999999999999999999060;b", "a&#99999999999999999999999999999999999999060;b", "forty digits");
	onetext(t, "a&#256;b", "a&#256;b", "256, as before");
}

# A comment that ends where the page does, or does not end.
testCommentAtEnd(t: ref T)
{
	onetext(t, "x<!--c-->y", "xy", "a comment in the middle");
	onetext(t, "x<!--c-->", "x", "a comment whose end is the page's");
	onetext(t, "x<!---->", "x", "an empty comment at the end");
	onetext(t, "x<!--", "x", "a comment begun in the last four bytes");
	onetext(t, "x<!-- never closed -", "x", "a comment with no end");
}

testLatin1(t: ref T)
{
	data := array of byte "<p>test</p>";
	tokens := html->lex(data, HTML->Latin1, 0);
	t.assert(tokens != nil, "Latin1 lex not nil");
}

# ── Nested tags ──────────────────────────────────────────────────────────────

testNestedTags(t: ref T)
{
	data := array of byte "<div><p><b>bold text</b></p></div>";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "nested lex not nil");
	t.assert(len tokens >= 5, sys->sprint("nested enough tokens: %d", len tokens));
}

# ── Multiple attributes ─────────────────────────────────────────────────────

testMultipleAttributes(t: ref T)
{
	data := array of byte "<img src=\"test.png\" width=\"100\" height=\"200\">";
	tokens := html->lex(data, HTML->UTF8, 0);
	t.assert(tokens != nil, "multi-attr lex not nil");

	for(i := 0; i < len tokens; i++) {
		if(tokens[i].tag == HTML->Timg) {
			(f1, v1) := html->attrvalue(tokens[i].attr, "src");
			t.assert(f1 != 0, "img src found");
			t.assertseq(v1, "test.png", "img src value");

			(f2, v2) := html->attrvalue(tokens[i].attr, "width");
			t.assert(f2 != 0, "img width found");
			t.assertseq(v2, "100", "img width value");

			(f3, v3) := html->attrvalue(tokens[i].attr, "height");
			t.assert(f3 != 0, "img height found");
			t.assertseq(v3, "200", "img height value");
			return;
		}
	}
	t.error("no <img> tag found");
}

# ── Keepnls flag ─────────────────────────────────────────────────────────────

testKeepNewlines(t: ref T)
{
	data := array of byte "<pre>line1\nline2\n</pre>";
	tokens := html->lex(data, HTML->UTF8, 1);  # keepnls=1
	t.assert(tokens != nil, "keepnls lex not nil");
	t.log(sys->sprint("keepnls tokens: %d", len tokens));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	html = load HTML HTML->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(html == nil) {
		sys->fprint(sys->fildes(2), "cannot load html module: %r\n");
		raise "fail:cannot load html";
	}

	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("LexSimple", testLexSimple);
	run("LexParagraph", testLexParagraph);
	run("LexEmpty", testLexEmpty);
	run("LexAttributes", testLexAttributes);
	run("Globalattr", testGlobalattr);
	run("Isbreak", testIsbreak);
	run("Lex2string", testLex2string);
	run("TagConstants", testTagConstants);
	run("UTF8", testUTF8);
	run("CutCharacter", testCutCharacter);
	run("NumericEntity", testNumericEntity);
	run("CommentAtEnd", testCommentAtEnd);
	run("Latin1", testLatin1);
	run("NestedTags", testNestedTags);
	run("MultipleAttributes", testMultipleAttributes);
	run("KeepNewlines", testKeepNewlines);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
