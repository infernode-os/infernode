# smtp protocol independent access to an email server.
 
Smtp : module
{
	PATH : con "/dis/lib/smtp.dis";
 
	# all functions return status (-ve when error)

         # open a connection with the email server
         # requires the email server's name or address or nil if a default server is to be used
	# returns (status, errror string)
         open: fn(server : string) : (int, string);
	# open a connection and authenticate (AUTH PLAIN) over TLS: from the
	# start (IMPLICIT_TLS, port 465) or after STARTTLS (port 587); server
	# is a host, or host!port.  PLAIN, which would send the password in
	# clear, is refused.
	PLAIN, IMPLICIT_TLS, STARTTLS: con iota;
	authopen: fn(user, password, server : string, mode: int) : (int, string);
	# send mail - returns (status, error string)
	# fromwho and each recipient is an address as okaddr has it, and is
	# refused otherwise before anything is sent.  msg is the message's
	# text in pieces, each one or more lines (an empty piece an empty
	# line).  A NUL anywhere in it, or a carriage return inside a header
	# line, refuses the message; one inside a body line ends that line.
	sendmail: fn(fromwho: string, 
		             towho: list of string, 
		             cc : list of string,
		             msg: list of string) : (int, string);

	# An address that can stand between < and > in MAIL FROM and RCPT TO:
	# not empty, no blank, control character, DEL, < or >.
	okaddr: fn(addr: string): int;
	# A header's value that stays one header: no CR, LF or NUL.
	okheader: fn(value: string): int;

	# Every reply is waited for ms milliseconds (30 seconds unless set
	# here), and so is the connection's making.  After a timeout, a
	# failed write or a reply that is not SMTP the connection is closed.
	timeout: fn(ms: int);

         # close the connection - returns (status, error string)
         close: fn() : (int, string);
};
