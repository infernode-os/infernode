#
# Twofa — Limbo wrapper over the #F (2fa) device (/dev/2fa).
#
# Provider-agnostic second-factor challenge-response. Callers (logon, factotum,
# wallet) use this instead of poking the device files directly. See
# doc/second-factor-auth.md. The hardware work happens in the emu host bridge
# (emu/port/fido2bridge.c via libfido2, shared across macOS/Linux/Windows);
# enroll() and derive() BLOCK on a physical touch.
#
Twofa: module
{
	PATH:	con "/dis/lib/twofa.dis";

	# Default mountpoint where the #F device is bound.
	Dev:	con "/mnt/2fa";

	init:	fn();

	# Bind '#F' at Dev (creating the mountpoint if needed).
	# Returns nil on success, else an error string.
	mount:	fn(): string;

	# 1 if a second-factor device (e.g. a YubiKey) is currently present.
	available:	fn(): int;

	# Enroll a fresh credential. If pin is non-empty the credential requires
	# user verification (FIDO2 PIN / AAL3); empty pin = touch-only. Returns
	# (credential-id-hex, nil) or (nil, error). The caller persists the
	# credential id alongside the secstore account so derive() reproduces later.
	enroll:	fn(pin: string): (string, string);

	# Derive the device-bound secret for (credential, 32-byte salt). If pin is
	# non-empty, user verification (PIN) is required; empty = touch-only.
	# Deterministic: same key + credential + salt -> same secret. cred is the
	# hex credential id from enroll(). Returns (secret-bytes, nil) or (nil, error).
	derive:	fn(cred: string, salt: array of byte, pin: string): (array of byte, string);
};
