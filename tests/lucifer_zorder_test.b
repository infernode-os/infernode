implement LuciferZorderTest;

#
# Regression tests for Lucifer presentation-zone layout + z-order.
#
# Guards two classes of bug fixed on feat/ios-phase-b:
#
# 1. Mobile accordion layout (INFR-137, commit c569adc5).
#    The accordion used to collapse non-active zones to a 1x1 sentinel
#    sub-image.  Because every /dis/wm app window is a child of presscr
#    (the presentation Screen allocated on the Workspace sub-image),
#    collapsing the Workspace shrank presscr to 1x1 and destroyed those
#    windows; re-expanding reallocated them blank.  Fix: all three zones
#    share the SAME full body rect and overlap — visibility is pure
#    z-order.  Part 1 mirrors zonerects()'s mobile branch and asserts
#    every zone gets the full body rect, never a 1x1 sentinel.
#
# 2. Presentation z-order (INFR-119, commit 83cc0a89).
#    Multiple apps on the single shared presscr were ordered by ad-hoc
#    top()/bottom() calls that raced (an app whose client had not joined
#    was "hidden" via a no-op, then topped itself on join), so the wrong
#    app could end up visible under the active tab.  Fix:
#    enforcepreszorder() — bottom every app in every activity, raise
#    lucipres, then raise the focused activity's active app.  Part 2
#    mirrors that ordering over a MockClient z-list and asserts the
#    active app ends on top, lucipres beneath it, all others bottomed;
#    the *Buggy variant documents the pre-fix failure.
#
# Like wmsrv_zorder_test.b, these are MIRRORS: the screen/draw ops need a
# live display, so the z-list logic is reproduced with a MockClient and
# the layout geometry with a pure mobilezonerects().  They are executable
# specifications of the invariants plus a buggy/fixed contrast.
#
# To run standalone:
#   ./emu/MacOSX/o.emu -r. /dis/tests/lucifer_zorder_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";
	Rect, Point: import Draw;

include "testing.m";
	testing: Testing;
	T: import testing;

LuciferZorderTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/lucifer_zorder_test.b";

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

# ─── Part 1: mobile accordion layout ────────────────────────────────────────

# Mirror of lucifer.b's layout constants.
MOBILE_HEADERH:   con 132;
MOBILE_TITLEBARH: con 72;

# mobilezonerects mirrors lucifer.b zonerects()'s mobile branch
# (post-INFR-137): three title bars stacked under the header, then ALL
# THREE zones share the full body rect below them.  Independent of which
# zone is "expanded" — that is decided by z-order, not geometry.
mobilezonerects(r: Rect): (Rect, Rect, Rect)
{
	zonety  := r.min.y + MOBILE_HEADERH + 1;
	bodytop := zonety + 3 * MOBILE_TITLEBARH;
	bodyr := Rect((r.min.x, bodytop), (r.max.x, r.max.y));
	return (bodyr, bodyr, bodyr);
}

# The pre-INFR-137 collapsed-zone rect: a 1x1 sentinel.  Kept here only to
# assert the live geometry is NOT this shape.
sentinel(r: Rect): Rect
{
	return Rect((r.max.x - 2, r.max.y - 1), (r.max.x - 1, r.max.y));
}

screenrect(): Rect
{
	return Rect((0, 0), (1179, 2556));	# representative phone size
}

# Rect.dx()/dy()/eq() are Draw-module methods that need the module loaded
# (and a display).  This headless test computes them from the .min/.max
# data fields instead, which are plain field accesses.
rdx(r: Rect): int { return r.max.x - r.min.x; }
rdy(r: Rect): int { return r.max.y - r.min.y; }
req(a, b: Rect): int
{
	return a.min.x == b.min.x && a.min.y == b.min.y &&
	       a.max.x == b.max.x && a.max.y == b.max.y;
}

testAccordionAllZonesShareBody(t: ref T)
{
	r := screenrect();
	(cr, pr, xr) := mobilezonerects(r);
	t.assert(req(cr, pr) && req(pr, xr),
		"all three accordion zones share one full-body rect");
	t.asserteq(rdx(cr), rdx(r), "zone spans full width");
	t.asserteq(cr.max.y, r.max.y, "zone extends to screen bottom");
}

