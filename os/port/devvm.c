/*
 * #V -- the Dis VMs (#944).
 *
 * The kernel runs one Dis VM per core: each with its own interpreter,
 * heap, collector and modules, so a program in one VM runs alongside a
 * program in another on a different core. Programs in different VMs
 * share nothing but the kernel: files, pipes, 9P, served names.
 *
 *	vm/ctl		read: "vms N max M", how many have been started
 *	vm/N/run	write "cmd arg ...": run cmd in VM N with the writer's
 *			namespace, environment and file descriptors; read:
 *			the pid it was given
 *	vm/N/status	read: "vm N progs P heap CUR MAX"
 *
 * Which VM a program goes to is policy, and is not decided here: a
 * program or a shell script writes to the VM it chooses. VM 0 is the
 * boot VM and the desktop's, and the only one with $Tk and $Draw.
 *
 *	bind -a '#V' /dev
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	<interp.h>

enum
{
	Qroot,
	Qvm,
	Qctl,
	Qndir,
	Qrun,
	Qstatus,

	Maxargs	= 32,
};

#define	QID(n, t)	((((n)+1)<<8) | (t))
#define	QVM(path)	((int)((path)>>8) - 1)
#define	QTYPE(path)	((int)((path) & 0xFF))

static int
vmgen(Chan *c, char *name, Dirtab *tab, int ntab, int i, Dir *dp)
{
	Qid q;
	int t, n;

	USED(name);
	USED(tab);
	USED(ntab);
	t = QTYPE(c->qid.path);
	n = QVM(c->qid.path);
	if(i == DEVDOTDOT){
		switch(t){
		case Qroot:
		case Qvm:
			mkqid(&q, Qroot, 0, QTDIR);
			devdir(c, q, "#V", 0, eve, DMDIR|0555, dp);
			return 1;
		case Qndir:
			mkqid(&q, Qvm, 0, QTDIR);
			devdir(c, q, "vm", 0, eve, DMDIR|0555, dp);
			return 1;
		}
		return -1;
	}
	switch(t){
	case Qroot:
		if(i != 0)
			return -1;
		mkqid(&q, Qvm, 0, QTDIR);
		devdir(c, q, "vm", 0, eve, DMDIR|0555, dp);
		return 1;
	case Qvm:
		if(i == 0){
			mkqid(&q, Qctl, 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0444, dp);
			return 1;
		}
		if(i > MAXVM)
			return -1;
		/*
		 * Not a buffer of our own: devdir keeps the pointer, and
		 * devwalk compares the name and devdirread packs it after
		 * we return. One on this stack was dead by then -- listings
		 * showed garbage, and a walk to "1" failed once in 142,000
		 * on the Pi 4's soak. up->genbuf outlives the call, as
		 * devprog's pids do.
		 */
		snprint(up->genbuf, sizeof up->genbuf, "%d", i-1);
		mkqid(&q, QID(i-1, Qndir), 0, QTDIR);
		devdir(c, q, up->genbuf, 0, eve, DMDIR|0555, dp);
		return 1;
	case Qndir:
		switch(i){
		case 0:
			mkqid(&q, QID(n, Qrun), 0, QTFILE);
			devdir(c, q, "run", 0, eve, 0666, dp);
			return 1;
		case 1:
			mkqid(&q, QID(n, Qstatus), 0, QTFILE);
			devdir(c, q, "status", 0, eve, 0444, dp);
			return 1;
		}
		return -1;
	}
	return -1;
}

static Chan*
vmattach(char *spec)
{
	return devattach('V', spec);
}

static Walkqid*
vmwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, vmgen);
}

static int
vmstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, vmgen);
}

static Chan*
vmopen(Chan *c, int omode)
{
	c->aux = nil;		/* run: the pid of the last command written on this fid */
	return devopen(c, omode, nil, 0, vmgen);
}

static void
vmclose(Chan *c)
{
	USED(c);
}

static long
vmread(Chan *c, void *va, long n, vlong off)
{
	char buf[128];
	Vm *v;
	ulong cur, max;
	int i, started;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, vmgen);
	switch(QTYPE(c->qid.path)){
	case Qctl:
		started = 0;
		for(i = 0; i < MAXVM; i++)
			if(vmn(i) != nil)
				started++;
		snprint(buf, sizeof buf, "vms %d max %d\n", started, MAXVM);
		return readstr(off, va, n, buf);
	case Qrun:
		snprint(buf, sizeof buf, "%lud\n", (ulong)(uintptr)c->aux);
		return readstr(off, va, n, buf);
	case Qstatus:
		v = vmn(QVM(c->qid.path));
		if(v == nil)
			snprint(buf, sizeof buf, "vm %d not started\n", QVM(c->qid.path));
		else{
			poolusage(v->vheap, &cur, &max);
			snprint(buf, sizeof buf, "vm %d progs %d heap %lud %lud\n",
				v->id, vmprogs(v), cur, max);
		}
		return readstr(off, va, n, buf);
	}
	error(Egreg);
	return 0;
}

static long
vmwrite(Chan *c, void *va, long n, vlong off)
{
	char *buf, *argv[Maxargs];
	int argc, pid;

	USED(off);
	if(QTYPE(c->qid.path) != Qrun)
		error(Eperm);
	if(n <= 0 || n >= 1024)
		error(Ebadarg);
	buf = smalloc(n+1);
	if(waserror()){
		free(buf);
		nexterror();
	}
	memmove(buf, va, n);
	buf[n] = 0;
	argc = tokenize(buf, argv, nelem(argv));
	if(argc < 1)
		error(Ebadarg);
	pid = vmrun(QVM(c->qid.path), argc, argv);
	c->aux = (void*)(uintptr)pid;
	poperror();
	free(buf);
	return n;
}

Dev vmdevtab = {
	'V',
	"vm",

	devreset,
	devinit,
	devshutdown,
	vmattach,
	vmwalk,
	vmstat,
	vmopen,
	devcreate,
	vmclose,
	vmread,
	devbread,
	vmwrite,
	devbwrite,
	devremove,
	devwstat,
};
