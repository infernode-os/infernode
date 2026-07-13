implement LuciuisrvTest;

#
# Regression tests for luciuisrv — the Lucifer UI 9P server.
#
# Tests all critical ctl commands and behaviors that have caused regressions:
#   - Activity creation and directory structure
#   - Conversation message write + readback
#   - Conversation message in-place update (streaming fix)
#   - Event delivery for conversation, presentation, context
#   - Presentation artifact create/update/append/center
#   - Context resource/gap/background task management
#   - Activity label + status read/write
#   - "conversation update N" event (used by lucibridge for streaming tokens)
#
# luciuisrv is loaded as a module and mounted at TESTMNT.
# No external processes required — the server runs in background goroutines.
#
# To run standalone:
#   ./emu/MacOSX/o.emu -r. /dis/tests/luciuisrv_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

# luciuisrv is loaded as a standard Inferno command module
LuciuiSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

LuciuisrvTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with LuciuiSrv
};

SRCFILE:	con "/tests/luciuisrv_test.b";
TESTMNT:	con "/tmp/luciuisrv_test";
SRVPATH:	con "/dis/luciuisrv.dis";

# Number of simulated app subscribers for the fan-out test. In the real
# desktop, settings / matrix / editor / shell / keyring / wallet / about /
# fractals / ftree each hold an open fd on /mnt/ui/event; one theme switch
# must reach all of them. NSUBS picks a representative handful.
NSUBS:		con 5;

passed := 0;
failed := 0;
skipped := 0;

# Activity created in testSetup; used by all subsequent tests.
actid := -1;

# Required by LuciuisrvTest module declaration to prevent joiniface() type conflation.
_marker() {}

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

# ============================================================================
# Helpers
# ============================================================================

actbase(): string
{
	return TESTMNT + "/activity/" + string actid;
}

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	n := sys->write(fd, b, len b);
	return n;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return string buf[0:n];
}

hassubstr(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++) {
		if(s[i:i+len sub] == sub)
			return 1;
	}
	return 0;
}

# Read one event from path (blocking); send on ch.
# Sends "error:..." if open/read fails.
eventreader(path: string, ch: chan of string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		ch <-= "error:open:" + path;
		return;
	}
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0) {
		ch <-= "error:read:" + path;
		return;
	}
	ch <-= string buf[0:n];
}

# Send 1 on ch after ms milliseconds.
timerwait(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

# Drain all buffered events on path until none arrive within 100ms.
# Call at the start of event-sensitive tests to clear stale events
# accumulated by prior tests that don't drain their own events.
drainall(path: string)
{
	for(;;) {
		ch := chan[1] of string;
		spawn eventreader(path, ch);
		toch := chan[1] of int;
		spawn timerwait(toch, 100);
		stop := 0;
		alt {
		<-ch =>
			;
		<-toch =>
			stop = 1;
		}
		if(stop)
			break;
	}
}

# Wait for an event on path, with a 3-second timeout.
# Returns the event string or "error:..." / "error:timeout".
readevent(path: string): string
{
	evch := chan[1] of string;
	spawn eventreader(path, evch);

	toch := chan[1] of int;
	spawn timerwait(toch, 3000);

	ev := "";
	alt {
	ev = <-evch =>
		;
	<-toch =>
		ev = "error:timeout";
	}
	return ev;
}

# Server startup goroutine
startserver(done: chan of int, mountpt: string)
{
	srv := load LuciuiSrv SRVPATH;
	if(srv == nil) {
		done <-= 0;
		return;
	}
	{
		srv->init(nil, "luciuisrv" :: "-m" :: mountpt :: nil);
		done <-= 1;
	} exception {
	* =>
		done <-= 0;
	}
}

# Read every entry from directory `path` in a goroutine; report the result
# on ch as "ok:<space-prefixed names>" or "error:...". Letting the caller
# bound this with a timeout means an INFR-127-style readdir hang surfaces as
# a clean test failure instead of wedging the whole runner.
dirreader(path: string, ch: chan of string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		ch <-= "error:open:" + path;
		return;
	}
	names := "";
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n < 0) {
			ch <-= "error:dirread:" + path;
			return;
		}
		if(n == 0)
			break;
		for(i := 0; i < n; i++)
			names += " " + dirs[i].name;
	}
	ch <-= "ok:" + names;
}

# List directory `path` with a 3-second timeout. Returns dirreader's result,
# or "error:timeout" if the readdir never completes.
readdirto(path: string): string
{
	ch := chan[1] of string;
	spawn dirreader(path, ch);
	toch := chan[1] of int;
	spawn timerwait(toch, 3000);
	res := "";
	alt {
	res = <-ch =>
		;
	<-toch =>
		res = "error:timeout";
	}
	return res;
}

# ============================================================================
# Test 1: testSetup
#
# Load and start luciuisrv at TESTMNT, create the test activity.
# Sets the global actid used by all subsequent tests.
# ============================================================================

testSetup(t: ref T)
{
	# Start luciuisrv in background; it mounts at TESTMNT and returns.
	done := chan[1] of int;
	spawn startserver(done, TESTMNT);

	toch := chan[1] of int;
	spawn timerwait(toch, 5000);

	ok := 0;
	alt {
	ok = <-done =>
		;
	<-toch =>
		t.fatal("luciuisrv did not start within 5 seconds");
	}

	if(ok == 0) {
		t.fatal("luciuisrv failed to load or mount (is " + SRVPATH + " present?)");
		return;
	}

	# Verify mount succeeded
	(st, nil) := sys->stat(TESTMNT + "/ctl");
	t.assert(st >= 0, "TESTMNT/ctl should exist after mount");
	(st2, nil) := sys->stat(TESTMNT + "/event");
	t.assert(st2 >= 0, "TESTMNT/event should exist after mount");
	(st3, nil) := sys->stat(TESTMNT + "/activity");
	t.assert(st3 >= 0, "TESTMNT/activity/ should exist after mount");

	# Create test activity
	n := writefile(TESTMNT + "/ctl", "activity create LuciuisrvTest");
	t.assert(n > 0, "activity create should write successfully");

	# Read current activity ID from activity/current (synchronous, no event race).
	# The global /event file is not buffered — events are dropped if no reader
	# is waiting when they fire, so we cannot rely on it here.
	idraw := readfile(TESTMNT + "/activity/current");
	t.assertnotnil(idraw, "activity/current should be readable after create");
	id := strtoint(strip(idraw));
	t.assert(id >= 0, "activity ID should be non-negative");
	actid = id;
	t.log(sys->sprint("test activity ID: %d", actid));

	# Verify activity directory exists
	(st4, nil) := sys->stat(actbase());
	t.assert(st4 >= 0, "activity directory should exist");
	(st5, nil) := sys->stat(actbase() + "/conversation/ctl");
	t.assert(st5 >= 0, "conversation/ctl should exist");
	(st6, nil) := sys->stat(actbase() + "/presentation/ctl");
	t.assert(st6 >= 0, "presentation/ctl should exist");
	(st7, nil) := sys->stat(actbase() + "/context/ctl");
	t.assert(st7 >= 0, "context/ctl should exist");
}

# ============================================================================
# Test 1b: testRootDirread (INFR-127)
#
# `ls /mnt/ui` — a readdir on the synthetic root — must enumerate the root's
# children and terminate. Regression (INFR-127): the root and per-activity
# conversation directory listings hung forever, even though targeted file
# reads and named walks worked. Each listing is timeout-bounded so a
# recurrence fails the test instead of wedging the runner.
# ============================================================================

