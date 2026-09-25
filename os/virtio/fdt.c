/*
 * The flattened device tree the firmware hands the kernel.
 *
 * Every AArch64 boot protocol -- the Linux arm64 one that QEMU
 * implements, and the Raspberry Pi firmware's -- passes a pointer to a
 * DTB in x0 at entry. l.S saves it here before it touches x0 for
 * anything else, because it is the only chance: x0 is the first
 * scratch register any code reaches for.
 *
 * This file was os/arm64/fdt.c while a virt port first shared this
 * kernel, left the tree with it, and is back with it. It lives with
 * the board that calls it: bcm2837 never has, and carried it as dead
 * code.
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
#include "board.h"

/*
 * dtbptr is set by l.S from x0 at reset, after .bss is cleared, and
 * defined in ../arm64/main.c (fns.h declares it). Zero means no device
 * tree was passed.
 */

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

/*
 * A property of a top-level node: fdtgetprop("psci", "method", &n) is
 * /psci's method, fdtgetprop("chosen", "bootargs", &n) the command line.
 *
 * The node is matched by the start of its name, so "memory" finds
 * "memory@40000000", and only at the top level, for fdtmemory's reason:
 * a node of the same name further down is some device's business.
 * Returns a pointer INTO the blob -- big-endian if it is a number, and
 * valid for as long as nothing is allocated over the blob, which
 * confinit sees to -- or nil.
 */
uchar*
fdtgetprop(char *node, char *prop, int *lenp)
{
	uchar *base, *p, *end, *strs, *nm, *data;
	u32int tok, len, nameoff;
	int depth, in;

	if(!fdtvalid())
		return nil;

	base = (uchar*)dtbptr;
	p    = base + be32(base + 8);
	end  = p + be32(base + 36);
	strs = base + be32(base + 12);

	depth = 0;
	in = 0;
	while(p + 4 <= end){
		tok = be32(p);
		p += 4;
		switch(tok){
		case Fdtbeginnode:
			depth++;
			nm = p;
			p += (namelen(nm) + 1 + 3) & ~3;
			if(depth == 2 && namestarts(nm, node))
				in = 1;
			break;
		case Fdtendnode:
			if(depth == 2)
				in = 0;
			if(--depth < 0)
				return nil;
			break;
		case Fdtprop:
			if(p + 8 > end)
				return nil;
			len = be32(p);
			nameoff = be32(p + 4);
			p += 8;
			data = p;
			if(data + len > end)
				return nil;
			p += (len + 3) & ~3;
			if(depth == 2 && in && nameis(strs + nameoff, prop)){
				*lenp = len;
				return data;
			}
			break;
		case Fdtnop:
			break;
		default:
			return nil;
		}
	}
	return nil;
}

/*
 * The processors: the reg (hart id, or MPIDR on arm64) of each
 * /cpus/cpu@N node whose status is not "disabled", up to max of them.
 * A RISC-V kernel needs this to start its harts, because the hart ids
 * are not 0..n-1 on every machine: a PolarFire SoC's first application
 * hart is 1, its hart 0 (the E51 monitor core) marked disabled.
 */
int
fdtcpus(ulong *ids, int max)
{
	uchar *base, *p, *end, *strs, *nm, *data;
	u32int tok, len, nameoff;
	int depth, incpus, incpu, n, disabled, hasreg;
	ulong reg;

	if(!fdtvalid())
		return 0;

	base = (uchar*)dtbptr;
	p    = base + be32(base + 8);
	end  = p + be32(base + 36);
	strs = base + be32(base + 12);

	depth = 0;
	incpus = incpu = 0;
	n = 0;
	disabled = hasreg = 0;
	reg = 0;
	while(p + 4 <= end){
		tok = be32(p);
		p += 4;
		switch(tok){
		case Fdtbeginnode:
			depth++;
			nm = p;
			p += (namelen(nm) + 1 + 3) & ~3;
			if(depth == 2 && nameis(nm, "cpus"))
				incpus = 1;
			else if(depth == 3 && incpus && namestarts(nm, "cpu@")){
				incpu = 1;
				disabled = hasreg = 0;
			}
			break;
		case Fdtendnode:
			if(depth == 3 && incpu){
				if(hasreg && !disabled && n < max)
					ids[n++] = reg;
				incpu = 0;
			}
			if(depth == 2)
				incpus = 0;
			if(--depth < 0)
				return n;
			break;
		case Fdtprop:
			if(p + 8 > end)
				return n;
			len = be32(p);
			nameoff = be32(p + 4);
			p += 8;
			data = p;
			if(data + len > end)
				return n;
			p += (len + 3) & ~3;
			if(depth == 3 && incpu){
				nm = strs + nameoff;
				if(nameis(nm, "reg") && len >= 4){
					reg = be32(data);
					if(len >= 8)
						reg = (reg << 32) | be32(data + 4);
					hasreg = 1;
				}else if(nameis(nm, "status") && len >= 8 && namestarts(data, "disabled"))
					disabled = 1;
			}
			break;
		case Fdtnop:
			break;
		default:
			return n;
		}
	}
	return n;
}

