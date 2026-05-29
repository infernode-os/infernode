/*
 * #f / `phone` — cross-platform phone & SMS device.
 *
 * Exposes the host's telephony and SMS as a Plan-9-style filesystem at
 * /phone (the namespace bind is done by userspace, e.g. lib/sh/profile
 * or a launcher: `bind -a '#f' /phone`). Mirrors the original
 * Hellaphone /phone interface (Plan9-Archive/hellaphone) so existing
 * Limbo tooling that targets it works unchanged.
 *
 *     /phone/ctl       (rw)    radio + routing control verbs
 *     /phone/sms       (rw)    SMS — write to send, read to receive
 *     /phone/phone     (rw)    phone call control / state notifications
 *     /phone/signal    (r)     signal strength (0..100, -1 = unknown)
 *     /phone/status    (r)     radio registration / network status
 *     /phone/calls     (r)     active call list
 *
 * Platform integration lives in emu/<plat>/phonebridge.{c,m} (the
 * declarations in phonebridge.h). This file owns the namespace and
 * the dispatch; the bridge owns the OS calls (iOS: MessageUI/CallKit;
 * Android: Telephony / SmsManager; MacOSX/Linux: stub).
 *
 * Outbound SMS protocol (write to /phone/sms):
 *     "send <number> <body...>\n"   — body may contain spaces; trailing
 *                                     newline is stripped.
 *
 * Outbound dial (write to /phone/phone):
 *     "dial <number>\n"
 *     "answer\n"        (where supported)
 *     "hangup\n"        (where supported)
 *
 * msg9p's `sms` MsgSrc (separate module) reads /phone/sms and forwards
 * incoming messages into /n/msg/notify so Veltro gets unified alerts;
 * this device only owns the device-level surface.
 */

#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"phonebridge.h"

#define	BRIDGE_BUFSZ	4096
#define	ERRBUFSZ	256
#define	QLIMIT		16384	/* per-channel queue cap; 32 SMS records ≈ */

enum
{
	Qdir,
	Qctl,
	Qsms,
	Qphone,
	Qsignal,
	Qstatus,
	Qcalls,
};

/*
 * Per-open-channel listener nodes. phoneopen of /phone/sms or
 * /phone/phone creates a Queue and links a Listener carrying it onto
 * the global per-stream list. phonebridge_post_{sms,call_event} walks
 * the list and qproduces the record onto every Queue — that unblocks
 * every reader sitting in qread, each getting an independent copy.
 *
 * Lock is Inferno's port-style spin lock — safe to acquire from both
 * Inferno kprocs (phoneopen, phoneclose, phoneread) and host threads
 * the bridge calls back on (UIKit main queue, Android Binder, …).
 */
typedef struct Listener Listener;
struct Listener
{
	Queue	*q;
	Listener *next;
};

static Listener *sms_listeners;
static Listener *phone_listeners;
static Lock      listener_lock;

static void
add_listener(Listener **head, Queue *q)
{
	Listener *l = malloc(sizeof *l);
	if(l == nil)
		return;	/* leak: extremely unlikely, dropping new reader is the survivable behaviour */
	l->q = q;
	lock(&listener_lock);
	l->next = *head;
	*head = l;
	unlock(&listener_lock);
}

static void
del_listener(Listener **head, Queue *q)
{
	Listener **pp, *cur;
	lock(&listener_lock);
	for(pp = head; (cur = *pp) != nil; pp = &cur->next){
		if(cur->q == q){
			*pp = cur->next;
			unlock(&listener_lock);
			free(cur);
			return;
		}
	}
	unlock(&listener_lock);
}

static void
listeners_produce(Listener **head, const void *buf, int n)
{
	Listener *cur;
	lock(&listener_lock);
	for(cur = *head; cur != nil; cur = cur->next)
		qproduce(cur->q, (void*)buf, n);
	unlock(&listener_lock);
}

void
phonebridge_post_sms(const char *line, int n)
{
	listeners_produce(&sms_listeners, line, n);
}

