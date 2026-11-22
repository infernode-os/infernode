implement GeomEdgeTest;

#
# $Draw's Point and Rect arithmetic (libinterp/geom.c) past an int.
#
# A Limbo int is a word holding a 32-bit value, and the VM's own
# arithmetic keeps it one.  These builtins added and multiplied whole
# words: the largest int plus one was a word no int is.  It printed as
# the most negative int and was not equal to it, nor less than zero, and
# as a big it was one number under the interpreter and another compiled.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Point, Rect: import draw;
include "testing.m";
	testing: Testing;
	T: import testing;

GeomEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/geom_edge_test.b";

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

MAX: con 16r7fffffff;
MIN: con -16r7fffffff - 1;

# an int that is one: equal to what it prints as, and the same as a big
isint(t: ref T, v, want: int, what: string)
{
	t.assert(v == want, sys->sprint("%s is %d", what, want));
	t.assert(big v == big want, what + " as a big");
	t.assert((v < 0) == (want < 0), what + " has its sign");
}

testPoint(t: ref T)
{
	p := Point(MAX, MIN);
	q := p.add(Point(1, -1));
	isint(t, q.x, MIN, "the largest int plus one");
	isint(t, q.y, MAX, "the most negative minus one");
	q = p.sub(Point(-1, 1));
	isint(t, q.x, MIN, "the largest int less minus one");
	isint(t, q.y, MAX, "the most negative less one");
	q = Point(MAX, 3).mul(2);
	isint(t, q.x, -2, "the largest int doubled");
	isint(t, q.y, 6, "three doubled");
	q = Point(MIN, 7).div(-1);
	isint(t, q.x, MIN, "the most negative int over -1");
	isint(t, q.y, -7, "seven over -1");
	q = Point(-9, 9).div(2);
	isint(t, q.x, -4, "-9 over 2");
	isint(t, q.y, 4, "9 over 2");
	e := "";
	{
		q = Point(1, 1).div(0);
	} exception ex {
	"*" =>
		e = ex;
	}
	t.assertseq(e, "zero divide", "a Point over 0");
}

testRect(t: ref T)
{
	r := Rect((MAX, MAX), (MIN, MIN));
	s := r.addpt(Point(1, 1));
	isint(t, s.min.x, MIN, "addpt past the largest int");
	isint(t, s.max.y, MIN+1, "addpt of the most negative");
	s = r.subpt(Point(-1, -1));
	isint(t, s.min.y, MIN, "subpt past the largest int");
	s = r.inset(-1);
	isint(t, s.min.x, MAX-1, "inset: min");
	isint(t, s.max.x, MIN+1, "inset: max");
	isint(t, Rect((MIN, 0), (MAX, 0)).dx(), -1, "dx across the whole range");
	isint(t, Rect((0, MAX), (0, MIN)).dy(), 1, "dy across the whole range");
	z := Rect((MIN, MIN), (MAX, MAX)).size();
	isint(t, z.x, -1, "size.x across the whole range");
	isint(t, z.y, -1, "size.y");
	# ordinary rectangles
	o := Rect((1, 2), (11, 22));
	t.assert(o.dx() == 10 && o.dy() == 20, "an ordinary rectangle's dx and dy");
	n := o.addpt(Point(5, 5)).inset(1);
	t.assert(n.min.x == 7 && n.min.y == 8 && n.max.x == 15 && n.max.y == 26, "moved and inset");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if(draw == nil){
		sys->print("SKIP: no $Draw: %r\n");
		return;
	}

	run("Point", testPoint);
	run("Rect", testRect);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