testRootDirread(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity (testSetup failed)");
		return;
	}

	# ls /mnt/ui
	root := readdirto(TESTMNT);
	t.assertsne(root, "error:timeout", "root readdir must terminate (INFR-127)");
	t.assert(hassubstr(root, " ctl"), "root listing includes ctl");
	t.assert(hassubstr(root, " event"), "root listing includes event");
	t.assert(hassubstr(root, " activity"), "root listing includes activity");
	t.assert(hassubstr(root, " catalog"), "root listing includes catalog");

	# ls /mnt/ui/activity/<id>/conversation/  (also reported hanging)
	conv := readdirto(actbase() + "/conversation");
	t.assertsne(conv, "error:timeout", "conversation readdir must terminate (INFR-127)");
	t.assert(hassubstr(conv, " ctl"), "conversation listing includes ctl");
	t.assert(hassubstr(conv, " input"), "conversation listing includes input");
	t.assert(hassubstr(conv, " voiceinput"), "conversation listing includes voiceinput");
	t.assert(hassubstr(conv, " control"), "conversation listing includes control: " + conv);
	t.assert(hassubstr(conv, " draft"), "conversation listing includes draft");
}

# ============================================================================
# Test 2: testConvMessageWrite
#
# Write a conversation message to conv/ctl and read it back from conv/0.
# Regression: broken QID encoding caused wrong file to be accessed.
# ============================================================================

testConvMessageWrite(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity (testSetup failed)");
		return;
	}

	convctl := actbase() + "/conversation/ctl";
	n := writefile(convctl, "role=human text=Hello from regression test");
	t.assert(n > 0, "write to conversation/ctl should succeed");

	# Read back from conversation/0
	msg := readfile(actbase() + "/conversation/0");
	t.assert(msg != nil, "conversation/0 should exist after message write");
	t.log("conv/0: " + msg);
	t.assert(hassubstr(msg, "role=human"), "message should have role=human");
	t.assert(hassubstr(msg, "Hello from regression test"),
		"message should contain the written text");
}

# ============================================================================
# Test 3: testConvMessageUpdate
#
# Write a message, then update it in-place with "update idx=0 text=..."
# Regression: streaming token delivery (lucibridge live updates) requires
# this path to work; broken = static placeholder cursor stuck on screen.
# ============================================================================

testConvMessageUpdate(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	convctl := actbase() + "/conversation/ctl";

	# Write a placeholder (streaming start)
	writefile(convctl, "role=veltro text=▌");

	# Find the index of the message we just wrote
	# It might be 0 if this is the first, or higher if previous tests wrote messages
	# Read the most recent message by checking how many exist
	msgidx := 0;
	for(i := 0; i < 20; i++) {
		(ok, nil) := sys->stat(actbase() + "/conversation/" + string i);
		if(ok < 0)
			break;
		msgidx = i;
	}
	t.log(sys->sprint("veltro placeholder at idx %d", msgidx));

	# Update in-place (simulates streaming token delivery)
	updatecmd := sys->sprint("update idx=%d text=Updated streaming content", msgidx);
	n := writefile(convctl, updatecmd);
	t.assert(n > 0, "update write to conversation/ctl should succeed");

	# Read back and verify updated content
	updated := readfile(actbase() + "/conversation/" + string msgidx);
	t.assert(updated != nil, "updated message file should exist");
	t.log("after update: " + updated);
	t.assert(hassubstr(updated, "Updated streaming content"),
		"message should contain updated text");
	t.assert(!hassubstr(updated, "▌"),
		"cursor placeholder should be replaced by update");
}

# ============================================================================
# Test 3b: testConvTextEmbeddedEquals
#
# Write a message whose text contains embedded "word=value" patterns and
# verify the full text is stored and returned.
#
# Regression: parseattrs() scanned the entire string for key= patterns.
# LLM responses often contain patterns like "access=read", "type=markdown",
# "path=/foo", "x=5 y=3" in explanations, causing text= to be truncated
# at the first such pattern found after the text= attribute.
# Fix: text= and data= are treated as terminal attributes (always extend to
# end-of-string) so embedded = signs never truncate the value.
# ============================================================================

testConvTextEmbeddedEquals(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	convctl := actbase() + "/conversation/ctl";

	# Text with embedded key=value patterns (common in LLM explanations).
	# Without the fix, parsing would stop at "access=" or "type=" etc.
	text := "Each subagent uses access=read for readonly ops, type=text for plain output. " +
		"The path=/n/tools mount provides namespace=isolated sandboxing. " +
		"Settings like max_tokens=4096 and temperature=0.7 control generation.";

	n := writefile(convctl, "role=veltro text=" + text);
	t.assert(n > 0, "write message with embedded = should succeed");

	# Find the index (last written message)
	msgidx := 0;
	for(i := 0; i < 50; i++) {
		(ok, nil) := sys->stat(actbase() + "/conversation/" + string i);
		if(ok < 0)
			break;
		msgidx = i;
	}

	# Read back — must contain the complete text, not just the part before "access="
	raw := readfile(actbase() + "/conversation/" + string msgidx);
	t.assert(raw != nil, "message should be readable");

	t.assert(hassubstr(raw, "access=read"),
		"message should contain 'access=read' without truncation");
	t.assert(hassubstr(raw, "type=text"),
		"message should contain 'type=text' without truncation");
	t.assert(hassubstr(raw, "namespace=isolated"),
		"message should contain 'namespace=isolated' without truncation");
	t.assert(hassubstr(raw, "max_tokens=4096"),
		"message should contain 'max_tokens=4096' without truncation");
	t.assert(hassubstr(raw, "temperature=0.7"),
		"message should contain 'temperature=0.7' — last embedded = pattern");
}

# ============================================================================
# Test 4: testConvEventDelivery
#
# Write a message and verify the activity event fires.
# Regression: broken event buffering (pendingevent) caused lucifer to miss
# updates when the nslistener was between reads.
# ============================================================================

testConvEventDelivery(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	# Write a message — this should trigger "conversation <idx>" event
	writefile(actbase() + "/conversation/ctl", "role=human text=event-test-message");

	# Read from per-activity event file
	ev := readevent(actbase() + "/event");
	t.log("conversation event: " + ev);
	t.assert(!hassubstr(ev, "error:"), "event read should not return error: " + ev);
	t.assert(hassubstr(ev, "conversation"),
		"event should contain 'conversation' after message write");
}

# ============================================================================
# Test 5: testConvUpdateEvent
#
# Update a message and verify "conversation update <idx>" event fires.
# Regression: the "update" command path needed its own event emission;
# without it lucifer's nslistener never received the streaming event.
# ============================================================================

