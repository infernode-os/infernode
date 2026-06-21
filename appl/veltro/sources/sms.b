implement SmsSrc;

#
# sms - SMS message source for Veltro
#
# Implements MsgSrc on top of the cross-platform /phone device
# (emu/port/devphone.c). watch() loops reading /phone/sms; each record
# arrives as the canonical Hellaphone wire format produced by devphone:
#
#     from <number> <iso-timestamp>\n
#     <body...>\n
#
# Anything else (empty, EOF, "-1") means the platform bridge had nothing
# to surface; we sleep briefly and re-read so msg9p stays responsive.
#
# send() writes the symmetric "send <number> <body>" line to /phone/sms.
# devphone's phonewrite splits the verb and hands (number, body) to
# phonebridge_send_sms — on iOS that opens the MFMessageComposeViewController
# pre-filled and the user one-taps; on Android it goes through SmsManager
# directly (when INFR-182 lands the live wiring).
#
# Platform reality (informational only — this source loads on every
# platform, it just produces no notifications when the bridge has no
# inbox API):
#   iOS:      no inbox API — bridge never calls phonebridge_post_sms,
#             so devphone's queue stays empty and watch() blocks forever.
#   Android:  bridge calls phonebridge_post_sms() from the
#             ContentResolver SMS_RECEIVED observer (INFR-182).
#   desktop:  no #f device registered; userspace mounts a phone's
#             /phone over 9P. Reads block on the remote queue.
#
# No config keys — devphone owns the queueing now; the source is just a
# blocking-read loop. (Earlier versions of this file took a `pollms`
# argument; deleted with the hellaphone-style refactor.)

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "msgsrc.m";

SmsSrc: module {
	PATH: con "/dis/veltro/sources/sms.dis";

	init:    fn(config: string): string;
	name:    fn(): string;
	capabilities: fn(): int;
	status:  fn(): string;
	close:   fn(): string;
	watch:   fn(updates: chan of ref MsgSrc->Notification, stop: chan of int): string;
	enumerate: fn(channel: string, count: int): (list of ref MsgSrc->Message, string);
	fetch:   fn(id: string): (ref MsgSrc->Message, string);
	search:  fn(query: string): (list of ref MsgSrc->Message, string);
	send:    fn(msg: ref MsgSrc->Message): string;
	reply:   fn(origid, body: string): string;
	setflag: fn(id: string, flag, add: int): string;

	# Exposed for tests/sms_msgsrc_test.b. Parses one devphone wire
	# record into a Message; returns nil on a malformed record. Safe
	# to call before init() so the test can load this module
	# standalone and exercise the parser in isolation.
	parserecord: fn(rec: string): ref MsgSrc->Message;
};

Message: import MsgSrc;
Notification: import MsgSrc;

PHONE_SMS: con "/phone/sms";

# Tracks the last seen sender (number) per message ID so reply() can
# pair an origid back to a number without round-tripping the bridge.
# Bounded — see addseenpair below.
seen_ids: list of (string, string);	# (id, number)
SEEN_MAX: con 256;

stderr: ref Sys->FD;
closed := 0;

init(config: string): string
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";

	# No config keys today — kept around so a future opt (e.g. a
	# read buffer hint) doesn't need a signature change.
	config = config;

	closed = 0;
	return nil;
}

name(): string { return "sms"; }

# SMS is conversational but stream-only: no inbox history (enumerate/fetch
# unsupported) and no read/flag state surfaced through /phone (setflag no-op).
capabilities(): int
{
	return MsgSrc->CAP_WATCH | MsgSrc->CAP_SEND | MsgSrc->CAP_REPLY;
}

status(): string
{
	# Read /phone/status to get a human-readable bridge state. Fall back
	# to "unconfigured" if the device isn't bound (no /phone tree).
	fd := sys->open("/phone/status", Sys->OREAD);
	if(fd == nil)
		return "unavailable (/phone not bound — bind -a '#f' /phone)";
	buf := array[256] of byte;
	rn := sys->read(fd, buf, len buf);
	if(rn <= 0)
		return "ready (no detail from bridge)";
	return string buf[:rn];
}

close(): string
{
	closed = 1;
	return nil;
}

watch(updates: chan of ref Notification, stop: chan of int): string
{
	# devphone backs /phone/sms with a per-channel Queue (hellaphone-
	# pattern, listener registry). One blocking read returns one full
	# wire-format record when the bridge posts incoming SMS, or stays
	# parked forever on platforms where the bridge can never push
	# (iOS — no inbox API). No polling, no sleep, no tunable interval.
	# A separate kproc drives the read so the stop channel is always
	# responsive.
	recs := chan of array of byte;
	errs := chan of string;
	spawn reader(recs, errs);

	for(;;) alt {
	<-stop =>
		closed = 1;
		return nil;
	rec := <-recs =>
		if(closed)
			return nil;
		handlerecord(updates, string rec);
	emsg := <-errs =>
		if(closed)
			return nil;
		err := ref Notification;
		err.kind = "error";
		err.detail = emsg;
		alt {
		updates <-= err => ;
		* => ;
		}
	}
}

