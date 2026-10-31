#
# appfs - a program's own files, served and posted (#1019)
#
# A program with something to show another (an agent's tool, Lucifer)
# names its files; appfs serves them, with event beside them, as a 9P
# tree posted as #s<spec>/fs (post9p(2)).  A read or write of one of
# them comes to the program as a Req on its channel, in its own loop,
# answered from what it holds now: nothing is written ahead of time,
# nothing is polled.  A read is made once an open (at offset 0), so a
# reader taking it in pieces sees one text.  A read of event waits for
# the program's next event (one line); each open has its own queue.
#
Appfs: module
{
	PATH:	con "/dis/lib/appfs.dis";

	Req: adt {
		file:	string;		# one of the names served
		data:	string;		# nil: a read; else what was written
		# the text read; or, for a write, nil if done, else why not
		# (the write's error)
		reply:	chan of string;
	};

	init:	fn(): string;

	# Serve files (and event) posted as #s<spec>/fs, or fs.1 ... for
	# another instance: the path posted and the tether, or nil and why
	# not.  The program keeps the tether: when it goes, or drops it,
	# the files go (appfs's procs are in a group of their own).
	serve:	fn(spec: string, files: array of string, reqs: chan of ref Req): (string, ref Sys->FD, string);

	# Give every reader of event the line msg (not again to one that
	# has it waiting already).
	event:	fn(msg: string);
};
