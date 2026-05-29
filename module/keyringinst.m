#
# keyringinst.m - Helpers for installing the serve-llm keyring keyfile.
#
# Pulled out of appl/wm/settings.b (INFR-169) so the install path can
# be exercised by tests/keyringinst_test.b without dragging in
# wmclient, flashstatus, or the settings UI.
#
# Tier: a single thin module loaded by Settings (settings.b owns the
# UI side and the snarf read); the testable pieces — payload cleanup,
# file write with strict mode, presence check — live here.
#

Keyringinst: module {
	PATH: con "/dis/lib/keyringinst.dis";

	# The canonical signer-key path mount -k looks at when ndb/llm
	# carries keyfile=/lib/keyring/serve-llm.
	DEFAULT_PATH: con "/lib/keyring/serve-llm";

	# Module-level state needs initialising before any of the helpers
	# below get called. init() loads sys; returns nil on success or
	# a short error string.
	init: fn(): string;

	# Returns 1 if the keyfile at DEFAULT_PATH exists, 0 if not. No
	# side effects.
	present: fn(): int;

	# Human-readable status line for the Settings UI / the test —
	# "Keyfile: present at <path>" or "Keyfile: missing — …".
	status_text: fn(): string;

	# prepare_payload: clean a freshly-read clipboard buffer before
	# writing it to disk. Today: strip a single trailing CR (Windows
	# clipboards) — the on-disk format is line-oriented and a stray
	# CR confuses factotum / mount -k. Pure function; testable.
	prepare_payload: fn(raw: string): string;

	# install_payload: write payload to dst with strict mode 0600
	# (factotum / mount -k refuse a world-readable signer key),
	# making sure dst's parent directory exists first. Returns nil on
	# success, an error string otherwise. The test uses /tmp paths;
	# Settings uses DEFAULT_PATH.
	install_payload: fn(payload, dst: string): string;
};
