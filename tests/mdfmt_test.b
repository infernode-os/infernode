implement MdfmtTest;

#
# md/fmt (appl/cmd/md/fmt.b), fmt(1) for Markdown:
#   - list items are not joined; a wrapped item continues under its text
#   - paragraphs are filled; hard breaks (two spaces, a backslash) kept
#   - code (fenced and indented), headings, tables, rules, HTML and
#     link definitions are copied as they are
#   - a word that would begin another block (- + 12. # >) is not put
#     at the start of a line
#   - block quotes are filled inside their > marks, nested too
#   - a code span is not broken
#   - -j folds long lines and joins none
#   - every Markdown file in the tree, filled at 40 and 70 columns,
#     parses to the same document (rlayout(2), which Render draws) and
#     is left as it is by a second fill
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "readdir.m";
	readdir: Readdir;

include "testing.m";
	testing: Testing;
	T: import testing;

include "rlayout.m";
	rlayout: Rlayout;
	DocNode: import rlayout;

MdfmtTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SRCFILE: con "/tests/mdfmt_test.b";
MDFMT: con "/dis/md/fmt.dis";

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

# md/fmt run with args on input: its output
mdfmt(t: ref T, args: list of string, input: string): string
{
	inp := array[2] of ref Sys->FD;
	outp := array[2] of ref Sys->FD;
	if(sys->pipe(inp) < 0 || sys->pipe(outp) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sync := chan of int;
	spawn runcmd("md/fmt" :: args, inp[1], outp[1], sync);
	<-sync;
	inp[1] = nil;
	outp[1] = nil;
	spawn feed(inp[0], input);
	inp[0] = nil;
	out := "";
	buf := array[8192] of byte;
	all := array[0] of byte;
	while((n := sys->read(outp[0], buf, len buf)) > 0){
		a := array[len all + n] of byte;
		a[0:] = all;
		a[len all:] = buf[0:n];
		all = a;
	}
	out = string all;
	return out;
}

feed(fd: ref Sys->FD, s: string)
{
	b := array of byte s;
	sys->write(fd, b, len b);
}

runcmd(args: list of string, in, out: ref Sys->FD, sync: chan of int)
{
	# a table of its own first: dup in the shared one would give the
	# test the pipe's write end as its fd 1, and the read no end
	sys->pctl(Sys->NEWFD, in.fd :: out.fd :: 2 :: nil);
	sys->dup(in.fd, 0);
	sys->dup(out.fd, 1);
	in = out = nil;
	sync <-= 1;
	cmd := load Command MDFMT;
	if(cmd == nil){
		sys->fprint(sys->fildes(2), "can't load %s: %r\n", MDFMT);
		return;
	}
	{
		cmd->init(nil, args);
	} exception {
	* =>
		;
	}
}

fmtis(t: ref T, args: list of string, input, want, msg: string)
{
	got := mdfmt(t, args, input);
	t.assertseq(got, want, msg);
	if(got == want)
		t.assertseq(mdfmt(t, args, got), got, msg + ", filled again");
}

testList(t: ref T)
{
	fmtis(t, "-l" :: "30" :: nil,
		"- one\n- two\n- a third item that is long enough to wrap\n",
		"- one\n- two\n- a third item that is long\n  enough to wrap\n",
		"items kept apart, continued under the text");
	fmtis(t, "-l" :: "30" :: nil,
		"1. a numbered item that is long enough\n   1. and a nested one that wraps too\n",
		"1. a numbered item that is\n   long enough\n   1. and a nested one that\n      wraps too\n",
		"numbered and nested");
	fmtis(t, "-l" :: "30" :: nil,
		"- [ ] a task that is long enough to wrap\n",
		"- [ ] a task that is long\n      enough to wrap\n",
		"a task's box is part of the marker");
	fmtis(t, "-l" :: "30" :: nil,
		"- an item\n  continued\n  here\n",
		"- an item continued here\n",
		"an item's own lines joined");
}

testPara(t: ref T)
{
	fmtis(t, "-l" :: "20" :: nil,
		"one two\nthree four five six seven\n\neight\nnine\n",
		"one two three four\nfive six seven\n\neight nine\n",
		"paragraphs filled, kept apart");
	fmtis(t, "-l" :: "70" :: nil,
		"a line that ends  \nhere and\nnot here\\\nbut here\n",
		"a line that ends  \nhere and not here\\\nbut here\n",
		"hard breaks kept");
	fmtis(t, "-l" :: "70" :: nil,
		"text\nwith `a | b` in it\n",
		"text with `a | b` in it\n",
		"a | in text is not a table");
}

testVerbatim(t: ref T)
{
	long := "this line is a good deal longer than twenty columns";
	in := "# " + long + "\n\n" +
		"```\n" + long + "\n" + long + "\n```\n\n" +
		"    " + long + "\n\n" +
		"| a | b |\n|---|---|\n| " + long + " | x |\n\n" +
		"---\n\n" +
		"<div>\n" + long + "\n</div>\n\n" +
		"[a]: http://example.com/a\n[b]: http://example.com/b\n";
	fmtis(t, "-l" :: "20" :: nil, in, in, "copied as they are");
}

testNoBlockStart(t: ref T)
{
	words := array[] of {"-", "+", "*", "12.", "3)", "#tag", ">", "```x"};
	for(i := 0; i < len words; i++){
		w := words[i];
		in := "aaaa bbbb " + w + " cccc\n";
		want := "aaaa bbbb " + w + "\ncccc\n";
		fmtis(t, "-l" :: "10" :: nil, in, want, sys->sprint("%q not at a line's start", w));
	}
	fmtis(t, "-l" :: "12" :: nil,
		"- aaaa bbbb - cccc\n",
		"- aaaa bbbb -\n  cccc\n",
		"nor in an item");
}

testQuote(t: ref T)
{
	fmtis(t, "-l" :: "24" :: nil,
		"> a quote that is long enough to wrap\n>\n> - an item in it, wrapping\n",
		"> a quote that is long\n> enough to wrap\n>\n> - an item in it,\n>   wrapping\n",
		"filled inside the marks");
	fmtis(t, "-l" :: "24" :: nil,
		"> > nested and long enough to wrap\n",
		"> > nested and long\n> > enough to wrap\n",
		"nested");
}

testCodeSpan(t: ref T)
{
	fmtis(t, "-l" :: "12" :: nil,
		"run `ls  -l /tmp` now\n",
		"run\n`ls  -l /tmp`\nnow\n",
		"one word, its spaces kept");
}

testJ(t: ref T)
{
	fmtis(t, "-j" :: "-l" :: "20" :: nil,
		"short\nlines kept\n- an item that is long enough to fold\n",
		"short\nlines kept\n- an item that is\n  long enough to\n  fold\n",
		"folded, not joined");
}

# What Render draws: each block's kind, numbers and text
doc(text: string): array of string
{
	d := rlayout->parsemd(text);
	r := array[len d] of string;
	for(i := 0; d != nil; d = tl d){
		n := hd d;
		t := n.text;
		if(n.kind == Rlayout->Ncodeblock || n.kind == Rlayout->Ntable)
			t = nil;	# in totext
		r[i++] = sys->sprint("%d %d %q: %s", n.kind, n.aux, t, onespace(rlayout->totext(n :: nil)));
	}
	return r;
}

# Runs of blanks as one: where md/fmt breaks a line, the next fill
# joins it with one space, whatever was typed there
onespace(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '\t')
			c = ' ';
		if(c == ' ' && len r > 0 && r[len r-1] == ' ')
			continue;
		r[len r] = c;
	}
	return r;
}

