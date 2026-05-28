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
	return devopen(c, omode, phonetab, nelem(phonetab), devgen);
}

static void
phoneclose(Chan *c)
{
	USED(c);
}

static long
phoneread(Chan *c, void *va, long n, vlong offset)
{
	char buf[BRIDGE_BUFSZ];
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
		/*
		 * Pull the next pending incoming SMS, if any. Bridge returns
		 * 0 on no-traffic (we report EOF — readers can poll or use
		 * /n/msg/notify via the sms MsgSrc). -1 = unsupported on
		 * this platform (e.g. iOS has no inbox API) → empty read.
		 * Format on a hit: "from <num> <iso-timestamp>\n<body>\n".
		 */
		got = phonebridge_recv_sms(buf, sizeof buf);
		if(got <= 0)
			return 0;
		return readstr(offset, va, n, buf);

	case Qphone:
		/* Call-state event stream — see /phone/sms for the same shape. */
		got = phonebridge_recv_call_event(buf, sizeof buf);
		if(got <= 0)
			return 0;
		return readstr(offset, va, n, buf);

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
	char *buf, *verb, *rest, errbuf[ERRBUFSZ];
	int r;

	if(c->qid.type & QTDIR)
		error(Eperm);

	/*
	 * Copy the write into a NUL-terminated scratch so the parser can
	 * mutate it freely. Limit is BRIDGE_BUFSZ; longer writes are an
	 * error (SMS body fits trivially; longer is almost certainly a
	 * caller bug).
	 */
	if(n <= 0)
		return 0;
	if(n >= BRIDGE_BUFSZ)
		error(Etoobig);
	buf = smalloc(n + 1);
	if(waserror()){
		free(buf);
		nexterror();
	}
	memmove(buf, va, n);
	buf[n] = 0;
	/* Strip a trailing newline so callers can pipe `echo ...`. */
	if(n > 0 && buf[n-1] == '\n')
		buf[n-1] = 0;

	verb = buf;
	rest = splitverb(buf);

	errbuf[0] = 0;
	r = 0;

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
