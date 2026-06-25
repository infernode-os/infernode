#
# agentlib.m - Shared agent library for Veltro
#
# Common functions used by veltro.b (single-shot agent) and repl.b
# (interactive REPL). Handles LLM session management, prompt building,
# response parsing, and tool execution via the /tool 9P filesystem.
#
# NOTE: Include sys.m before including this file (needed for Sys->FD type).
#

AgentLib: module {
	PATH: con "/dis/veltro/agentlib.dis";

	STREAM_THRESHOLD: con 4096;
	SCRATCH_PATH: con "/tmp/veltro/scratch";

	init: fn();
	setverbose: fn(v: int);
	settoolmount: fn(path: string);

	# LLM session management
	createsession: fn(): string;
	closesession: fn(id: string);
	setprefillpath: fn(path, prefill: string);
	queryllmfd: fn(fd: ref Sys->FD, prompt: string): string;
	setsystemprompt: fn(path, prompt: string);

	# Prompt building
	discovernamespace: fn(): string;
	buildsystemprompt: fn(ns, persona: string): string;
	loadreminders: fn(toollist: list of string): string;
	loadtooldocs: fn(toollist: list of string): string;
	defaultsystemprompt: fn(): string;
	readtooldoc: fn(name: string): string;
	tooldocsummary: fn(name: string): string;

	# Response parsing
	parseaction: fn(response: string): (string, string);
	parseactions: fn(response: string): list of (string, string);
	parseheredoc: fn(args: string, lines: list of string): (string, list of string);
	collectsaytext: fn(first: string, lines: list of string): string;
	stripmarkdown: fn(s: string): string;
	stripaction: fn(response: string): string;

	# Tool execution (9P)
	calltool: fn(tool, args: string): string;
	writescratch: fn(content: string, step: int): string;

	# Native tool_use protocol (Anthropic JSON API)
	buildtooldefs: fn(toollist: list of string): string;
	initsessiontools: fn(id: string, toollist: list of string);
	parsellmresponse: fn(response: string): (string, list of (string, string, string), string);
	buildtoolresults: fn(results: list of (string, string)): string;

	# MCP router (INFR-247): generic 9P-MCP discovery, tool-def building, and
	# tolerant tool-name routing — shared by NERVA and the sub-agent bridge. MCP
	# adapters present /mnt/mcp/<server>/{_meta/name, tools/<tool>/{doc,schema,call}}.
	#  mcpdiscover: among the given mount paths (e.g. "/mnt/mcp/osm"), find those
	#   exposing _meta/name + tools/; returns ((prefix,mount)...) and every
	#   (bare-tool,mount). prefix = _meta/name (fallback: path basename).
	#  mcptooldefs: combined OpenAI/Anthropic tool-defs JSON array ("[{...},...]")
	#   for the (prefix,mount) list; names are "<prefix>_<tool>" (sanitized);
	#   maxper caps tools/mount, budget caps total bytes.
	#  mcpresolve: resolve a model-emitted name to (mount,bare) — prefer the
	#   claimed prefix's mount, else the unique owner of <bare> (tolerant of a
	#   wrong prefix, the INFR-224 failure mode). ("","") if unresolved.
	#  mcpcall: one tool call with a bounded timeout (path = <mount>/tools/<bare>/call).
	mcpdiscover: fn(mountpaths: list of string): (list of (string, string), list of (string, string));
	mcptooldefs: fn(mounts: list of (string, string), maxper, budget: int): string;
	mcpresolve: fn(name: string, mounts, tools: list of (string, string)): (string, string, int);
	mcpcall: fn(path, args: string, timeoutms: int): string;

	# Utilities
	readfile: fn(path: string): string;
	pathexists: fn(path: string): int;
	ensuredir: fn(path: string);
	strip: fn(s: string): string;
	contains: fn(s, sub: string): int;
	hasprefix: fn(s, prefix: string): int;
	splitfirst: fn(s: string): (string, string);
	truncate: fn(s: string, max: int): string;
	findheredoc: fn(s: string): int;
};
