implement LinkDigestTest;

#
# The check the loader makes of a function one module imports from
# another (libinterp/link.c, load.c; limbo's sign and dissigs).
#
# It compared two 32-bit numbers, each MD5 of the function type's text
# folded to 32 bits by the compiler.  Two types that differ and fold
# alike take a second to find, so a module declaring one linked to a
# module implementing the other, and the callee read its frame as the
# wrong types.  The builtin modules ($Sys and the rest) were checked the
# same way.
#
# The compiler now writes SHA-256 of the same text for each link and
# import, after the module's source path (HASSIGS in the header's
# flags), the builtins' tables carry theirs, and the loader compares
# them when both sides have them.  A module with none links by the 32
# bits as before, unless the system is strict (emu -L, a 1 written to
# /dev/strictlink, which nothing takes back): then it is refused.
#
# Here: tests/link_digest_a.b's twin is imported as it is declared and
# with a type whose 32 bits are the same (the pair is two scalar types;
# nothing is called through the wrong one); the same through "$self" and
# against Sys->millisec; a module whose digests are taken away; and
# module files whose digest section is cut short, miscounted or changed.
# -d dir: the same files as tests/host/link_digest/mksigs.py made them.
# -r: the switch itself, which leaves this emulator strict
# (tests/host/link_digest_test.sh).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "dis.m";
	dis: Dis;
	Mod: import dis;
include "keyring.m";
	kr: Keyring;

LinkDigestTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
	# for the loads of "$self"
	selftwin:	fn(a: big, p0: big, p1: int, p2: big, p3: big, p4: int, p5: real, p6: int, p7: real, p8: real, p9: big, p10: int): int;
};

# tests/link_digest_a.b as it declares itself
Honest: module
{
	twin:	fn(a: big, p0: big, p1: int, p2: big, p3: big, p4: int, p5: real, p6: int, p7: real, p8: real, p9: big, p10: int): int;
	plain:	fn(x: int): int;
};

# twin with another type, whose 32-bit signature is the same (16r3047a704)
Liar: module
{
	twin:	fn(a: real, p0: big, p1: int, p2: big, p3: real, p4: real, p5: int, p6: int, p7: int, p8: int, p9: real, p10: int): int;
};

# plain with another type, whose 32 bits are not the same
Wrong: module
{
	plain:	fn(x: big): int;
};

Selfhonest: module
{
	selftwin:	fn(a: big, p0: big, p1: int, p2: big, p3: big, p4: int, p5: real, p6: int, p7: real, p8: real, p9: big, p10: int): int;
};

Selfliar: module
{
	selftwin:	fn(a: real, p0: big, p1: int, p2: big, p3: real, p4: real, p5: int, p6: int, p7: int, p8: int, p9: real, p10: int): int;
};

# Sys->millisec as it is, with a type whose 32 bits are another's, and
# with one whose 32 bits are millisec's own (16r616977e8)
Sysm: module
{
	millisec:	fn(): int;
};

Syswrong: module
{
	millisec:	fn(x: int): int;
};

Sysliar: module
{
	millisec:	fn(p0: byte, p1: big, p2: byte, p3: byte, p4: big, p5: big, p6: byte, p7: big, p8: byte, p9: byte, p10: int, p11: real, p12: big, p13: big, p14: byte, p15: byte, p16: real): int;
};

# tests/link_digest_b.b
Bmod: module
{
	init:	fn();
	try:	fn(path: string): string;
};

SRCFILE: con "/tests/link_digest_test.b";

passed := 0;
failed := 0;
skipped := 0;

# A module's import table has the functions the module refers to, so each
# wrong declaration is referred to: in a call that is never made.
never := 0;

patched: string;	# -d: where mksigs.py's files are
ratchet := 0;		# -r

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

selftwin(a: big, nil: big, nil: int, nil: big, nil: big, nil: int, nil: real, nil: int, nil: real, nil: real, nil: big, nil: int): int
{
	return int a;
}

