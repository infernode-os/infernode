/*
 * fido2bridge.c (Windows stub) — Windows currently has no libfido2 link.
 * The kernel-side #F (2fa) device is still wired up so /dev/2fa exists and
 * the persona/Settings code paths run; operations return a clean
 * "not supported" string the Limbo layer can show to the user. Future
 * Windows libfido2 work flips this file to a real bridge alongside the
 * macOS implementation in emu/MacOSX/fido2bridge.c.
 */
#include "../port/fido2bridge.h"
#include <stdio.h>

int fido2bridge_available(void)
{
	return 0;
}

int fido2bridge_enroll(const char *pin, char *cred_hex, int cred_hexlen,
                       char *err, int errlen)
{
	(void)pin; (void)cred_hex; (void)cred_hexlen;
	_snprintf(err, errlen, "fido2 not supported on Windows in this build");
	if (errlen > 0) err[errlen - 1] = 0;
	return -1;
}

int fido2bridge_derive(const char *pin, const char *cred_hex, const char *salt_hex,
                       char *secret_hex, int secret_hexlen,
                       char *err, int errlen)
{
	(void)pin; (void)cred_hex; (void)salt_hex;
	(void)secret_hex; (void)secret_hexlen;
	_snprintf(err, errlen, "fido2 not supported on Windows in this build");
	if (errlen > 0) err[errlen - 1] = 0;
	return -1;
}
