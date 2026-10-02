implement WebHtmlTest;

#
# The HTML parser against tree-construction cases in the html5lib test
# format: tests/web/html/*.dat (#data, #errors, #document blocks).
# tree.dat is generated from corpus.txt (see mkdat.py); extra.dat holds
# hand-written cases.  Official html5lib-tests files can be dropped in.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "testing.m";
	testing: Testing;
	T: import testing;
include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/html.m";
	html: Html;

WebHtmlTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_html_test.b";
DATDIR: con "/tests/web/html";

passed := 0;
failed := 0;
skipped := 0;

Case: adt {
	file:	string;
	line:	int;
	data:	string;
	want:	string;
};

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

# Read the cases in one .dat file.
readdat(path: string): list of ref Case
{
	f := bufio->open(path, Bufio->OREAD);
	if(f == nil)
		return nil;
	cases: list of ref Case;
	c: ref Case;
	sect := "";
	ln := 0;
	while((l := f.gets('\n')) != nil) {
		ln++;
		if(l == "#data\n") {
			if(c != nil)
				cases = c :: cases;
			c = ref Case(path, ln, "", "");
			sect = "data";
			continue;
		}
		if(l == "#errors\n" || l == "#new-errors\n" || l == "#document-fragment\n" ||
		   l == "#script-off\n" || l == "#script-on\n") {
			sect = l;
			continue;
		}
		if(l == "#document\n") {
			sect = "document";
			continue;
		}
		case sect {
		"data" =>
			c.data += l;
		"document" =>
			c.want += l;
		}
	}
	if(c != nil)
		cases = c :: cases;
	r: list of ref Case;
	for(; cases != nil; cases = tl cases) {
		c = hd cases;
		# the data's final newline is the format's, not the input's;
		# the document ends with a blank separator line
		if(len c.data > 0)
			c.data = c.data[0:len c.data-1];
		while(len c.want > 1 && c.want[len c.want-1] == '\n' && c.want[len c.want-2] == '\n')
			c.want = c.want[0:len c.want-1];
		r = c :: r;
	}
	return r;
}

datfiles(): list of string
{
	fd := sys->open(DATDIR, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of string;
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			nm := d[i].name;
			if(len nm > 4 && nm[len nm-4:] == ".dat")
				l = DATDIR + "/" + nm :: l;
		}
	}
	return l;
}

testTrees(t: ref T)
{
	files := datfiles();
	if(files == nil)
		t.fatal("no .dat files in " + DATDIR);
	n := 0;
	bad := 0;
	for(; files != nil; files = tl files)
		for(cs := readdat(hd files); cs != nil; cs = tl cs) {
			c := hd cs;
			n++;
			got: string;
			{
				got = html->parsestring(c.data, nil).dump();
			} exception e {
			"*" =>
				got = "exception: " + e + "\n";
			}
			if(got != c.want) {
				bad++;
				t.error(sys->sprint("%s:%d\n#data\n%s\n#want\n%s#got\n%s", c.file, c.line, c.data, c.want, got));
			}
		}
	t.log(sys->sprint("%d cases, %d failed", n, bad));
}

testCharset(t: ref T)
{
	t.assertseq(html->charset(array of byte "<meta charset=\"ISO-8859-1\">", nil), "windows-1252", "meta charset");
	t.assertseq(html->charset(array of byte "<meta http-equiv=content-type content=\"text/html; charset=koi8-r\">", nil), "koi8-r", "http-equiv");
	t.assertseq(html->charset(array of byte "<p>x", "UTF-8"), "utf-8", "transport wins");
	t.assertseq(html->charset(array of byte "<p>x", nil), "utf-8", "default");
	b := array[] of {byte 16rEF, byte 16rBB, byte 16rBF, byte 'x'};
	t.assertseq(html->charset(b, "latin1"), "utf-8", "BOM wins");
	d := html->parse(array of byte "<p>café", nil, nil);
	t.assertseq(d.textof(d.root()), "café", "utf-8 decode");
	l1 := array[] of {byte '<', byte 'p', byte '>', byte 16rE9};
	d = html->parse(l1, "iso-8859-1", nil);
	t.assertseq(d.textof(d.root()), "é", "latin1 decode");
	# undeclared and not UTF-8: windows-1252, as browsers in a Western locale
	t.assertseq(html->charset(l1, nil), "windows-1252", "undeclared latin1 is sniffed");
	d = html->parse(l1, nil, nil);
	t.assertseq(d.textof(d.root()), "é", "undeclared latin1 decode");
	t.assertseq(html->charset(array of byte "<p>日本語", nil), "utf-8", "undeclared valid utf-8");
	# UTF-16 with a byte-order mark
	u16 := array[] of {byte 16rFF, byte 16rFE, byte '<', byte 0, byte 'p', byte 0, byte '>', byte 0, byte 16rE9, byte 0};
	t.assertseq(html->charset(u16, nil), "utf-16le", "utf-16 BOM");
	d = html->parse(u16, nil, nil);
	t.assertseq(d.textof(d.root()), "é", "utf-16 decode");
	t.assertseq(d.nodes[d.find(1, Dom->Tp)].name, "p", "utf-16 markup parsed");
	t.assertseq(html->charset(array of byte "<p>x", "GBK"), "gb2312", "gbk alias");
	# a truncated end tag at the end of script data is text
	d = html->parsestring("<script>x</scri", nil);
	t.assertseq(d.textof(d.find(1, Dom->Tscript)), "x</scri", "truncated end tag is text");
}