testConvUpdateEvent(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	convctl := actbase() + "/conversation/ctl";
	evpath := actbase() + "/event";

	# Flush all stale events from previous tests: writing to the event file
	# discards the pending-event queue and kicks any waiting readers.
	writefile(evpath, "flush");

	# Write a message to update
	writefile(convctl, "role=veltro text=initial");

	# Drain the "conversation N" event from writing
	readevent(evpath);

	# Find the index of this message
	msgidx := 0;
	for(i := 0; i < 50; i++) {
		(ok, nil) := sys->stat(actbase() + "/conversation/" + string i);
		if(ok < 0)
			break;
		msgidx = i;
	}

	# Now update — should fire "conversation update <idx>" event
	writefile(convctl, sys->sprint("update idx=%d text=updated-for-event-test", msgidx));

	ev := readevent(evpath);
	t.log("update event: " + ev);
	t.assert(!hassubstr(ev, "error:"), "event should not be an error: " + ev);
	t.assert(hassubstr(ev, "conversation update"),
		"event should say 'conversation update'");
	t.assert(hassubstr(ev, string msgidx),
		sys->sprint("event should reference idx %d", msgidx));
}

# ============================================================================
# Test 6: testPresentationCreate
#
# Create an artifact and verify its directory structure.
# Regression: broken QID sub-id encoding caused wrong artifact to be returned.
# ============================================================================

testPresentationCreate(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	presctl := actbase() + "/presentation/ctl";

	n := writefile(presctl, "create id=regtest-art type=markdown label=RegressionArtifact");
	t.assert(n > 0, "create artifact should succeed");

	# Verify artifact subdirectory structure
	artbase := actbase() + "/presentation/regtest-art";
	(ok1, nil) := sys->stat(artbase + "/type");
	t.assert(ok1 >= 0, "artifact/type should exist");
	(ok2, nil) := sys->stat(artbase + "/label");
	t.assert(ok2 >= 0, "artifact/label should exist");
	(ok3, nil) := sys->stat(artbase + "/data");
	t.assert(ok3 >= 0, "artifact/data should exist");

	# Verify type and label are readable and correct
	atype := strip(readfile(artbase + "/type"));
	t.assertseq(atype, "markdown", "artifact type should be 'markdown'");
	alabel := strip(readfile(artbase + "/label"));
	t.assertseq(alabel, "RegressionArtifact", "artifact label should match");
}

# ============================================================================
# Test 7: testPresentationDataWrite
#
# Write data to an artifact's data file and read it back.
# Regression: data writes going to wrong artifact (sub-id ordering bug).
# ============================================================================

testPresentationDataWrite(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	# Ensure artifact exists (depends on testPresentationCreate)
	presctl := actbase() + "/presentation/ctl";
	writefile(presctl, "create id=datatest-art type=text label=DataTest");

	artdata := actbase() + "/presentation/datatest-art/data";
	content := "# Test Content\n\nThis is regression test data for the presentation zone.";

	n := writefile(artdata, content);
	t.assert(n > 0, "write to artifact data should succeed");

	# Read back and verify
	readback := readfile(artdata);
	t.assert(readback != nil, "artifact data should be readable after write");
	t.assertseq(readback, content, "artifact data should match written content");
}

# ============================================================================
# Test 8: testPresentationUpdate
#
# Update an artifact via presentation/ctl "update id=... data=..." command.
# Regression: update command parsed wrong field (label vs data mismatch).
# ============================================================================

testPresentationUpdate(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	presctl := actbase() + "/presentation/ctl";
	writefile(presctl, "create id=updatetest type=text label=UpdateTest");

	# Update the artifact data via ctl
	n := writefile(presctl, "update id=updatetest data=new-content-via-update");
	t.assert(n > 0, "update artifact via ctl should succeed");

	# Verify data changed
	data := readfile(actbase() + "/presentation/updatetest/data");
	t.assert(data != nil, "artifact data should be readable");
	t.assert(hassubstr(data, "new-content-via-update"),
		"artifact data should contain updated content");
}

# ============================================================================
# Test 8b: testPresentationDataEmbeddedControls
#
# Presentation data is model-controlled content. Strings that look like
# presentation control attributes must stay inside data= and must not mutate
# type/dispath/app launch state.
# ============================================================================

testPresentationDataEmbeddedControls(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	presctl := actbase() + "/presentation/ctl";
	writefile(presctl, "create id=controltext type=text label=ControlText");

	payload := "This is inert text: type=app dis=/dis/wm/shell.dis label=Owned data=-c secrets";
	n := writefile(presctl, "update id=controltext data=" + payload);
	t.assert(n > 0, "update with embedded control-looking data should succeed");

	artbase := actbase() + "/presentation/controltext";
	data := readfile(artbase + "/data");
	t.assertseq(data, payload, "embedded control-looking data should remain intact");

	atype := strip(readfile(artbase + "/type"));
	t.assertseq(atype, "text", "embedded type=app should not change artifact type");

	dispath := readfile(artbase + "/dispath");
	t.assert(dispath == nil || strip(dispath) == "",
		"embedded dis=/... should not create an app dispath");
}

# ============================================================================
# Test 9: testPresentationAppend
#
# Append data to an artifact using "append id=... data=..." command.
# Regression: append command was added for streaming artifacts; if missing,
# progressive artifact generation doesn't work in the presentation zone.
# ============================================================================

testPresentationAppend(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	presctl := actbase() + "/presentation/ctl";
	writefile(presctl, "create id=appendtest type=markdown label=AppendTest");

	# Write initial content
	artdata := actbase() + "/presentation/appendtest/data";
	writefile(artdata, "Initial content.");

	# Append via ctl
	writefile(presctl, "append id=appendtest data= More appended content.");

	# Read and verify data grew
	data := readfile(artdata);
	t.assert(data != nil, "artifact data should be readable after append");
	t.log("after append: " + data);
	t.assert(hassubstr(data, "Initial content."),
		"original content should be preserved");
	t.assert(hassubstr(data, "More appended content."),
		"appended content should be present");
}

# ============================================================================
# Test 10: testPresentationCenter
#
# Center an artifact and verify the presentation/current file updates.
# Regression: center command was added for tab click support; broken = tabs
# don't switch when clicked in the Lucifer UI.
# ============================================================================

testPresentationCenter(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	presctl := actbase() + "/presentation/ctl";
	writefile(presctl, "create id=center-a type=text label=CenterA");
	writefile(presctl, "create id=center-b type=text label=CenterB");

	# Center artifact A
	n := writefile(presctl, "center id=center-a");
	t.assert(n > 0, "center command should succeed");

	current := strip(readfile(actbase() + "/presentation/current"));
	t.assert(current != nil, "presentation/current should be readable");
	t.assertseq(current, "center-a", "presentation/current should be 'center-a'");

	# Switch to artifact B
	writefile(presctl, "center id=center-b");
	current = strip(readfile(actbase() + "/presentation/current"));
	t.assertseq(current, "center-b", "presentation/current should switch to 'center-b'");
}

# ============================================================================
# Test 11: testPresentationEvent
#
# Create an artifact and verify "presentation new <id>" event fires.
# Regression: missing event emission caused lucifer to not load new artifacts.
# ============================================================================

testPresentationEvent(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	evpath := actbase() + "/event";

	# Flush all stale events from previous tests (write to event file).
	writefile(evpath, "flush");

	# Now trigger a known event
	writefile(actbase() + "/presentation/ctl",
		"create id=event-art type=text label=EventArt");

	ev := readevent(evpath);
	t.log("presentation event: " + ev);
	t.assert(!hassubstr(ev, "error:"), "should not get error: " + ev);
	t.assert(hassubstr(ev, "presentation"),
		"event should mention 'presentation' after artifact create");
}

# ============================================================================
# Test 12: testContextResourceAdd
#
# Add a resource to the context zone and read it back.
# Regression: context ctl parser broke resource tracking used in context zone.
# ============================================================================

