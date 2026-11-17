#
# A connection to a mail server (IMAP, SMTP, POP3), read and written
# under deadlines and in bounded pieces.
#
# The mail protocols' libraries read replies with no limit of time or
# size: a server that stopped answering held its caller for ever, and
# one line or one count from it could be as long as it liked.  Every
# read and write here ends by a deadline, a line is no longer than its
# caller allows, and a connection that fails is closed: its processes
# go and every later call returns the reason.
#
# TLS is the tree's client (tls(2)): the server's chain is verified
# against the system's roots and its name against the certificate.
# Include keyring.m and tls.m before this.
#

Mailconn: module
{
	PATH: con "/dis/lib/mailconn.dis";

	# how a connection is made
	CLEAR,			# as it is dialled: no TLS (SMTP to port 25, POP3 to 110)
	IMPLICIT,		# TLS from the first byte
	IMAPSTARTTLS,		# IMAP's greeting and STARTTLS in clear, then TLS
	SMTPSTARTTLS: con iota;	# SMTP's greeting, EHLO and STARTTLS in clear, then TLS

	STOPPED: con "stopped";	# waitline's error when its stop channel spoke

	init:	fn(): string;

	Link: adt {
		fd:	ref Sys->FD;
		tc:	ref TLS->Conn;		# its TLS connection; nil in clear
		err:	string;			# why it is down; nil while it is up
		rc:	chan of array of byte;	# from the reader; nil at end of file
		wc:	chan of array of byte;	# to the writer
		wdone:	chan of string;		# and its answer
		tick:	chan of int;
		never:	chan of int;
		rpid, wpid, tpid:	int;
		buf:	array of byte;		# read and not yet taken
		rp, wp:	int;
		idle, total:	int;		# the deadline: ms without a byte, ms in all
		t0, tlast:	int;

		# addr is a dial string (tcp!host!port); servername the name the
		# certificate must carry; helo the name EHLO gives (SMTPSTARTTLS).
		# The connection is made, TLS and all, within ms milliseconds.
		dial:	fn(addr, servername: string, how: int, helo: string, ms: int): (ref Link, string);
		# From now, reads and writes fail ("timed out") once idlems pass
		# with nothing moving or totalms pass in all (0: no such limit).
		deadline:	fn(c: self ref Link, idlems, totalms: int);
		# A line, without its CR LF.  One longer than max bytes is an
		# error, and ends the connection.
		getline:	fn(c: self ref Link, max: int): (string, string);
		# getline with no deadline, given up (STOPPED) when stop speaks
		waitline:	fn(c: self ref Link, max: int, stop: chan of int): (string, string);
		# exactly n bytes, in memory taken as they arrive
		getbytes:	fn(c: self ref Link, n: int): (array of byte, string);
		write:	fn(c: self ref Link, b: array of byte): string;
		# hang up: the processes go and the descriptor is dropped
		close:	fn(c: self ref Link);
	};
};
