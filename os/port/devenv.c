/*
 * IMPORTED from upstream Inferno (inferno-os/inferno-os), os/port/devenv.c.
 * The NOTICE at that tree's root states "The bulk of the tree is
 * covered by the permissive MIT licence"; this tree's LICENSE already
 * credits Vita Nuova's revisions.
 *
 * #e -- the environment, as files.
 *
 * Inferno has no environ array: a variable IS a file under /env, and
 * inheritance is a namespace operation rather than a copy. That is why
 * the shell can set a variable in a subshell without it leaking back,
 * and why "cat /env/path" works -- the environment is not a special
 * case of anything, it is a file server.
 *
 * The pieces it needs were already here: Egrp and Evalue are declared
 * in portdat.h, and pgrp.c allocates and closes environment groups. Only
 * the device was missing, so until now a Limbo program could not read
 * or set a variable at all.
 *
 * Dialect: qlock(eg) and friends became qlock(&eg->l), matching the
 * convention the rest of os/port follows here -- Egrp names its QLock
 * "l" and its Ref "r". See the decision in os/bcm2837/README.md for
 * why this is done by hand rather than with -fplan9-extensions.
 */
/*
 *	devenv - environment
 */
#include "u.h"
#include "../port/lib.h"
#include "../port/error.h"
#include "mem.h"
#include	"dat.h"
#include	"fns.h"

static void envremove(Chan*);

enum
{
	Maxenvsize = 16300,
};

static int
envgen(Chan *c, char*, Dirtab*, int, int s, Dir *dp)
{
	Egrp *eg;
	Evalue *e;

	if(s == DEVDOTDOT){
		devdir(c, c->qid, "#e", 0, eve, DMDIR|0775, dp);
		return 1;
	}
	eg = up->env->egrp;
	qlock(&eg->l);
	for(e = eg->entries; e != nil && s != 0; e = e->next)
		s--;
	if(e == nil) {
		qunlock(&eg->l);
		return -1;
	}
	/* make sure name string continues to exist after we release lock */
	kstrcpy(up->genbuf, e->var, sizeof up->genbuf);
	devdir(c, e->qid, up->genbuf, e->len, eve, 0666, dp);
	qunlock(&eg->l);
	return 1;
}

static Chan*
envattach(char *spec)
{
	if(up->env == nil || up->env->egrp == nil)
		error(Enodev);
	return devattach('e', spec);
}

static Walkqid*
envwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, 0, 0, envgen);
}

static int
envstat(Chan *c, uchar *db, int n)
{
	if(c->qid.type & QTDIR)
		c->qid.vers = up->env->egrp->vers;
	return devstat(c, db, n, 0, 0, envgen);
}

