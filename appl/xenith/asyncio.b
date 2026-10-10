implement Asyncio;

include "common.m";


sys: Sys;
dat: Dat;
utils: Utils;
bufferm: Bufferm;

error, warning: import utils;
Buffer: import bufferm;

# Next operation ID
nextopid: int;

# Chunk size for reads
CHUNKSIZE: con 8*1024;

# Max content to load into heap — files larger than this get a header-only read
# (renderers like pdfrender stream directly from the file path)
MAXCONTENTLOAD: con 4*1024*1024;

init(mods: ref Dat->Mods)
{
	sys = mods.sys;
	dat = mods.dat;
	utils = mods.utils;
	bufferm = mods.bufferm;

	nextopid = 1;
	# Initialize the global casync channel in dat module
	# Buffer size of 64 allows async tasks to make progress even when
	# the main loop is in a nested event loop (e.g., dragwin)
	dat->casync = chan[64] of ref AsyncMsg;
}

asyncload(path: string, q0: int): ref AsyncOp
{
	op := ref AsyncOp;
	op.opid = nextopid++;
	op.ctl = chan[1] of int;
	op.path = path;
	op.active = 1;
	op.winid = 0;

	spawn readtask(op, path, q0);
	return op;
}

asyncloadtext(path: string, q0: int, winid: int): ref AsyncOp
{
	op := ref AsyncOp;
	op.opid = nextopid++;
	op.ctl = chan[1] of int;
	op.path = path;
	op.active = 1;
	op.winid = winid;

	spawn texttask(op, path, q0, winid);
	return op;
}

texttask(op: ref AsyncOp, path: string, q0: int, winid: int)
{
	# Check for cancellation before starting
	alt {
		<-op.ctl =>
			op.active = 0;
			return;
		* => ;
	}

	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		# Non-blocking send - if cancelled, just exit
		alt {
			dat->casync <-= ref AsyncMsg.TextComplete(op.opid, winid, path, 0, 0, sys->sprint("can't open: %r")) => ;
			<-op.ctl => ;
		}
		op.active = 0;
		return;
	}

	# Get file size for progress
	(ok, dir) := sys->fstat(fd);
	fsize := 0;
	if(ok == 0)
		fsize = int dir.length;

	pbuf := array[Dat->Maxblock+Sys->UTFmax] of byte;
	m := 0;
	nbytes := 0;
	nrunes := 0;

	for(;;) {
		# Check for cancellation
		alt {
			<-op.ctl =>
				fd = nil;
				op.active = 0;
				return;
			* => ;
		}

		n := sys->read(fd, pbuf[m:], Dat->Maxblock);
		if(n < 0) {
			fd = nil;
			# Non-blocking send
			alt {
				dat->casync <-= ref AsyncMsg.TextComplete(op.opid, winid, path, nbytes, nrunes, sys->sprint("read error: %r")) => ;
				<-op.ctl => ;
			}
			op.active = 0;
			return;
		}
		if(n == 0)
			break;

		m += n;
		# Find valid UTF-8 boundary
		nb := sys->utfbytes(pbuf, m);
		if(nb == 0 && m > 0) {
			# No complete characters yet, need more data
			continue;
		}

		data := string pbuf[0:nb];
		nr := len data;

		# Move leftover bytes to start
		if(nb < m) {
			pbuf[0:] = pbuf[nb:m];
			m = m - nb;
		} else {
			m = 0;
		}

		nbytes += nb;

		# Send chunk - retry with cancellation check if channel full
		for(;;) {
			alt {
				dat->casync <-= ref AsyncMsg.TextData(op.opid, winid, path, q0, data, nrunes, nil) =>
					nrunes += nr;
				<-op.ctl =>
					fd = nil;
					op.active = 0;
					return;
				* =>
					# Channel full - yield and retry
					sys->sleep(1);
					continue;
			}
			break;
		}
	}

	fd = nil;
	# Final send - non-blocking with cancellation check
	alt {
		dat->casync <-= ref AsyncMsg.TextComplete(op.opid, winid, path, nbytes, nrunes, nil) => ;
		<-op.ctl => ;
	}
	op.active = 0;
}

asynccancel(op: ref AsyncOp)
{
	if(op != nil && op.active) {
		op.active = 0;
		# Non-blocking send to cancel
		alt {
			op.ctl <-= 1 => ;
			* => ;
		}
	}
}

asyncactive(op: ref AsyncOp): int
{
	if(op == nil)
		return 0;
	return op.active;
}

readtask(op: ref AsyncOp, path: string, q0: int)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		alt { dat->casync <-= ref AsyncMsg.Error(op.opid, sys->sprint("can't open %s: %r", path)) => ; * => ; }
		op.active = 0;
		return;
	}

	# Get file size for progress reporting
	(ok, dir) := sys->fstat(fd);
	total := 0;
	if(ok == 0)
		total = int dir.length;

	buf := array[CHUNKSIZE + Sys->UTFmax] of byte;
	nbytes := 0;
	nrunes := 0;
	offset := q0;
	leftover := 0;  # Bytes left over from partial UTF-8 sequence

	for(;;) {
		# Check for cancellation
		alt {
			<-op.ctl =>
				fd = nil;
				alt { dat->casync <-= ref AsyncMsg.Error(op.opid, "cancelled") => ; * => ; }
				op.active = 0;
				return;
			* => ;
		}

		n := sys->read(fd, buf[leftover:], CHUNKSIZE);
		if(n < 0) {
			alt { dat->casync <-= ref AsyncMsg.Error(op.opid, sys->sprint("read error: %r")) => ; * => ; }
			op.active = 0;
			return;
		}
		if(n == 0)
			break;

		m := leftover + n;
		# Find valid UTF-8 boundary
		nb := sys->utfbytes(buf, m);
		if(nb == 0 && m > 0) {
			# No complete characters yet, need more data
			leftover = m;
			continue;
		}

		s := string buf[0:nb];
		nr := len s;

		# Move leftover bytes to start
		if(nb < m) {
			buf[0:] = buf[nb:m];
			leftover = m - nb;
		} else {
			leftover = 0;
		}

		nbytes += nb;
		nrunes += nr;

		# Send chunk (non-blocking to avoid deadlock)
		alt { dat->casync <-= ref AsyncMsg.Chunk(op.opid, s, offset) => ; * => ; }
		offset += nr;

		# Send progress every 64KB
		if((nbytes % (64*1024)) < CHUNKSIZE)
			alt { dat->casync <-= ref AsyncMsg.Progress(op.opid, nbytes, total) => ; * => ; }
	}

	fd = nil;
	alt { dat->casync <-= ref AsyncMsg.Complete(op.opid, nbytes, nrunes, nil) => ; * => ; }
	op.active = 0;
}

