/*
 * The flattened device tree the firmware hands the kernel.
 *
 * Every AArch64 boot protocol -- the Linux arm64 one that QEMU
 * implements, and the Raspberry Pi firmware's -- passes a pointer to a
 * DTB in x0 at entry. l.S saves it here before it touches x0 for
 * anything else, because it is the only chance: x0 is the first
 * scratch register any code reaches for.
 *
 * Only enough of the format is implemented to answer one question --
 * where is RAM and how much of it is there -- because that is the one
 * thing this kernel genuinely cannot hardcode. On the virt machine it
 * varies with -m; on a Pi it varies with the config.txt memory split
 * (which is why BCM2837 asks the VideoCore mailbox instead, an answer
 * the DTB does not carry).
 *
 * Everything is read a byte at a time. That is not caution about
 * endianness alone -- the DTB is big-endian and the CPU is not, so a
 * swap is needed regardless -- it is that this runs BEFORE the MMU,
 * where all memory is Device-nGnRnE and an unaligned access is a fault
 * rather than a slow path. Byte loads are always aligned.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

/*
 * Set by l.S from x0 at reset, after .bss is cleared -- clearing .bss
 * would otherwise wipe it. Zero means no device tree was passed.
 */
uintptr	dtbptr;

enum
{
	Fdtmagic	= 0xD00DFEED,

	Fdtbeginnode	= 1,
	Fdtendnode	= 2,
	Fdtprop		= 3,
	Fdtnop		= 4,
	Fdtend		= 9,

	/* a DTB larger than this is not one we were handed */
	Fdtmaxsize	= 2*1024*1024,
};

static u32int
be32(uchar *p)
{
	return ((u32int)p[0]<<24) | ((u32int)p[1]<<16) |
	       ((u32int)p[2]<<8)  | (u32int)p[3];
}

/* strcmp against a NUL-terminated name in the DTB, byte at a time */
static int
nameis(uchar *p, char *s)
{
	while(*s != 0){
		if(*p != (uchar)*s)
			return 0;
		p++;
		s++;
	}
	return *p == 0;
}

/* does the node name start with s?  "memory@40000000" starts with "memory" */
static int
namestarts(uchar *p, char *s)
{
	while(*s != 0){
		if(*p != (uchar)*s)
			return 0;
		p++;
		s++;
	}
	return 1;
}

static int
namelen(uchar *p)
{
	int n;

	for(n = 0; n < 256 && p[n] != 0; n++)
		;
	return n;
}

/*
 * Is there a device tree at all, and does it look like one?
 *
 * Checked rather than assumed because the alternative failure is
 * silent: a garbage pointer walked as a DTB produces garbage node
 * names, and the memory size that comes out is then a plausible-looking
 * number that is simply wrong.
 */
int
fdtvalid(void)
{
	uchar *p;
	u32int sz;

	p = (uchar*)dtbptr;
	if(p == nil)
		return 0;
	if(be32(p) != Fdtmagic)
		return 0;
	sz = be32(p + 4);
	return sz >= 40 && sz <= Fdtmaxsize;
}

uintptr
fdtsize(void)
{
	if(!fdtvalid())
		return 0;
	return (uintptr)be32((uchar*)dtbptr + 4);
}

/*
 * Find the first /memory node and return its first reg entry.
 *
 * Returns 0 on success. The caller must have a fallback: a kernel that
 * cannot find its own RAM should say so and use a conservative default
 * rather than compute a size from a failed parse.
 */
int
fdtmemory(uintptr *basep, uintptr *sizep)
{
	uchar *base, *p, *end, *strs, *nm, *data;
	u32int tok, len, nameoff, acells, scells;
	int depth, inmem, i;
	uintptr addr, size;

	if(!fdtvalid())
		return -1;

	base = (uchar*)dtbptr;
	p    = base + be32(base + 8);		/* off_dt_struct */
	end  = p + be32(base + 36);		/* size_dt_struct */
	strs = base + be32(base + 12);		/* off_dt_strings */

	/*
	 * The spec's defaults, used only if the root node does not say.
	 * virt sets both to 2; a Pi DTB sets 2 and 1.
	 */
	acells = 2;
	scells = 1;

	depth = 0;
	inmem = 0;

	while(p + 4 <= end){
		tok = be32(p);
		p += 4;

		switch(tok){
		case Fdtbeginnode:
			depth++;
			nm = p;
			p += (namelen(nm) + 1 + 3) & ~3;
			/*
			 * The root node is depth 1 with an empty name; its
			 * children are depth 2. Only a top-level /memory
			 * counts -- a "memory" node nested inside some
			 * other device is not the machine's RAM.
			 */
			if(depth == 2 && namestarts(nm, "memory"))
				inmem = 1;
			break;

		case Fdtendnode:
			if(depth == 2 && inmem)
				inmem = 0;
			depth--;
			if(depth < 0)
				return -1;	/* malformed */
			break;

		case Fdtprop:
			if(p + 8 > end)
				return -1;
			len = be32(p);
			nameoff = be32(p + 4);
			p += 8;
			data = p;
			if(data + len > end)
				return -1;
			p += (len + 3) & ~3;

			nm = strs + nameoff;
			if(depth == 1){
				if(nameis(nm, "#address-cells") && len == 4)
					acells = be32(data);
				else if(nameis(nm, "#size-cells") && len == 4)
					scells = be32(data);
			}else if(depth == 2 && inmem && nameis(nm, "reg")){
				if(acells == 0 || acells > 2 ||
				   scells == 0 || scells > 2)
					return -1;
				if(len < (acells + scells) * 4)
					return -1;

				addr = 0;
				for(i = 0; i < (int)acells; i++)
					addr = (addr << 32) | be32(data + i*4);
				size = 0;
				for(i = 0; i < (int)scells; i++)
					size = (size << 32) |
						be32(data + (acells + i)*4);

				*basep = addr;
				*sizep = size;
				return 0;
			}
			break;

		case Fdtnop:
			break;

		case Fdtend:
			return -1;		/* walked it all, no /memory */

		default:
			return -1;		/* not a structure block */
		}
	}
	return -1;
}