testAccordionNeverSentinel(t: ref T)
{
	# Core INFR-137 guard: a collapsed zone must NOT be a 1x1 sentinel,
	# or presscr collapses to 1x1 and the app windows on it are destroyed.
	r := screenrect();
	(cr, pr, xr) := mobilezonerects(r);
	t.assertne(rdx(cr) * rdy(cr), 1, "conv zone is not 1x1");
	t.assertne(rdx(pr) * rdy(pr), 1, "pres zone is not 1x1");
	t.assertne(rdx(xr) * rdy(xr), 1, "ctx zone is not 1x1");
	# And explicitly distinct from the old sentinel shape.
	t.assert(!req(pr, sentinel(r)),
		"pres zone is not the old 1x1 sentinel rect");
}

testAccordionBodyBelowTitlebars(t: ref T)
{
	# The body must start below all three stacked title bars so the
	# drawchrome title bars (drawn on mainwin) are never covered.
	r := screenrect();
	(cr, nil, nil) := mobilezonerects(r);
	wanttop := r.min.y + MOBILE_HEADERH + 1 + 3 * MOBILE_TITLEBARH;
	t.asserteq(cr.min.y, wanttop, "body starts below the three title bars");
}

# ─── Part 2: presentation z-order (mirror of enforcepreszorder) ─────────────

# MockClient mirrors the z-list fields exercised by Client.top()/bottom().
# 'top of z-order' == head of the mzorder list (mtop moves to head).
MockClient: adt {
	id:    string;
	actid: int;
	znext: ref MockClient;
};

mzorder: ref MockClient;

mreset()
{
	mzorder = nil;
}

mappend(c: ref MockClient)
{
	c.znext = nil;
	if(mzorder == nil) { mzorder = c; return; }
	z := mzorder;
	while(z.znext != nil)
		z = z.znext;
	z.znext = c;
}

# mtop / mbottom mirror the FIXED wmsrv.b Client.top()/bottom() list logic.
mtop(c: ref MockClient)
{
	if(mzorder == c)
		return;
	prev: ref MockClient;
	for(z := mzorder; z != nil; (prev, z) = (z, z.znext))
		if(z == c)
			break;
	if(prev != nil)
		prev.znext = c.znext;
	c.znext = mzorder;
	mzorder = c;
}

mbottom(c: ref MockClient)
{
	# Unlink c from wherever it currently sits in the z-list.
	prev: ref MockClient;
	for(z := mzorder; z != nil; (prev, z) = (z, z.znext))
		if(z == c)
			break;
	if(prev != nil)
		prev.znext = c.znext;
	else if(mzorder == c)
		mzorder = c.znext;
	# Re-append at the tail (z-back).
	c.znext = nil;
	if(mzorder == nil) {
		mzorder = c;
		return;
	}
	tail := mzorder;
	while(tail.znext != nil)
		tail = tail.znext;
	tail.znext = c;
}

# enforce mirrors lucifer.b enforcepreszorder(): bottom every app window
# in every activity, raise lucipres, then raise the focused activity's
# active app.  Result (head→tail): activeapp, lucipres, …everything else.
enforce(apps: list of ref MockClient, lucipres: ref MockClient,
	focusact: int, activeid: string)
{
	for(l := apps; l != nil; l = tl l)
		mbottom(hd l);
	if(lucipres != nil)
		mtop(lucipres);
	for(l = apps; l != nil; l = tl l) {
		c := hd l;
		if(c.actid == focusact && c.id == activeid)
			mtop(c);
	}
}

# headid / secondid — convenience accessors for the z-list order.
headid(): string
{
	if(mzorder == nil)
		return "";
	return mzorder.id;
}

secondid(): string
{
	if(mzorder == nil || mzorder.znext == nil)
		return "";
	return mzorder.znext.id;
}

# isbottomed — true if id sits below lucipres in the z-list.
isbottomed(id: string): int
{
	seenluci := 0;
	for(z := mzorder; z != nil; z = z.znext) {
		if(z.id == "lucipres")
			seenluci = 1;
		else if(z.id == id)
			return seenluci;
	}
	return 0;
}

