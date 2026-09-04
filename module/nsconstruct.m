#
# nsconstruct.m - Namespace construction for Veltro agents (v3)
#
# Security Model (v3): FORKNS + bind-replace
#   Fork parent namespace, then restrict directories via bind-replace (MREPL).
#   restrictdir() replaces a directory's contents with only allowed items.
#   This is an allowlist operation — anything not explicitly placed is invisible.
#
# Capability attenuation is natural: children fork an already-restricted
# namespace and can only narrow further.
#
# Replaces v2's NEWNS + copied sandbox with zero file copying and no NEWNS
# bootstrap problem. Bind shadows are physical directories and are reclaimed
# by the trusted tools9p cleanup loop.
#

NsConstruct: module {
	PATH: con "/dis/veltro/nsconstruct.dis";

	# LLM configuration for a child agent
	LLMConfig: adt {
		model:       string;   # Model name (e.g., "haiku", "sonnet", "opus")
		temperature: real;     # 0.0 - 2.0
		system:      string;   # System prompt (parent-controlled)
		thinking:    int;      # Thinking tokens: 0=off, -1=max, >0=budget
	};

	# MCP provider configuration (for mc9p integration)
	MCProvider: adt {
		name:     string;          # Provider name ("http", "fs", "search")
		domains:  list of string;  # Domains to grant within provider
		netgrant: int;             # 1 = provider has /net access
	};

	# Capabilities to grant to an agent
	Capabilities: adt {
		tools:       list of string;       # Tool names to include ("read", "list")
		paths:       list of string;       # File paths to expose; prefix-routed:
		                                   #   /dis/wm  → expose /dis/wm/ to agent
		                                   #   /n/local/Users/pdfinn/tmp → expose that host path
		shellcmds:   list of string;       # Shell commands for exec — if non-nil, sh.dis + these are allowed
		llmconfig:   ref LLMConfig;        # Child's LLM settings
		fds:         list of int;          # Explicit FD keep-list
		mcproviders: list of ref MCProvider;  # mc9p providers to spawn
		memory:      int;                  # 1 = enable agent memory
		xenith:      int;                  # 1 = grant /chan (Xenith 9P) access
		actid:       int;                  # Lucifer activity ID (-1 = no cowfs)
		writepaths:  list of string;       # Granted paths that should get staged cowfs writes
		mcpdeny:     list of string;       # MCP tool basenames to drop from every granted
		                                   #   /mnt/mcp/<server>/tools listing (defense-in-depth,
		                                   #   INFR-258). The tool dir — and so its /call path —
		                                   #   becomes invisible to the child's mcpdiscover,
		                                   #   regardless of which servers `paths` granted. The
		                                   #   names are caller policy; nsconstruct never knows
		                                   #   what they mean.
	};

	# Initialize the module
	init: fn();

	# Restrict a directory to only the allowed entries.
	# Creates a shadow dir whose entries and outer view are MREADONLY, or uses
	# MCREATE when writable=1. Service allowlists with writable protocol files
	# use a separate internal filtering primitive.
	# Items not in allowed list become invisible after the bind-replace.
	# Returns nil on success, error string on failure.
	restrictdir: fn(target: string, allowed: list of string, writable: int): string;

	# Apply the full namespace policy, including /dis, /dev, /n, /mnt,
	# /lib, /env, /prog, /tool, activity scratch, /tmp, and root.
	# Returns nil on success, error string on failure
	restrictns: fn(caps: ref Capabilities): string;

	# Emit namespace manifest for the UI to display.
	# Writes to mpath — one entry per line.
	# Must be called AFTER restrictns() from the restricted namespace.
	emitmanifest: fn(caps: ref Capabilities, mpath: string);

	# Verify namespace matches expected security policy
	# Reads /prog/$pid/ns and checks for dangerous paths
	# expected: list of paths that should be accessible
	# Returns nil on success, violation description on failure
	verifyns: fn(expected: list of string): string;

	# Emit audit log of namespace restriction operations
	# Writes to the trusted backing tree under /tmp/.veltro-ns/audit.
	emitauditlog: fn(id: string, ops: list of string);

	# True if `path` names a per-account wallet control surface that
	# must never be granted to an agent (per-account `ctl`, and the
	# retired `sign` oracle). Exported so tools9p and nsconstruct
	# cannot drift apart on it: two copies of a security predicate
	# that disagree mean one of them re-opens what the other closed.
	walletcontrolpath: fn(path: string): int;

	# Clean up shadow directories for the current process.
	# Call on agent exit to reclaim /tmp/.veltro-ns/shadow/{pid}-* entries.
	cleanup: fn();
};
