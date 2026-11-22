/*
 * $Flow: the flow table (module/flow.m), for minos's measurements.
 * The table itself is flowtab.c, which is infernode-os/minos's
 * exp/flow/flow.c and is tested there on the host; this is only the
 * checking of what Limbo hands it.
 */
#include "lib9.h"
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "flowif.h"
#include "flowmod.h"

#define FLOW_HAVE_TYPES
#include "flowtab.c"

void
flowmodinit(void)
{
	builtinmod("$Flow", Flowmodtab, Flowmodlen);
}

/* an array as a table, or an error */
static Flowtab*
table(Array *a)
{
	if(a == H)
		error(exNilref);
	if(((uintptr)a->data & 7) != 0 || !flowvalid((Flowtab*)a->data, a->len))
		error(exBounds);
	return (Flowtab*)a->data;
}

static Flowkey*
flkey(Array *a)
{
	if(a == H)
		error(exNilref);
	if(a->len < sizeof(Flowkey) || ((uintptr)a->data & 1) != 0)
		error(exBounds);
	return (Flowkey*)a->data;
}

void
Flow_size(void *fp)
{
	F_Flow_size *f;

	f = fp;
	if(f->n < Flook || f->n > (1<<24) || (f->n & (f->n-1)) != 0)
		error(exBounds);
	*f->ret = flowsize(f->n);
}

void
Flow_init(void *fp)
{
	F_Flow_init *f;

	f = fp;
	if(f->tab == H)
		error(exNilref);
	if(f->n < Flook || f->n > (1<<24) || (f->n & (f->n-1)) != 0
	|| ((uintptr)f->tab->data & 7) != 0 || f->tab->len < flowsize(f->n))
		error(exBounds);
	flowinit((Flowtab*)f->tab->data, f->n, f->k0, f->k1);
}

void
Flow_key(void *fp)
{
	F_Flow_key *f;
	Flowkey k;
	int dir, r;

	f = fp;
	if(f->frame == H || f->k == H)
		error(exNilref);
	if(f->k->len < sizeof(Flowkey))
		error(exBounds);
	r = flowkey(f->frame->data, f->frame->len, &k, &dir);
	if(r != Kok){
		*f->ret = r;
		return;
	}
	memmove(f->k->data, &k, sizeof k);
	*f->ret = dir;
}

void
Flow_lookup(void *fp)
{
	F_Flow_lookup *f;
	Flowtab *t;
	Flowent *e;
	Flowkey k;

	f = fp;
	t = table(f->tab);
	memmove(&k, flkey(f->k), sizeof k);
	e = flowlookup(t, &k, f->dir != 0, f->n, f->now);
	*f->ret = e != nil ? e->verdict : 0;
}

void
Flow_add(void *fp)
{
	F_Flow_add *f;
	Flowtab *t;
	Flowkey k;

	f = fp;
	t = table(f->tab);
	memmove(&k, flkey(f->k), sizeof k);
	if(f->verdict < Fpass || f->verdict > Fcopy || f->idle < 0)
		error(exBounds);
	*f->ret = flowadd(t, &k, f->dir != 0, f->verdict, f->idle, f->now) != nil;
}

void
Flow_sweep(void *fp)
{
	F_Flow_sweep *f;
	Flowtab *t;

	f = fp;
	t = table(f->tab);
	if(f->out == H)
		error(exNilref);
	if(((uintptr)f->out->data & 7) != 0)
		error(exBounds);
	*f->ret = flowsweep(t, f->now, (Flowent*)f->out->data, f->out->len/sizeof(Flowent));
}