exists(path: string): int
{
	return sys->stat(path).t0 >= 0;
}

# a module of the tests, where the build left it or where it installs
built(name: string): string
{
	p := "/tests/" + name;
	if(exists(p))
		return p;
	return "/dis/tests/" + name;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	b := array[int d.length] of byte;
	if(sys->read(fd, b, len b) != len b)
		return nil;
	return b;
}

# b as a file of this test's in /tmp; nil if it cannot be written
tmpfile(tag: string, b: array of byte): string
{
	path := sys->sprint("/tmp/link_digest_%d_%s.dis", sys->pctl(0, nil), tag);
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil || sys->write(fd, b, len b) != len b)
		return nil;
	return path;
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# is the system strict?  -1 if it does not say
strict(): int
{
	fd := sys->open("/dev/strictlink", Sys->OREAD);
	if(fd == nil)
		return -1;
	buf := array[16] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return -1;
	return int string buf[0:n];
}

setstrict(v: string): int
{
	fd := sys->open("/dev/strictlink", Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte v;
	return sys->write(fd, b, len b);
}

# the module at path with its type digests gone, as one from before
# there were any; (its path, error)
stripped(path, tag: string): (string, string)
{
	(m, err) := dis->loadobj(path);
	if(m == nil)
		return (nil, sys->sprint("loadobj %s: %s", path, err));
	for(i := 0; i < len m.links; i++)
		m.links[i].dig = nil;
	for(i = 0; i < len m.imports; i++)
		for(j := 0; j < len m.imports[i]; j++)
			m.imports[i][j].dig = nil;
	out := tmpfile(tag, dis->writeobj(m));
	if(out == nil)
		return (nil, sys->sprint("cannot write a file in /tmp: %r"));
	return (out, nil);
}

# why path does not load as link_digest_a.b's module; nil if it does and works
tryhonest(path: string): string
{
	h := load Honest path;
	if(h == nil)
		return sys->sprint("%r");
	if(h->plain(41) != 42)
		return "plain(41) is not 42";
	if(h->twin(big 7, big 0, 0, big 0, big 0, 0, 0.0, 0, 0.0, 0.0, big 0, 0) != 7)
		return "twin(7, ...) is not 7";
	return nil;
}

# the digest the compiler should give a type whose text is s
textdigest(s: string): array of byte
{
	b := array of byte s;
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(b, len b, d, nil);
	return d;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

# this module's imports called name: one for each module type above that has it
imports(t: ref T, name: string): list of ref Dis->Import
{
	(m, err) := dis->loadobj(built("link_digest_test.dis"));
	if(m == nil)
		t.fatal("loadobj of this test: " + err);
	l: list of ref Dis->Import;
	for(i := 0; i < len m.imports; i++)
		for(j := 0; j < len m.imports[i]; j++)
			if(m.imports[i][j].name == name)
				l = m.imports[i][j] :: l;
	return l;
}

# The compiler writes a digest for every link and import, and it is
# SHA-256 of the type's text.
testWritten(t: ref T)
{
	for(l := "link_digest_a.dis" :: "link_digest_b.dis" :: "link_digest_test.dis" :: nil; l != nil; l = tl l){
		(m, err) := dis->loadobj(built(hd l));
		if(m == nil){
			t.error(sys->sprint("loadobj %s: %s", hd l, err));
			continue;
		}
		t.assert((m.rt & Dis->HASSIGS) != 0, hd l + ": HASSIGS is set in the header");
		n := 0;
		for(i := 0; i < len m.links; i++)
			if(len m.links[i].dig != Dis->SIGDLEN)
				n++;
		for(i = 0; i < len m.imports; i++)
			for(j := 0; j < len m.imports[i]; j++)
				if(len m.imports[i][j].dig != Dis->SIGDLEN)
					n++;
		t.asserteq(n, 0, hd l + ": links and imports with no digest");
	}
	(m, err) := dis->loadobj(built("link_digest_a.dis"));
	if(m == nil)
		t.fatal("loadobj: " + err);
	for(i := 0; i < len m.links; i++)
		if(m.links[i].name == "plain")
			t.assert(same(m.links[i].dig, textdigest("f(i)i")), "plain's digest is SHA-256 of f(i)i");
		else if(m.links[i].name == "twin")
			t.assert(same(m.links[i].dig, textdigest("f(B,B,i,B,B,i,r,i,r,r,B,i)i")), "twin's digest is SHA-256 of its type's text");
}

# What the rest stands on: each pair of declarations above has one
# 32-bit signature and two digests.  (If the compiler's text for a type
# changes, the pairs no longer collide and this says so.)
testPairs(t: ref T)
{
	for(l := "twin" :: "selftwin" :: "millisec" :: nil; l != nil; l = tl l){
		n := 0;
		for(a := imports(t, hd l); a != nil; a = tl a)
			for(b := tl a; b != nil; b = tl b)
				if((hd a).sig == (hd b).sig && !same((hd a).dig, (hd b).dig))
					n++;
		t.assert(n > 0, hd l + ": two of its declarations have one 32-bit signature and two digests");
	}
}

# (b) types that are the same link, and the functions are called
testSameLinks(t: ref T)
{
	t.assertnil(tryhonest(built("link_digest_a.dis")), "link_digest_a as it declares itself");
	s := load Selfhonest "$self";
	if(s == nil)
		t.fatal(sys->sprint("$self as it declares itself: %r"));
	t.asserteq(s->selftwin(big 9, big 0, 0, big 0, big 0, 0, 0.0, 0, 0.0, 0.0, big 0, 0), 9, "selftwin through $self");
	m := load Sysm "$Sys";
	if(m == nil)
		t.fatal(sys->sprint("$Sys with millisec as it is: %r"));
	t.log(sys->sprint("millisec: %d", m->millisec()));
}

refused(t: ref T, what, err, want: string)
{
	t.assert(contains(err, "link typecheck"), sys->sprint("%s: the error is a link typecheck (%s)", what, err));
	t.assert(contains(err, want), sys->sprint("%s: the error says %q (%s)", what, want, err));
}

# (a) a type whose 32 bits are the same and whose digest is not does not link
testCollisionRefused(t: ref T)
{
	l := load Liar built("link_digest_a.dis");
	err := sys->sprint("%r");
	if(never)
		l->twin(0.0, big 0, 0, big 0, 0.0, 0.0, 0, 0, 0, 0, 0.0, 0);
	if(l != nil)
		t.error("twin declared with another type of the same 32-bit signature linked");
	else
		refused(t, "twin", err, "type digests differ");

	s := load Selfliar "$self";
	err = sys->sprint("%r");
	if(never)
		s->selftwin(0.0, big 0, 0, big 0, 0.0, 0.0, 0, 0, 0, 0, 0.0, 0);
	if(s != nil)
		t.error("selftwin declared with another type of the same 32-bit signature linked through $self");
	else
		refused(t, "selftwin", err, "type digests differ");

	# and a type whose 32 bits differ, as ever
	w := load Wrong built("link_digest_a.dis");
	err = sys->sprint("%r");
	if(never)
		w->plain(big 0);
	if(w != nil)
		t.error("plain declared with another type linked");
	else
		refused(t, "plain", err, "plain");
}

# (d) the same against a builtin module's table
testBuiltin(t: ref T)
{
	w := load Syswrong "$Sys";
	err := sys->sprint("%r");
	if(never)
		w->millisec(0);
	if(w != nil)
		t.error("Sys->millisec declared with another type linked");
	else
		refused(t, "millisec", err, "millisec");

	l := load Sysliar "$Sys";
	err = sys->sprint("%r");
	if(never)
		l->millisec(byte 0, big 0, byte 0, byte 0, big 0, big 0, byte 0, big 0, byte 0, byte 0, 0, 0.0, big 0, big 0, byte 0, byte 0, 0.0);
	if(l != nil)
		t.error("Sys->millisec declared with another type of the same 32-bit signature linked");
	else
		refused(t, "millisec", err, "type digests differ");
}

# what loading a module with no digests should do: link by its 32 bits,
# or be refused where the system is strict
nodigests(t: ref T, what, path: string)
{
	err := tryhonest(path);
	case strict() {
	0 =>
		t.assertnil(err, what + ": links by its 32 bits");
		t.log(what + ": not strict, linked by its 32 bits");
	1 =>
		if(err == nil)
			t.error(what + ": linked in a strict system");
		else{
			refused(t, what, err, "no type digests");
			t.log(what + ": strict, refused: " + err);
		}
	* =>
		t.error(sys->sprint("/dev/strictlink does not say: %r"));
	}
}

# (c) a module from before there were digests
testNoDigests(t: ref T)
{
	(path, err) := stripped(built("link_digest_a.dis"), "strip");
	if(path == nil)
		t.fatal(err);
	b := readfile(path);
	a := readfile(built("link_digest_a.dis"));
	t.assert(b != nil && a != nil && len b < len a, "the copy with no digests is the shorter");
	nodigests(t, "a module with no digests", path);
	sys->remove(path);
}

Bad, Differ, None: con iota;

Variant: adt
{
	name:	string;
	want:	int;
};

variants := array[] of {
	Variant("trunc", Bad),		# the last byte gone
	Variant("nosec", Bad),		# the flag and no section
	Variant("over", Bad),		# one digest too many, counted
	Variant("under", Bad),		# the count one less
	Variant("huge", Bad),		# a count of 2^20
	Variant("flip", Differ),	# a bit of plain's digest changed
	Variant("noflag", None),	# the section and no flag
};

checkvariant(t: ref T, v: Variant, path: string)
{
	if(!exists(path)){
		t.error(path + ": not there");
		return;
	}
	case v.want {
	Bad =>
		h := load Honest path;
		err := sys->sprint("%r");
		if(h != nil)
			t.error(v.name + ": loaded");
		else
			t.assert(contains(err, "bad type digests"), sys->sprint("%s: refused as bad type digests (%s)", v.name, err));
	Differ =>
		err := tryhonest(path);
		if(err == nil)
			t.error(v.name + ": linked");
		else
			refused(t, v.name, err, "type digests differ");
	None =>
		nodigests(t, v.name, path);
	}
}

# (e) a digest section that is not what the header and the tables say
testBadSection(t: ref T)
{
	apath := built("link_digest_a.dis");
	b := readfile(apath);
	(m, err) := dis->loadobj(apath);
	if(b == nil || m == nil)
		t.fatal(sys->sprint("%s: %s", apath, err));
	nd := len m.links;	# it imports nothing
	if(nd > 63 || len m.imports != 0 || int b[4] != 16r80 || (int b[5] & Dis->HASSIGS) == 0)
		t.fatal("link_digest_a.dis is not laid out as this test supposes");
	sec := len b - 1 - nd*Dis->SIGDLEN;	# the count's one byte, then the digests
	t.asserteq(int b[sec], nd, "the section begins with the number of digests");
	head := b[0:sec];
	digs := b[sec+1:];
	plain := -1;
	for(i := 0; i < len m.links; i++)
		if(m.links[i].name == "plain")
			plain = i;
	for(i = 0; i < len variants; i++){
		v := variants[i];
		f: array of byte;
		case v.name {
		"trunc" =>
			f = b[0:len b - 1];
		"nosec" =>
			f = head;
		"over" =>
			f = cat(cat(cat(head, array[] of {byte (nd+1)}), digs), array[Dis->SIGDLEN] of {* => byte 0});
		"under" =>
			f = cat(cat(head, array[] of {byte (nd-1)}), digs);
		"huge" =>
			f = cat(cat(head, array[] of {byte 16rC0, byte 16r10, byte 0, byte 0}), digs);
		"flip" =>
			f = array[len b] of byte;
			f[0:] = b;
			f[sec+1+plain*Dis->SIGDLEN] ^= byte 1;
		"noflag" =>
			f = array[len b] of byte;
			f[0:] = b;
			f[5] &= byte ~Dis->HASSIGS;
		}
		path := tmpfile(v.name, f);
		if(path == nil)
			t.fatal(sys->sprint("cannot write a file in /tmp: %r"));
		checkvariant(t, v, path);
		sys->remove(path);
	}
}

# the same, as tests/host/link_digest/mksigs.py made them
testPatched(t: ref T)
{
	if(patched == nil)
		t.skip("no -d dir: tests/host/link_digest_test.sh makes the files");
	for(i := 0; i < len variants; i++)
		checkvariant(t, variants[i], patched + "/" + variants[i].name + ".dis");
	nodigests(t, "strip", patched + "/strip.dis");
}

# The switch: set by a write of 1, never cleared; then a module with no
# digests is refused whichever side of the link it is on.
testRatchet(t: ref T)
{
	if(!ratchet)
		t.skip("no -r: it leaves the emulator strict (tests/host/link_digest_test.sh)");
	if(strict() != 0)
		t.skip("the emulator is strict already");
	apath := built("link_digest_a.dis");
	(bpath, err) := stripped(built("link_digest_b.dis"), "bstrip");
	if(bpath == nil)
		t.fatal(err);
	(spath, serr) := stripped(apath, "astrip");
	if(spath == nil)
		t.fatal(serr);

	# not strict: a module with no digests is loaded, and loads another
	b := load Bmod bpath;
	if(b == nil)
		t.fatal(sys->sprint("link_digest_b with no digests: %r"));
	b->init();
	t.assertnil(b->try(apath), "not strict: a module with no digests imports from one with them");

	t.assert(setstrict("0") < 0, "a write of 0 is refused");
	t.asserteq(strict(), 0, "and changes nothing");
	t.assert(setstrict("1") > 0, sys->sprint("a write of 1 is taken: %r"));
	t.asserteq(strict(), 1, "the system is strict");
	t.assert(setstrict("0") < 0, "a write of 0 is refused once it is");
	t.assert(setstrict("off") < 0, "and of off");
	t.asserteq(strict(), 1, "it is still strict");

	e := b->try(apath);
	if(e == nil)
		t.error("strict: a module with no digests, loaded before, imported from one with them");
	else
		refused(t, "the importer with no digests", e, "no type digests");
	e = tryhonest(spath);
	if(e == nil)
		t.error("strict: a module with no digests was linked");
	else
		refused(t, "the exporter with no digests", e, "no type digests");
	t.assertnil(tryhonest(apath), "strict: modules with digests link");
	sys->remove(bpath);
	sys->remove(spath);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	dis = load Dis Dis->PATH;
	kr = load Keyring Keyring->PATH;
	if(dis == nil || kr == nil){
		sys->fprint(sys->fildes(2), "cannot load dis or keyring: %r\n");
		raise "fail:cannot load";
	}
	dis->init();

	for(a := tl args; a != nil; a = tl a)
		case hd a {
		"-v" =>
			testing->verbose(1);
		"-r" =>
			ratchet = 1;
		"-d" =>
			if(tl a != nil){
				a = tl a;
				patched = hd a;
			}
		}

	run("Written", testWritten);
	run("Pairs", testPairs);
	run("SameLinks", testSameLinks);
	run("CollisionRefused", testCollisionRefused);
	run("Builtin", testBuiltin);
	run("NoDigests", testNoDigests);
	run("BadSection", testBadSection);
	run("Patched", testPatched);
	run("Ratchet", testRatchet);	# last: it changes the emulator

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