testContextResourceAdd(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	ctxctl := actbase() + "/context/ctl";
	n := writefile(ctxctl,
		"resource add path=/api/test label=TestAPI type=api status=streaming");
	t.assert(n > 0, "resource add should succeed");

	# Read back from resources/0
	res := readfile(actbase() + "/context/resources/0");
	t.assert(res != nil, "context/resources/0 should exist after resource add");
	t.log("resource/0: " + res);
	t.assert(hassubstr(res, "path=/api/test"),
		"resource should contain path=/api/test");
	t.assert(hassubstr(res, "status=streaming"),
		"resource should contain status=streaming");
}

# ============================================================================
# Test 13: testContextGapAdd
#
# Add a knowledge gap and read it back.
# ============================================================================

testContextGapAdd(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	ctxctl := actbase() + "/context/ctl";
	n := writefile(ctxctl, "gap add desc=missing_weather_data relevance=high");
	t.assert(n > 0, "gap add should succeed");

	# Read back from gaps/0
	gap := readfile(actbase() + "/context/gaps/0");
	t.assert(gap != nil, "context/gaps/0 should exist after gap add");
	t.log("gaps/0: " + gap);
	t.assert(hassubstr(gap, "missing_weather_data"),
		"gap should contain the description");
	t.assert(hassubstr(gap, "high"),
		"gap should contain relevance=high");
}

# ============================================================================
# Test 14: testContextBgTaskAdd
#
# Add a background task and read it back.
# ============================================================================

testContextBgTaskAdd(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	ctxctl := actbase() + "/context/ctl";
	n := writefile(ctxctl, "bg add label=web-search status=live");
	t.assert(n > 0, "bg add should succeed");

	# Read back from background/0
	bg := readfile(actbase() + "/context/background/0");
	t.assert(bg != nil, "context/background/0 should exist after bg add");
	t.log("background/0: " + bg);
	t.assert(hassubstr(bg, "web-search"),
		"background task should contain label");
	t.assert(hassubstr(bg, "live"),
		"background task should contain status=live");
}

# ============================================================================
# Test 15: testActivityLabel
#
# Read and write the activity label file.
# ============================================================================

testActivityLabel(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	labelfile := actbase() + "/label";

	# Read initial label (set at creation time)
	initial := readfile(labelfile);
	t.assert(initial != nil, "label file should be readable");
	t.log("initial label: " + initial);

	# Write new label
	n := writefile(labelfile, "UpdatedLabel");
	t.assert(n > 0, "write to label should succeed");

	# Read back and verify
	updated := strip(readfile(labelfile));
	t.assert(updated != nil, "updated label should be readable");
	t.assertseq(updated, "UpdatedLabel", "label should match written value");
}

# ============================================================================
# Test 16: testActivityStatus
#
# Read and write the activity status file.
# ============================================================================

testActivityStatus(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	statusfile := actbase() + "/status";

	# Read initial status
	initial := readfile(statusfile);
	t.assert(initial != nil, "status file should be readable");
	t.log("initial status: " + initial);

	# Write "working" status (used by lucibridge while LLM is thinking)
	n := writefile(statusfile, "working");
	t.assert(n > 0, "write to status should succeed");
	s := strip(readfile(statusfile));
	t.assertseq(s, "working", "status should be 'working'");

	# Write back to idle
	writefile(statusfile, "idle");
	s = strip(readfile(statusfile));
	t.assertseq(s, "idle", "status should return to 'idle'");
}

# ============================================================================
# Test 17: testMultipleArtifacts
#
# Create multiple artifacts and verify each is independently accessible.
# Regression: QID sub-id overflow or index collision caused wrong artifact
# data returned when multiple artifacts existed simultaneously (tab switching).
# ============================================================================

testMultipleArtifacts(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	presctl := actbase() + "/presentation/ctl";

	# Create 5 artifacts with distinct content
	for(i := 0; i < 5; i++) {
		id := "multi-art-" + string i;
		writefile(presctl, "create id=" + id + " type=text label=Art" + string i);
		writefile(actbase() + "/presentation/" + id + "/data",
			"Content for artifact " + string i + " only.");
	}

	# Verify each artifact has its own distinct data (no cross-contamination)
	for(i = 0; i < 5; i++) {
		id := "multi-art-" + string i;
		data := readfile(actbase() + "/presentation/" + id + "/data");
		t.assert(data != nil, "artifact " + id + " data should be readable");
		t.assert(hassubstr(data, "Content for artifact " + string i + " only."),
			sys->sprint("artifact %d should have its own content", i));
		# Verify it does NOT contain other artifacts' content
		for(j := 0; j < 5; j++) {
			if(j != i)
				t.assert(!hassubstr(data, "artifact " + string j + " only."),
					sys->sprint("artifact %d should not contain artifact %d content",
						i, j));
		}
	}
}

# ============================================================================
# Test 18: testMultipleMessages
#
# Write multiple messages and verify each is independently accessible.
# Regression: message index counter not incremented (all messages at idx 0).
# ============================================================================

testMultipleMessages(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	convctl := actbase() + "/conversation/ctl";

	# Find starting index (how many messages exist already)
	startidx := 0;
	for(i := 0; i < 100; i++) {
		(ok, nil) := sys->stat(actbase() + "/conversation/" + string i);
		if(ok < 0) {
			startidx = i;
			break;
		}
	}

	# Write 5 messages
	nmsgs := 5;
	for(i = 0; i < nmsgs; i++) {
		role := "human";
		if(i % 2 == 1)
			role = "veltro";
		writefile(convctl,
			"role=" + role + " text=MultiMsg-" + string (startidx + i));
	}

	# Verify each message exists with correct content
	for(i = 0; i < nmsgs; i++) {
		idx := startidx + i;
		msg := readfile(actbase() + "/conversation/" + string idx);
		t.assert(msg != nil,
			sys->sprint("conversation/%d should exist", idx));
		t.assert(hassubstr(msg, "MultiMsg-" + string idx),
			sys->sprint("message %d should contain its unique marker", idx));
	}
}

# ============================================================================
# Test 19: testConvInput
#
# Verify the conversation/input file exists and is openable.
# This is the file lucibridge reads from (blocking) to get user messages.
# Regression: input file missing caused lucibridge to fail silently at startup.
# ============================================================================

testConvInput(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	inputfile := actbase() + "/conversation/input";
	(ok, nil) := sys->stat(inputfile);
	t.assert(ok >= 0, "conversation/input should exist");

	# Opening it should succeed (it's a blocking read; we just check open)
	fd := sys->open(inputfile, Sys->OREAD);
	t.assert(fd != nil, "conversation/input should be openable");
	fd = nil;
}

testVoiceInputMode(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	modefile := TESTMNT + "/input-mode";
	t.assertseq(strip(readfile(modefile)), "k", "input-mode defaults to keyboard");
	t.asserteq(writefile(modefile, "v"), 1, "can switch to voice mode");
	t.assertseq(strip(readfile(modefile)), "v", "input-mode reads voice mode");
	t.asserteq(writefile(modefile, "k"), 1, "can switch back to keyboard mode");
	t.assertseq(strip(readfile(modefile)), "k", "input-mode reads keyboard mode");
}

