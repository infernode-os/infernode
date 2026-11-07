#
# post9p - a 9P server posted in #s, Inferno's /srv
#
# #s<spec> is one directory per spec (and user) across every name space,
# so a file posted there is where any process of the user can find the
# server, whatever its name space was built from:
#	mount -A '#seditor/fs' /mnt/editor
# Each open of the posted file is a 9P connection of its own, whose
# server end is sent on the poster's conns channel to be served (one
# Styxserver each, say).  A process with NODEVS cannot attach #s<spec>,
# so an agent's tools reach a posted server only through a trusted
# wrapper that mounts it for them (tools9p).
#
Post9p: module
{
	PATH:	con "/dis/lib/post9p.dis";

	Post: adt {
		path:	string;			# #s<spec>/<name>
		quit:	chan of int;
		# Take the posted file away.  Connections made through it
		# stay until their clients go.
		unpost:	fn(p: self ref Post);
	};

	init:	fn();

	# Post as #s<spec>/fs, or fs.1, fs.2 ... where one is taken (a
	# second instance of a program): the Post, or why not.
	post:	fn(spec: string, conns: chan of ref Sys->FD): (ref Post, string);

	# Post as #s<spec>/<name>, a name of the caller's.
	postas:	fn(spec, name: string, conns: chan of ref Sys->FD): (ref Post, string);
};