void
phonebridge_post_call_event(const char *line, int n)
{
	listeners_produce(&phone_listeners, line, n);
}

static
Dirtab phonetab[] =
{
	".",      {Qdir, 0, QTDIR},  0,  DMDIR|0555,
	"ctl",    {Qctl,    0, 0},   0,  0666,
	"sms",    {Qsms,    0, 0},   0,  0666,
	"phone",  {Qphone,  0, 0},   0,  0666,
	"signal", {Qsignal, 0, 0},   0,  0444,
	"status", {Qstatus, 0, 0},   0,  0444,
	"calls",  {Qcalls,  0, 0},   0,  0444,
};

static void
phoneinit(void)
{
	phonebridge_init();
}

static Chan*
phoneattach(char *spec)
{
	return devattach('f', spec);
}

static Walkqid*
phonewalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, phonetab, nelem(phonetab), devgen);
}

static int
phonestat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, phonetab, nelem(phonetab), devgen);
}

static Chan*
phoneopen(Chan *c, int omode)
{
	c = devopen(c, omode, phonetab, nelem(phonetab), devgen);
	switch((ulong)c->qid.path){
	case Qsms:
		c->aux = qopen(QLIMIT, 0, nil, nil);
		if(c->aux != nil)
			add_listener(&sms_listeners, c->aux);
		break;
	case Qphone:
		c->aux = qopen(QLIMIT, 0, nil, nil);
		if(c->aux != nil)
			add_listener(&phone_listeners, c->aux);
		break;
	}
	return c;
}

static void
phoneclose(Chan *c)
{
	Queue *q;
	if((c->flag & COPEN) == 0)
		return;
	switch((ulong)c->qid.path){
	case Qsms:
		q = c->aux;
		if(q != nil){
			del_listener(&sms_listeners, q);
			qhangup(q, nil);
			qfree(q);
			c->aux = nil;
		}
		break;
	case Qphone:
		q = c->aux;
		if(q != nil){
			del_listener(&phone_listeners, q);
			qhangup(q, nil);
			qfree(q);
			c->aux = nil;
		}
		break;
	}
}

static long
phoneread(Chan *c, void *va, long n, vlong offset)
{
	char buf[BRIDGE_BUFSZ];	/* Flawfinder: ignore — bounded by sizeof buf at every readstr/snprint call below */
	int got;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, phonetab, nelem(phonetab), devgen);

	switch((ulong)c->qid.path){
	case Qctl:
		got = phonebridge_ctl_status(buf, sizeof buf);
		if(got < 0)
			return readstr(offset, va, n, "off\n");
		return readstr(offset, va, n, buf);

	case Qsms:
	case Qphone:
		/*
		 * Block on the per-channel queue until the bridge produces an
		 * incoming record (SMS from carrier, or call-state change).
		 * Format: "from <num> <iso-ts>\n<body>\n" for sms,
		 * "<state> <handle> <iso-ts>\n" for phone events. EOF on
		 * platforms where the bridge can never produce (iOS sms,
		 * macOS/Linux desktop with no #f registered — though those
		 * builds shouldn't even have this device).
		 */
		if(c->aux == nil)
			return 0;
		return qread(c->aux, va, n);

	case Qsignal:
		snprint(buf, sizeof buf, "%d\n", phonebridge_signal());
		return readstr(offset, va, n, buf);

	case Qstatus:
		got = phonebridge_status(buf, sizeof buf);
		if(got < 0)
			return readstr(offset, va, n, "unknown\n");
		return readstr(offset, va, n, buf);

	case Qcalls:
		got = phonebridge_calls(buf, sizeof buf);
		if(got < 0)
			return 0;
		return readstr(offset, va, n, buf);
	}
	return 0;
}

/*
 * Parse "<verb> <rest>" out of a write buffer; returns the verb in
 * place (NUL-terminated) and a pointer to the rest (or NULL if the
 * input was a single token). Mutates `s`.
 */