testVoiceInput(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	voicefile := actbase() + "/conversation/voiceinput";
	(ok, nil) := sys->stat(voicefile);
	t.assert(ok >= 0, "conversation/voiceinput should exist");
	t.asserteq(writefile(voicefile, "voice injected turn"), len "voice injected turn",
		"voiceinput write should queue voice-originated text");
	t.assertseq(strip(readfile(voicefile)), "voice injected turn",
		"voiceinput read should return queued voice-originated text");
}

testVoiceInputFIFO(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	voicefile := actbase() + "/conversation/voiceinput";
	t.asserteq(writefile(voicefile, "first voice turn"), len "first voice turn",
		"first voice write");
	t.asserteq(writefile(voicefile, "second voice turn"), len "second voice turn",
		"second voice write");
	t.asserteq(writefile(voicefile, "third voice turn"), len "third voice turn",
		"third voice write");
	t.assertseq(strip(readfile(voicefile)), "first voice turn",
		"voiceinput preserves FIFO order for first turn");
	t.assertseq(strip(readfile(voicefile)), "second voice turn",
		"voiceinput preserves FIFO order for second turn");
	t.assertseq(strip(readfile(voicefile)), "third voice turn",
		"voiceinput preserves FIFO order for third turn");
}

testConversationControl(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}
	control := actbase() + "/conversation/control";
	(ok, nil) := sys->stat(control);
	t.assert(ok >= 0, "conversation/control should exist");
	t.asserteq(writefile(control, "pause"), len "pause", "pause control write");
	t.asserteq(writefile(control, "resume"), len "resume", "resume control write");
	t.assertseq(strip(readfile(control)), "pause", "control preserves FIFO first item");
	t.assertseq(strip(readfile(control)), "resume", "control preserves FIFO second item");
}

testConversationDraft(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	draftfile := actbase() + "/conversation/draft";
	(ok, nil) := sys->stat(draftfile);
	t.assert(ok >= 0, "conversation/draft should exist");
	t.asserteq(writefile(draftfile, "half a thou"), len "half a thou",
		"first partial replaces the draft");
	t.assertseq(readfile(draftfile), "half a thou",
		"draft is readable without becoming a message");
	t.asserteq(writefile(draftfile, "half a thousand"), len "half a thousand",
		"revised partial replaces rather than appends");
	t.assertseq(readfile(draftfile), "half a thousand",
		"latest hypothesis is the whole draft");

	# Draft writes are presentation events, distinct from input submission.
	writefile(actbase() + "/event", "flush");
	writefile(draftfile, "visible hypothesis");
	ev := readevent(actbase() + "/event");
	t.assertseq(strip(ev), "conversation draft",
		"draft replacement notifies the conversation renderer");

	writefile(draftfile, "");
	t.assertseq(readfile(draftfile), "", "empty write clears the draft");
}

# ============================================================================
# testConvClear (INFR-131)
#
# `echo clear > conversation/ctl` must non-destructively wipe an activity's
# accumulated messages while leaving the activity itself intact, and the
# conversation must accept fresh messages starting at index 0 again. The
# meta-agent (A0) can't be deleted, so this is the only way to reset its
# conversation between eval-harness scenarios.
# ============================================================================

testConvClear(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	convctl := actbase() + "/conversation/ctl";

	# Seed a couple of messages so there is something to clear.
	writefile(convctl, "role=human text=ClearTest-one");
	writefile(convctl, "role=veltro text=ClearTest-two");
	(okpre, nil) := sys->stat(actbase() + "/conversation/0");
	t.assert(okpre >= 0, "conversation/0 should exist before clear");

	# Non-destructive clear.
	n := writefile(convctl, "clear");
	t.assert(n > 0, "write 'clear' to conversation/ctl should succeed");

	# All messages gone: conversation/0 must no longer stat.
	(okpost, nil) := sys->stat(actbase() + "/conversation/0");
	t.assert(okpost < 0, "conversation/0 should be gone after clear");

	# The activity itself survives (clear != delete).
	(okact, nil) := sys->stat(actbase());
	t.assert(okact >= 0, "activity should still exist after clear");

	# Indices reset: a new message lands back at conversation/0.
	n2 := writefile(convctl, "role=human text=AfterClear");
	t.assert(n2 > 0, "write after clear should succeed");
	msg := readfile(actbase() + "/conversation/0");
	t.assert(msg != nil && hassubstr(msg, "AfterClear"),
		"new message should start at index 0 after clear");
}

# ============================================================================
# testConvCtlBadWrite (INFR-131)
#
# A rejected conversation/ctl write must fail at the 9P level (write returns
# < 0). The original bug was not that the write succeeded, but that sh's `>`
# redirect swallowed the real error so callers assumed success. This pins the
# protocol-level contract that a malformed ctl write is a genuine failure.
# ============================================================================

testConvCtlBadWrite(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	convctl := actbase() + "/conversation/ctl";
	# A message with no role is rejected by convctl ("missing role").
	n := writefile(convctl, "text=message with no role");
	t.assert(n < 0, "ctl write with missing role should fail at the 9P level");
}

# ============================================================================
# Test 20: testContextResourceUpdate
#
# Update a resource's status and verify the change persists.
# Regression: resource update command parsed wrong attributes.
# ============================================================================

testContextResourceUpdate(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	ctxctl := actbase() + "/context/ctl";

	# Add a resource first
	writefile(ctxctl,
		"resource add path=/api/updatable label=Updatable type=api status=streaming");

	# Update its status to stale
	n := writefile(ctxctl, "resource update path=/api/updatable status=stale");
	t.assert(n > 0, "resource update should succeed");

	# Read back and verify status changed
	# Find the resource (might not be resources/0 if others exist)
	found := 0;
	for(i := 0; i < 20; i++) {
		res := readfile(actbase() + "/context/resources/" + string i);
		if(res == nil)
			break;
		if(hassubstr(res, "path=/api/updatable")) {
			t.log("updated resource: " + res);
			t.assert(hassubstr(res, "status=stale"),
				"resource status should be updated to stale");
			found = 1;
			break;
		}
	}
	t.assert(found == 1, "updated resource should be findable in resources/");
}

# ============================================================================
# Test 21: testGapUpsert
#
# Verify gap upsert is idempotent by description: adding the same desc twice
# should yield a single entry with the updated relevance.
# ============================================================================

