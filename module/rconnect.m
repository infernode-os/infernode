#
# rconnect(2): a connection to a 9front cpu server's rcpu service, as
# 9front's rconnect(1) makes one: p9any (dp9ik) through factotum, TLS
# with the session secret as its key (tlspsk(2)), and an rc script for
# the server to run, whose input and output are then the connection.
# Not in CNSA mode: dp9ik is 9front's classical authentication.
#
Rconnect: module
{
	PATH:	con "/dis/lib/rconnect.dis";

	init:	fn(): string;
	# host as dial(2) takes it: host, net!host or net!host!port
	# (port 17019, rcpu, by default); keyspec more factotum attributes
	connect:	fn(host, keyspec, script: string): (ref Sys->FD, ref Factotum->Authinfo, string);
	# rc's quoting of a word
	rcquote:	fn(s: string): string;
};
