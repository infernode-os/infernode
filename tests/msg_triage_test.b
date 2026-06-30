implement MsgTriage;

# Deterministic pre-LLM triage test. msg9p stamps a verdict on each notification
# from the message's structured fields (flags/headers/sender); msgwatch routes:
# ignore/context are filtered and NEVER injected into the agent, only wake/preempt
# are. Reads msgwatch's log and asserts the routing. No LLM involved.
# Expected for the mock inbox: wake=2, preempt=1, ignore=1, context=1, injected=3.

include "sys.m";
	sys: Sys;
include "draw.m";

MsgTriage: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	fd := sys->open("/tmp/mw.log", Sys->OREAD);
	if(fd == nil) {
		sys->print("MSGTRIAGE: FAIL cannot open msgwatch log: %r\n");
		return;
	}
	buf := array[32768] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0) {
		sys->print("MSGTRIAGE: FAIL empty log\n");
		return;
	}
	s := string buf[0:n];
	wake := count(s, "[triage wake] relayed");
	preempt := count(s, "[triage preempt] relayed");
	ignore := count(s, "[triage ignore]");
	context := count(s, "[triage context]");
	injected := count(s, "relayed to Meta Agent");
	sys->print("MSGTRIAGE: wake=%d preempt=%d ignore=%d context=%d injected=%d\n",
		wake, preempt, ignore, context, injected);
	if(wake == 2 && preempt == 1 && ignore == 1 && context == 1 && injected == 3)
		sys->print("MSGTRIAGE: PASS ignore+context filtered pre-LLM; only wake+preempt dispatched\n");
	else
		sys->print("MSGTRIAGE: FAIL routing mismatch (want wake=2 preempt=1 ignore=1 context=1 injected=3)\n");
}

count(hay, needle: string): int
{
	c := 0;
	nl := len needle;
	for(i := 0; i <= len hay - nl; i++)
		if(hay[i:i+nl] == needle)
			c++;
	return c;
}