/*
 * What the firmware says is not the kernel's to allocate: the entries
 * of the header's memory reservation block, then the reg of each child
 * of the top-level /reserved-memory node (whose own #address-cells and
 * #size-cells describe them). Up to max of them into base[] and size[];
 * returns how many.
 *
 * A child with no reg -- a "size" and "alloc-ranges" asking the OS to
 * find room for, say, a CMA pool -- is a request to Linux, not a
 * region, and is not counted. Whether a region is no-map does not
 * matter here: this kernel maps nothing, and it must not allocate a
 * reserved page either way.
 *
 * A PolarFire SoC board needs this: the BeagleV-Fire's tree reserves
 * the HSS's region and buffers the FPGA fabric DMAs into, inside the
 * one /memory bank.
 */
int
fdtreserved(uintptr *rbase, uintptr *rsize, int max)
{
	uchar *base, *p, *end, *strs, *nm, *data, *r;
	u32int tok, len, nameoff, acells, scells;
	int depth, inres, n, i, j, k;
	uintptr addr, size;

	if(!fdtvalid())
		return 0;

	base = (uchar*)dtbptr;
	n = 0;

	/* the memory reservation block: (address, size) be64 pairs, ending in 0,0 */
	r = base + be32(base + 16);
	for(;;){
		if(r + 16 > base + fdtsize() || n >= max)
			break;
		addr = ((uintptr)be32(r) << 32) | be32(r + 4);
		size = ((uintptr)be32(r + 8) << 32) | be32(r + 12);
		if(addr == 0 && size == 0)
			break;
		rbase[n] = addr;
		rsize[n] = size;
		n++;
		r += 16;
	}

	p    = base + be32(base + 8);
	end  = p + be32(base + 36);
	strs = base + be32(base + 12);

	acells = 2;
	scells = 2;
	depth = 0;
	inres = 0;
	while(p + 4 <= end && n < max){
		tok = be32(p);
		p += 4;
		switch(tok){
		case Fdtbeginnode:
			depth++;
			nm = p;
			p += (namelen(nm) + 1 + 3) & ~3;
			if(depth == 2 && nameis(nm, "reserved-memory"))
				inres = 1;
			break;
		case Fdtendnode:
			if(depth == 2)
				inres = 0;
			if(--depth < 0)
				return n;
			break;
		case Fdtprop:
			if(p + 8 > end)
				return n;
			len = be32(p);
			nameoff = be32(p + 4);
			p += 8;
			data = p;
			if(data + len > end)
				return n;
			p += (len + 3) & ~3;
			if(!inres)
				break;
			nm = strs + nameoff;
			if(depth == 2){
				if(nameis(nm, "#address-cells") && len == 4)
					acells = be32(data);
				else if(nameis(nm, "#size-cells") && len == 4)
					scells = be32(data);
			}else if(depth == 3 && nameis(nm, "reg")){
				if(acells == 0 || acells > 2 || scells == 0 || scells > 2)
					break;
				/* reg may list several regions */
				for(j = 0; (j+1)*(acells+scells)*4 <= len && n < max; j++){
					k = j*(acells+scells);
					addr = 0;
					for(i = 0; i < (int)acells; i++)
						addr = (addr << 32) | be32(data + (k+i)*4);
					size = 0;
					for(i = 0; i < (int)scells; i++)
						size = (size << 32) | be32(data + (k+acells+i)*4);
					rbase[n] = addr;
					rsize[n] = size;
					n++;
				}
			}
			break;
		case Fdtnop:
			break;
		default:
			return n;
		}
	}
	return n;
}
