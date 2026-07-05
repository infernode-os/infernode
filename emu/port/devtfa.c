/*
 * devtfa — #F, the "2fa" device: a provider-agnostic second-factor
 * challenge-response service, exposed as a small synthetic filesystem.
 *
 *   /dev/2fa/providers   (r)   available backends, e.g. "yubikey-fido2 available=1"
 *   /dev/2fa/ctl         (rw)  write "enroll" (touch) to bind a credential;
 *                              write "clear" to forget it; read status line
 *   /dev/2fa/cred        (r)   the enrolled credential id (hex)
 *   /dev/2fa/derive      (rw)  write a 64-hex (32-byte) salt -> YubiKey returns
 *                              (touch) a device-bound 32-byte secret; read it back as hex
 *
 * Phase 1 of doc/second-factor-auth.md. The actual hardware work is done by the
 * host-side bridge (emu/port/fido2bridge.c via libfido2); this kernel device
 * only relays text. Phase 2 will mix `derive`'s output into the secstore file
 * key in appl/wm/logon.b. Blocking bridge calls run in the writing kproc (a
 * pthread on this build), exactly as devphone blocks on a biometric prompt.
 */
#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"fido2bridge.h"

enum {
	Qdir,
	Qctl,
	Qcred,
	Qderive,
	Qproviders,
};

static Dirtab tfatab[] =
{
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"ctl",		{Qctl, 0},		0,	0666,
	"cred",		{Qcred, 0},		0,	0444,
	"derive",	{Qderive, 0},		0,	0666,
	"providers",	{Qproviders, 0},	0,	0444,
};

#define HEXMAX	1200		/* room for a long credential id in hex */

static Lock	tfalk;
static char	tfacred[HEXMAX];	/* enrolled credential id (hex), or "" */
static char	tfasecret[130];		/* last derived secret (64 hex + nul), or "" */

/* bounded string copy (avoid assuming a particular kernel helper) */
static void
cpystr(char *d, char *s, int dn)
{
	int i;
	for(i = 0; i < dn - 1 && s[i]; i++)
		d[i] = s[i];
	d[i] = 0;
}

static Chan*
tfaattach(char *spec)
{
	return devattach('F', spec);
}

static Walkqid*
tfawalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, tfatab, nelem(tfatab), devgen);
}

static int
tfastat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, tfatab, nelem(tfatab), devgen);
}

static Chan*
tfaopen(Chan *c, int omode)
{
	return devopen(c, omode, tfatab, nelem(tfatab), devgen);
}

static void
tfaclose(Chan *c)
{
	USED(c);
}

static long
tfaread(Chan *c, void *va, long n, vlong offset)
{
	char buf[HEXMAX + 64];
	int avail;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, tfatab, nelem(tfatab), devgen);

	switch((ulong)c->qid.path){
	case Qctl:
		avail = fido2bridge_available();
		lock(&tfalk);
		snprint(buf, sizeof buf, "provider=yubikey-fido2 available=%d enrolled=%d\n",
			avail, tfacred[0] != 0);
		unlock(&tfalk);
		return readstr(offset, va, n, buf);

	case Qproviders:
		avail = fido2bridge_available();
		snprint(buf, sizeof buf, "yubikey-fido2 available=%d\n", avail);
		return readstr(offset, va, n, buf);

	case Qcred:
		lock(&tfalk);
		snprint(buf, sizeof buf, "%s\n", tfacred);
		unlock(&tfalk);
		return readstr(offset, va, n, buf);

	case Qderive:
		lock(&tfalk);
		snprint(buf, sizeof buf, "%s\n", tfasecret);
		unlock(&tfalk);
		return readstr(offset, va, n, buf);
	}
	return 0;
}

static long
tfawrite(Chan *c, void *va, long n, vlong offset)
{
	char *buf, *sp, *pin, errbuf[256];
	char cred[HEXMAX], secret[130];
	int r;

	USED(offset);
	if(c->qid.type & QTDIR)
		error(Eperm);
	if(n <= 0)
		return 0;
	if(n >= HEXMAX)
		error(Etoobig);

	buf = smalloc(n + 1);
	memmove(buf, va, n);
	buf[n] = 0;
	while(n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' '))
		buf[--n] = 0;

	errbuf[0] = 0;
	if(waserror()){
		free(buf);
		nexterror();
	}

	switch((ulong)c->qid.path){
	case Qctl:
		if(strncmp(buf, "enroll", 6) == 0 && (buf[6] == 0 || buf[6] == ' ')){
			/* "enroll" (touch-only) or "enroll <pin>" (UV / AAL3) */
			pin = buf + 6;
			while(*pin == ' ')
				pin++;
			r = fido2bridge_enroll(pin, cred, sizeof cred, errbuf, sizeof errbuf);	/* touch (+PIN if UV) */
			if(r < 0)
				error(errbuf[0] ? errbuf : "enroll failed");
			lock(&tfalk);
			cpystr(tfacred, cred, sizeof tfacred);
			tfasecret[0] = 0;
			unlock(&tfalk);
		}else if(strcmp(buf, "clear") == 0){
			lock(&tfalk);
			tfacred[0] = 0;
			tfasecret[0] = 0;
			unlock(&tfalk);
		}else
			error("usage: write 'enroll' or 'clear' to ctl");
		break;

	case Qderive:
		/* stateless: buf = "<cred-hex> <salt-hex> [pin]" (cred + optional UV PIN
		 * supplied each call, not kernel state) */
		sp = strchr(buf, ' ');
		if(sp == nil)
			error("usage: write '<cred-hex> <salt-hex> [pin]' to derive");
		*sp++ = 0;			/* buf = cred */
		while(*sp == ' ')
			sp++;			/* sp = salt[ pin] */
		pin = strchr(sp, ' ');
		if(pin != nil){
			*pin++ = 0;		/* sp = salt */
			while(*pin == ' ')
				pin++;
		}else
			pin = "";
		USED(cred);
		r = fido2bridge_derive(pin, buf, sp, secret, sizeof secret, errbuf, sizeof errbuf);	/* touch (+PIN if UV) */
		if(r < 0)
			error(errbuf[0] ? errbuf : "derive failed");
		lock(&tfalk);
		cpystr(tfasecret, secret, sizeof tfasecret);
		unlock(&tfalk);
		break;

	default:
		error("read-only file");
	}

	poperror();
	free(buf);
	return n;
}

Dev tfadevtab = {
	'F',
	"2fa",

	devinit,
	tfaattach,
	tfawalk,
	tfastat,
	tfaopen,
	devcreate,
	tfaclose,
	tfaread,
	devbread,
	tfawrite,
	devbwrite,
	devremove,
	devwstat,
};
