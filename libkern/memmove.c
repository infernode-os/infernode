#include	<lib9.h>

/*
 * The native kernels' copy (arm64 and riscv64; the hosted emulators
 * use the host's). Eight bytes at a time in general registers, so it is
 * safe where the kernel is built -mgeneral-regs-only: interrupt paths
 * call it, and they must not touch FP/SIMD state.
 *
 * Every word load and store is naturally aligned, which both
 * architectures do at full speed and RISC-V requires to avoid a trap.
 * When source and destination are not aligned alike, each output word
 * is made from two aligned source words, shifted; those reads stay
 * within the aligned words that hold source bytes, so never cross a
 * page. Both kernels are little-endian, which the shifts assume.
 *
 * Not for device registers: it reads and writes in words, as the byte
 * loop it replaced read and wrote in bytes; drivers use their own
 * accessors.
 *
 * The loops are in memmove's own body: a compiler may turn a copy loop
 * into a call to memcpy, which here calls memmove, but not inside a
 * function of that name. tests/host/libkern_copy_test.sh checks the
 * kernels' objects for any such call.
 */

typedef uvlong __attribute__((__may_alias__)) Word;

enum
{
	Wsz	= sizeof(Word),
	Wmask	= Wsz-1,
};

void*
memcpy(void *a1, void *a2, ulong n)
{
	return memmove(a1, a2, n);
}

void*
memmove(void *a1, void *a2, ulong n)
{
	uchar *d, *s;
	Word *wd, *ws, cur, w, a, b, c, e;
	int sh, ls, rs;

	d = a1;
	s = a2;
	if(d == s || n == 0)
		return a1;

	if(d < s){
		/* forwards: the destination is below the source */
		if(n >= 2*Wsz){
			while((uintptr)d & Wmask){
				*d++ = *s++;
				n--;
			}
			wd = (Word*)d;
			sh = (uintptr)s & Wmask;
			if(sh == 0){
				ws = (Word*)s;
				for(; n >= 4*Wsz; n -= 4*Wsz){
					a = ws[0]; b = ws[1]; c = ws[2]; e = ws[3];
					wd[0] = a; wd[1] = b; wd[2] = c; wd[3] = e;
					wd += 4;
					ws += 4;
				}
				for(; n >= Wsz; n -= Wsz)
					*wd++ = *ws++;
				s = (uchar*)ws;
			}else{
				ls = 8*sh;
				rs = 8*Wsz - ls;
				ws = (Word*)(s - sh);
				cur = *ws++;
				for(; n >= Wsz; n -= Wsz){
					w = *ws++;
					*wd++ = cur>>ls | w<<rs;
					cur = w;
					s += Wsz;
				}
			}
			d = (uchar*)wd;
		}
		while(n > 0){
			*d++ = *s++;
			n--;
		}
		return a1;
	}

	/* backwards: the destination is above the source, perhaps overlapping it */
	d += n;
	s += n;
	if(n >= 2*Wsz){
		while((uintptr)d & Wmask){
			*--d = *--s;
			n--;
		}
		wd = (Word*)d;
		sh = (uintptr)s & Wmask;
		if(sh == 0){
			ws = (Word*)s;
			for(; n >= 4*Wsz; n -= 4*Wsz){
				ws -= 4;
				wd -= 4;
				a = ws[3]; b = ws[2]; c = ws[1]; e = ws[0];
				wd[3] = a; wd[2] = b; wd[1] = c; wd[0] = e;
			}
			for(; n >= Wsz; n -= Wsz)
				*--wd = *--ws;
			s = (uchar*)ws;
		}else{
			/* cur's low sh bytes are the source's last sh bytes not yet copied */
			ls = 8*sh;
			rs = 8*Wsz - ls;
			ws = (Word*)(s - sh);
			cur = *ws;
			for(; n >= Wsz; n -= Wsz){
				w = *--ws;
				*--wd = w>>ls | cur<<rs;
				cur = w;
				s -= Wsz;
			}
		}
		d = (uchar*)wd;
	}
	while(n > 0){
		*--d = *--s;
		n--;
	}
	return a1;
}
