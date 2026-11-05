#
# gefs: errors, as 9front's error.c and main.c. error() and broke() raise
# a Limbo exception, "gefs:" and the message, where the C longjmps;
# waserror/nexterror are exception blocks and a re-raise. broke() is an
# error that means the disk cannot be trusted any more: as in 9front it
# makes the file system read-only, and says so.
#

Efs:	con "internal error";
Eheight:	con "tree exceeds max height";
Enoval:	con "message to missing key";
Ecorrupt:	con "block contents corrupted";
Efsvers:	con "unknown fs version";
Eimpl:	con "not implemented";
Ebotch:	con "protocol botch";
Eio:	con "i/o error";
Enofid:	con "unknown fid";
Efid:	con "fid in use";
Etype:	con "invalid fid type";
Edscan:	con "invalid dir scan offset";
Esrch:	con "directory entry not found";
Eexist:	con "create/wstat -- file exists";
Emode:	con "open/create -- unknown mode";
Efull:	con "file system full";
Estuffed:	con "emergency blocks exhausted";
Eauth:	con "authentication failed";
Elength:	con "name too long";
Eperm:	con "permission denied";
Einuse:	con "resource in use";
Ebadf:	con "invalid file";
Ename:	con "create/wstat -- bad character in file name";
Enomem:	con "out of memory";
Eattach:	con "attach required";
Enosnap:	con "attach -- bad specifier";
Edir:	con "invalid directory";
Esyntax:	con "syntax error";
Enouser:	con "user does not exist";
Enogrp:	con "group does not exist";
Efsize:	con "file too big";
Ebadu:	con "attach -- unknown user or failed authentication";
Erdonly:	con "file system read only";
Elocked:	con "open/create -- file is locked";
Eauthp:	con "authread -- auth protocol not finished";
Eauthd:	con "authread -- not enough data";
Eauthph:	con "auth phase error";
Enone:	con "auth -- user 'none' requires no authentication";
Enoauth:	con "auth -- authentication disabled";
Ephase:	con "phase error -- use after remove";
Ecdir:	con "create -- in a non-directory";
Ebadctl:	con "invalid control message";
Enoqid:	con "qids exhausted";
Enempty:	con "directory is not empty";
Enoadm:	con "missing adm snapshot";
Echeck:	con "check -- fs not ok";
Eopen:	con "read/write -- on non open fid";
Eoffset:	con "read/write -- offset negative";
Esnapu:	con "snap -- is currently mounted";
Esnapx:	con "snap -- already exists";
Esnapr:	con "snap -- reserved name";
Ewstatb:	con "wstat -- unknown bits in qid.type/mode";
Ewstatd:	con "wstat -- attempt to change directory";
Ewstatg:	con "wstat -- not in group";
Ewstatl:	con "wstat -- attempt to make length negative";
Ewstatm:	con "wstat -- attempt to change muid";
Ewstato:	con "wstat -- not owner or group leader";
Ewstatu:	con "wstat -- not owner";
Ewstatq:	con "wstat -- attempt to change qid";

Eprefix:	con "gefs:";

error(s: string)
{
	raise Eprefix+s;
}

broke(s: string)
{
	if(fs != nil)
		fs.rdonly = 1;
	sys->fprint(sys->fildes(2), "gefs: %s\n", s);
	raise Eprefix+s;
}

# the message of an exception raised by error() or broke(), or nil for another
errmsg(e: string): string
{
	if(len e >= len Eprefix && e[0:len Eprefix] == Eprefix)
		return e[len Eprefix:];
	return nil;
}

bassert(b: ref Blk, cond: int, what: string)
{
	if(!cond)
		broke(sys->sprint("assert failed for [%bux]: %s", b.bp.addr, what));
}

fsassert(cond: int, what: string)
{
	if(!cond)
		broke("assert failed: "+what);
}
