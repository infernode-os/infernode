#
# gefs: the constants and shapes of 9front's dat.h, in Limbo.
#
# The on-disk format is 9front's, byte for byte, so a disk made by one
# is read by the other: every size and code below is theirs. What is
# not here is what Limbo makes unnecessary -- locks and epochs for the
# readers, mutator, syncers and sweeper that 9front runs in parallel.
# This one serves from a single loop (see gefs.b), so nothing is read
# while it changes.
#

KiB:	con big 1024;
MiB:	con big 1024*KiB;
GiB:	con big 1024*MiB;

Lgblk:	con 14;
Blksz:	con 1<<Lgblk;		# 16384

Max9p:	con 32*1024;
Nsec:	con big 1000000000;
Maxent:	con 256;		# the largest ent key, with its terminator
Maxname: con Maxent-1-9-1;	# the largest name element
Maxuname: con 64;

Keymax:	con Maxent;
Inlmax:	con 512;
Ptrsz:	con 24;			# off, hash, gen
Pptrsz:	con 26;			# off, hash, gen, fill
Fillsz:	con 2;
Offksz:	con 17;			# type, qid, off
Snapsz:	con 9;			# tag, snapid
Dpfxsz:	con 9;
Upksz:	con 9;
Dlksz:	con 1+8+8;		# tag, death, birth
Dlvsz:	con Ptrsz+Ptrsz;	# head and tail of a deadlist
Dlkvpsz: con Dlksz+Dlvsz;
Treesz:	con 4+4+4+4+8+8+8+8+Ptrsz;
Xdirsz:	con 8+8+4+1+4+8+8+8+4+4+4;
Kvmax:	con Keymax+Inlmax;
Kpmax:	con Keymax+Ptrsz;
Wstatmax: con 4+8+8+8;
Arenasz: con 8+8+8+8;

Pivhdsz: con 10;
Leafhdsz: con 6;
Loghdsz: con 2+2+8+Ptrsz;	# type, len, hash, chain
Rootsz:	con 4+Ptrsz;
Pivsz:	con Blksz-Pivhdsz;
Bufspc:	con (Blksz-Pivhdsz)/2;
Pivspc:	con Blksz-Pivhdsz-Bufspc;
Logspc:	con Blksz-Loghdsz;
Logslop: con 16+16+8;
Leafspc: con Blksz-Leafhdsz;
Msgmax:	con 1+Kvmax;		# Kvmax > Kpmax
Maxheight: con 32;

# the fixed qids of a reamed file system
Qmainroot, Qadmroot, Qadmuser, Nreamqid: con iota;

# key types
Kdat,	# qid[8] off[8] => ptr: a page of a file
Kent,	# pqid[8] name[n] => dir: a directory entry
Kup,	# qid[8] => Kent: a directory's parent
Klabel,	# name[] => snapid[]
Ksnap,	# sid[8] => ref[8], tree[52]
Kdlist,	# snap[8] gen[8] => hd[ptr], tl[ptr]
Kconf:	con iota;

# block flags (in memory)
Bdirty:	con 1<<0;
Bfinal:	con 1<<1;
Bfreed:	con 1<<2;
Bcached: con 1<<3;
Bqueued: con 1<<4;
Blimbo:	con 1<<5;
Bstatic: con 1<<6;
Bdefer:	con 1<<7;	# a tree root not yet hashed or written (settle)

# label flags
Lmut:	con 1<<0;

# block types
Tdat, Tpivot, Tleaf, Tlog, Tdlist, Tarena: con iota;
Tsuper:	con 16r6765;		# "ge"

# getblk flags
GBraw:	con 1<<0;
GBwrite: con 1<<1;
GBnochk: con 1<<2;
GBtry:	con 1<<3;

# messages
Onop, Oinsert, Odelete, Oclearb, Oclobber, Owstat, Orelink, Oreprev, Oincref, Nmsgtype: con iota;

# wstat message flags, and their data in this order
Owsize:	con 1<<0;	# [8]
Owmode:	con 1<<1;	# [4]
Owmtime: con 1<<2;	# [8] nsec
Owatime: con 1<<3;	# [8] nsec
Owuid:	con 1<<4;	# [4]
Owgid:	con 1<<5;	# [4]
Owmuid:	con 1<<6;	# [4]
Owqpath: con 1<<7;	# [8]

# allocation log
LogNop, LogAlloc1, LogFree1, LogSync, LogAlloc, LogFree: con iota;
Log2wide: con LogAlloc;

# the qids of the virtual files under a mount's dump
Qmagic:	con big 1<<63;
Qdump:	con Qmagic;
Qctl:	con Qmagic+big 1;
Qstatus: con Qmagic+big 2;

Superver: con "gefs9.00";

Bptr: adt {
	addr:	big;
	hash:	big;
	gen:	big;
};

Kvp: adt {
	k:	array of byte;
	v:	array of byte;
};

Msg: adt {
	op:	int;
	k:	array of byte;
	v:	array of byte;
};

Tree: adt {
	# in memory
	memgen:	big;
	dirty:	int;
	# on disk
	nref:	int;
	nlbl:	int;
	ht:	int;
	flag:	int;
	bp:	Bptr;
	gen:	big;
	pred:	big;
	succ:	big;
	base:	big;
};

Dlist: adt {
	gen:	big;	# deadlist gen
	bgen:	big;	# birth gen
	head:	Bptr;
	tail:	Bptr;
	ins:	ref Blk;	# loaded head
	cnext:	cyclic ref Dlist;
	cprev:	cyclic ref Dlist;
	chain:	cyclic ref Dlist;
};

Xdir: adt {
	flag:	big;
	qpath:	big;
	qvers:	int;
	qtype:	int;
	mode:	int;
	atime:	big;	# nsec
	mtime:	big;	# nsec
	length:	big;
	uid:	int;
	gid:	int;
	muid:	int;
	name:	string;
};

Blk: adt {
	ty:	int;	# @0
	# pivots and leaves
	nval:	int;	# @2
	valsz:	int;	# @4
	nbuf:	int;	# @6, pivot
	bufsz:	int;	# @8, pivot
	# logs
	logsz:	int;	# @2
	logh:	big;	# @4
	logp:	Bptr;	# @12, the next of a deadlist chain

	bp:	Bptr;
	flag:	int;
	refs:	int;
	buf:	array of byte;		# Blksz
	data:	array of byte;		# buf, past its header
	cnext:	cyclic ref Blk;	# lru
	cprev:	cyclic ref Blk;
	hnext:	cyclic ref Blk;	# cache hash chain
};

# the zero block pointer
Zb(): Bptr
{
	return Bptr(big -1, big -1, big -1);
}