# nil if two documents are the same, else the first block that differs
differ(a, b: array of string): string
{
	for(i := 0; i < len a && i < len b; i++)
		if(a[i] != b[i])
			return sys->sprint("block %d: %q, now %q", i, a[i], b[i]);
	if(len a != len b)
		return sys->sprint("%d blocks, now %d", len a, len b);
	return nil;
}

mdfiles(dir: string): list of string
{
	files: list of string;
	(d, n) := readdir->init(dir, Readdir->NAME);
	for(i := 0; i < n; i++){
		name := d[i].name;
		if(len name > 3 && name[len name-3:] == ".md")
			files = dir + "/" + name :: files;
	}
	return files;
}

readfile(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	all := array[0] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0){
		a := array[len all + n] of byte;
		a[0:] = all;
		a[len all:] = buf[0:n];
		all = a;
	}
	return string all;
}

testTree(t: ref T)
{
	files := mdfiles("/docs");
	files = "/README.md" :: "/CLAUDE.md" :: "/QUICKSTART.md" :: files;
	nf := 0;
	for(; files != nil; files = tl files){
		in := readfile(hd files);
		if(in == nil)
			continue;
		nf++;
		want := doc(in);
		for(w := "40" :: "70" :: nil; w != nil; w = tl w){
			out := mdfmt(t, "-l" :: hd w :: nil, in);
			if((e := differ(want, doc(out))) != nil){
				t.error(sys->sprint("%s at %s: %s", hd files, hd w, e));
				break;
			}
			if(mdfmt(t, "-l" :: hd w :: nil, out) != out){
				t.error(sys->sprint("%s at %s: filled again, changed", hd files, hd w));
				break;
			}
		}
	}
	t.log(sys->sprint("%d files", nf));
	if(nf < 10)
		t.error(sys->sprint("only %d Markdown files found", nf));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	readdir = load Readdir Readdir->PATH;
	rlayout = load Rlayout Rlayout->PATH;

	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	if(rlayout == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Rlayout->PATH);
		raise "fail:cannot load rlayout";
	}
	rlayout->init(nil);

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("List", testList);
	run("Para", testPara);
	run("Verbatim", testVerbatim);
	run("NoBlockStart", testNoBlockStart);
	run("Quote", testQuote);
	run("CodeSpan", testCodeSpan);
	run("J", testJ);
	run("Tree", testTree);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
