#
# Twofaslot — per-account second-factor key-slots (LUKS model) for secstore.
#
# A 2FA account's factotum blob is encrypted under a random data key DK; DK is
# wrapped in one or more slot files under /usr/inferno/secstore/<user>/2fa/.
# Each slot = encrypt3(DK, KEK):
#   key slot:      KEK = mkkek2fa(rootkey, R)   (R = YubiKey hmac-secret, touch)
#   recovery slot: KEK = mkfilekey3(user, recoverypass)
# The presence of a slot dir is the marker that the account is "2FA"; legacy
# password-only accounts have none and are left untouched. This module is pure
# local-file + crypto: the caller (Settings enroll / logon unlock) owns the
# secstore re-encrypt of the factotum blob. See doc/second-factor-auth.md.
#
Twofaslot: module
{
	PATH:		con "/dis/lib/twofaslot.dis";
	Slotbase:	con "/usr/inferno/secstore";
	Addr:		con "tcp!localhost!5356";	# local secstored

	init:	fn();

	# Flip an account to 2FA: decrypt the current (password-encrypted) factotum
	# blob, re-encrypt it under a fresh random data key, write the key-slots +
	# recovery slot, and store the new blob — all verify-before-commit. keys is
	# a list of (slotname, cred-id-hex, salt-hex); derives R per key (touch).
	# pin is the FIDO2 PIN for UV-required (AAL3) credentials, "" for touch-only.
	# Returns nil on success, else an error (account left unchanged).
	enroll:	fn(user, pass, recoverypass: string, keys: list of (string, string, string), pin: string): string;

	# Is this account in 2FA mode (has any key-slots)?
	is2fa:	fn(user: string): int;

	# Recover the data key DK from the slots. Tries each key slot (present
	# YubiKey, touch) first; then the recovery slot if recoverypass is given.
	# rootkey is mkfilekey3(user,pass). Returns (DK, nil) or (nil, error).
	unlock:	fn(user: string, rootkey: array of byte, recoverypass, pin: string): (array of byte, string);

	# Create the key-slots + recovery slot for DK. keys is a list of
	# (slotname, cred-id-hex, salt-hex). Derives R per key (touch), wraps DK,
	# VERIFIES every slot unwraps DK before writing anything. Returns nil or error.
	writeslots:	fn(user: string, rootkey, DK: array of byte, keys: list of (string, string, string), recoverypass, pin: string): string;

	# Revert account to password-only: re-encrypt the factotum back under the
	# password (needs a present key or the recovery passphrase to recover DK),
	# then remove the slots. Returns nil or error.
	disable:	fn(user, pass, recoverypass, pin: string): string;
};
