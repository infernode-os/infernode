implement MathEdgeTest;

#
# $Math's builtins (libinterp/math.c) given what a program may pass.
#
# gemm checked each matrix by its columns alone, in an int: a matrix of
# one column was not looked at, so sixteen rows were read from, and
# written to, an array of one element (the Dis heap's own headers, and
# from there anything); with a nil the other operand was checked in one
# shape and read in another; and a leading dimension large enough wrapped
# the product.
#
# sort recursed on both parts of each partition on the Dis process's C
# stack: 400 NaNs (each "greater" than the other) ended the emulator.
# And it, import_int and export_int took a Limbo int for four bytes, where
# it is a word: on a 64-bit host half the permutation was sorted.
#
# A nil array is an exception here, and has to be one made by the builtin:
# in the native kernels a fault in the kernel's C stops the machine.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "testing.m";
	testing: Testing;
	T: import testing;

MathEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/math_edge_test.b";

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

# "" if the call returned, else the exception
gemm(ta, tb, m, n, k: int, alpha: real, a: array of real, lda: int,
	b: array of real, ldb: int, beta: real, c: array of real, ldc: int): string
{
	{
		math->gemm(ta, tb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
	} exception e {
	"*" =>
		return e;
	}
	return "";
}

reals(n: int, v: real): array of real
{
	a := array[n] of real;
	for(i := 0; i < n; i++)
		a[i] = v;
	return a;
}

refused(t: ref T, e: string, what: string)
{
	t.assert(e != "", what + " is refused");
	if(e != "")
		t.log(what + ": " + e);
}

testGemmBounds(t: ref T)
{
	one := reals(1, 1.0);
	a16 := reals(16, 1.0);
	# guard: an array allocated after the short one, which a write past it lands in
	c := reals(1, 7.0);
	guard := reals(64, 5.0);

	refused(t, gemm('N','N', 16, 1, 1, 1.0, a16, 16, one, 1, 0.0, c, 16),
		"sixteen rows into a c of one element");
	refused(t, gemm('N','N', 16, 1, 1, 1.0, one, 16, one, 1, 0.0, reals(16, 0.0), 16),
		"sixteen rows from an a of one element");
	refused(t, gemm('N','N', 2, 2, 1, 1.0, reals(2, 1.0), 2, reals(2, 1.0), 1, 0.0, reals(2, 0.0), 2),
		"two columns of two rows into a c of two elements");
	refused(t, gemm('N','N', 1, 1, 16, 1.0, a16, 1, one, 16, 0.0, c, 1),
		"sixteen rows from a b of one element");

	# a nil: C := alpha*B + beta*C, and B is m by n
	refused(t, gemm('N','N', 16, 1, 1, 1.0, nil, 0, one, 1, 0.0, reals(16, 0.0), 16),
		"with a nil, sixteen rows from a b of one element");
	refused(t, gemm('N','T', 4, 1, 1, 1.0, nil, 0, one, 1<<20, 0.0, reals(16, 0.0), 16),
		"with a nil, b' read a megabyte apart");
	refused(t, gemm('N','T', 4, 1, 1, 1.0, nil, 0, one, 1<<28, 0.0, reals(16, 0.0), 16),
		"with a nil, b' read further apart");
	refused(t, gemm('N','N', 2, 1, 1, 1.0, nil, 0, nil, 1, 0.0, reals(2, 0.0), 2),
		"a and b both nil with alpha not zero");

	# nil b and nil c
	refused(t, gemm('N','N', 2, 1, 1, 1.0, reals(4, 2.0), 2, nil, 1, 0.0, reals(2, 0.0), 2),
		"a nil b");
	refused(t, gemm('N','N', 2, 1, 1, 1.0, reals(4, 2.0), 2, one, 1, 0.0, nil, 2),
		"a nil c");

	# products that wrap an int
	a8 := reals(8, 2.0);
	b9 := reals(9, 1.0);
	refused(t, gemm('N','N', 1, 1, 9, 1.0, a8, 16r20000001, b9, 9, 0.0, c, 1),
		"lda 16r20000001 with nine columns");
	refused(t, gemm('N','N', 1, 1, 3, 1.0, a8, 16r40000000, b9, 9, 0.0, c, 1),
		"lda 16r40000000 with three columns");
	refused(t, gemm('N','N', 1, 5, 1, 1.0, a8, 1, b9, 1, 0.0, c, 16r40000000),
		"ldc 16r40000000 with five columns");
	refused(t, gemm('N','N', 1, 4097, 1, 1.0, a8, 1, reals(4097, 1.0), 1, 0.0, c, 1<<20),
		"ldc 1<<20 with 4097 columns");
	refused(t, gemm('N','N', 1, 2, 1, 1.0, a8, 1, b9, 1, 0.0, reals(4, 0.0), -1),
		"a negative ldc");
	refused(t, gemm('N','N', -1, 1, 1, 1.0, a8, 1, b9, 1, 0.0, c, 1), "a negative m");
	refused(t, gemm('X','N', 1, 1, 1, 1.0, a8, 1, b9, 1, 0.0, c, 1), "a transa that is none");

	t.assert(c[0] == 7.0, "the short c is as it was");
	ok := 1;
	for(i := 0; i < len guard; i++)
		if(guard[i] != 5.0)
			ok = 0;
	t.assert(ok, "and the array after it");
}

# c := alpha*op(a)*op(b) + beta*c, the slow way
refgemm(ta, tb, m, n, k: int, alpha: real, a: array of real, lda: int,
	b: array of real, ldb: int, beta: real, c: array of real, ldc: int)
{
	for(j := 0; j < n; j++)
		for(i := 0; i < m; i++){
			s := 0.0;
			for(l := 0; l < k; l++){
				av, bv: real;
				if(ta == 'N')
					av = a[i + l*lda];
				else
					av = a[l + i*lda];
				if(tb == 'N')
					bv = b[l + j*ldb];
				else
					bv = b[j + l*ldb];
				s += av*bv;
			}
			c[i + j*ldc] = alpha*s + beta*c[i + j*ldc];
		}
}

seed := 12345;
rnd(): real
{
	seed = (seed*1103515245 + 12345) & 16r7fffffff;
	return real ((seed>>8) % 19 - 9);
}

rmat(n: int): array of real
{
	a := array[n] of real;
	for(i := 0; i < n; i++)
		a[i] = rnd();
	return a;
}

same(a, b: array of real): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

testGemmStillRight(t: ref T)
{
	tr := array[] of {'N', 'T', 'C'};
	bad := 0;
	n := 0;
	for(ia := 0; ia < len tr; ia++)
	for(ib := 0; ib < len tr; ib++)
	for(m := 0; m <= 3; m++)
	for(nn := 0; nn <= 3; nn++)
	for(k := 0; k <= 3; k++)
	for(pad := 0; pad <= 1; pad++){
		ta := tr[ia];
		tb := tr[ib];
		ra := m; ca := k;
		if(ta != 'N'){ ra = k; ca = m; }
		rb := k; cb := nn;
		if(tb != 'N'){ rb = nn; cb = k; }
		# exactly as large as each has to be, and no larger
		lda := ra + pad; ldb := rb + pad; ldc := m + pad;
		if(lda == 0) lda = 1;
		if(ldb == 0) ldb = 1;
		if(ldc == 0) ldc = 1;
		la := 0; if(ra > 0 && ca > 0) la = lda*(ca-1) + ra;
		lb := 0; if(rb > 0 && cb > 0) lb = ldb*(cb-1) + rb;
		lc := 0; if(m > 0 && nn > 0) lc = ldc*(nn-1) + m;
		a := rmat(la);
		b := rmat(lb);
		c := rmat(lc);
		want := array[lc] of real;
		want[0:] = c;
		refgemm(ta, tb, m, nn, k, 2.0, a, lda, b, ldb, 3.0, want, ldc);
		e := gemm(ta, tb, m, nn, k, 2.0, a, lda, b, ldb, 3.0, c, ldc);
		n++;
		if(e != "" || !same(c, want)){
			if(bad++ < 5)
				t.error(sys->sprint("gemm %c %c m=%d n=%d k=%d pad=%d: %s", ta, tb, m, nn, k, pad, e));
		}
	}
	t.asserteq(bad, 0, sys->sprint("%d products in arrays exactly large enough are right", n));

	# the two uses appl/math/linalg.b makes of a nil
	dx := array[] of {1.0, 2.0, 3.0};
	dy := array[] of {10.0, 20.0, 30.0};
	t.assertseq(gemm('N','N', 3, 1, 3, 2.0, nil, 0, dx, 3, 1.0, dy, 3), "", "y += a*x, a nil");
	t.assert(dy[0] == 12.0 && dy[1] == 24.0 && dy[2] == 36.0, "gives y + 2x");
	t.assertseq(gemm('N','N', 3, 1, 3, 0.0, nil, 0, nil, 0, 0.5, dx, 3), "", "x *= a, a and b nil and alpha zero");
	t.assert(dx[0] == 0.5 && dx[1] == 1.0 && dx[2] == 1.5, "gives x/2");
	# and with a nil, b' as it is read
	bt := array[] of {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};	# n=2 rows, m=3 columns
	ct := reals(6, 0.0);
	t.assertseq(gemm('N','T', 3, 2, 9, 1.0, nil, 0, bt, 2, 0.0, ct, 3), "", "c = b', a nil, whatever k");
	t.assert(ct[0] == 1.0 && ct[1] == 3.0 && ct[2] == 5.0 && ct[3] == 2.0 && ct[4] == 4.0 && ct[5] == 6.0,
		"gives the transpose");
	# nothing to do: nil is taken
	t.assertseq(gemm('N','N', 0, 3, 3, 1.0, nil, 0, nil, 0, 0.0, nil, 1), "", "no rows, everything nil");
}

sortok(x: array of real, pi: array of int): string
{
	n := len pi;
	seen := array[len x] of {* => 0};
	for(i := 0; i < n; i++){
		if(pi[i] < 0 || pi[i] >= len x)
			return sys->sprint("pi[%d] is %d", i, pi[i]);
		if(seen[pi[i]]++)
			return sys->sprint("%d is there twice", pi[i]);
	}
	for(i = 1; i < n; i++){
		a := x[pi[i-1]];
		b := x[pi[i]];
		# (no comparison with a NaN here: what Limbo makes of one is
		# another test's business)
		if(math->isnan(a)){
			if(!math->isnan(b))
				return sys->sprint("a NaN before a number at %d", i);
			continue;
		}
		if(math->isnan(b))
			continue;
		if(a > b)
			return sys->sprint("%g before %g at %d", a, b, i);
	}
	return "";
}

ident(n: int): array of int
{
	pi := array[n] of int;
	for(i := 0; i < n; i++)
		pi[i] = i;
	return pi;
}

testSortWords(t: ref T)
{
	x := array[] of {3.0, 1.0, 2.0, 0.5};
	pi := ident(4);
	math->sort(x, pi);
	t.assert(pi[0] == 3 && pi[1] == 1 && pi[2] == 2 && pi[3] == 0,
		sys->sprint("four reals sorted: %d %d %d %d", pi[0], pi[1], pi[2], pi[3]));

	for(n := 0; n < 200; n++){
		y := rmat(n);
		p := ident(n);
		math->sort(y, p);
		e := sortok(y, p);
		if(e != ""){
			t.error(sys->sprint("%d reals: %s", n, e));
			break;
		}
	}
	# a permutation of part of the vector
	z := rmat(100);
	q := array[] of {99, 3, 50, 7, 0, 42, 98, 1};
	math->sort(z, q);
	t.assertseq(sortok(z, q), "", "eight of a hundred sorted");

	# the range check sees every element
	r := ident(8);
	r[5] = 100;
	{
		math->sort(reals(8, 1.0), r);
		t.error("a permutation naming element 100 of 8 was taken");
	} exception {
	"*" =>
		;
	}
	r[5] = -1;
	{
		math->sort(reals(8, 1.0), r);
		t.error("a permutation naming element -1 was taken");
	} exception {
	"*" =>
		;
	}
}

testSortDeep(t: ref T)
{
	N: con 200000;
	nan := math->NaN;

	x := reals(5000, nan);
	p := ident(5000);
	math->sort(x, p);
	t.assertseq(sortok(x, p), "", "5000 NaNs sorted");

	x = array[N] of real;
	for(i := 0; i < N; i++)
		if(i % 3 == 0)
			x[i] = nan;
		else
			x[i] = real (i % 1000);
	p = ident(N);
	t0 := sys->millisec();
	math->sort(x, p);
	t.assertseq(sortok(x, p), "", "numbers and NaNs: the numbers in order, the NaNs after");

	# shapes that split a median-of-three badly
	for(i = 0; i < N; i++)
		if(i < N/2)
			x[i] = real i;
		else
			x[i] = real (N - i);
	p = ident(N);
	math->sort(x, p);
	t.assertseq(sortok(x, p), "", "an organ pipe");
	for(i = 0; i < N; i++)
		x[i] = real ((i * 7919) % 13);
	p = ident(N);
	math->sort(x, p);
	t.assertseq(sortok(x, p), "", "thirteen values");
	for(i = 0; i < N; i++)
		x[i] = rnd();
	p = ident(N);
	# sorted through a permutation already in order, then in reverse
	math->sort(x, p);
	math->sort(x, p);
	t.assertseq(sortok(x, p), "", "a sorted permutation sorted again");
	for(i = 0; i < N/2; i++)
		(p[i], p[N-1-i]) = (p[N-1-i], p[i]);
	math->sort(x, p);
	t.assertseq(sortok(x, p), "", "and reversed");
	dt := sys->millisec() - t0;
	t.log(sys->sprint("five sorts of %d in %d ms", N, dt));
	t.assert(dt < 20000, "in time");
}

testIntWords(t: ref T)
{
	b := array[] of {byte 0, byte 0, byte 0, byte 5, byte 16rff, byte 16rff, byte 16rff, byte 16rfe,
		byte 16r80, byte 0, byte 0, byte 0, byte 16r7f, byte 16rff, byte 16rff, byte 16rff};
	v := array[4] of {* => 99};
	math->import_int(b, v);
	t.asserteq(v[0], 5, "import_int: 5");
	t.asserteq(v[1], -2, "-2");
	t.assert(v[1] < 0 && big v[1] == big -2, "which is negative, as a big too");
	t.asserteq(v[2], -16r7fffffff - 1, "the most negative int");
	t.assert(v[2] < 0, "which is negative");
	t.asserteq(v[3], 16r7fffffff, "the largest");

	out := array[16] of {* => byte 16raa};
	math->export_int(out, v);
	ok := 1;
	for(i := 0; i < len b; i++)
		if(out[i] != b[i])
			ok = 0;
	t.assert(ok, "export_int gives the bytes back");

	rb := math->realbits32(-1.0);
	t.assert(rb < 0, "realbits32(-1.0) is negative");
	t.assert(rb == int 16rBF800000, "and is 16rBF800000");
	t.assert(big rb == big -1082130432, "as a big too");
	t.assert(math->bits32real(rb) == -1.0, "and back");
	t.assert(math->bits64real(math->realbits64(-2.5)) == -2.5, "realbits64 and back");

	# real32 and real round trips
	xs := array[] of {1.5, -2.25, 0.0, 1e10};
	b4 := array[16] of byte;
	b8 := array[32] of byte;
	math->export_real32(b4, xs);
	ys := array[4] of real;
	math->import_real32(b4, ys);
	t.assert(same(xs, ys), "export_real32 and import_real32");
	math->export_real(b8, xs);
	zs := array[4] of real;
	math->import_real(b8, zs);
	t.assert(same(xs, zs), "export_real and import_real");
}

NILCALLS: con 14;

nilcall(i: int)
{
	b := array[8] of byte;
	x := array[1] of real;
	v := array[2] of int;
	case i {
	0 => math->import_int(nil, v);
	1 => math->import_int(b, nil);
	2 => math->import_real32(nil, x);
	3 => math->import_real(b, nil);
	4 => math->export_int(nil, v);
	5 => math->export_real32(b, nil);
	6 => math->export_real(nil, x);
	7 => math->sort(nil, v);
	8 => math->sort(x, nil);
	9 => math->dot(nil, x);
	10 => math->dot(x, nil);
	11 => math->iamax(nil);
	12 => math->norm1(nil);
	13 => math->norm2(nil);
	}
}

testNilArrays(t: ref T)
{
	for(i := 0; i < NILCALLS; i++){
		e := "";
		{
			nilcall(i);
		} exception ex {
		"*" =>
			e = ex;
		}
		t.assertseq(e, "dereference of nil", sys->sprint("nil array, call %d", i));
	}
}

ticker(stop: chan of int, worst: chan of int)
{
	w := 0;
	last := sys->millisec();
	for(;;){
		alt {
		<-stop =>
			worst <-= w;
			return;
		* =>
			;
		}
		sys->sleep(10);
		now := sys->millisec();
		if(now - last - 10 > w)
			w = now - last - 10;
		last = now;
	}
}

testLongBessel(t: ref T)
{
	# small orders, as they were
	t.assert(math->fabs(math->jn(2, 1.0) - 0.1149034849319005) < 1e-12, "jn(2, 1)");
	t.assert(math->fabs(math->yn(2, 1.0) - -1.650682606816254) < 1e-12, "yn(2, 1)");
	t.assert(math->fabs(math->jn(5000, 5000.0) - 0.02607) < 1e-4, "jn(5000, 5000)");

	stop := chan of int;
	worst := chan of int;
	spawn ticker(stop, worst);
	sys->sleep(50);
	t0 := sys->millisec();
	math->jn(200000000, 1.0);
	math->yn(100000000, 3e9);
	dt := sys->millisec() - t0;
	stop <-= 1;
	w := <-worst;
	t.log(sys->sprint("orders of 2e8 and 1e8 took %d ms; a ticker beside them was at worst %d ms late", dt, w));
	if(dt < 400)
		t.skip("the long orders took no time here");
	t.assert(w < dt/2, "other Progs run during a long order");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("GemmBounds", testGemmBounds);
	run("GemmStillRight", testGemmStillRight);
	run("SortWords", testSortWords);
	run("SortDeep", testSortDeep);
	run("IntWords", testIntWords);
	run("NilArrays", testNilArrays);
	run("LongBessel", testLongBessel);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
