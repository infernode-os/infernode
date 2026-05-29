implement ToolContacts;

#
# contacts - Look up phone numbers in the device address book.
#
# Reads /phone/contacts (TSV: <name>\t<kind>\t<number>\n per number)
# and returns rows whose name matches the supplied query
# case-insensitively. Lets the agent take "text mom" or "call sarah at
# work" and resolve a number without making the operator spell out
# the full international format.
#
# /phone/contacts is provided by devphone on platforms with a real
# address book (iOS via CNContactStore; Android via ContentResolver
# once INFR-182 lands). On desktops without a phone bound, /phone is
# absent — the tool returns a clear "not available" error rather than
# silently empty so the agent can fall back to asking the user.
#
# Usage:
#   contacts <query>
#
# Examples:
#   contacts mom
#   contacts sarah
#   contacts smith
#
# Output: one TSV line per matching number — the same wire format the
# Veltro agent's other phone-tools consume, plus a header so the LLM
# has named columns to reason about.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "../tool.m";

ToolContacts: module {
	init:   fn(): string;
	name:   fn(): string;
	doc:    fn(): string;
	exec:   fn(args: string): string;
	schema: fn(): string;
};

PHONE_CONTACTS: con "/phone/contacts";
MAX_RESULTS: con 50;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load Bufio";
	return nil;
}

name(): string  { return "contacts"; }

doc(): string
{
	return "Contacts - Look up phone numbers from the device address book.\n\n" +
		"Usage:\n" +
		"  contacts <query>\n\n" +
		"Arguments:\n" +
		"  query - Substring matched case-insensitively against the\n" +
		"          contact's display name. Empty query returns the first " +
		string MAX_RESULTS + " contacts.\n\n" +
		"Examples:\n" +
		"  contacts mom\n" +
		"  contacts sarah\n" +
		"  contacts smith\n\n" +
		"Output: TSV rows (one number per row):\n" +
		"  name<TAB>kind<TAB>number\n\n" +
		"Where kind is one of mobile / work / home / main / other.\n" +
		"On iOS the first read triggers the contacts permission prompt.\n" +
		"Without permission, the underlying /phone/contacts returns a\n" +
		"single \"# contacts: permission denied …\" line.\n\n" +
		"Requires /phone (mobile build, or desktop mounting a phone's /phone).";
}

schema(): string
{
	return "{" +
		"\"name\":\"contacts\"," +
		"\"description\":\"Search the device address book by name " +
			"(case-insensitive substring match). Returns matching " +
			"contacts as TSV: name\\tkind\\tnumber per row. Use the " +
			"returned number with the sms or dial tools.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"query\":{\"type\":\"string\"," +
					"\"description\":\"Name substring to match (e.g. 'mom', 'sarah', 'smith'). " +
					"Empty string returns the first 50 contacts.\"}" +
			"}," +
			"\"required\":[\"query\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	q := args;
	# Trim surrounding whitespace.
	while(len q > 0 && (q[0] == ' ' || q[0] == '\t'))
		q = q[1:];
	while(len q > 0 && (q[len q - 1] == ' ' || q[len q - 1] == '\t' || q[len q - 1] == '\n'))
		q = q[0:len q - 1];
	ql := str->tolower(q);

	iob := bufio->open(PHONE_CONTACTS, Sys->OREAD);
	if(iob == nil)
		return sys->sprint("contacts: cannot open %s: %r (is /phone bound?)",
			PHONE_CONTACTS);

	out := "name\tkind\tnumber\n";
	matched := 0;
	for(;;) {
		line := iob.gets('\n');
		if(line == nil || len line == 0)
			break;
		# Strip trailing newline.
		if(line[len line - 1] == '\n')
			line = line[0:len line - 1];
		if(len line == 0)
			continue;
		# Skip bridge status / error lines ("# …").
		if(line[0] == '#') {
			# Surface the bridge's status so the agent knows *why*
			# results are missing rather than silently empty.
			out += line + "\n";
			continue;
		}
		# TSV: name\tkind\tnumber
		# Match against the name column (first field). tolower for
		# case-insensitive substring; empty query matches everything.
		tab := -1;
		for(i := 0; i < len line; i++)
			if(line[i] == '\t') { tab = i; break; }
		if(tab < 0)
			continue;	# malformed row — drop
		name := line[0:tab];
		if(ql == "" || contains_lower(name, ql)) {
			out += line + "\n";
			matched++;
			if(matched >= MAX_RESULTS) {
				out += sys->sprint("# truncated at %d rows (query='%s')\n",
					MAX_RESULTS, q);
				break;
			}
		}
	}

	if(matched == 0)
		return sys->sprint("contacts: no matches for '%s'", q);
	return out;
}

# Case-insensitive substring search. Both args are tolower'd at the
# call site for `pat` and we do a manual scan over `s` against
# tolower(s[i:i+len pat]). For typical phone-book sizes (<10k entries)
# the cost is negligible.
contains_lower(s, pat: string): int
{
	if(len pat == 0)
		return 1;
	sl := str->tolower(s);
	for(i := 0; i <= len sl - len pat; i++)
		if(sl[i:i+len pat] == pat)
			return 1;
	return 0;
}