testEnforceActiveOnTop(t: ref T)
{
	mreset();
	luci := ref MockClient("lucipres", 1, nil);
	a1 := ref MockClient("app1", 1, nil);
	a2 := ref MockClient("app2", 1, nil);
	a3 := ref MockClient("app3", 1, nil);
	mappend(luci); mappend(a1); mappend(a2); mappend(a3);

	enforce(a1 :: a2 :: a3 :: nil, luci, 1, "app2");

	t.assertseq(headid(), "app2", "active app is on top");
	t.assertseq(secondid(), "lucipres", "lucipres is directly beneath active app");
	t.asserteq(isbottomed("app1"), 1, "inactive app1 is bottomed");
	t.asserteq(isbottomed("app3"), 1, "inactive app3 is bottomed");
}

testEnforceNoActiveShowsLucipres(t: ref T)
{
	mreset();
	luci := ref MockClient("lucipres", 1, nil);
	a1 := ref MockClient("app1", 1, nil);
	a2 := ref MockClient("app2", 1, nil);
	mappend(luci); mappend(a1); mappend(a2);

	# Non-app artifact centered: activeappid == "" → lucipres on top.
	enforce(a1 :: a2 :: nil, luci, 1, "");

	t.assertseq(headid(), "lucipres", "lucipres on top when no active app");
	t.asserteq(isbottomed("app1"), 1, "app1 bottomed");
	t.asserteq(isbottomed("app2"), 1, "app2 bottomed");
}

testEnforceCrossActivity(t: ref T)
{
	# Two activities share one presscr.  Only the focused activity's
	# active app may be visible; a background activity's app must stay
	# bottomed even though its window lives on the same screen.
	mreset();
	luci := ref MockClient("lucipres", 0, nil);
	main := ref MockClient("mainapp", 1, nil);	# focused activity 1
	bg   := ref MockClient("bgapp",   2, nil);	# background activity 2
	mappend(luci); mappend(main); mappend(bg);

	enforce(main :: bg :: nil, luci, 1, "mainapp");

	t.assertseq(headid(), "mainapp", "focused activity's active app on top");
	t.asserteq(isbottomed("bgapp"), 1, "background activity's app stays bottomed");
}

testJoinRaceBuggyThenFixed(t: ref T)
{
	# Pre-fix: each app self-topped on join regardless of which app was
	# active.  If a non-active app (app3) joined LAST it ended on top,
	# covering the active app (app1) — the "wrong app under the tab"
	# desync.  Reproduce that, then show enforce() repairs it.
	mreset();
	luci := ref MockClient("lucipres", 1, nil);
	a1 := ref MockClient("app1", 1, nil);
	a3 := ref MockClient("app3", 1, nil);
	mappend(luci);

	# app1 launched + active, joins and self-tops.
	mappend(a1); mtop(a1);
	# app3 launched later (non-active), joins and self-tops (BUG).
	mappend(a3); mtop(a3);
	t.assertseq(headid(), "app3", "BUGGY: late non-active app self-tops over active");

	# enforce() re-asserts the invariant: active app1 back on top.
	enforce(a1 :: a3 :: nil, luci, 1, "app1");
	t.assertseq(headid(), "app1", "FIXED: enforce restores active app on top");
	t.assertseq(secondid(), "lucipres", "FIXED: lucipres beneath active app");
	t.asserteq(isbottomed("app3"), 1, "FIXED: non-active app bottomed");
}

# ─── init ───────────────────────────────────────────────────────────────────

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

	# Part 1: mobile accordion layout (INFR-137)
	run("AccordionAllZonesShareBody",  testAccordionAllZonesShareBody);
	run("AccordionNeverSentinel",      testAccordionNeverSentinel);
	run("AccordionBodyBelowTitlebars", testAccordionBodyBelowTitlebars);

	# Part 2: presentation z-order (INFR-119)
	run("EnforceActiveOnTop",          testEnforceActiveOnTop);
	run("EnforceNoActiveShowsLucipres", testEnforceNoActiveShowsLucipres);
	run("EnforceCrossActivity",        testEnforceCrossActivity);
	run("JoinRaceBuggyThenFixed",      testJoinRaceBuggyThenFixed);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
