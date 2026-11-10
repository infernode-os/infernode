implement MermaidFlowTest;

#
# mermaid(2) flowcharts, by their pixels in colours of the test's own:
# a quoted label holding its delimiter is one node; <br/> breaks a
# label's lines; a quoted edge label with a "-" in it (AES-256) keeps its
# edge; an edge that skips a layer goes round the node in its way, not
# under it; the gap between layers grows to fit an edge's label, which
# the nodes either side were drawn over; two edges bending into one node
# keep their labels apart, each at its own source's height.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "testing.m";
	testing: Testing;
	T: import testing;
include "mermaid.m";
	mermaid: Mermaid;

MermaidFlowTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/mermaid_flow_test.b";

passed := 0;
failed := 0;
skipped := 0;
display: ref Display;
LINE: con int 16rFF0000FF;	# lines and arrows, and node borders

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

# the chart drawn, copied to XRGB32 so its pixels can be read
chart(t: ref T, src: string): ref Image
{
	(img, err) := mermaid->render(src, 200);
	if(img == nil){
		t.fatal("render: " + err);
		return nil;
	}
	x := display.newimage(img.r, Draw->XRGB32, 0, Draw->White);
	x.draw(x.r, img, nil, img.r.min);
	return x;
}

# the rows in which a line-coloured pixel is, lowest last
linerows(img: ref Image): list of int
{
	w := img.r.dx();
	b := array[4*w] of byte;
	rows: list of int;
	for(y := img.r.min.y; y < img.r.max.y; y++){
		img.readpixels(Rect((img.r.min.x, y), (img.r.max.x, y+1)), b);
		for(x := 0; x < w; x++)
			if(int b[4*x+2] > 200 && int b[4*x+1] < 60 && int b[4*x] < 60){
				rows = y :: rows;
				break;
			}
	}
	return rows;
}

testQuoted(t: ref T)
{
	q := chart(t, "flowchart LR\n  a[\"p]q\"] --> b\n");
	p := chart(t, "flowchart LR\n  a[pq] --> b\n");
	if(q == nil || p == nil)
		return;
	t.asserteq(q.r.dy(), p.r.dy(), "a quoted label holding ] is one node: the chart as tall as one without it");
	t.asserteq(q.r.dx(), p.r.dx(), "and as wide");
}

testBreak(t: ref T)
{
	two := chart(t, "flowchart LR\n  a[\"one<br/>two\"] --> b\n");
	one := chart(t, "flowchart LR\n  a[one] --> b\n");
	if(two == nil || one == nil)
		return;
	t.assert(two.r.dy() > one.r.dy(), sys->sprint("<br/> breaks the label: %d high, one line %d", two.r.dy(), one.r.dy()));
	t.assert(two.r.dx() <= one.r.dx() + 2, "and its lines are not drawn as one");
}

testDashLabel(t: ref T)
{
	d := chart(t, "flowchart LR\n  a -- \"x-y\" --> b\n");
	p := chart(t, "flowchart LR\n  a -->|x-y| b\n");
	if(d == nil || p == nil)
		return;
	t.asserteq(d.r.dx(), p.r.dx(), "-- \"x-y\" --> is an edge as -->|x-y| is: as wide");
	t.asserteq(d.r.dy(), p.r.dy(), "and as tall");
}

testAround(t: ref T)
{
	row := chart(t, "flowchart LR\n  a --> b --> c\n");
	skip := chart(t, "flowchart LR\n  a --> b --> c\n  a --> c\n");
	if(row == nil || skip == nil)
		return;
	r := linerows(row);
	s := linerows(skip);
	if(r == nil || s == nil){
		t.fatal("no lines drawn");
		return;
	}
	bottom := hd r;		# the row's lowest border
	t.assert(hd s > bottom + 4, sys->sprint("a -> c goes round below b: lines to row %d, the nodes end at %d", hd s, bottom));
	t.assert(skip.r.dy() > row.r.dy(), "and the chart makes room for it");
}

