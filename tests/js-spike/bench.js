// bench.js - the JavaScript the spike's Dis versions are hand-compiled
// from (spike.b), to time QuickJS on the same work: qjs bench.js
//
// Each benchmark is a pattern page scripts lean on.  The counts are
// spike.b's; keep them equal.

function now() { return Date.now(); }

function bench(name, f) {
	const t = now();
	const r = f();
	print(name + "\t" + (now() - t) + " ms\t" + r);
}

// a property read and written on one object, over and over: the
// inline cache's hit path
bench("prop", function() {
	const o = {x: 1, y: 2};
	let s = 0;
	for (let i = 0; i < 5000000; i++) {
		o.x = o.x + o.y;
		s += o.x & 1;
	}
	return s;
});

// calls to a small function
function add(a, b) { return a + b; }
bench("call", function() {
	let s = 0;
	for (let i = 0; i < 5000000; i++)
		s = add(s, i) | 0;
	return s;
});

// closures made and called
bench("closure", function() {
	function mk(n) { let c = n; return function() { return c++; }; }
	let s = 0;
	for (let i = 0; i < 500000; i++) {
		const f = mk(i);
		s = (s + f() + f()) | 0;
	}
	return s;
});

// small objects allocated, linked, walked
bench("alloc", function() {
	let head = null;
	for (let i = 0; i < 1000000; i++)
		head = {v: i, next: head};
	let s = 0;
	for (let p = head; p; p = p.next)
		s = (s + p.v) | 0;
	return s;
});

// one call site, three receiver classes: methods found on prototypes
bench("poly", function() {
	class A { f() { return 1; } }
	class B { f() { return 2; } }
	class C { f() { return 3; } }
	const a = [new A(), new B(), new C()];
	let s = 0;
	for (let i = 0; i < 3000000; i++)
		s += a[i % 3].f();
	return s;
});

// a string built a piece at a time, then split
bench("string", function() {
	let s = "";
	for (let i = 0; i < 200000; i++)
		s += "ab" + i;
	return s.split("a").length;
});

// floating-point arithmetic in a loop
bench("float", function() {
	let x = 0.5;
	for (let i = 0; i < 5000000; i++)
		x = x * 1.000001 + 0.000001;
	return Math.round(x * 1000);
});