static char*
splitverb(char *s)
{
	char *p;

	for(p = s; *p && *p != ' ' && *p != '\t'; p++)
		;
	if(*p == 0)
		return nil;
	*p++ = 0;
	while(*p == ' ' || *p == '\t')
		p++;
	return *p ? p : nil;
}

static long
phonewrite(Chan *c, void *va, long n, vlong offset)
{
	USED(offset);
	char *buf, *verb, *rest, errbuf[ERRBUFSZ];	/* Flawfinder: ignore — errbuf bounded by sizeof errbuf at every snprint call below */
	int r;

	if(c->qid.type & QTDIR)
		error(Eperm);

	/*
	 * Copy the write into a NUL-terminated scratch so the parser can
	 * mutate it freely. Limit is BRIDGE_BUFSZ; longer writes are an
	 * error (SMS body fits trivially; longer is almost certainly a
	 * caller bug).
	 *
	 * The waserror() guard is set up AFTER parsing — none of memmove /
	 * splitverb can longjmp, so buf is fully prepared before the
	 * protected region begins. Bridge calls inside the guard may
	 * error(); the handler then runs free(buf) and re-raises. CodeQL
	 * doesn't model setjmp/longjmp and otherwise sees the post-handler
	 * uses of buf as use-after-free; this single-direction structure
	 * makes the dataflow analysable.
	 */
	if(n <= 0)
		return 0;
	if(n >= BRIDGE_BUFSZ)
		error(Etoobig);
	buf = smalloc(n + 1);
	memmove(buf, va, n);
	buf[n] = 0;
	/* Strip a trailing newline so callers can pipe `echo ...`. */
	if(n > 0 && buf[n-1] == '\n')
		buf[n-1] = 0;

	verb = buf;
	rest = splitverb(buf);

	errbuf[0] = 0;
	r = 0;

	if(waserror()){
		free(buf);
		buf = nil;
		nexterror();
		/* nexterror() longjmps to the next-outer waserror handler and
		 * never returns. fns.h declares it without _Noreturn /
		 * __attribute__((noreturn)), so static analysers (CodeQL, in
		 * particular) think the handler can fall through to the final
		 * free(buf) at the bottom of the function and flag it as a
		 * potential double free. The hint below is the local, no-op
		 * way to tell them that path is dead — equivalent to changing
		 * fns.h, without touching every other site in emu/. */
		__builtin_unreachable();
	}

	switch((ulong)c->qid.path){
	case Qctl:
		/* radio on / radio off / mute / unmute / ... — bridge decides */
		r = phonebridge_ctl(verb, rest, errbuf, sizeof errbuf);
		break;

	case Qsms:
		if(strcmp(verb, "send") != 0){
			snprint(errbuf, sizeof errbuf, "sms: usage: send <number> <body>");
			r = -1;
			break;
		}
		if(rest == nil){
			snprint(errbuf, sizeof errbuf, "sms: missing number");
			r = -1;
			break;
		}
		{
			char *body = splitverb(rest);
			if(body == nil){
				snprint(errbuf, sizeof errbuf, "sms: missing body");
				r = -1;
				break;
			}
			r = phonebridge_send_sms(rest, body, errbuf, sizeof errbuf);
		}
		break;

	case Qphone:
		/* dial <num> / answer [id] / hangup [id] */
		r = phonebridge_phone_ctl(verb, rest, errbuf, sizeof errbuf);
		break;

	default:
		snprint(errbuf, sizeof errbuf, "phone: read-only file");
		r = -1;
	}

	poperror();
	free(buf);
	buf = nil;	/* single-owner; helps CodeQL prove no double-free */

	if(r < 0)
		error(errbuf[0] ? errbuf : "phone: bridge error");
	return n;
}

Dev phonedevtab = {
	'f',
	"phone",

	phoneinit,
	phoneattach,
	phonewalk,
	phonestat,
	phoneopen,
	devcreate,
	phoneclose,
	phoneread,
	devbread,
	phonewrite,
	devbwrite,
	devremove,
	devwstat,
};
