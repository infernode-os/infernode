implement AuditProv;

#
# auditprov - agent-provenance emitter for the tamper-evident audit log.
#
# Composition, not mechanism: payloads (prompts, tool arguments and
# results, completions) go to a write-once venti content store
# (ventisrv(8)) as vac hash trees; the audit record carries the entry
# score plus a SHA-256 of the raw payload. The score is the locator
# (venti mechanism, SHA-1); the SHA-256 is the integrity pin, sealed
# into the SHA-256 hash chain by auditfs — so a chosen-prefix SHA-1
# collision cannot equivocate what an agent was prompted with or did.
#
# Loosely coupled like audit(2): no store attached -> records still
# seal with content=unstored; no audit sink -> log() returns -1 and
# the caller decides (fail-closed under Audit->ONFILE).
#
# See docs/compliance/audit-log-design.md §8.
#

include "sys.m";
	sys: Sys;

include "dial.m";
	dial: Dial;

include "keyring.m";
	kr: Keyring;

include "lock.m";
	lock: Lock;
	Semaphore: import lock;

include "venti.m";
	venti: Venti;
	Score, Session, Entry, Entrysize, Datatype, Dirtype: import venti;

include "vac.m";
	vac: Vac;
	File, Vacfile: import vac;

include "audit.m";
	audit: Audit;

include "auditprov.m";

session: ref Session;
sema: ref Semaphore;

init(): string
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	if(dial == nil)
		return sys->sprint("load dial: %r");
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return sys->sprint("load keyring: %r");
	lock = load Lock Lock->PATH;
	if(lock == nil)
		return sys->sprint("load lock: %r");
	venti = load Venti Venti->PATH;
	if(venti == nil)
		return sys->sprint("load venti: %r");
	venti->init();
	vac = load Vac Vac->PATH;
	if(vac == nil)
		return sys->sprint("load vac: %r");
	vac->init();
	audit = load Audit Audit->PATH;
	if(audit == nil)
		return sys->sprint("load audit: %r");
	audit->init();
	sema = Semaphore.new();
	return nil;
}

resolveaddr(addr: string): string
{
	if(addr != nil && addr != "")
		return addr;
	fd := sys->open("/env/auditventi", Sys->OREAD);
	if(fd != nil) {
		buf := array[128] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0) {
			s := string buf[:n];
			# environment values may carry a trailing NUL or newline
			while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == 0))
				s = s[:len s - 1];
			if(s != "")
				return s;
		}
	}
	return DEFADDR;
}

dialraw(addr: string): (ref Sys->FD, string)
{
	a := dial->netmkaddr(resolveaddr(addr), "net", "venti");
	cc := dial->dial(a, nil);
	if(cc == nil)
		return (nil, sys->sprint("dial %s: %r", a));
	return (cc.dfd, nil);
}

attachfd(fd: ref Sys->FD): string
{
	s := Session.new(fd);
	if(s == nil)
		return sys->sprint("venti handshake: %r");
	session = s;
	return nil;
}

attach(addr: string): string
{
	(fd, err) := dialraw(addr);
	if(err != nil)
		return err;
	return attachfd(fd);
}

attached(): int
{
	return session != nil;
}

hexstr(d: array of byte): string
{
	s := "";
	for(i := 0; i < len d; i++)
		s += sys->sprint("%.2ux", int d[i]);
	return s;
}

sha256(data: array of byte): string
{
	digest := array[Keyring->SHA256dlen] of byte;
	kr->sha256(data, len data, digest, nil);
	return hexstr(digest);
}

put(data: array of byte): (string, string, string)
{
	sha := sha256(data);
	if(len data > MAXPAYLOAD)
		return (nil, sha, "payload exceeds audit limit");
	if(session == nil)
		return (nil, sha, "no content store attached");

	sema.obtain();
	{
		f := File.new(session, Datatype, Vac->Dsize);
		if(f == nil) {
			sema.release();
			return (nil, sha, sys->sprint("vac file: %r"));
		}
		for(o := 0; o < len data; o += Vac->Dsize) {
			e := o + Vac->Dsize;
			if(e > len data)
				e = len data;
			if(f.write(data[o:e]) < 0) {
				sema.release();
				return (nil, sha, sys->sprint("store write: %r"));
			}
		}
		ent := f.finish();
		if(ent == nil) {
			sema.release();
			return (nil, sha, sys->sprint("store flush: %r"));
		}
		(ok, score) := session.write(Dirtype, ent.pack());
		if(ok < 0) {
			sema.release();
			return (nil, sha, sys->sprint("store entry: %r"));
		}
		if(session.sync() < 0) {
			sema.release();
			return (nil, sha, sys->sprint("store sync: %r"));
		}
		sema.release();
		return (score.text(), sha, nil);
	} exception {
	* =>
		sema.release();
		return (nil, sha, "content store failed");
	}
}

get(scorestr: string): (array of byte, string)
{
	if(session == nil)
		return (nil, "no content store attached");
	(ok, score) := Score.parse(scorestr);
	if(ok != 0)
		return (nil, "bad score: " + scorestr);

	sema.obtain();
	{
		d := session.read(score, Dirtype, Entrysize);
		if(d == nil) {
			sema.release();
			return (nil, sys->sprint("read entry: %r"));
		}
		ent := Entry.unpack(d);
		if(ent == nil) {
			sema.release();
			return (nil, sys->sprint("unpack entry: %r"));
		}
		if(ent.size < big 0 || ent.size > big MAXPAYLOAD) {
			sema.release();
			return (nil, "payload size outside audit limit");
		}
		nbytes := int ent.size;
		if(big nbytes != ent.size) {
			sema.release();
			return (nil, "payload size cannot be represented");
		}
		data := array[nbytes] of byte;
		vf := Vacfile.new(session, ent);
		o := 0;
		while(o < len data) {
			n := vf.read(data[o:], len data - o);
			if(n < 0) {
				sema.release();
				return (nil, sys->sprint("read payload: %r"));
			}
			if(n == 0)
				break;
			o += n;
		}
		sema.release();
		if(o != len data)
			return (nil, sys->sprint("short payload: %d of %d bytes", o, len data));
		return (data, nil);
	} exception {
	* =>
		sema.release();
		return (nil, "content store failed");
	}
}

log(source, event, msg: string, payload: array of byte): int
{
	if(payload == nil)
		return audit->log(source, event, msg);

	(score, sha, err) := put(payload);
	if(err != nil) {
		if(audit->log(source, event, msg + " content=unstored sha256=" + sha +
		    " size=" + string len payload) < 0)
			return -1;
		return -2;
	}
	return audit->log(source, event, msg + " content=" + score + " sha256=" + sha +
	    " size=" + string len payload);
}