testLabelGap(t: ref T)
{
	short := chart(t, "flowchart LR\n  a -->|x| b\n");
	long := chart(t, "flowchart LR\n  a -->|a much longer label than the gap| b\n");
	if(short == nil || long == nil)
		return;
	t.assert(long.r.dx() > short.r.dx() + 60, sys->sprint("a long edge label widens the gap: %d wide, %d with a short one", long.r.dx(), short.r.dx()));
}

# the columns where a line-coloured pixel is: the leftmost and rightmost
linecols(img: ref Image): (int, int)
{
	w := img.r.dx();
	b := array[4*w] of byte;
	(lo, hi) := (w, -1);
	for(y := img.r.min.y; y < img.r.max.y; y++){
		img.readpixels(Rect((img.r.min.x, y), (img.r.max.x, y+1)), b);
		for(x := 0; x < w; x++)
			if(int b[4*x+2] > 200 && int b[4*x+1] < 60 && int b[4*x] < 60){
				if(x < lo) lo = x;
				if(x > hi) hi = x;
			}
	}
	return (lo, hi);
}

# groups of rows with dark (text) pixels in columns x0 to x1
textgroups(img: ref Image, x0, x1: int): int
{
	w := img.r.dx();
	b := array[4*w] of byte;
	groups := 0;
	gap := 99;
	for(y := img.r.min.y; y < img.r.max.y; y++){
		img.readpixels(Rect((img.r.min.x, y), (img.r.max.x, y+1)), b);
		dark := 0;
		for(x := x0; x < x1 && x < w; x++)
			if(int b[4*x] < 80 && int b[4*x+1] < 80 && int b[4*x+2] < 80)
				dark = 1;
		if(dark){
			if(gap > 2)
				groups++;
			gap = 0;
		} else
			gap++;
	}
	return groups;
}

# the width of the first node: the longest line-coloured run in a row
nodewidth(img: ref Image, lo, hi: int): int
{
	w := img.r.dx();
	row := array[4*w] of byte;
	best := 0;
	for(y := img.r.min.y; y < img.r.max.y; y++){
		img.readpixels(Rect((img.r.min.x, y), (img.r.max.x, y+1)), row);
		run := 0;
		for(x := lo; x <= hi && x < w; x++)
			if(int row[4*x+2] > 200 && int row[4*x+1] < 60 && int row[4*x] < 60){
				run++;
				if(run > best && x - run + 1 == lo)
					best = run;
			} else
				run = 0;
	}
	return best;
}

testConverge(t: ref T)
{
	# two-line labels, as ns2mmd's are: at the middle of their bends they
	# were taller than the rows are apart, and one over the other
	img := chart(t, "flowchart LR\n  a[aaaa] -->|\"first<br/>one\"| c[aaaa]\n  b[aaaa] -->|\"second<br/>two\"| c\n");
	if(img == nil)
		return;
	# a, b and c are the same width; the gap between the columns is
	# what is left after a's on the left and c's on the right
	(lo, hi) := linecols(img);
	nw := nodewidth(img, lo, hi);
	if(nw < 10){
		t.fatal(sys->sprint("no node found (lines %d to %d)", lo, hi));
		return;
	}
	g := textgroups(img, lo + nw + 2, hi - nw - 2);
	# each label's two lines a group of rows: four, none drawn over another
	t.asserteq(g, 4, "two edges bending into one node: their two-line labels apart, four lines");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	mermaid = load Mermaid Mermaid->PATH;
	if(mermaid == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Mermaid->PATH);
		raise "fail:load";
	}
	display = Display.allocate(nil);
	if(display == nil){
		sys->print("SKIP: no display: %r\n");
		return;
	}
	mermaid->init(display, nil, nil);
	mermaid->colours(display.white, display.white, display.color(LINE), display.black);
	run("Quoted", testQuoted);
	run("Break", testBreak);
	run("DashLabel", testDashLabel);
	run("Around", testAround);
	run("LabelGap", testLabelGap);
	run("Converge", testConverge);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
