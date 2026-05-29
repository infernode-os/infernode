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
	Qcontacts,
	/*
	 * Biometric-protected secret storage. Flat layout (no subdir) so
	 * the same dirtab works on every platform without nested walkers.
	 *
	 *   /phone/bio_status   r   read returns one of:
	 *                              "available\n"   biometric is enrolled
	 *                              "unavailable\n" no biometric / locked out
	 *                              "unsupported\n" platform has no bridge
	 *   /phone/bio_store    w   write payload bytes prefixed by
	 *                            "<name>\n" — the bridge triggers a
	 *                            biometric prompt then commits to the
	 *                            platform keystore. Errors via error().
	 *   /phone/bio_retrieve rw  write "<name>\n" to set the slot, then
	 *                            read to get the stored payload (after
	 *                            biometric prompt). Per-open state via
	 *                            c->aux so concurrent readers don't
	 *                            collide.
	 */
	Qbio_status,
	Qbio_store,
	Qbio_retrieve,
};

#define	BIO_NAME_MAX	64

/* Max contacts snapshot we'll cache per open (single phoneopen / read /
 * close cycle); ample for typical address books. Allocated lazily so
 * a /phone/sms or /phone/ctl session doesn't pay for it. */
#define	CONTACTS_BUFSZ	(64 * 1024)

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
	"calls",    {Qcalls,    0, 0}, 0, 0444,
	"contacts", {Qcontacts, 0, 0}, 0, 0444,
	"bio_status",   {Qbio_status,   0, 0}, 0, 0444,
	"bio_store",    {Qbio_store,    0, 0}, 0, 0222,
	"bio_retrieve", {Qbio_retrieve, 0, 0}, 0, 0666,
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
	case Qcontacts:
		/* Snapshot the address book once per open. Bridge can be
		 * expensive (CNContactStore on iOS prompts and walks); we
		 * pay it on the open, then paginate from c->aux via
		 * readstr with the caller's offset. */
		{
			char *buf = malloc(CONTACTS_BUFSZ);
			int got;
			if(buf == nil)
				break;
			got = phonebridge_contacts(buf, CONTACTS_BUFSZ);
			if(got <= 0){
				free(buf);
				break;
			}
			if(got > CONTACTS_BUFSZ - 1)
				got = CONTACTS_BUFSZ - 1;
			buf[got] = 0;
			c->aux = buf;
		}
		break;
	case Qbio_retrieve:
		/* Two buffers in one allocation:
		 *   [0..BIO_NAME_MAX)        — slot name (set by phonewrite)
		 *   [BIO_NAME_MAX..CONTACTS_BUFSZ) — retrieved payload cache
		 * The name starts empty; phoneread treats an empty name as
		 * "no slot requested" and returns EOF rather than calling
		 * the bridge with a stale or unset slot. */
		{
			char *aux = malloc(CONTACTS_BUFSZ);
			if(aux != nil){
				aux[0] = 0;
				c->aux = aux;
			}
		}
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
	case Qcontacts:
	case Qbio_retrieve:
		if(c->aux != nil){
			free(c->aux);
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

	case Qcontacts:
		/* Cached snapshot allocated in phoneopen; nil on permission
		 * deny / framework unavailable. EOF in that case. */
		if(c->aux == nil)
			return 0;
		return readstr(offset, va, n, (char *)c->aux);

	case Qbio_status:
		switch(phonebridge_bio_available()){
		case 1:  return readstr(offset, va, n, "available\n");
		case 0:  return readstr(offset, va, n, "unavailable\n");
		default: return readstr(offset, va, n, "unsupported\n");
		}

	case Qbio_retrieve:
		/* c->aux is the slot name set by a prior write.  Reading
		 * without writing first returns EOF rather than blocking,
		 * so a stat / mistaken `cat /phone/bio_retrieve` can't
		 * trigger an unwanted biometric prompt. The snapshot is
		 * fetched once on first read after the write (offset 0)
		 * and cached on a second slot in c->aux as `name\0payload`. */
		if(c->aux == nil)
			return 0;
		{
			char *name = (char *)c->aux;
			char *cached = name + BIO_NAME_MAX;
			char errbuf[ERRBUFSZ];	/* Flawfinder: ignore */
			int got;
			if(offset == 0){
				cached[0] = 0;
				errbuf[0] = 0;
				got = phonebridge_bio_retrieve(name,
					cached, CONTACTS_BUFSZ - 1,
					errbuf, sizeof errbuf);
				if(got < 0)
					error(errbuf[0] ? errbuf : "bio_retrieve failed");
				if(got > CONTACTS_BUFSZ - 1)
					got = CONTACTS_BUFSZ - 1;
				cached[got] = 0;
			}
			return readstr(offset, va, n, cached);
		}
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

	case Qbio_store:
		/*
		 * Write payload is "<name>\n<payload-bytes...>". Parse the
		 * name (which can't contain '/' or '\n'), pass the rest as
		 * the payload. Bridge prompts for biometric synchronously
		 * and either succeeds (returns 0) or surfaces a short error.
		 */
		{
			char *body = nil;
			int i;
			for(i = 0; i < n; i++){
				if(buf[i] == '\n'){
					buf[i] = 0;
					body = buf + i + 1;
					break;
				}
			}
			if(body == nil){
				snprint(errbuf, sizeof errbuf,
					"bio_store: missing payload (need '<name>\\n<bytes>')");
				r = -1;
				break;
			}
			if(buf[0] == 0 || strchr(buf, '/') != nil){
				snprint(errbuf, sizeof errbuf,
					"bio_store: invalid slot name");
				r = -1;
				break;
			}
			r = phonebridge_bio_store(buf, body, n - i - 1,
				errbuf, sizeof errbuf);
		}
		break;

	case Qbio_retrieve:
		/*
		 * Write sets the slot name for this open channel. The next
		 * read returns the retrieved payload (bridge prompts and
		 * returns bytes; phoneread caches the result for paging).
		 * Slot name must fit in BIO_NAME_MAX and may not contain
		 * '/' or '\n'.
		 */
		{
			char *aux = c->aux;
			if(aux == nil){
				snprint(errbuf, sizeof errbuf,
					"bio_retrieve: channel has no name slot");
				r = -1;
				break;
			}
			int slen = (int)strlen(buf);
			if(slen >= BIO_NAME_MAX){
				snprint(errbuf, sizeof errbuf,
					"bio_retrieve: slot name too long (max %d)", BIO_NAME_MAX - 1);
				r = -1;
				break;
			}
			if(slen == 0 || strchr(buf, '/') != nil){
				snprint(errbuf, sizeof errbuf,
					"bio_retrieve: invalid slot name");
				r = -1;
				break;
			}
			memmove(aux, buf, slen + 1);
			r = 0;
		}
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