# Block on /phone/sms forever, deliver each record. If /phone is
# unmounted the open fails; surface once and exit (the supervising
# msg9p will not re-spawn until ctl re-registers).
reader(recs: chan of array of byte, errs: chan of string)
{
	fd := sys->open(PHONE_SMS, Sys->OREAD);
	if(fd == nil) {
		alt {
		errs <-= sys->sprint("sms: cannot open %s: %r", PHONE_SMS) => ;
		* => ;
		}
		return;
	}
	for(;;) {
		if(closed)
			return;
		buf := array[4096] of byte;
		rn := sys->read(fd, buf, len buf);
		if(rn <= 0)
			return;	# EOF — bridge hung up the queue
		recs <-= buf[:rn];
	}
}

# Handle one wire-format record from /phone/sms.
handlerecord(updates: chan of ref Notification, rec: string)
{

	m := parserecord(rec);
	if(m == nil) {
		# Garbled record — emit an error notification so the agent
		# stack at least sees something went wrong, then move on.
		err := ref Notification;
		err.kind = "error";
		err.detail = "sms: malformed inbound record from /phone/sms";
		alt {
		updates <-= err => ;
		* => ;
		}
		return;
	}

	addseenpair(m.id, m.sender);

	nn := ref Notification;
	nn.kind = "new";
	nn.msg = m;
	# msg9p's notify loop may be full or stalled. Drop rather than
	# block — the next /phone/sms read will surface fresher state
	# anyway. (msg9p has its own bounded queue downstream.)
	alt {
	updates <-= nn => ;
	* => ;
	}
}

# Parse the devphone wire format:
#     from <number> <iso-timestamp>\n
#     <body...>\n
# Returns nil if the record doesn't match.
parserecord(rec: string): ref Message
{
	# Split off the first line as the header.
	nlpos := indexof(rec, '\n');
	if(nlpos < 0)
		return nil;
	header := rec[0:nlpos];
	body := rec[nlpos+1:];
	# Strip a trailing newline from body if present (devphone adds one).
	if(len body > 0 && body[len body - 1] == '\n')
		body = body[0:len body - 1];

	(nt, toks) := sys->tokenize(header, " \t");
	if(nt < 3)
		return nil;
	verb := hd toks;
	if(verb != "from")
		return nil;
	number := hd tl toks;
	ts := hd tl tl toks;

	m := ref Message;
	# ID is (timestamp + number) so each record is unique without round-
	# tripping the bridge for a sequence number. msg9p dedup keys off id.
	m.id = ts + ":" + number;
	m.source = "sms";
	m.channel = "inbox";
	m.sender = number;
	m.recipient = "";	# the device's own number — bridge doesn't expose it.
	m.subject = "";
	m.body = body;
	m.timestamp = ts;
	m.threadid = number;	# threading by remote party — same as Messages.app.
	m.replyto = "";
	m.flags = MsgSrc->FUNREAD;
	m.headers = header;
	return m;
}

# Track id → number so reply() can address the original sender.
# Bounded; oldest pairs fall off when SEEN_MAX is hit. Linear scans
# are fine — SMS arrival rates are nothing close to taxing.
addseenpair(id, num: string)
{
	# Prepend; trim from the end if oversize.
	seen_ids = (id, num) :: seen_ids;
	count := 0;
	prev: list of (string, string);
	for(p := seen_ids; p != nil; p = tl p) {
		count++;
		if(count >= SEEN_MAX)
			break;
		prev = hd p :: prev;
	}
	# Rebuild in original order.
	out: list of (string, string);
	for(p = prev; p != nil; p = tl p)
		out = hd p :: out;
	seen_ids = out;
}

lookupseen(id: string): string
{
	for(p := seen_ids; p != nil; p = tl p) {
		(pid, pnum) := hd p;
		if(pid == id)
			return pnum;
	}
	return "";
}

enumerate(channel: string, count: int): (list of ref Message, string)
{
	# /phone/sms is a stream-only event file — there is no inbox-history
	# API on either iOS or Android-via-stub. Honestly say so.
	channel = channel; count = count;
	return (nil, "sms: enumerate not supported (no inbox-history API)");
}

fetch(id: string): (ref Message, string)
{
	id = id;
	return (nil, "sms: fetch not supported (no inbox-history API)");
}

search(query: string): (list of ref Message, string)
{
	query = query;
	return (nil, "sms: search not supported (no inbox-history API)");
}

send(msg: ref Message): string
{
	if(msg == nil)
		return "sms: send: nil message";
	if(msg.recipient == nil || msg.recipient == "")
		return "sms: send: missing recipient";
	if(msg.body == nil || msg.body == "")
		return "sms: send: missing body";

	fd := sys->open(PHONE_SMS, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("sms: cannot open %s: %r (is /phone bound?)",
			PHONE_SMS);

	line := "send " + msg.recipient + " " + msg.body;
	b := array of byte line;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("sms: write to %s failed: %r", PHONE_SMS);
	return nil;
}

reply(origid, body: string): string
{
	num := lookupseen(origid);
	if(num == "")
		return "sms: reply: origid " + origid + " not in recently-seen table";
	m := ref Message;
	m.source = "sms";
	m.recipient = num;
	m.body = body;
	return send(m);
}

setflag(id: string, flag, add: int): string
{
	# SMS has no read/unread/star semantics surfaced through /phone.
	# Idempotent no-op so the agent's flag flips don't fail loudly.
	id = id; flag = flag; add = add;
	return nil;
}

# String index-of for a single byte. Returns -1 if absent.
indexof(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}
