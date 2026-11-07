implement EditorTest;

#
# editor_test - Tests for the wm/editor text editing logic
#
# Tests document operations through the editor's 9P files, posted as
# #seditor/fs (post9p(2)) and mounted here: text manipulation,
# find/replace, cursor movement.  A command is done when its write
# returns, so nothing waits.
#
# NOTE: These tests require the editor to be running; with none
# posted they skip.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

EditorTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/editor_test.b";

passed := 0;
failed := 0;
skipped := 0;

EDIT_DIR:  con "/tmp/editor_test";
EDIT_INST: con "/tmp/editor_test/1";
posted := 0;	# #seditor/fs mounted at EDIT_DIR

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

# --- IPC helpers ---

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	n := sys->write(fd, b, len b);
	fd = nil;
	return n;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	result := "";
	buf := array[65536] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		result += string buf[0:n];
	}
	fd = nil;
	return result;
}

# Send a ctl command: done when the write returns
sendctl(path, cmd: string)
{
	writefile(path, cmd);
}

# Send doc ctl command
docctl(cmd: string)
{
	sendctl(EDIT_INST + "/ctl", cmd);
}

# Send global ctl command
gctl(cmd: string)
{
	sendctl(EDIT_DIR + "/ctl", cmd);
}

# Set body: a write of body replaces the text
setbody(text: string)
{
	writefile(EDIT_INST + "/body", text);
}

# Read body
getbody(): string
{
	return readfile(EDIT_INST + "/body");
}

# Read cursor address
getaddr(): string
{
	s := readfile(EDIT_INST + "/addr");
	# Strip trailing whitespace
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return s;
}

# Check if editor is running
editorRunning(): int
{
	return posted;
}

# the editor's posted server, mounted at EDIT_DIR in this name space
mounteditor(): int
{
	sys->pctl(Sys->FORKNS, nil);
	fd := sys->open("#seditor/fs", Sys->ORDWR);
	if(fd == nil)
		return 0;
	sys->create(EDIT_DIR, Sys->OREAD, Sys->DMDIR|8r755);
	return sys->mount(fd, nil, EDIT_DIR, Sys->MREPL, nil) >= 0;
}

# ----------------------------------------------------------------
# Tests
# ----------------------------------------------------------------

# Test that the editor IPC files exist
testEditorRunning(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	t.assert(1, "editor IPC files exist");
}

# Test setting and reading body text
testSetBody(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("hello world");
	body := getbody();
	t.assertseq(body, "hello world", "body should match after set");
}

# Test multiline body
testMultilineBody(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("line one\nline two\nline three");
	body := getbody();
	t.assertseq(body, "line one\nline two\nline three", "multiline body should match");
}

# Test empty body
testEmptyBody(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("");
	body := getbody();
	# Empty body produces single empty line
	t.assert(body == "" || body == "\n", "empty body should be empty or single newline");
}

# Test goto command moves cursor
testGoto(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("aaa\nbbb\nccc\nddd\neee");
	docctl("goto 3");
	addr := getaddr();
	t.assertseq(addr, "3 1", "cursor should be at line 3 col 1");
}

# Test goto line 1
testGotoFirst(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("first\nsecond\nthird");
	docctl("goto 1");
	addr := getaddr();
	t.assertseq(addr, "1 1", "cursor should be at line 1 col 1");
}

# Test goto beyond last line clamps
testGotoBeyondEnd(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("only\ntwo");
	docctl("goto 99");
	addr := getaddr();
	t.assertseq(addr, "2 1", "cursor should clamp to last line");
}

# Test find command
testFind(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("the quick brown fox");
	docctl("goto 1");
	docctl("find brown");
	addr := getaddr();
	# Find should place cursor at the match position
	# "brown" starts at col 11 (1-indexed)
	t.assertseq(addr, "1 11", "cursor should be at 'brown' position");
}

# Test find on multiline
testFindMultiline(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("aaa\nbbb\nccc target ddd\neee");
	docctl("goto 1");
	docctl("find target");
	addr := getaddr();
	t.assertseq(addr, "3 5", "find should locate 'target' on line 3");
}

# Test insert command
testInsert(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("hello world");
	# columns count from 1: column 7 is the w
	docctl("insert 1 7 beautiful ");
	body := getbody();
	t.assertseq(body, "hello beautiful world", "insert should add text at position");
}

# Test delete command
testDelete(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("hello beautiful world");
	# Delete "beautiful " (cols 6-15 on line 1)
	docctl("delete 1 6 1 16");
	body := getbody();
	t.assertseq(body, "hello world", "delete should remove text range");
}

# Test name command
testName(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	docctl("name /tmp/test_editor_file.txt");
	# Read index to verify
	idx := readfile(EDIT_DIR + "/index");
	t.assert(idx != nil && len idx > 0, "index should contain doc info");
	# Check that filename appears in index
	found := 0;
	for(i := 0; i < len idx - 20; i++) {
		if(idx[i:i+20] == "test_editor_file.txt") {
			found = 1;
			break;
		}
	}
	t.assert(found, "index should contain new filename");
}