static Chan *
envopen(Chan *c, int mode)
{
	Egrp *eg;
	Evalue *e;
	
	if(c->qid.type & QTDIR) {
		if(mode != OREAD)
			error(Eperm);
		c->mode = mode;
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}
	eg = up->env->egrp;
	qlock(&eg->l);
	for(e = eg->entries; e != nil; e = e->next)
		if(e->qid.path == c->qid.path)
			break;
	if(e == nil) {
		qunlock(&eg->l);
		error(Enonexist);
	}
	if((mode & OTRUNC) && e->val) {
		free(e->val);
		e->val = 0;
		e->len = 0;
		e->qid.vers++;
	}
	qunlock(&eg->l);
	c->mode = openmode(mode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
envcreate(Chan *c, char *name, int mode, ulong)
{
	Egrp *eg;
	Evalue *e, **le;

	if(c->qid.type != QTDIR)
		error(Eperm);
	if(strlen(name) >= sizeof(up->genbuf))
		error("name too long");	/* needs to fit for stat */
	mode = openmode(mode);
	eg = up->env->egrp;
	qlock(&eg->l);
	if(waserror()){
		qunlock(&eg->l);
		nexterror();
	}
	for(le = &eg->entries; (e = *le) != nil; le = &e->next)
		if(strcmp(e->var, name) == 0)
			error(Eexist);
	e = smalloc(sizeof(Evalue));
	e->var = smalloc(strlen(name)+1);
	strcpy(e->var, name);
	e->val = 0;
	e->len = 0;
	e->qid.path = ++eg->path;
	e->next = nil;
	e->qid.vers = 0;
	*le = e;
	c->qid = e->qid;
	eg->vers++;
	poperror();
	qunlock(&eg->l);
	c->offset = 0;
	c->flag |= COPEN;
	c->mode = mode;
}

static void
envclose(Chan *c)
{
	if(c->flag & CRCLOSE)
		envremove(c);
}

static long
envread(Chan *c, void *a, long n, vlong offset)
{
	Egrp *eg;
	Evalue *e;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, 0, 0, envgen);
	eg = up->env->egrp;
	qlock(&eg->l);
	if(waserror()){
		qunlock(&eg->l);
		nexterror();
	}
	for(e = eg->entries; e != nil; e = e->next)
		if(e->qid.path == c->qid.path)
			break;
	if(e == nil)
		error(Enonexist);
	if(offset > e->len)	/* protects against overflow converting vlong to ulong */
		n = 0;
	else if(offset + n > e->len)
		n = e->len - offset;
	if(n <= 0)
		n = 0;
	else
		memmove(a, e->val+offset, n);
	poperror();
	qunlock(&eg->l);
	return n;
}

static long
envwrite(Chan *c, void *a, long n, vlong offset)
{
	char *s;
	ulong ve;
	Egrp *eg;
	Evalue *e;

	if(n <= 0)
		return 0;
	ve = offset+n;
	if(ve > Maxenvsize)
		error(Etoobig);
	eg = up->env->egrp;
	qlock(&eg->l);
	if(waserror()){
		qunlock(&eg->l);
		nexterror();
	}
	for(e = eg->entries; e != nil; e = e->next)
		if(e->qid.path == c->qid.path)
			break;
	if(e == nil)
		error(Enonexist);
	if(ve > e->len) {
		s = smalloc(ve);
		memmove(s, e->val, e->len);
		if(e->val != nil)
			free(e->val);
		e->val = s;
		e->len = ve;
	}
	memmove(e->val+offset, a, n);
	e->qid.vers++;
	poperror();
	qunlock(&eg->l);
	return n;
}

static void
envremove(Chan *c)
{
	Egrp *eg;
	Evalue *e, **l;

	if(c->qid.type & QTDIR)
		error(Eperm);
	eg = up->env->egrp;
	qlock(&eg->l);
	for(l = &eg->entries; (e = *l) != nil; l = &e->next)
		if(e->qid.path == c->qid.path)
			break;
	if(e == nil) {
		qunlock(&eg->l);
		error(Enonexist);
	}
	*l = e->next;
	eg->vers++;
	qunlock(&eg->l);
	free(e->var);
	if(e->val != nil)
		free(e->val);
	free(e);
}

Dev envdevtab = {
	'e',
	"env",

	devreset,
	devinit,
	devshutdown,
	envattach,
	envwalk,
	envstat,
	envopen,
	envcreate,
	envclose,
	envread,
	devbread,
	envwrite,
	devbwrite,
	envremove,
	devwstat
};

/*
 * kernel interface to environment variables
 */
Egrp*
newegrp(void)
{
	Egrp	*e;

	e = smalloc(sizeof(Egrp));
	e->r.ref = 1;
	return e;
}

void
closeegrp(Egrp *e)
{
	Evalue *el, *nl;

	if(e == nil || decref(&e->r) != 0)
		return;
	for (el = e->entries; el != nil; el = nl) {
		free(el->var);
		if (el->val)
			free(el->val);
		nl = el->next;
		free(el);
	}
	free(e);
}

void
egrpcpy(Egrp *to, Egrp *from)
{
	Evalue *e, *ne, **last;

	if(from == nil)
		return;
	last = &to->entries;
	qlock(&from->l);
	for (e = from->entries; e != nil; e = e->next) {
		ne = smalloc(sizeof(Evalue));
		ne->var = smalloc(strlen(e->var)+1);
		strcpy(ne->var, e->var);
		if (e->val) {
			ne->val = smalloc(e->len);
			memmove(ne->val, e->val, e->len);
			ne->len = e->len;
		}
		ne->qid.path = ++to->path;
		*last = ne;
		last = &ne->next;
	}
	qunlock(&from->l);
}

void
ksetenv(char *var, char *val, int)
{
	Chan *c;
	char buf[2*KNAMELEN];

	snprint(buf, sizeof(buf), "#e/%s", var);
	if(waserror())
		return;
	c = namec(buf, Acreate, OWRITE, 0600);
	poperror();
	if(!waserror()){
		if(!waserror()){
			devtab[c->type]->write(c, val, strlen(val), 0);
			poperror();
		}
		poperror();
	}
	cclose(c);
}
