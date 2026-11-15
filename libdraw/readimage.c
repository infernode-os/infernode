#include "lib9.h"
#include "kernel.h"
#include "draw.h"

Image*
readimage(Display *d, int fd, int dolock)
{
	char hdr[5*12+1];
	int dy;
	int new;
	uint l, n;
	int m, j, chunk;
	int miny, maxy;
	Rectangle r;
	int ldepth;
	ulong chan;
	uchar *tmp;
	Image *i;

	if(libreadn(fd, hdr, 11) != 11) {
		kwerrstr("readimage: short header");
		return nil;
	}
	if(memcmp(hdr, "compressed\n", 11) == 0)
		return creadimage(d, fd, dolock);
	dolock &= 1;
	if(libreadn(fd, hdr+11, 5*12-11) != 5*12-11) {
		kwerrstr("readimage: short header");
		return nil;
	}
	/*
	 * Each field is eleven characters and a blank (image(6)).  The
	 * numbers are read with atoi, which stops at what is not a digit:
	 * a field of twelve digits ran into the next, and the last into
	 * hdr[60], which nothing had set, and the stack after it.
	 */
	hdr[5*12] = '\0';
	for(m=1; m<5; m++){
		if(hdr[m*12+11] != ' '){
			kwerrstr("readimage: bad format");
			return nil;
		}
	}
	chunk = d->bufsize - 32;	/* a little room for header */

	/*
	 * distinguish new channel descriptor from old ldepth.
	 * channel descriptors have letters as well as numbers,
	 * while ldepths are a single digit formatted as %-11d.
	 */
	new = 0;
	for(m=0; m<10; m++){
		if(hdr[m] != ' '){
			new = 1;
			break;
		}
	}
	if(hdr[11] != ' '){
		kwerrstr("readimage: bad format");
		return nil;
	}
	if(new){
		hdr[11] = '\0';
		if((chan = strtochan(hdr)) == 0){
			kwerrstr("readimage: bad channel string %s", hdr);
			return nil;
		}
	}else{
		ldepth = ((int)hdr[10])-'0';
		if(ldepth<0 || ldepth>3){
			kwerrstr("readimage: bad ldepth %d", ldepth);
			return nil;
		}
		chan = drawld2chan[ldepth];
	}

	r.min.x = atoi(hdr+1*12);
	r.min.y = atoi(hdr+2*12);
	r.max.x = atoi(hdr+3*12);
	r.max.y = atoi(hdr+4*12);
	if(r.min.x>r.max.x || r.min.y>r.max.y){
		kwerrstr("readimage: bad rectangle");
		return nil;
	}

	miny = r.min.y;
	maxy = r.max.y;

	l = bytesperline(r, chantodepth(chan));
	if(dolock)
		dolock = lockdisplay(d);
	i = allocimage(d, r, chan, 0, -1);
	if(dolock)
		unlockdisplay(d);
	if(i == nil)
		return nil;
	tmp = malloc(chunk);
	if(tmp == nil)
		goto Err;
	while(maxy > miny){
		dy = maxy - miny;
		/* by division: the product is the file's to choose, and wraps */
		if(l == 0 || dy > chunk/l)
			dy = l == 0? 0: chunk/l;
		if(dy <= 0){
			kwerrstr("readimage: image too wide for buffer");
			goto Err;
		}
		n = dy*l;
		m = libreadn(fd, tmp, n);
		if(m != n){
			kwerrstr("readimage: read count %d not %d: %r", m, n);
   Err:
			if(dolock)
				lockdisplay(d);
   Err1:
 			freeimage(i);
			if(dolock)
				unlockdisplay(d);
			free(tmp);
			return nil;
		}
		if(!new)	/* an old image: must flip all the bits */
			for(j=0; j<chunk; j++)
				tmp[j] ^= 0xFF;

		if(dolock)
			lockdisplay(d);
		if(loadimage(i, Rect(r.min.x, miny, r.max.x, miny+dy), tmp, chunk) <= 0)
			goto Err1;
		if(dolock)
			unlockdisplay(d);
		miny += dy;
	}
	free(tmp);
	return i;
}
