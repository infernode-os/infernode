implement BrickD2Test;

#
# The brick(1) D2 commander against a synthetic file tree.  A renewal is
# parked in its grant read, release overtakes it, then the old grant is let
# go: no command after release may reassert the output.
#

include "sys.m";
	sys: Sys;
	FileIO, Rread: import Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "keyring.m";
	keyring: Keyring;

Brick: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

AuthFactotum: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

BrickD2Test: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/brick_d2_test.b";

mkdir(p: string): int
{
	fd := sys->create(p, Sys->OREAD, Sys->DMDIR|8r700);
	return fd != nil;
}

putfile(p, s: string): int
{
	fd := sys->create(p, Sys->OWRITE, 8r600);
	if(fd == nil)
		return 0;
	b := array of byte s;
	return sys->write(fd, b, len b) == len b;
}

writefile(p, s: string): string
{
	fd := sys->open(p, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open %s: %r", p);
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write %s: %r", p);
	return nil;
}

readfile(p: string): string
{
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

exists(p: string): int
{
	(ok, nil) := sys->stat(p);
	return ok >= 0;
}

runid(): string
{
	fd := sys->open("/dev/time", Sys->OREAD);
	b := array[32] of byte;
	n := 0;
	if(fd != nil)
		n = sys->read(fd, b, len b);
	if(n <= 0)
		return string sys->millisec();
	s := string b[0:n];
	if(s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

waitfile(p: string, ms: int): int
{
	for(n := 0; n < ms; n += 10){
		if(exists(p))
			return 1;
		sys->sleep(10);
	}
	return 0;
}

sliced(s: string, off, n: int): array of byte
{
	b := array of byte s;
	if(off >= len b)
		return nil;
	if(off + n < len b)
		return b[off:off+n];
	return b[off:];
}

server(clone, grant, cmd: ref FileIO, parked: chan of Rread,
	commands: chan of string, failnext: chan of string, quit: chan of int)
{
	ngrants := 0;
	fail: string;
	for(;;) alt {
	<-quit =>
		return;
	fail = <-failnext =>
		;
	(off, n, nil, rc) := <-clone.read =>
		if(rc != nil)
			rc <-= (sliced("device boot 1 100\n", off, n), nil);
	(nil, b, nil, wc) := <-clone.write =>
		if(wc != nil)
			wc <-= (len b, nil);
	(off, n, nil, rc) := <-grant.read =>
		if(rc == nil)
			continue;
		ngrants++;
		if(ngrants == 3)
			parked <-= rc;
		else
			rc <-= (sliced(sys->sprint("device boot %d\n", ngrants), off, n), nil);
	(nil, b, nil, wc) := <-grant.write =>
		if(wc != nil)
			wc <-= (len b, nil);
	(nil, b, nil, wc) := <-cmd.write =>
		if(wc == nil)
			continue;
		if(fail != nil){
			wc <-= (0, fail);
			fail = nil;
		}else{
			wc <-= (len b, nil);
			commands <-= string b;
		}
	(nil, nil, nil, rc) := <-cmd.read =>
		if(rc != nil)
			rc <-= (nil, "write only");
	}
}

runbrick(brick: Brick, args: list of string, done: chan of string)
{
	e: string;
	{
		brick->init(nil, args);
	} exception x {
	"*" =>
		e = x;
	}
	done <-= e;
}

nextcmd(c: chan of string, ms: int): string
{
	tick := chan of int;
	spawn timer(tick, ms);
	alt {
	s := <-c =>
		return s;
	<-tick =>
		return nil;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 => ;
	* => ;
	}
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

hex(a: array of byte): string
{
	digits := "0123456789abcdef";
	s := array[2*len a] of byte;
	for(i := 0; i < len a; i++){
		s[2*i] = byte digits[int a[i] >> 4 & 16rf];
		s[2*i+1] = byte digits[int a[i] & 16rf];
	}
	return string s;
}

brickslot(keydir: string): string
{
	d := array[Keyring->SHA256dlen] of byte;
	b := array of byte keydir;
	keyring->sha256(b, len b, d, nil);
	return hex(d);
}

testReleaseBarrier(t: ref T)
{
	brick := load Brick "/dis/brick.dis";
	if(brick == nil)
		t.fatal(sys->sprint("load brick: %r"));
	# Refused before any key or device path is touched; otherwise a zero
	# sleep renewal loop can consume the commander.
	badlease := chan of string;
	spawn runbrick(brick, "brick" :: "d2" :: "-l" :: "1" :: "/no" :: "/no" :: nil, badlease);
	le := <-badlease;
	# brick prints the detailed reason on stderr and raises only the stable
	# command status, so the in-process harness can assert the early D2 refusal
	# but cannot recover the prose diagnostic.
	t.assert(le == "fail:d2",
		"a lease below the safe grant interval is refused before setup: " + le);
	base := "/tmp/brick_d2_test." + runid();
	bmnt := base + "/brick";
	d2 := bmnt + "/d2";
	srv := base + "/srv";
	keys := base + "/keys";
	out := base + "/out";
	if(!mkdir(base) || !mkdir(bmnt) || !mkdir(d2) || !mkdir(srv) ||
	   !mkdir(keys) || !mkdir(out))
		t.fatal(sys->sprint("make test tree: %r"));
	if(!putfile(d2 + "/status", "pwm/2 max 1000\n") ||
	   !putfile(d2 + "/clone", "") || !putfile(d2 + "/grant", "") ||
	   !putfile(d2 + "/cmd", ""))
		t.fatal(sys->sprint("make test files: %r"));
	if(!exists("/mnt/factotum") && !mkdir("/mnt/factotum"))
		t.fatal(sys->sprint("make factotum mount point: %r"));
	authfactotum := load AuthFactotum "/dis/auth/factotum.dis";
	if(authfactotum == nil)
		t.fatal(sys->sprint("load factotum: %r"));
	authfactotum->init(nil,
		"auth/factotum" :: "-f" :: base + "/factotum.keys" ::
		"-p" :: "testpass" :: nil);
	if(!waitfile("/mnt/factotum/ctl", 2000))
		t.fatal("factotum ctl did not appear");
	keyline := "key proto=pass service=brick role=client slot=" +
		brickslot(keys) + " purpose=d2 user=brick !password=" +
		"0000000000000000000000000000000000000000000000000000000000000000";
	t.assertnil(writefile("/mnt/factotum/ctl", keyline), "install D2 key in factotum");
	if(sys->bind("#s", srv, Sys->MREPL) < 0)
		t.fatal(sys->sprint("bind srv: %r"));
	clone := sys->file2chan(srv, "brickd2clone");
	grant := sys->file2chan(srv, "brickd2grant");
	cmd := sys->file2chan(srv, "brickd2cmd");
	if(clone == nil || grant == nil || cmd == nil)
		t.fatal(sys->sprint("file2chan: %r"));
	if(sys->bind(srv + "/brickd2clone", d2 + "/clone", Sys->MREPL) < 0 ||
	   sys->bind(srv + "/brickd2grant", d2 + "/grant", Sys->MREPL) < 0 ||
	   sys->bind(srv + "/brickd2cmd", d2 + "/cmd", Sys->MREPL) < 0)
		t.fatal(sys->sprint("bind D2 files: %r"));

	parked := chan[1] of Rread;
	commands := chan[16] of string;
	failnext := chan[1] of string;
	quit := chan of int;
	spawn server(clone, grant, cmd, parked, commands, failnext, quit);
	done := chan of string;
	spawn runbrick(brick,
		"brick" :: "d2" :: "-d" :: keys :: "-l" :: "500" :: bmnt :: out :: nil,
		done);
	berr := <-done;
	t.assert(berr == nil, "brick d2 starts: " + berr);
	if(berr != nil)
		return;
	if(!waitfile(out + "/ctl", 2000) || !waitfile(out + "/pwm.2", 2000))
		t.fatal("commander files did not appear");

	t.assertnil(writefile(out + "/ctl", "arm"), "arm");
	a := nextcmd(commands, 2000);
	t.assert(a != nil && has(a, " arm "), "arm reached the device");
	t.assertnil(writefile(out + "/pwm.2", "42"), "set 42");
	s := nextcmd(commands, 2000);
	t.assert(s != nil && has(s, " set ") && has(s, "pwm/2=42"), "set reached the device");

	# The next renewal is now waiting in grant.  Release must not wait for
	# it, and after the parked read resumes that old snapshot must vanish.
	pr: Rread;
	tick := chan of int;
	spawn timer(tick, 2000);
	alt {
	pr = <-parked => ;
	<-tick => t.fatal("renewal did not reach the parked grant");
	}
	t.assertnil(writefile(out + "/pwm.2", "release"), "release while renewal is parked");
	r := nextcmd(commands, 2000);
	t.assert(r != nil && has(r, " release "), "release overtook the renewal");
	pr <-= (array of byte "device boot 3\n", nil);
	sys->sleep(300);
	alt {
	late := <-commands =>
		t.assert(!has(late, " set "), "no stale set after release: " + late);
	* =>
		;
	}

	# A failed value write is not retained as hidden staged authority, and
	# a transport failure makes the local state immediately non-live.
	failnext <-= "link down";
	e := writefile(out + "/pwm.2", "99");
	t.assert(e != nil, "failed device command is reported");
	t.assert(has(readfile(out + "/pwm.2"), "released"), "failed value rolled back");
	ctl := readfile(out + "/ctl");
	t.assert(has(ctl, "failsafe") && has(ctl, "link"), "transport loss disarms local state: " + ctl);
	quit <-= 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	keyring = load Keyring Keyring->PATH;
	if(sys == nil || testing == nil || keyring == nil)
		raise "fail:load";
	testing->init();
	t := testing->newTsrc("ReleaseBarrier", SRCFILE);
	{
		testReleaseBarrier(t);
	} exception e {
	"fail:fatal" => ;
	"fail:skip" => ;
	"*" => t.error("exception: " + e);
	}
	failed := !testing->done(t);
	if(testing->summary(!failed, failed, 0) > 0)
		raise "fail:tests failed";
}
