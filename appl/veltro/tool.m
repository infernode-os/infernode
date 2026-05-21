
#
# Defines the pluggable tool interface that all Veltro agents use to invoke
# tools through the 9P filesystem. Tools implement init(), name(), doc(), and
# exec() functions to support dynamic loading and execution within isolated
# namespace contexts.
#
# tool.m - Veltro Agent Tool Interface Module
#
# This module defines the standard contract that all Veltro tools must implement.
# It specifies four essential functions: init() for tool initialization, name() to
# return the tool identifier, doc() to provide usage documentation, and exec() to
# perform the actual tool operation. Tools follow a stateless design where each
# execution receives fresh arguments and returns results; any required state is
# managed by the 9P server's per-fid context. This interface enables Veltro's
# pluggable architecture, allowing agents to dynamically load and execute diverse
# tools within a secure, isolated namespace with fine-grained access control.
#


Tool: module {
	# Initialize the tool (load dependencies)
	# Must be called before exec() and while filesystem paths are accessible
	# Returns error string or nil on success
	init: fn(): string;

	# Return the tool name (lowercase, e.g., "read")
	name: fn(): string;

	# Return documentation for this tool
	doc: fn(): string;

	# Execute the tool with given arguments
	# Returns result string (may include error messages)
	exec: fn(args: string): string;

	# Return the OpenAI-format function-schema for this tool, as a JSON
	# object string. Read by tools9p as /tool/<name>/schema and used by
	# the LLM-facing bridge to advertise the tool to pretrained models
	# via their native tool-call API.
	#
	# Convention (V1): properties are string-only and declared in the
	# order that the existing exec() argv parser expects, so the bridge's
	# default insertion-order space-join produces a valid ctl-line.
	# Return "" if the tool does not yet have a published schema; callers
	# fall back to a generic "args:string" definition in that case.
	schema: fn(): string;
};
