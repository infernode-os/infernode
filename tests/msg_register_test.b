implement MsgRegisterTest;

include "sys.m";
	sys: Sys;

include "draw.m";

MsgRegisterTest: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

CTL: con "/mnt/msg/ctl";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	checkreject("register bad/name /tests/msg_badsrc.dis", "unsafe source name");
	checkreject("register bad /tmp/../tests/msg_badsrc.dis", "unsafe module path");
	checkreject("register bad tests/msg_badsrc.dis", "unsafe module path");
	checkreject("register bad /tests/msg_badsrc", "unsafe module path");

	sys->print("MSGREGISTER: PASS unsafe register names and paths rejected\n");
}

checkreject(cmd, want: string)
{
	fd := sys->open(CTL, Sys->OWRITE);
	if(fd == nil) {
		sys->print("MSGREGISTER: FAIL cannot open %s: %r\n", CTL);
		raise "fail:msgregister";
	}
	b := array of byte cmd;
	if(sys->write(fd, b, len b) >= 0) {
		sys->print("MSGREGISTER: FAIL accepted unsafe command: %s\n", cmd);
		raise "fail:msgregister";
	}
	err := sys->sprint("%r");
	if(!contains(err, want)) {
		sys->print("MSGREGISTER: FAIL wrong error for %s: %s\n", cmd, err);
		raise "fail:msgregister";
	}
}

contains(hay, needle: string): int
{
	nl := len needle;
	for(i := 0; i <= len hay - nl; i++)
		if(hay[i:i+nl] == needle)
			return 1;
	return 0;
}
