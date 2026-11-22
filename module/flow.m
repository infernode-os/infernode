#
# Flow: a table of the flows on a wire, and what to do with each.
# Built in (libinterp/flow.c), as $Tensor and $Bayer are: functions
# over arrays, keeping nothing between calls. The table is the
# caller's array of byte and holds no pointers; every call checks it
# is a table before using it, so a program that writes on it spoils
# its own table and nothing else.
#
# EXPERIMENTAL: for minos's measurements (infernode-os/minos,
# exp/flow). The interface will change.
#
Flow: module
{
	PATH:	con	"$Flow";

	# verdicts
	Pass, Drop, Divert, Copy: con iota+1;

	# key's refusals
	Short:	con -1;		# the frame ends before what its headers promise
	Notip:	con -2;		# not IPv4 or IPv6
	Frag:	con -3;		# a later fragment: it has no ports
	Bad:	con -4;		# headers that contradict themselves

	Keylen:	con 40;
	Entlen:	con 96;		# a flow's record, as sweep gives it

	# the time, in ms, that run stamps frames with: use it for every
	# now given to this module
	now:	fn(): big;

	# bytes a table of n entries needs
	size:	fn(n: int): int;

	# make tab an empty table of n entries (a power of two, at least
	# 16), hashed under the secret k0, k1
	init:	fn(tab: array of byte, n: int, k0, k1: big);

	# the flow an Ethernet frame belongs to, into k (Keylen bytes):
	# 0 or 1, the direction it travels, or a refusal
	key:	fn(frame: array of byte, k: array of byte): int;

	# a packet of n bytes on flow k, direction dir: the flow's
	# verdict, counted, or 0 if the table has no such flow
	lookup:	fn(tab: array of byte, k: array of byte, dir, n: int, now: big): int;

	# give flow k a verdict; it ends after idle ms without a packet.
	# 0 if the table has no room for it
	add:	fn(tab: array of byte, k: array of byte, dir, verdict, idle: int, now: big): int;

	# the records of flows that have ended, Entlen bytes each, into
	# out; how many. Each is reported once
	sweep:	fn(tab: array of byte, now: big, out: array of byte): int;

	# flow k's record as it stands (Entlen bytes into out), counting
	# nothing and ending nothing: 1, or 0 if the table has no such flow
	stat:	fn(tab: array of byte, k: array of byte, out: array of byte): int;

	# forget flow k now, with no record: 1 if it was there
	del:	fn(tab: array of byte, k: array of byte): int;

	# forward without Limbo: read frames from file descriptor in; one
	# whose flow passes is written to out, one whose flow drops is
	# dropped. The first frame the table cannot decide (no such flow,
	# another verdict, not a flow at all) is left in buf and its length
	# returned, for the caller to judge. 0 after max frames; -1 when a
	# read fails.
	run:	fn(tab: array of byte, in, out: int, buf: array of byte, max: int): int;
};
