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
	checkreject("flag bad/name 1 seen", "unsafe source name");
	checkreject("flag email real-id urgent seen", "usage: flag");

	checkaccept("register email /dis/veltro/sources/mockmail.dis");
	checkrejectdraft("email\nreal-id urgent\nbody", "unsafe message id");

	sys->print("MSGREGISTER: PASS unsafe register names and paths rejected\n");
}

checkaccept(cmd: string)
{
	fd := sys->open(CTL, Sys->OWRITE);
	if(fd == nil) {
		sys->print("MSGREGISTER: FAIL cannot open %s: %r\n", CTL);
		raise "fail:msgregister";
	}
	b := array of byte cmd;
	if(sys->write(fd, b, len b) != len b) {
		sys->print("MSGREGISTER: FAIL rejected safe command %s: %r\n", cmd);
		raise "fail:msgregister";
	}
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

checkrejectdraft(data, want: string)
{
	fd := sys->open("/mnt/msg/draft", Sys->OWRITE);
	if(fd == nil) {
		sys->print("MSGREGISTER: FAIL cannot open /mnt/msg/draft: %r\n");
		raise "fail:msgregister";
	}
	b := array of byte data;
	if(sys->write(fd, b, len b) >= 0) {
		sys->print("MSGREGISTER: FAIL accepted unsafe draft id\n");
		raise "fail:msgregister";
	}
	err := sys->sprint("%r");
	if(!contains(err, want)) {
		sys->print("MSGREGISTER: FAIL wrong draft error: %s\n", err);
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
