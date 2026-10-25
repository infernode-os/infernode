implement VeltroEditTest;

#
# veltro_edit_test.b - the agent's edit tool.
#
# One change or several to one file in a call, each found in the file
# as it was before the call; a change that matches more than one place,
# or none, or that overlaps another, refused with what to do about it;
# text that differs only in what models get wrong (the read tool's line
# numbers copied in, trailing blanks, curly quotes) still found, and
# nothing but the matched text changed.  The files are in the agent's
# workspace, the one place the tool writes without a path grant.
#
# To run: emu -r. /tests/veltro_edit_test.dis [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Tool: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

VeltroEditTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/veltro_edit_test.b";
DIR: con "/tmp/veltro/scratch/edit_test";

passed := 0;
failed := 0;
skipped := 0;
edit: Tool;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	* => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

put(name, text: string): string
{
	path := DIR + "/" + name;
	fd := sys->create(path, Sys->OWRITE, 8r644);
	b := array of byte text;
	sys->write(fd, b, len b);
	return path;
}

get(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	out := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		out += string buf[0:n];
	return out;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# JSON string literal
q(s: string): string
{
	out := "\"";
	for(i := 0; i < len s; i++)
		case s[i] {
		'"' =>	out += "\\\"";
		'\\' =>	out += "\\\\";
		'\n' =>	out += "\\n";
		'\t' =>	out += "\\t";
		* =>	out[len out] = s[i];
		}
	return out + "\"";
}

SRC: con "implement Foo;\n\ninit()\n{\n\tx := 1;\n\ty := 2;\n\tz := 3;\n}\n";

testOneRaw(t: ref T)
{
	p := put("one.b", SRC);
	r := edit->exec("-r " + p + " \"x := 1;\" \"x := 10;\"");
	t.assert(hasprefix(r, "replaced 1 occurrence"), "result: " + r);
	t.assert(contains(get(p), "\tx := 10;\n"), "changed");
}

testSeveral(t: ref T)
{
	p := put("several.b", SRC);
	js := "{\"path\":" + q(p) + ",\"edits\":[" +
		"{\"old\":" + q("\tz := 3;") + ",\"new\":" + q("\tz := 30;") + "}," +
		"{\"old\":" + q("\tx := 1;") + ",\"new\":" + q("\tx := 10;\n\tw := 0;") + "}]}";
	r := edit->exec("-j " + p + " " + js);
	t.assert(hasprefix(r, "replaced 2 occurrence"), "result: " + r);
	t.assertseq(get(p), "implement Foo;\n\ninit()\n{\n\tx := 10;\n\tw := 0;\n\ty := 2;\n\tz := 30;\n}\n", "both made, against the original");
}

testEditsAsString(t: ref T)
{
	p := put("asstring.b", SRC);
	inner := "[{\"old\":" + q("y := 2;") + ",\"new\":" + q("y := 20;") + "}]";
	js := "{\"path\":" + q(p) + ",\"edits\":" + q(inner) + "}";
	r := edit->exec("-j " + p + " " + js);
	t.assert(hasprefix(r, "replaced 1 occurrence"), "a list sent as a string: " + r);
}

testOverlap(t: ref T)
{
	p := put("overlap.b", SRC);
	js := "{\"path\":" + q(p) + ",\"edits\":[" +
		"{\"old\":" + q("x := 1;\n\ty") + ",\"new\":\"A\"}," +
		"{\"old\":" + q("y := 2;") + ",\"new\":\"B\"}]}";
	r := edit->exec("-j " + p + " " + js);
	t.assert(hasprefix(r, "error: edits[0] and edits[1] overlap"), "overlap refused: " + r);
	t.assertseq(get(p), SRC, "nothing written");
}

testAmbiguous(t: ref T)
{
	p := put("ambig.b", SRC);
	r := edit->exec("-r " + p + " \":= \" \"= \"");
	t.assert(hasprefix(r, "error:") && contains(r, "found 3 times") && contains(r, "more of the text"), "ambiguous: " + r);
	r = edit->exec("-r " + p + " \":= \" \"= \" all");
	t.assert(hasprefix(r, "replaced 3 occurrence"), "all: " + r);
}

testNotFoundHint(t: ref T)
{
	p := put("hint.b", SRC);
	r := edit->exec("-r " + p + " \"\ty := 2;\n\tz := 4;\" \"\"");
	t.assert(hasprefix(r, "error:") && contains(r, "not found"), "not found: " + r);
	t.assert(contains(r, "line 6"), "where its first line is: " + r);
}

# The read tool's line numbers, copied into old (and new).
testLineNumbers(t: ref T)
{
	p := put("numbers.b", SRC);
	js := "{\"path\":" + q(p) + ",\"edits\":[{\"old\":" + q("    5\t\tx := 1;\n    6\t\ty := 2;") +
		",\"new\":" + q("    5\t\tx := 1;\n    6\t\ty := 22;") + "}]}";
	r := edit->exec("-j " + p + " " + js);
	t.assert(hasprefix(r, "replaced 1 occurrence") && contains(r, "line numbers"), "numbers taken off: " + r);
	t.assertseq(get(p), "implement Foo;\n\ninit()\n{\n\tx := 1;\n\ty := 22;\n\tz := 3;\n}\n", "only the text changed");
}

# Trailing blanks and curly quotes in the file, not in old: found, and
# the lines around it left as they were.
testLoose(t: ref T)
{
	p := put("loose.txt", "keep   \nsay “hello”   \nkeep too  \n");
	r := edit->exec("-r " + p + " \"say \\\"hello\\\"\" \"say goodbye\"");
	t.assert(hasprefix(r, "replaced 1 occurrence") && contains(r, "curly quotes"), "loose: " + r);
	t.assertseq(get(p), "keep   \nsay goodbye   \nkeep too  \n", "the rest as it was");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	edit = load Tool "/dis/veltro/tools/edit.dis";
	if(edit == nil) {
		sys->fprint(sys->fildes(2), "cannot load edit: %r\n");
		raise "fail:cannot load edit";
	}
	if((e := edit->init()) != nil) {
		sys->fprint(sys->fildes(2), "edit init: %s\n", e);
		raise "fail:edit init";
	}
	sys->create("/tmp/veltro", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/tmp/veltro/scratch", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR | 8r755);

	run("OneRaw", testOneRaw);
	run("Several", testSeveral);
	run("EditsAsString", testEditsAsString);
	run("Overlap", testOverlap);
	run("Ambiguous", testAmbiguous);
	run("NotFoundHint", testNotFoundHint);
	run("LineNumbers", testLineNumbers);
	run("Loose", testLoose);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