# Test clean/dirty commands
testCleanDirty(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("some text");
	# After setbody, doc should be dirty
	idx := readfile(EDIT_DIR + "/index");
	t.assert(idx != nil, "index should be readable");

	docctl("clean");
	idx = readfile(EDIT_DIR + "/index");
	# Last field should be 0 (not dirty)
	t.assert(idx != nil, "index after clean should be readable");

	docctl("dirty");
	idx = readfile(EDIT_DIR + "/index");
	t.assert(idx != nil, "index after dirty should be readable");
}

# Test replace command (single occurrence)
testReplace(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("the cat sat on the mat");
	docctl("goto 1");
	docctl("replace cat\tdog");
	body := getbody();
	t.assertseq(body, "the dog sat on the mat", "replace should substitute first match");
}

# Test replaceall command
testReplaceAll(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("foo bar foo baz foo");
	docctl("replaceall foo\tqux");
	body := getbody();
	t.assertseq(body, "qux bar qux baz qux", "replaceall should substitute all matches");
}

# Test new (global ctl)
testNew(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("this should be cleared");
	gctl("new");
	body := getbody();
	t.assert(body == "" || body == "\n", "new should clear document body");
}

# Test sequence: set body, goto, find
testSequence(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("alpha\nbeta\ngamma\ndelta\nepsilon");
	docctl("goto 1");
	docctl("find delta");
	addr := getaddr();
	t.assertseq(addr, "4 1", "find 'delta' should land on line 4");
}

# Test insert at end of line
testInsertAtEnd(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("hello");
	docctl("insert 1 6 !");
	body := getbody();
	t.assertseq(body, "hello!", "insert at end should append to line");
}

# Test delete across lines
testDeleteAcrossLines(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("aaa\nbbb\nccc");
	# Delete from line 1 col 2 to line 3 col 2 (everything in middle)
	docctl("delete 1 2 3 2");
	body := getbody();
	t.assertseq(body, "acc", "cross-line delete should merge remaining text");
}

# Test replace with empty string (deletion)
testReplaceEmpty(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("hello world");
	docctl("goto 1");
	docctl("replace world\t");
	body := getbody();
	t.assertseq(body, "hello ", "replace with empty should delete the match");
}

# Test replace when not found (body unchanged)
testReplaceNotFound(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	setbody("hello world");
	docctl("goto 1");
	docctl("replace xyz\tabc");
	body := getbody();
	t.assertseq(body, "hello world", "replace with no match should leave body unchanged");
}

# A text longer than one 9P message arrives in pieces: the body is all
# of it, and reads back whole
testLongBody(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	line := "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz\n";
	text := "";
	for(i := 0; i < 400; i++)
		text += line;	# 29600 bytes, several messages
	setbody(text);
	body := getbody();
	t.asserteq(len body, len text, "a long body is all of it");
	t.assert(body == text, "and reads back as written");
}

# Each open of event gets every event: two readers both see an edit
# (they took turns from one channel, and a read held the server)
testEventPerOpen(t: ref T)
{
	if(!editorRunning())
		t.skip("editor not running");
	got := chan of string;
	for(i := 0; i < 2; i++) {
		fd := sys->open(EDIT_INST + "/event", Sys->OREAD);
		if(fd == nil)
			t.fatal(sys->sprint("open event: %r"));
		spawn evreader(fd, got);
	}
	sys->sleep(100);	# both readers waiting
	setbody("x");
	docctl("insert 1 1 y");
	timeout := chan of int;
	spawn timer(timeout, 3000);
	n := 0;
	while(n < 2)
		alt {
		e := <-got =>
			t.assertnotnil(e, "an event line");
			n++;
		<-timeout =>
			t.fatal(sys->sprint("%d of 2 readers got an event", n));
		}
	t.asserteq(n, 2, "both readers got the event");
}

evreader(fd: ref Sys->FD, got: chan of string)
{
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n > 0)
		got <-= string buf[0:n];
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	posted = mounteditor();

	# Run tests
	run("EditorRunning", testEditorRunning);
	run("SetBody", testSetBody);
	run("MultilineBody", testMultilineBody);
	run("EmptyBody", testEmptyBody);
	run("Goto", testGoto);
	run("GotoFirst", testGotoFirst);
	run("GotoBeyondEnd", testGotoBeyondEnd);
	run("Find", testFind);
	run("FindMultiline", testFindMultiline);
	run("Insert", testInsert);
	run("Delete", testDelete);
	run("Name", testName);
	run("CleanDirty", testCleanDirty);
	run("Replace", testReplace);
	run("ReplaceAll", testReplaceAll);
	run("New", testNew);
	run("Sequence", testSequence);
	run("InsertAtEnd", testInsertAtEnd);
	run("DeleteAcrossLines", testDeleteAcrossLines);
	run("ReplaceEmpty", testReplaceEmpty);
	run("ReplaceNotFound", testReplaceNotFound);
	run("LongBody", testLongBody);
	run("EventPerOpen", testEventPerOpen);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
