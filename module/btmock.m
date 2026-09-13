#
#	A fake Bluetooth controller: the other end of an H4 stream.
#
#	Bytes in, bytes out, no process and no fd: feed() takes what the
#	host wrote and returns what the controller says back, so a test
#	can put one on the far end of a pipe (tests/bthci_test.b) and
#	btmock(4) can serve one as a file for bt9p to open. It answers
#	the commands bt9p issues -- Reset, the Read_Local_* set, the scan
#	and name writes, Inquiry with results, and the Broadcom vendor
#	commands the CYW43455's patch upload uses -- with what a real
#	controller answers, and an unknown opcode with Command Status
#	"unknown HCI command", as the specification says.
#
#	It is deliberately a little difficult where a real controller
#	can be: stingy withholds command credits so the host's flow
#	control is exercised, and Inquiry results arrive one per tick()
#	rather than all at once, so a streaming reader sees them stream.
#

Btmock: module
{
	PATH:	con "/dis/lib/btmock.dis";

	init:	fn(b: Bthci);

	Ctlr: adt {
		addr:	array of byte;		# little-endian, as on the wire
		name:	string;
		hci, lmp, manuf:	int;
		scanenable:	int;
		class:	int;
		nearby:	list of ref Bthci->Found;	# what an Inquiry finds
		stingy:	int;			# answer with no credit; tick() refunds it
		owed:	int;			# a credit refund is pending
		inquiring:	list of ref Bthci->Found;	# results not yet emitted
		inquirydone:	int;		# Inquiry Complete not yet emitted
		log:	list of string;		# "cmd 0x0c03 <hex params>", newest first
		d:	ref Bthci->Deframer;

		new:	fn(addr: string): ref Ctlr;
		feed:	fn(c: self ref Ctlr, b: array of byte): array of byte;
		tick:	fn(c: self ref Ctlr): array of byte;
		seen:	fn(c: self ref Ctlr, op: int): int;	# how many times this opcode arrived
	};
};