testGapUpsert(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	ctxctl := actbase() + "/context/ctl";
	i: int;

	# Count gaps before test
	startcount := 0;
	for(i = 0; i < 50; i++) {
		(ok, nil) := sys->stat(actbase() + "/context/gaps/" + string i);
		if(ok < 0) {
			startcount = i;
			break;
		}
	}

	# Upsert a new gap with relevance=high
	n := writefile(ctxctl, "gap upsert desc=test_upsert_idempotency relevance=high");
	t.assert(n > 0, "gap upsert should succeed");

	# Find and verify the gap was created
	found := "";
	for(i = startcount; i < startcount + 20; i++) {
		g := readfile(actbase() + "/context/gaps/" + string i);
		if(g == nil)
			break;
		if(hassubstr(g, "test_upsert_idempotency")) {
			found = g;
			break;
		}
	}
	t.assert(found != "", "gap should exist after upsert");
	t.log("gap after first upsert: " + found);
	t.assert(hassubstr(found, "relevance=high"), "gap relevance should be high");

	# Upsert again with same desc, different relevance — should NOT create duplicate
	n = writefile(ctxctl, "gap upsert desc=test_upsert_idempotency relevance=low");
	t.assert(n > 0, "second gap upsert should succeed");

	# Count gaps after second upsert — should be same as after first
	countafter := 0;
	for(i = 0; i < 100; i++) {
		(ok, nil) := sys->stat(actbase() + "/context/gaps/" + string i);
		if(ok < 0) {
			countafter = i;
			break;
		}
	}
	# Count with test gap included = startcount + 1
	t.assert(countafter == startcount + 1,
		sys->sprint("gap count should be %d, got %d (no duplicate created)",
			startcount + 1, countafter));

	# Verify relevance was updated
	updated := "";
	for(i = startcount; i < startcount + 20; i++) {
		g := readfile(actbase() + "/context/gaps/" + string i);
		if(g == nil)
			break;
		if(hassubstr(g, "test_upsert_idempotency")) {
			updated = g;
			break;
		}
	}
	t.assert(updated != "", "gap should still exist after second upsert");
	t.log("gap after second upsert: " + updated);
	t.assert(hassubstr(updated, "relevance=low"), "gap relevance should be updated to low");
	t.assert(!hassubstr(updated, "relevance=high"), "old relevance should be gone");
}

# ============================================================================
# Test 22: testGapResolve
#
# Verify gap resolve removes a gap by description match.
# ============================================================================

testGapResolve(t: ref T)
{
	i: int;

	if(actid < 0) {
		t.skip("no activity");
		return;
	}

	ctxctl := actbase() + "/context/ctl";

	# Add a gap to resolve
	n := writefile(ctxctl, "gap upsert desc=test_resolve_target relevance=medium");
	t.assert(n > 0, "gap upsert for resolve test should succeed");

	# Count gaps (to verify count decreases after resolve)
	countbefore := 0;
	for(i = 0; i < 100; i++) {
		(ok, nil) := sys->stat(actbase() + "/context/gaps/" + string i);
		if(ok < 0) {
			countbefore = i;
			break;
		}
	}

	# Resolve by desc
	n = writefile(ctxctl, "gap resolve desc=test_resolve_target");
	t.assert(n > 0, "gap resolve should succeed");

	# Count after resolve — should have decreased by 1
	countafter := 0;
	for(i = 0; i < 100; i++) {
		(ok, nil) := sys->stat(actbase() + "/context/gaps/" + string i);
		if(ok < 0) {
			countafter = i;
			break;
		}
	}
	t.assert(countafter == countbefore - 1,
		sys->sprint("gap count should decrease from %d to %d, got %d",
			countbefore, countbefore - 1, countafter));

	# Verify the resolved gap is no longer findable
	found := 0;
	for(i = 0; i < countafter; i++) {
		g := readfile(actbase() + "/context/gaps/" + string i);
		if(g == nil)
			break;
		if(hassubstr(g, "test_resolve_target")) {
			found = 1;
			break;
		}
	}
	t.assert(found == 0, "resolved gap should not be findable in gaps/");

	# Resolve of non-existent gap should return error (n < 0)
	fd := sys->open(ctxctl, Sys->OWRITE);
	if(fd != nil) {
		cmd := array of byte "gap resolve desc=nonexistent_gap_xyz";
		sys->write(fd, cmd, len cmd);
		# The write should fail (server returns error)
		# We can't easily check the error string, but we verify gaps count unchanged
		fd = nil;
	}
	countfinal := 0;
	for(i = 0; i < 100; i++) {
		(ok, nil) := sys->stat(actbase() + "/context/gaps/" + string i);
		if(ok < 0) {
			countfinal = i;
			break;
		}
	}
	t.assert(countfinal == countafter, "failed resolve should not change gap count");
}

# ============================================================================
# Test 23: testCatalogRead
#
# Verify catalog/ directory is served and entries are readable.
# The catalog is populated from /lib/veltro/resources/*.resource files.
# If the directory has no files, the test skips (non-fatal).
# ============================================================================

testCatalogRead(t: ref T)
{
	# Verify catalog/ directory exists in the 9P namespace
	(st, nil) := sys->stat(TESTMNT + "/catalog");
	t.assert(st >= 0, "catalog/ directory should exist in /mnt/ui namespace");

	# Try to read first catalog entry
	s := readfile(TESTMNT + "/catalog/0");
	if(s == nil) {
		t.skip("no catalog entries (no *.resource files in /lib/veltro/resources/)");
		return;
	}

	t.log("catalog/0: " + s);
	# Entry should have name= field
	t.assert(hassubstr(s, "name="), "catalog entry should have name= field");
	# Entry should have type= field
	t.assert(hassubstr(s, "type="), "catalog entry should have type= field");
	# mount= field should NOT be present (it's internal)
	t.assert(!hassubstr(s, "mount="), "catalog entry should NOT expose mount= field");
}

# ============================================================================
# Helpers: strtoint (local copy, no dep on luciuisrv internals)
# ============================================================================

strtoint(s: string): int
{
	n := 0;
	if(len s == 0)
		return -1;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return -1;
		n = n * 10 + (c - '0');
	}
	return n;
}

# Strip trailing whitespace/newlines (server appends \n to most file reads).
strip(s: string): string
{
	j := len s;
	while(j > 0 && s[j-1] <= ' ')
		j--;
	return s[0:j];
}

# ============================================================================
# Test: testAutocenterOnKill
#
# Regression test for f8b46094: when the current artifact is killed,
# luciuisrv should auto-center the next remaining artifact and fire
# "presentation current".  Before the fix, the presentation zone went
# blank because no artifact was re-centered.
# ============================================================================

testAutocenterOnKill(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity (testSetup failed)");
		return;
	}

	presctl := actbase() + "/presentation/ctl";
	evpath := actbase() + "/event";

	# Create three artifacts: ac-a, ac-b, ac-c
	writefile(presctl, "create id=ac-a type=text label=A");
	writefile(presctl, "create id=ac-b type=text label=B");
	writefile(presctl, "create id=ac-c type=text label=C");

	# Center on ac-b
	writefile(presctl, "center id=ac-b");
	cur := strip(readfile(actbase() + "/presentation/current"));
	t.assertseq(cur, "ac-b", "current should be ac-b after center");

	# Drain stale events before the kill
	drainall(evpath);

	# Kill ac-b — autocenter should select ac-c (the artifact that
	# slides into the deleted position) and fire "presentation current".
	writefile(presctl, "kill id=ac-b");

	# Read the current artifact — should NOT be empty
	cur = strip(readfile(actbase() + "/presentation/current"));
	t.assertnotnil(cur, "current should not be empty after killing centered artifact");
	# Should be ac-c (slid into ac-b's old position) or ac-a
	t.assert(cur == "ac-c" || cur == "ac-a",
		"current should be ac-c or ac-a, got: " + cur);
	t.log("autocenter selected: " + cur);

	# Verify "presentation current" event was fired
	ev := readevent(evpath);
	# Events from kill include: "presentation kill ac-b",
	# "presentation current", "presentation delete ac-b".
	# We need to find "presentation current" among them.
	found := 0;
	for(i := 0; i < 5 && !found; i++) {
		if(hassubstr(ev, "presentation current"))
			found = 1;
		else
			ev = readevent(evpath);
	}
	t.assert(found != 0, "should receive 'presentation current' event after kill");

	# Clean up remaining artifacts
	writefile(presctl, "delete id=ac-a");
	writefile(presctl, "delete id=ac-c");
	drainall(evpath);
}

