implement Parread;

#
# Reads in flight: a buffer read as several preads of contiguous pieces
# at once.  See parread(2).
#

include "sys.m";
	sys: Sys;
include "parread.m";

MINPIECE: con 16*1024;	# smaller pieces are not worth a process

pread(fd: ref Sys->FD, b: array of byte, off: big, ways: int): (int, string)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(ways > len b / MINPIECE)
		ways = len b / MINPIECE;
	if(ways <= 1)
		return piece(fd, b, off);
	size := (len b + ways - 1) / ways;
	done := chan[ways] of (int, int, string);
	n := 0;
	for(s := 0; s < len b; s += size){
		e := s + size;
		if(e > len b)
			e = len b;
		spawn worker(fd, b[s:e], off + big s, n, done);
		n++;
	}
	got := array[n] of int;
	errs := array[n] of string;
	lens := array[n] of int;
	for(i := 0; i < n; i++){
		(k, m, err) := <-done;
		got[k] = m;
		errs[k] = err;
	}
	for(i = 0; i < n; i++){
		lens[i] = size;
		if(i == n-1)
			lens[i] = len b - size*(n-1);
	}
	# contiguous from the start: a short piece ends it, its error first
	total := 0;
	for(i = 0; i < n; i++){
		total += got[i];
		if(got[i] < lens[i])
			return (total, errs[i]);
	}
	return (total, nil);
}

worker(fd: ref Sys->FD, b: array of byte, off: big, k: int, done: chan of (int, int, string))
{
	(m, err) := piece(fd, b, off);
	done <-= (k, m, err);
}

# one pread loop over b: (bytes read, the error that stopped it)
piece(fd: ref Sys->FD, b: array of byte, off: big): (int, string)
{
	got := 0;
	while(got < len b){
		m := sys->pread(fd, b[got:], len b - got, off + big got);
		if(m < 0)
			return (got, sys->sprint("%r"));
		if(m == 0)
			break;
		got += m;
	}
	return (got, nil);
}
