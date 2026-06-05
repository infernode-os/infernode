#
# mc9p.m - 9P-based MCP alternative where filesystem IS schema
#
# Design Principles:
#   1. Filesystem IS schema - No JSON. Directory structure = API structure.
#   2. Namespace = capability - If path exists, you can use it.
#   3. No ambient authority - No inherited env, no leaked FDs.
#   4. Per-agent sidecar - Runs inside sandbox with same isolation.
#   5. Pipe mount - Explicit channel, not /srv registration.
#
# Filesystem Schema:
#   /mnt/mcp/                     <- mount point
#   ├── _meta/
#   │   ├── name               -> provider name
#   │   ├── version            -> version string
#   │   └── caps               -> capability list
#   ├── http/                  <- HTTP domain (if granted)
#   │   ├── get                -> write URL, read response
#   │   ├── post               -> write "URL\nbody", read response
#   │   └── headers            -> write to set, read current
#   ├── fs/                    <- Filesystem domain
#   │   ├── read               -> write path, read content
#   │   ├── write              -> write "path\ncontent", read status
#   │   └── list               -> write path, read entries
#   └── search/                <- Search domain (if granted)
#       └── web                -> write query, read results
#
# Usage:
#   echo "https://example.com" > /mnt/mcp/http/get
#   cat /mnt/mcp/http/get    -> response body
#

Mc9p: module {
	PATH: con "/dis/veltro/mc9p.dis";

	# Provider configuration
	ProviderConfig: adt {
		name:     string;          # Provider name (e.g., "http", "fs")
		version:  string;          # Version string
		domains:  list of string;  # Domains to enable
		netgrant: int;             # 1 = has /net access
	};

	# Domain definition
	Domain: adt {
		name:      string;              # Domain name (e.g., "http")
		endpoints: list of ref Endpoint;
	};

	# Endpoint definition
	Endpoint: adt {
		name:   string;  # Endpoint name (e.g., "get")
		domain: string;  # Parent domain
	};

	# Initialize module
	init: fn(nil: ref Draw->Context, args: list of string);

	# Start mc9p server with given configuration
	# Returns mount point path or nil on error
	start: fn(cfg: ref ProviderConfig): string;

	# Stop mc9p server
	stop: fn();
};
