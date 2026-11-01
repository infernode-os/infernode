#include	<lib9.h>

/* for testing only */
void*
memcpy(void *a1, void *a2, ulong n)
{
	return memmove(a1, a2, n);
}

void*
memmove(void *a1, void *a2, ulong n)
{
	int m = (int)n;
	uchar *s, *d;
	
	d = a1;
	s = a2;
	if(d > s){
		s += m;
		d += m;
#ifdef WORDMEM
		if(m >= 64 && (((uintptr)d ^ (uintptr)s) & 7) == 0){
			u64int *wd, *ws;

			while(((uintptr)d & 7) != 0){
				*--d = *--s;
				m--;
			}
			wd = (u64int*)d;
			ws = (u64int*)s;
			for(; m >= 32; m -= 32){
				wd -= 4;
				ws -= 4;
				wd[3] = ws[3];
				wd[2] = ws[2];
				wd[1] = ws[1];
				wd[0] = ws[0];
			}
			d = (uchar*)wd;
			s = (uchar*)ws;
		}
#endif
		while(--m >= 0)
			*--d = *--s;
	}
	else{
#ifdef WORDMEM
		/* see memset.c */
		if(m >= 64 && (((uintptr)d ^ (uintptr)s) & 7) == 0){
			u64int *wd, *ws;

			while(((uintptr)d & 7) != 0){
				*d++ = *s++;
				m--;
			}
			wd = (u64int*)d;
			ws = (u64int*)s;
			for(; m >= 32; m -= 32){
				wd[0] = ws[0];
				wd[1] = ws[1];
				wd[2] = ws[2];
				wd[3] = ws[3];
				wd += 4;
				ws += 4;
			}
			d = (uchar*)wd;
			s = (uchar*)ws;
		}
#endif
		while(--m >= 0)
			*d++ = *s++;
	}
	return a1;
}