# ============================================================================
# Test: testAutocenterOnDelete
#
# Same as above but for the "delete" ctl command path.
# ============================================================================

testAutocenterOnDelete(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity (testSetup failed)");
		return;
	}

	presctl := actbase() + "/presentation/ctl";
	evpath := actbase() + "/event";

	# Create two artifacts
	writefile(presctl, "create id=acd-x type=text label=X");
	writefile(presctl, "create id=acd-y type=text label=Y");
	writefile(presctl, "center id=acd-y");
	cur := strip(readfile(actbase() + "/presentation/current"));
	t.assertseq(cur, "acd-y", "current should be acd-y");

	drainall(evpath);

	# Delete the centered artifact
	writefile(presctl, "delete id=acd-y");

	# Autocenter should select acd-x
	cur = strip(readfile(actbase() + "/presentation/current"));
	t.assertseq(cur, "acd-x", "current should be acd-x after deleting acd-y");

	# Clean up
	writefile(presctl, "delete id=acd-x");
	drainall(evpath);
}

# ============================================================================
# Test: testAutocenterNonCurrent
#
# Deleting a non-current artifact should NOT change current.
# ============================================================================

testAutocenterNonCurrent(t: ref T)
{
	if(actid < 0) {
		t.skip("no activity (testSetup failed)");
		return;
	}

	presctl := actbase() + "/presentation/ctl";
	evpath := actbase() + "/event";

	# Create two artifacts and center the first
	writefile(presctl, "create id=acnc-p type=text label=P");
	writefile(presctl, "create id=acnc-q type=text label=Q");
	writefile(presctl, "center id=acnc-p");

	drainall(evpath);

	# Delete Q (not current) — current should remain P
	writefile(presctl, "delete id=acnc-q");
	cur := strip(readfile(actbase() + "/presentation/current"));
	t.assertseq(cur, "acnc-p",
		"deleting non-current artifact should not change current");

	# Clean up
	writefile(presctl, "delete id=acnc-p");
	drainall(evpath);
}

# ============================================================================
# Teardown: unmount the test server
# ============================================================================

teardown()
{
	sys->unmount(nil, TESTMNT);
}

# ============================================================================
# Test: ThemeEventStreaming
#
# Regression: every wm app's themelistener opens /mnt/ui/event ONCE and
# reads from that fd in a loop.  Before INFR-28 (commit 5f90faba) the
# styx fid's client-side offset accumulated by each read's byte count;
# the second read returned only the tail of the next event (data[offset:])
# and the third returned 0 / EOF, killing the listener.  Every theme
# switch after the first was thus silently dropped.
#
# Fix: themelisteners sys->seek(fd, big 0, Sys->SEEKSTART) after each
# successful read.  This test simulates that pattern and asserts each
# pushed event is fully delivered to a long-lived subscriber.
#
# DO NOT close+reopen the fd between iterations — that would mask the
# offset bug.  The whole point is that ONE fd survives many events.
# ============================================================================

testThemeEventStreaming(t: ref T)
{
	evpath := TESTMNT + "/event";
	ctlpath := TESTMNT + "/ctl";

	# Drain any earlier events so our reads see only what we push here.
	drainall(evpath);

	# Open the event stream ONCE — exactly as themelistener does.
	fd := sys->open(evpath, Sys->OREAD);
	if(fd == nil) {
		t.assert(0, "cannot open " + evpath + ": %r");
		return;
	}

	# Push a sequence of theme events and verify each one round-trips
	# through the open fd in order, in full.
	themes := array[] of {"brimstone", "halo", "brimstone", "halo", "brimstone"};
	buf := array[256] of byte;

	for(i := 0; i < len themes; i++) {
		# Trigger a global "theme <name>" event via /mnt/ui/ctl.
		n := writefile(ctlpath, "theme " + themes[i]);
		t.assert(n > 0,
			sys->sprint("write 'theme %s' to ctl should succeed", themes[i]));

		# Read on the long-lived fd.  Must use a goroutine + timeout
		# because read blocks until the event arrives.
		rch := chan[1] of (int, string);
		spawn fdreader(fd, buf, rch);
		toch := chan[1] of int;
		spawn timerwait(toch, 3000);

		nread: int;
		ev: string;
		alt {
		(nread, ev) = <-rch =>
			;
		<-toch =>
			t.assert(0, sys->sprint(
				"timed out waiting for 'theme %s' event (iteration %d)",
				themes[i], i));
			return;
		}

		t.assert(nread > 0,
			sys->sprint("read should return >0 bytes (got %d) on iter %d — "+
				"if 0/EOF, the fid-offset regression has returned",
				nread, i));

		expected := "theme " + themes[i] + "\n";
		t.assertseq(ev, expected,
			sys->sprint("event content should match exactly on iter %d", i));

		# Reset client-side fid offset — exactly as the themelistener
		# fix does.  Without this, the bug returns immediately.
		sys->seek(fd, big 0, Sys->SEEKSTART);
	}

	fd = nil;
}

# ============================================================================
# Test: BufferedEventOrder
#
# Regression: INFR-36 — when MULTIPLE global events accumulate in a
# subscriber's buffer (no pending reader at write time), they must
# drain in FIFO order. The earlier implementation cons'd events to the
# head of a "list of string" and called qrev() on every doread, which
# only ordered the first event correctly:
#
#   buffer [E3,E2,E1] (cons order, E3 newest)
#   read 1: qrev -> [E1,E2,E3]; take E1; left = [E2,E3]
#   read 2: qrev([E2,E3]) -> [E3,E2]; take E3 (WRONG, should be E2)
#   read 3: qrev([E2]) -> [E2]; take E2 (WRONG, should be E3)
#
# Theme events were idempotent so the visible damage was small, but
# applaunch / activity-new / activity-delete were vulnerable.
#
# To exercise the buffer path: open the event fd but DO NOT start a
# read goroutine before the writes, so pushglobalevent has no pending
# reader to deliver to and must buffer.
# ============================================================================

testBufferedEventOrder(t: ref T)
{
	evpath := TESTMNT + "/event";
	ctlpath := TESTMNT + "/ctl";

	drainall(evpath);

	fd := sys->open(evpath, Sys->OREAD);
	if(fd == nil) {
		t.assert(0, "cannot open " + evpath + ": %r");
		return;
	}

	# Burst three writes back-to-back with no intervening read. With no
	# pending reader, all three accumulate in s.events.
	bursts := array[] of {"brimstone", "halo", "brimstone"};
	for(wi := 0; wi < len bursts; wi++) {
		n := writefile(ctlpath, "theme " + bursts[wi]);
		t.assert(n > 0,
			sys->sprint("write 'theme %s' to ctl should succeed", bursts[wi]));
	}

	# Now drain three reads on the same fd and check FIFO order.
	buf := array[256] of byte;
	for(i := 0; i < len bursts; i++) {
		rch := chan[1] of (int, string);
		spawn fdreader(fd, buf, rch);
		toch := chan[1] of int;
		spawn timerwait(toch, 3000);

		nread: int;
		ev: string;
		alt {
		(nread, ev) = <-rch =>
			;
		<-toch =>
			t.assert(0, sys->sprint(
				"timed out draining buffered event %d (got %d so far)",
				i, i));
			fd = nil;
			return;
		}

		expected := "theme " + bursts[i] + "\n";
		t.assertseq(ev, expected,
			sys->sprint("buffered event %d should be %q (got %q) — "+
				"FIFO ordering regression (INFR-36)",
				i, expected, ev));

		sys->seek(fd, big 0, Sys->SEEKSTART);
	}

	fd = nil;
}

