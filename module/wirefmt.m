#
# wirefmt.m - Shared wire-format codec for the LLM-bridge TOOL: protocol.
#
# Single source of truth for the STOP:/TOOL: tool-call line, shared between
# the PRODUCER (appl/lib/llmclient.b, running inside llmsrv) and the CONSUMER
# (appl/veltro/agentlib.b). Both modules load this one codec so the escape and
# unescape halves cannot drift apart. The previous split — escape in
# llmclient.b, unescape in agentlib.b — silently corrupted any tool argument
# containing a backslash. See docs/veltro-llm-bridge-bug-taxonomy.md (Class A/B).
#
# A tool call is carried on a single line:
#
#     TOOL:<id>:<name>:<args>
#
# Each field is escaped so that the field delimiter ':', the line delimiter
# '\n', and the escape character '\' are all representable unambiguously:
#
#     '\'  -> "\\"      '\n' (newline) -> "\n"      ':' -> "\:"
#
# escapefield and unescapefield are exact inverses, so encodetool followed by
# parsetoolline round-trips any (id, name, args) triple verbatim.
#

WireFmt: module
{
	PATH: con "/dis/lib/wirefmt.dis";

	init: fn();

	# Escape / unescape a single field. Exact inverses.
	escapefield:   fn(s: string): string;
	unescapefield: fn(s: string): string;

	# Build a full "TOOL:<id>:<name>:<args>" line from raw, unescaped fields.
	encodetool: fn(id, name, args: string): string;

	# Parse the part of a TOOL line AFTER the "TOOL:" prefix
	# (i.e. "<id>:<name>:<args>") back into raw, unescaped fields.
	parsetoolline: fn(s: string): (string, string, string);
};
