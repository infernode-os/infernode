#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

int
cloadmemimage(Memimage *i, Rectangle r, uchar *data, int ndata)
{
	int y, bpl, c, cnt, offs, ret;
	uchar mem[NMEM], *memp, *omemp, *emem, *linep, *elinep, *u, *eu;

	if(badrect(r) || !rectinrect(r, i->r))
		return -1;
	bpl = bytesperline(r, i->depth);
	u = data;
	eu = data+ndata;
	memset(mem, 0, sizeof mem);
	memp = mem;
	emem = mem+NMEM;
	y = r.min.y;
	linep = byteaddr(i, Pt(r.min.x, y));
	elinep = linep+bpl;
	for(;;){
		if(linep == elinep){
			if(++y == r.max.y)
				break;
			linep = byteaddr(i, Pt(r.min.x, y));
			elinep = linep+bpl;
		}
		if(u == eu){	/* buffer too small */
			ret = -1;
			goto Out;
		}
		c = *u++;
		if(c >= 128){
			for(cnt=c-128+1; cnt!=0 ;--cnt){
				if(u == eu){		/* buffer too small */
					ret = -1;
					goto Out;
				}
				if(linep == elinep){	/* phase error */
					ret = -1;
					goto Out;
				}
				*linep++ = *u;
				*memp++ = *u++;
				if(memp == emem)
					memp = mem;
			}
		}
		else{
			if(u == eu){	/* short buffer */
				ret = -1;
				goto Out;
			}
			offs = *u++ + ((c&3)<<8)+1;
			if(memp-mem < offs)
				omemp = memp+(NMEM-offs);
			else
				omemp = memp-offs;
			for(cnt=(c>>2)+NMATCH; cnt!=0; --cnt){
				if(linep == elinep){	/* phase error */
					ret = -1;
					goto Out;
				}
				*linep++ = *omemp;
				*memp++ = *omemp++;
				if(omemp == emem)
					omemp = mem;
				if(memp == emem)
					memp = mem;
			}
		}
	}
	ret = u-data;
Out:
	memset(mem, 0, sizeof mem);
	return ret;
}
