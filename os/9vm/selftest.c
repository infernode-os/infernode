/*
 * selftest.c -- the #~ rings at boot, when the kernel command line asks.
 *
 * This is what proves the transport until os/port and devmnt are here:
 * every channel the host offers is negotiated and attached; channel 0,
 * the host filesystem, is walked and read; then eight reads are left in
 * flight on channel 0 while the other channels are used, so more than
 * one ring is exercised at a time.  The large file is verified byte for
 * byte in place, in the ring's buffer, with no copy.
 *
 * The kernel runs it when the Multiboot command line contains "ringtest";
 * an ordinary boot only reports the rings.
 */

#include <string.h>
#include "board.h"

#define MAXTESTFILE	(8 * 1024 * 1024)	/* a sanity bound, not a limit */

static int failed;

/* "infernode/9vm: #~/0 host: " */
static void
prefix(Board *b, int ci)
{
	consprint("infernode/9vm: #~/");
	consprintdec(ci);
	consprint(" ");
	consprint(boardchanname(b, ci));
	consprint(": ");
}

static void
fail(Board *b, int ci, const char *what, P9Client *c)
{
	if(ci >= 0)
		prefix(b, ci);
	else
		consprint("infernode/9vm: ");
	consprint(what);
	if(c != 0 && p9err(c)[0] != 0){
		consprint(": ");
		consprint(p9err(c));
	}
	consprint("\n");
	consprint("infernode/9vm: ring test failed\n");
	failed = 1;
}

/* the file the host exports: byte i is 'a' + i%26 */
static int
pattern(const uint8_t *p, uint32_t n, uint64_t off)
{
	uint32_t i;

	for(i = 0; i < n; i++)
		if(p[i] != 'a' + (off + i) % 26)
			return 0;
	return 1;
}

/*
 * Checks one collected batch: the offsets are the ones submitted and
 * every byte matches the pattern.  Returns 1 when the batch reached end
 * of file, 0 when more remain, -1 on bad data.
 */
static int
verifybatch(Board *b, int ci, P9Read *rd, uint32_t chunk, uint64_t off,
	uint64_t *total)
{
	uint32_t i;
	int last;

	last = 0;
	for(i = 0; i < P9_HOST_SLOTS; i++){
		if(rd[i].off != off + (uint64_t)i*chunk ||
		   !pattern(rd[i].data, rd[i].len, rd[i].off)){
			prefix(b, ci);
			consprint("pattern broken at ");
			consprinthex(rd[i].off);
			consprint("\n");
			return -1;
		}
		*total += rd[i].len;
		if(rd[i].len != chunk)
			last = 1;
	}
	return last;
}

