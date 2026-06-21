/*
 * fido2bridge — host-side libfido2 interface for the #F (2fa) device.
 *
 * Plain C contract between the kernel-side device (emu/port/devtfa.c, which
 * includes only Inferno headers) and the host-side implementation
 * (emu/MacOSX/fido2bridge.c, which includes <fido.h>). All values cross the
 * boundary as NUL-terminated hex strings so neither side needs the other's
 * types. Functions return 0 on success, -1 on error (with a short message in
 * `err`). The enroll/derive calls BLOCK on a YubiKey touch — safe, because the
 * caller is an Inferno kproc (a pthread on this build), mirroring devphone's
 * blocking biometric path.
 */
#ifndef FIDO2BRIDGE_H
#define FIDO2BRIDGE_H

/* 1 if at least one FIDO authenticator is present (non-blocking). */
int fido2bridge_available(void);

/*
 * Create a non-resident hmac-secret credential. On success writes the
 * credential id as hex into cred_hex (cred_hexlen incl. NUL).
 * If `pin` is non-NULL and non-empty, the credential requires user
 * verification (UV / FIDO2 PIN) — AAL3 — and `pin` is used at creation;
 * otherwise touch-only (user presence). Touch required either way.
 */
int fido2bridge_enroll(const char *pin, char *cred_hex, int cred_hexlen,
                       char *err, int errlen);

/*
 * Derive the device-bound secret for (credential, salt). cred_hex is the hex
 * credential id from enroll; salt_hex is 64 hex chars (32 bytes). On success
 * writes 64 hex chars (32-byte secret) into secret_hex. Deterministic.
 * If `pin` is non-NULL and non-empty, user verification (PIN) is required;
 * otherwise touch-only. Touch required either way.
 */
int fido2bridge_derive(const char *pin, const char *cred_hex, const char *salt_hex,
                       char *secret_hex, int secret_hexlen,
                       char *err, int errlen);

#endif /* FIDO2BRIDGE_H */
