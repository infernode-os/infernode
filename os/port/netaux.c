/*
 * IMPORTED from upstream Inferno (inferno-os/inferno-os), os/port/netaux.c.
 * Root NOTICE: "The bulk of the tree is covered by the permissive MIT
 * licence"; this tree's LICENSE credits Vita Nuova's revisions.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/netif.h"


void
hnputv(void *p, vlong v)
{
	uchar *a;

	a = p;
	hnputl(a, v>>32);
	hnputl(a+4, v);
}

void
hnputl(void *p, ulong v)
{
	uchar *a;

	a = p;
	a[0] = v>>24;
	a[1] = v>>16;
	a[2] = v>>8;
	a[3] = v;
}

void
hnputs(void *p, ushort v)
{
	uchar *a;

	a = p;
	a[0] = v>>8;
	a[1] = v;
}

vlong
nhgetv(void *p)
{
	uchar *a;

	a = p;
	return ((vlong)nhgetl(a) << 32) | nhgetl(a+4);
}

ulong
nhgetl(void *p)
{
	uchar *a;

	a = p;
	/*
	 * The casts are the fix, not decoration.
	 *
	 * Without them a[0] promotes to int, a[0]<<24 sets the int SIGN
	 * BIT for any first byte >= 0x80, and converting that negative
	 * int to a 64-bit ulong sign extends it: nhgetl("192.168.1.1")
	 * returns 0xFFFFFFFFC0A80101 instead of 0xC0A80101.
	 *
	 * That is harmless on the 32-bit machines this was written for
	 * and wrong here. It is also not theoretical -- the same bug was
	 * fixed in emu/port/ipaux.c earlier, where it was LATENT because
	 * emu has no IP stack. Linking os/ip is exactly the moment it
	 * stops being latent: route ranges are computed as (start|~mask)
	 * and TCP compares sequence numbers, and both silently produce
	 * wrong answers rather than failing.
	 *
	 * Guarded by tests/host/nhgetl_test.sh.
	 */
	return ((ulong)a[0]<<24)|((ulong)a[1]<<16)|((ulong)a[2]<<8)|((ulong)a[3]<<0);
}

ushort
nhgets(void *p)
{
	uchar *a;

	a = p;
	return ((ushort)a[0]<<8)|((ushort)a[1]<<0);
}
