/*
 * phonebridge — Android stub.
 *
 * Today: logging stub so the devphone namespace mounts cleanly on
 * Android builds (Termux, the SDL Activity APK) — Veltro tools / msg9p
 * plumbing can be exercised end-to-end against this stub, nothing real
 * goes over the air yet.
 *
 * INFR-182 fills in the real bodies, mapping to modern Android
 * telephony APIs (the original Hellaphone's RIL parcel impl in
 * Plan9-Archive/hellaphone is a structural reference, ~13 years old):
 *
 *   send_sms     → SmsManager.sendTextMessage (CALL_PHONE / SEND_SMS)
 *   recv_sms     → ContentResolver observer on content://sms/inbox
 *                  (READ_SMS + RECEIVE_SMS); push records into the
 *                  ring drained by recv_sms.
 *   dial         → TelecomManager.placeCall (CALL_PHONE)
 *   answer / hangup → TelecomManager.acceptRingingCall /
 *                  endCall (ANSWER_PHONE_CALLS, API 26+)
 *   call events  → TelephonyManager TelephonyCallback for
 *                  STATE_RINGING / STATE_OFFHOOK / STATE_IDLE.
 *
 * Wiring lives in android-app/.../InfernodeService.kt (the existing
 * JNI surface — see the SDL Activity's JNI bridge for the pattern;
 * INFR-182 documents the two options [direct JNI vs unix socket]).
 */

#include <stdio.h>
#include <string.h>
#include "phonebridge.h"

void
phonebridge_init(void)
{
	fprintf(stderr, "phone: bridge=Android-stub (Telephony not yet wired — INFR-182)\n");
}

int
phonebridge_ctl(const char *verb, const char *rest, char *err, int errlen)
{
	fprintf(stderr, "phone: Android ctl %s%s%s (stub)\n",
		verb ? verb : "", rest ? " " : "", rest ? rest : "");
	(void)err; (void)errlen;
	return 0;
}

int
phonebridge_ctl_status(char *buf, int buflen)
{
	return snprintf(buf, buflen, "stub (Telephony not wired)\n");
}

int
phonebridge_send_sms(const char *number, const char *body, char *err, int errlen)
{
	fprintf(stderr, "phone: Android send_sms to=%s body=%s (stub)\n",
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
	fprintf(stderr, "phone: Android phone_ctl %s%s%s (stub)\n",
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
	return snprintf(buf, buflen, "Android stub — Telephony not wired (INFR-182)\n");
}

int
phonebridge_calls(char *buf, int buflen)
{
	(void)buf; (void)buflen;
	return 0;
}
