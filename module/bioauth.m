#
# bioauth.m — Biometric-protected secret storage helper.
#
# Wraps /phone/bio_status, /phone/bio_store, /phone/bio_retrieve (see
# emu/port/devphone.c + emu/iOS/phonebridge.m + emu/Android/phonebridge.c).
# The userspace file protocol is identical on every platform; only the
# bridge implementation differs (iOS LAContext+Keychain biometryCurrentSet
# today; Android BiometricPrompt+EncryptedSharedPreferences pending
# INFR-182).
#
# Split out from settings.b for the same reason keyringinst was —
# tests/bioauth_test.b can exercise name validation and the
# store/retrieve file-protocol formatting without the UI or a real
# biometric prompt.
#

Bioauth: module {
	PATH: con "/dis/lib/bioauth.dis";

	# /phone file paths. Public so tests can point a fake bridge at
	# /tmp/phone-fake/ and confirm the helper writes the right bytes.
	STATUS: con "/phone/bio_status";
	STORE:  con "/phone/bio_store";
	RETRIEVE: con "/phone/bio_retrieve";

	# Bridge availability states surfaced by /phone/bio_status:
	#   "available\n"   — hardware + enrollment ready
	#   "unavailable\n" — hardware present, no enrollment / locked out
	#   "unsupported\n" — no biometric hardware (or Android stub)
	AVAIL_OK:      con 0;
	AVAIL_NOENROL: con 1;
	AVAIL_NONE:    con 2;

	# Loads sys. Returns nil on success or a short error string.
	init: fn(): string;

	# Reads /phone/bio_status and maps the line to AVAIL_*. Returns
	# AVAIL_NONE on any read error so callers can degrade quietly.
	available: fn(): int;

	# True if `name` is a valid slot identifier — non-empty, no '/',
	# no NUL, no newline, <= 63 bytes (matches BIO_NAME_MAX-1 in
	# devphone.c). Pure function; the bridge revalidates.
	valid_name: fn(name: string): int;

	# Writes "<name>\n<payload>" to /phone/bio_store in a single
	# write(2). Returns nil on success or an error string. Surfaces
	# valid_name failures before touching the bridge.
	store: fn(name, payload: string): string;

	# One-shot read of slot `name` after writing the slot name to the
	# write side of /phone/bio_retrieve. Returns (payload, nil) on
	# success or (nil, err) on failure. Triggers the OS biometric
	# prompt; blocks the calling thread until the user responds.
	retrieve: fn(name: string): (string, string);
};
