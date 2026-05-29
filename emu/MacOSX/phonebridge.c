/*
 * phonebridge — macOS stub.
 *
 * macOS has no cellular radio, so the bridge is a logging stub that
 * lets the devphone namespace mount on a developer Mac for headless
 * testing (e.g. the same headless emu we use to round-trip /n/llm).
 * Veltro tool wrappers and msg9p plumbing can be exercised end-to-end
 * here; nothing real goes over the air.
 *
 * Linux can include this file in the same way until a desktop-gateway
 * backend (gammu / a SIP modem service / a cloud SMS API) lands.
 */

#include <stdio.h>
#include <string.h>
#include "phonebridge.h"

void
phonebridge_init(void)
{
	fprintf(stderr, "phone: bridge=MacOSX-stub (no cellular radio)\n");
}

int
phonebridge_ctl(const char *verb, const char *rest, char *err, int errlen)
{
	fprintf(stderr, "phone: macOS ctl %s%s%s (stub)\n",
		verb ? verb : "", rest ? " " : "", rest ? rest : "");
	(void)err; (void)errlen;
	return 0;
}

int
phonebridge_ctl_status(char *buf, int buflen)
{
	return snprintf(buf, buflen, "stub (no radio)\n");
}

int
phonebridge_send_sms(const char *number, const char *body, char *err, int errlen)
{
	fprintf(stderr, "phone: macOS send_sms to=%s body=%s (stub)\n",
		number ? number : "(nil)", body ? body : "(nil)");
	(void)err; (void)errlen;
	return 0;
}

int
phonebridge_recv_sms(char *buf, int buflen)
{
	(void)buf; (void)buflen;
	return 0;
}

int
phonebridge_phone_ctl(const char *verb, const char *rest, char *err, int errlen)
{
	fprintf(stderr, "phone: macOS phone_ctl %s%s%s (stub)\n",
		verb ? verb : "", rest ? " " : "", rest ? rest : "");
	(void)err; (void)errlen;
	return 0;
}

int
phonebridge_recv_call_event(char *buf, int buflen)
{
	(void)buf; (void)buflen;
	return 0;
}

int
phonebridge_signal(void)
{
	return -1;
}

int
phonebridge_status(char *buf, int buflen)
{
	return snprintf(buf, buflen, "macOS stub — no cellular radio\n");
}

int
phonebridge_calls(char *buf, int buflen)
{
	(void)buf; (void)buflen;
	return 0;
}
