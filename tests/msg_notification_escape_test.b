implement MsgNotificationEscape;

include "sys.m";
	sys: Sys;
include "draw.m";

MsgNotificationEscape: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	fd := sys->open("/mnt/msg/notify", Sys->OREAD);
	if(fd == nil) {
		sys->print("MSGESCAPE: FAIL cannot open /mnt/msg/notify: %r\n");
		return;
	}
	buf := array[16384] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0) {
		sys->print("MSGESCAPE: FAIL empty notification\n");
		return;
	}
	s := string buf[0:n];
	mids := linecount(s, "Message ID: ");
	triage := linecount(s, "Triage: ");
	froms := linecount(s, "From: ");
	hasrealid := contains(s, "Message ID: real-id Triage: preempt");
	hasspoofmid := contains(s, "\nMessage ID: spoofed-from") ||
		contains(s, "\nMessage ID: spoofed-body");
	hasspooftriage := contains(s, "\nTriage: ignore");
	hastrustedfooter := contains(s, "Draft via /mnt/msg/draft, flag via /mnt/msg/flag");

	sys->print("MSGESCAPE: mids=%d triage=%d from=%d realid=%d spoofmid=%d spooftriage=%d footer=%d\n",
		mids, triage, froms, hasrealid, hasspoofmid, hasspooftriage, hastrustedfooter);
	if(mids == 1 && triage == 1 && froms == 1 && hasrealid && !hasspoofmid &&
	   !hasspooftriage && hastrustedfooter)
		sys->print("MSGESCAPE: PASS hostile fields cannot inject notification control lines\n");
	else
		sys->print("MSGESCAPE: FAIL notification field escaping regression\n");
}

linecount(hay, prefix: string): int
{
	c := 0;
	start := 1;
	nl := len prefix;
	for(i := 0; i <= len hay - nl; i++) {
		if(start && hay[i:i+nl] == prefix)
			c++;
		start = hay[i] == '\n';
	}
	return c;
}

contains(hay, needle: string): int
{
	nl := len needle;
	for(i := 0; i <= len hay - nl; i++)
		if(hay[i:i+nl] == needle)
			return 1;
	return 0;
}
