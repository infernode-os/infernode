#
# veltrosrv.m - the Veltro agent harness, served as files at /mnt/veltro
#
# A client loads this module and calls init() in a process sharing its
# namespace: the server mounts itself at the mount point (default
# /mnt/veltro) and init returns.  The serving process forks and restricts
# its own namespace first, so the agent never sees the mount.
#
#	veltrosrv [-v] [-n maxsteps] [-m toolmount] [-S scratchdir] [-a tag]
#	          [-t tool,...] [-p path[:ro|:rw],...] [-M mountpoint]
#
# See man/4/veltrosrv for the files served.
#
VeltroSrv: module {
	PATH: con "/dis/veltro/veltrosrv.dis";

	init: fn(nil: ref Draw->Context, args: list of string);
};