void
ringselftest(Board *b)
{
	P9Client c[P9_HOST_NCHAN];
	P9Read rd[P9_HOST_SLOTS];	/* the host channel's batch */
	P9Read nrd[P9_HOST_SLOTS];	/* each other channel's, while it runs */
	const char *names[2], *dot[1];
	Qid q, wq[P9_Maxwelem];
	uint64_t off, total;
	uint32_t iounit, chunk, nchunk, i;
	int ci, nq, last, firstslot;

	failed = 0;

	if(b->nchan <= 0){
		fail(b, -1, "the host offers no channel", 0);
		return;
	}

	/* every ring the host offers: negotiate and attach */
	for(ci = 0; ci < b->nchan; ci++){
		if(p9mount(&c[ci], &b->chan[ci], P9_HOST_MSIZE) < 0){
			fail(b, ci, "no 9P2000", &c[ci]);
			return;
		}
		prefix(b, ci);
		consprint("9P2000 msize ");
		consprintdec(c[ci].msize);
		consprint("\n");
		if(p9attach(&c[ci], 0, "inferno", "", &q) < 0){
			fail(b, ci, "attach", &c[ci]);
			return;
		}
	}

	/* channel 0 is the host filesystem: a two-element walk and a read */
	names[0] = "sub";
	names[1] = "hello.txt";
	if(p9walk(&c[0], 0, 1, names, 2, wq, P9_Maxwelem, &nq) < 0 ||
	   nq != 2){
		fail(b, 0, "walk sub/hello.txt", &c[0]);
		return;
	}
	if(p9open(&c[0], 1, P9_Oread, &q, &iounit) < 0){
		fail(b, 0, "open sub/hello.txt", &c[0]);
		return;
	}
	if(p9pread(&c[0], 1, 0, 4096, 1, rd) < 0){
		fail(b, 0, "read sub/hello.txt", &c[0]);
		return;
	}
	if(rd[0].len != 15 || memcmp(rd[0].data, "hello from 9vm\n", 15) != 0){
		p9pdone(&c[0], rd, 1);
		fail(b, 0, "sub/hello.txt content", 0);
		return;
	}
	p9pdone(&c[0], rd, 1);
	if(p9clunk(&c[0], 1) < 0){
		fail(b, 0, "clunk", &c[0]);
		return;
	}
	prefix(b, 0);
	consprint("sub/hello.txt 15 bytes, content ok\n");

	/*
	 * The pipeline: eight reads in flight at once, each the largest
	 * reply the host said it would return.  The reply stays in its
	 * ring buffer and is verified there.
	 */
	names[0] = "pattern.bin";
	if(p9walk(&c[0], 0, 2, names, 1, wq, P9_Maxwelem, &nq) < 0 ||
	   nq != 1){
		fail(b, 0, "walk pattern.bin", &c[0]);
		return;
	}
	if(p9open(&c[0], 2, P9_Oread, &q, &iounit) < 0){
		fail(b, 0, "open pattern.bin", &c[0]);
		return;
	}
	chunk = iounit;
	if(chunk == 0 || chunk > P9_HOST_MSIZE - P9_Readhdrsz)
		chunk = P9_HOST_MSIZE - P9_Readhdrsz;

	off = 0;
	total = 0;
	if(p9psubmit(&c[0], 2, off, chunk, P9_HOST_SLOTS, rd) < 0){
		fail(b, 0, "pipelined read", &c[0]);
		return;
	}

	/*
	 * Channel 0 now has eight requests outstanding.  Use the other
	 * rings before collecting them: they are independent, and this is
	 * the case a namespace being read while the filesystem is read
	 * depends on.  The server behind the ns channel answers these
	 * reads in reverse, so a guest that pairs completions by arrival
	 * order would verify the wrong bytes.
	 */
	dot[0] = ".";
	for(ci = 1; ci < b->nchan; ci++){
		if(p9walk(&c[ci], 0, 1, dot, 1, wq, P9_Maxwelem, &nq) < 0 ||
		   nq != 1){
			fail(b, ci, "walk .", &c[ci]);
			return;
		}
		prefix(b, ci);
		consprint("walked . while #~/0 host had ");
		consprintdec(P9_HOST_SLOTS);
		consprint(" reads in flight\n");

		names[0] = "data";
		if(p9walk(&c[ci], 0, 2, names, 1, wq, P9_Maxwelem, &nq) < 0 ||
		   nq != 1){
			fail(b, ci, "walk data", &c[ci]);
			return;
		}
		if(p9open(&c[ci], 2, P9_Oread, &q, &iounit) < 0){
			fail(b, ci, "open data", &c[ci]);
			return;
		}
		nchunk = iounit;
		if(nchunk == 0 || nchunk > P9_HOST_MSIZE - P9_Readhdrsz)
			nchunk = P9_HOST_MSIZE - P9_Readhdrsz;

		b->chan[ci].nseq = 0;
		if(p9pread(&c[ci], 2, 0, nchunk, P9_HOST_SLOTS, nrd) < 0){
			fail(b, ci, "pipelined read", &c[ci]);
			return;
		}
		firstslot = nrd[0].msg.slot;	/* the first request, not the first reply */
		for(i = 0; i < P9_HOST_SLOTS; i++){
			if(nrd[i].off != (uint64_t)i*nchunk ||
			   nrd[i].len != nchunk ||
			   !pattern(nrd[i].data, nrd[i].len, nrd[i].off)){
				p9pdone(&c[ci], nrd, P9_HOST_SLOTS);
				fail(b, ci, "read data", 0);
				return;
			}
		}
		p9pdone(&c[ci], nrd, P9_HOST_SLOTS);

		prefix(b, ci);
		consprintdec(P9_HOST_SLOTS);
		consprint(" concurrent reads of ");
		consprintdec(nchunk);
		consprint(" bytes, replies ");
		if(b->chan[ci].nseq > 0 &&
		   b->chan[ci].seq[0] != (uint32_t)firstslot)
			consprint("out of order\n");
		else
			consprint("in order\n");
	}

	if(p9pcollect(&c[0], P9_HOST_SLOTS, rd) < 0){
		fail(b, 0, "pipelined read", &c[0]);
		return;
	}
	last = verifybatch(b, 0, rd, chunk, off, &total);
	p9pdone(&c[0], rd, P9_HOST_SLOTS);

	while(last == 0){
		off += (uint64_t)P9_HOST_SLOTS*chunk;
		if(p9pread(&c[0], 2, off, chunk, P9_HOST_SLOTS, rd) < 0){
			fail(b, 0, "pipelined read", &c[0]);
			return;
		}
		last = verifybatch(b, 0, rd, chunk, off, &total);
		p9pdone(&c[0], rd, P9_HOST_SLOTS);
	}
	if(last < 0){
		fail(b, 0, "pattern.bin content", 0);
		return;
	}
	if(total == 0){
		fail(b, 0, "pattern.bin is empty", 0);
		return;
	}

	prefix(b, 0);
	consprintdec(b->chan[0].maxinflight);
	consprint(" concurrent reads of ");
	consprintdec(chunk);
	consprint(" bytes, ");
	consprintdec(total);
	consprint(" bytes verified\n");

	if(p9clunk(&c[0], 2) < 0){
		fail(b, 0, "clunk", &c[0]);
		return;
	}

	if(!failed)
		consprint("infernode/9vm: ring test passed\n");
}