testMutation(t: ref T)
{
	d := html->parsestring("<ul><li>a<li>c</ul>", nil);
	ul := d.find(1, Dom->Tul);
	t.assert(ul != 0, "find ul");
	li := d.create(Dom->Element, "li", Dom->HTML);
	tx := d.create(Dom->Text, nil, Dom->HTML);
	d.settext(tx, "b");
	d.append(li, tx);
	second := d.nodes[d.nodes[ul].first].next;
	d.insert(ul, li, second);
	# the impossible is refused, not done
	d.insert(ul, second, second);
	d.insert(second, ul, 0);
	t.asserteq(d.nodes[second].next, 0, "insert before itself refused");
	t.asserteq(d.nodes[ul].parent != second, 1, "insert into a descendant refused");
	t.assertseq(d.textof(ul), "abc", "insert before");
	d.remove(d.nodes[ul].first);
	t.assertseq(d.textof(ul), "bc", "remove first");
	d.setattr(ul, "class", "x");
	d.setattr(ul, "class", "y");
	t.assertseq(d.attr(ul, "class"), "y", "setattr replaces");
	t.asserteq(len d.nodes[ul].attrs, 1, "one attribute");
}

# XHTML parses as XML: CDATA is text, <x/> is empty, namespaces decide
# which elements are HTML, SVG or neither.
testXML(t: ref T)
{
	src := "<?xml version=\"1.0\"?>\n<!DOCTYPE html PUBLIC \"x\" \"y\" [ <!ENTITY e \"z\"> ]>\n" +
		"<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:s=\"http://www.w3.org/2000/svg\">" +
		"<head><style><![CDATA[ p > a { color: red } ]]></style></head>" +
		"<body><div/><p title=\"a&amp;b\">x&lt;y&#x41;&eacute;</p><s:svg><s:rect/></s:svg>" +
		"<foo xmlns=\"urn:other\"><p/></foo></body></html>";
	d := html->parsexml(array of byte src, nil, nil);
	got := d.dump();
	t.log(got);
	want := "| <html>\n" +
		"|   xmlns=\"http://www.w3.org/1999/xhtml\"\n" +
		"|   xmlns:s=\"http://www.w3.org/2000/svg\"\n" +
		"|   <head>\n" +
		"|     <style>\n" +
		"|       \" p > a { color: red } \"\n" +
		"|   <body>\n" +
		"|     <div>\n" +
		"|     <p>\n" +
		"|       title=\"a&b\"\n" +
		"|       \"x<yAé\"\n" +
		"|     <svg svg>\n" +
		"|       <svg rect>\n" +
		"|     <foo>\n" +
		"|       xmlns=\"urn:other\"\n" +
		"|       <p>\n";
	t.assertseq(got, want, "tree");
	foo := d.find(1, Dom->Tp);
	t.assert(foo != 0, "the XHTML p is an HTML p");
	for(n := 1; n < d.n; n++)
		if(d.nodes[n].name == "p" && d.nodes[d.nodes[n].parent].name == "foo")
			t.asserteq(d.nodes[n].tag, Dom->Tnone, "a p in another namespace is not an HTML p");
}

testTags(t: ref T)
{
	for(i := 1; i < Dom->Ntags; i++)
		if(dom->atom(dom->tagname(i)) != i)
			t.error("tag table out of order at " + dom->tagname(i));
	t.asserteq(dom->atom("my-widget"), Dom->Tnone, "unknown tag");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	testing = load Testing Testing->PATH;
	dom = load Dom Dom->PATH;
	html = load Html Html->PATH;
	if(testing == nil || dom == nil || html == nil) {
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:load";
	}
	testing->init();
	html->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Tags", testTags);
	run("Trees", testTrees);
	run("Charset", testCharset);
	run("Mutation", testMutation);
	run("XML", testXML);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