# Read into buf on fd, send (n, string) on ch.
fdreader(fd: ref Sys->FD, buf: array of byte, ch: chan of (int, string))
{
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		ch <-= (n, "");
	else
		ch <-= (n, string buf[0:n]);
}

# ============================================================================
# Test: ThemeBroadcastAllSubs
#
# Regression: a single theme switch must reach EVERY subscribed app at once.
#
# In the running desktop, every wm app's themelistener holds its own open fd
# on /mnt/ui/event and blocks reading it. A theme change in Settings writes
# ONE "theme <name>" to /mnt/ui/ctl; luciuisrv's pushglobalevent must fan it
# out to ALL of those subscribers so the whole UI re-themes together.
#
# The rest of the suite only ever drives a SINGLE subscriber (ThemeEventStreaming,
# BufferedEventOrder), so a fan-out break — one app updates, the rest don't,
# i.e. the user-visible "theme stopped switching across all apps" — would sail
# through green. This stands up NSUBS concurrent long-lived subscribers, each
# pending on a blocking read exactly like a real app, then asserts one ctl
# write is delivered in full to every one of them.
#
# (This guards the client-fan-out contract. The companion class of theme bug —
# apps compiled against a stale mount path so they never open the right event
# file at all — is caught by the dis-freshness verifier, not here: a test that
# controls the mount point via -m cannot observe an app's hardcoded path.)
# ============================================================================

# One simulated app themelistener: open the global event file, announce it is
# registered, then block on a single read and report what arrives.
themeSubReader(idx: int, evpath: string, readyc: chan of int,
		resultc: chan of (int, string))
{
	fd := sys->open(evpath, Sys->OREAD);
	if(fd == nil) {
		readyc <-= idx;
		resultc <-= (idx, "error:open");
		return;
	}
	readyc <-= idx;			# fd open + EventSub registered
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);	# blocks until a global event fires
	if(n <= 0)
		resultc <-= (idx, "error:eof");
	else
		resultc <-= (idx, string buf[0:n]);
	fd = nil;
}

testThemeBroadcastAllSubs(t: ref T)
{
	evpath := TESTMNT + "/event";
	ctlpath := TESTMNT + "/ctl";

	drainall(evpath);

	readyc := chan of int;
	resultc := chan of (int, string);

	# Stand up NSUBS subscribers, each blocking on a read — the steady
	# state of NSUBS running apps with live themelisteners.
	for(i := 0; i < NSUBS; i++)
		spawn themeSubReader(i, evpath, readyc, resultc);

	# Wait until every subscriber has opened and registered its fd.
	for(i = 0; i < NSUBS; i++)
		<-readyc;

	# Let the readers reach the blocking read so the write below finds
	# NSUBS pending readers rather than racing ahead of them.
	sys->sleep(300);

	# ONE theme switch, exactly as Settings' applytheme does.
	n := writefile(ctlpath, "theme halo");
	t.assert(n > 0, "single 'theme halo' write to ctl should succeed");

	# Gather every subscriber's result under one overall timeout.
	expected := "theme halo\n";
	got := array[NSUBS] of { * => "(none)" };
	toch := chan[1] of int;
	spawn timerwait(toch, 5000);
	ndone := 0;
	timedout := 0;
	while(ndone < NSUBS && !timedout) {
		alt {
		(idx, ev) := <-resultc =>
			if(idx >= 0 && idx < NSUBS)
				got[idx] = ev;
			ndone++;
		<-toch =>
			timedout = 1;
		}
	}

	t.asserteq(ndone, NSUBS,
		sys->sprint("all %d subscribers must receive the theme event (got %d) — "+
			"a shortfall is the 'theme stops switching across apps' regression",
			NSUBS, ndone));
	for(i = 0; i < NSUBS; i++)
		t.assertseq(got[i], expected,
			sys->sprint("subscriber %d should receive %#q in full, got %#q",
				i, expected, got[i]));
}

# ============================================================================
# Main
# ============================================================================

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

	# Start server and create activity (must run first)
	run("Setup", testSetup);

	# INFR-127 regression: directory listing (ls/readdir) on the root and
	# on a per-activity conversation dir must enumerate children and finish.
	run("RootDirread", testRootDirread);

	# Conversation tests
	run("ConvMessageWrite", testConvMessageWrite);
	run("ConvMessageUpdate", testConvMessageUpdate);
	run("ConvTextEmbeddedEquals", testConvTextEmbeddedEquals);
	run("ConvEventDelivery", testConvEventDelivery);
	run("ConvUpdateEvent", testConvUpdateEvent);
	run("ConvMultipleMessages", testMultipleMessages);
	run("ConvInput", testConvInput);
	run("ConvCtlBadWrite", testConvCtlBadWrite);
	run("ConvClear", testConvClear);
	run("VoiceInputMode", testVoiceInputMode);
	run("VoiceInput", testVoiceInput);
	run("VoiceInputFIFO", testVoiceInputFIFO);
	run("ConversationControl", testConversationControl);
	run("ConversationDraft", testConversationDraft);

	# Presentation tests
	run("PresCreate", testPresentationCreate);
	run("PresDataWrite", testPresentationDataWrite);
	run("PresUpdate", testPresentationUpdate);
	run("PresDataEmbeddedControls", testPresentationDataEmbeddedControls);
	run("PresAppend", testPresentationAppend);
	run("PresCenter", testPresentationCenter);
	run("PresEvent", testPresentationEvent);
	run("PresMultipleArtifacts", testMultipleArtifacts);

	# Context tests
	run("ContextResourceAdd", testContextResourceAdd);
	run("ContextGapAdd", testContextGapAdd);
	run("ContextBgTaskAdd", testContextBgTaskAdd);
	run("ContextResourceUpdate", testContextResourceUpdate);
	run("GapUpsert", testGapUpsert);
	run("GapResolve", testGapResolve);
	run("CatalogRead", testCatalogRead);

	# Autocenter regression tests (f8b46094)
	run("AutocenterOnKill", testAutocenterOnKill);
	run("AutocenterOnDelete", testAutocenterOnDelete);
	run("AutocenterNonCurrent", testAutocenterNonCurrent);

	# Activity metadata tests
	run("ActivityLabel", testActivityLabel);
	run("ActivityStatus", testActivityStatus);

	# INFR-28 regression: theme events must stream to long-lived
	# subscribers across many switches (fid offset must reset).
	run("ThemeEventStreaming", testThemeEventStreaming);

	# INFR-36 regression: multiple buffered events must drain in
	# FIFO order (earlier qrev-on-every-read corrupted order from
	# the second event onward).
	run("BufferedEventOrder", testBufferedEventOrder);

	# Multi-subscriber fan-out: one theme switch must reach EVERY subscribed
	# app at once. The single-subscriber theme tests above can't see an
	# "all apps" fan-out break — the exact shape of the post-/mnt/ui-move
	# regression where the desktop stopped re-theming.
	run("ThemeBroadcastAllSubs", testThemeBroadcastAllSubs);

	teardown();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