asyncloaddir(path: string, winid: int): ref AsyncOp
{
	op := ref AsyncOp;
	op.opid = nextopid++;
	op.ctl = chan[1] of int;
	op.path = path;
	op.active = 1;
	op.winid = winid;

	spawn dirtask(op, path, winid);
	return op;
}

dirtask(op: ref AsyncOp, path: string, winid: int)
{
	# Check for cancellation before starting
	alt {
		<-op.ctl =>
			op.active = 0;
			return;
		* => ;
	}

	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		alt {
			dat->casync <-= ref AsyncMsg.DirComplete(op.opid, winid, path, 0, sys->sprint("can't open: %r")) => ;
			<-op.ctl => ;
		}
		op.active = 0;
		return;
	}

	nentries := 0;

	for(;;) {
		# Check for cancellation
		alt {
			<-op.ctl =>
				fd = nil;
				op.active = 0;
				return;
			* => ;
		}

		(nd, dbuf) := sys->dirread(fd);
		if(nd <= 0)
			break;

		for(i := 0; i < nd; i++) {
			name := dbuf[i].name;
			isdir := 0;
			if(dbuf[i].mode & Sys->DMDIR) {
				name = name + "/";
				isdir = 1;
			}

			# Send entry - retry with cancellation check if channel full
			for(;;) {
				alt {
					dat->casync <-= ref AsyncMsg.DirEntry(op.opid, winid, name, isdir) =>
						nentries++;
					<-op.ctl =>
						fd = nil;
						op.active = 0;
						return;
					* =>
						# Channel full - yield and retry
						sys->sleep(1);
						continue;
				}
				break;
			}
		}
	}

	fd = nil;
	# Final send - non-blocking with cancellation check
	alt {
		dat->casync <-= ref AsyncMsg.DirComplete(op.opid, winid, path, nentries, nil) => ;
		<-op.ctl => ;
	}
	op.active = 0;
}

asyncsavefile(path: string, winid: int, buf: ref Bufferm->Buffer, q0, q1: int): ref AsyncOp
{
	op := ref AsyncOp;
	op.opid = nextopid++;
	op.ctl = chan[1] of int;
	op.path = path;
	op.active = 1;
	op.winid = winid;

	spawn savetask(op, path, winid, buf, q0, q1);
	return op;
}

savetask(op: ref AsyncOp, path: string, winid: int, buf: ref Bufferm->Buffer, q0, q1: int)
{
	# Check for cancellation before starting
	alt {
		<-op.ctl =>
			op.active = 0;
			return;
		* => ;
	}

	fd := sys->create(path, Sys->OWRITE, 8r664);
	if(fd == nil) {
		alt {
			dat->casync <-= ref AsyncMsg.SaveComplete(op.opid, winid, path, 0, 0, sys->sprint("can't create: %r")) => ;
			<-op.ctl => ;
		}
		op.active = 0;
		return;
	}

	total := q1 - q0;
	written := 0;
	rp := ref Dat->Astring;

	for(q := q0; q < q1; ) {
		# Check for cancellation
		alt {
			<-op.ctl =>
				fd = nil;
				op.active = 0;
				return;
			* => ;
		}

		n := q1 - q;
		if(n > Dat->BUFSIZE)
			n = Dat->BUFSIZE;

		buf.read(q, rp, 0, n);
		ab := array of byte rp.s[0:n];

		nw := sys->write(fd, ab, len ab);
		wantlen := len ab;
		ab = nil;

		if(nw != wantlen) {
			fd = nil;
			alt {
				dat->casync <-= ref AsyncMsg.SaveComplete(op.opid, winid, path, written, 0, sys->sprint("write error: %r")) => ;
				<-op.ctl => ;
			}
			op.active = 0;
			return;
		}

		written += nw;
		q += n;

		# Send progress every 64KB
		if((written % (64*1024)) < Dat->BUFSIZE) {
			alt {
				dat->casync <-= ref AsyncMsg.SaveProgress(op.opid, winid, written, total) => ;
				<-op.ctl =>
					fd = nil;
					op.active = 0;
					return;
				* => ;
			}
		}
	}

	# Get new mtime
	(ok, dir) := sys->fstat(fd);
	mtime := 0;
	if(ok == 0)
		mtime = dir.mtime;

	fd = nil;
	# Final send - non-blocking with cancellation check
	alt {
		dat->casync <-= ref AsyncMsg.SaveComplete(op.opid, winid, path, written, mtime, nil) => ;
		<-op.ctl => ;
	}
	op.active = 0;
}
