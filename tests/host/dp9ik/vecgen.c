#include <u.h>
#include <libc.h>
#include <mp.h>
#include <libsec.h>
#include <authsrv.h>

static void
hex(char *name, uchar *p, int n)
{
	int i;
	print("%s ", name);
	for(i = 0; i < n; i++)
		print("%.2ux", p[i]);
	print("\n");
}

void
main(void)
{
	static char *users[] = { "glenda", "alice", "a-much-longer-user-name-xx" };
	static char *pws[] = { "glendapass9f", "correct horse battery", "x" };
	Authkey kc, ks;
	PAKpriv pc, ps;
	uchar yc[PAKYLEN], ys[PAKYLEN];
	Ticket t;
	Authenticator a;
	char buf[MAXTICKETLEN+MAXAUTHENTLEN];
	int i, n, rc, rs;

	for(i = 0; i < nelem(users); i++){
		print("case %d\nuser %s\npassword %s\n", i, users[i], pws[i]);
		passtokey(&kc, pws[i]);
		hex("des", (uchar*)kc.des, DESKEYLEN);
		hex("aes", kc.aes, AESKEYLEN);
		authpak_hash(&kc, users[i]);
		hex("pakhash", kc.pakhash, PAKHASHLEN);
		memmove(&ks, &kc, sizeof ks);
		authpak_new(&pc, &kc, yc, 1);
		authpak_new(&ps, &ks, ys, 0);
		hex("xc", pc.x, PAKXLEN);
		hex("yc", yc, PAKYLEN);
		hex("xs", ps.x, PAKXLEN);
		hex("ys", ys, PAKYLEN);
		rc = authpak_finish(&pc, &kc, ys);
		rs = authpak_finish(&ps, &ks, yc);
		print("finish %d %d\n", rc, rs);
		hex("pakkeyc", kc.pakkey, PAKKEYLEN);
		hex("pakkeys", ks.pakkey, PAKKEYLEN);
		memset(&t, 0, sizeof t);
		t.num = AuthTc;
		memset(t.chal, 'c', CHALLEN);
		strcpy(t.cuid, users[i]);
		strcpy(t.suid, users[i]);
		memset(t.key, 0x5a, NONCELEN);
		t.form = 1;
		n = convT2M(&t, buf, sizeof buf, &kc);
		hex("ticket", (uchar*)buf, n);
		memset(&a, 0, sizeof a);
		a.num = AuthAc;
		memset(a.chal, 'c', CHALLEN);
		memset(a.rand, 0x33, NONCELEN);
		n = convA2M(&a, buf, sizeof buf, &t);
		hex("authenticator", (uchar*)buf, n);
	}
	exits(nil);
}
