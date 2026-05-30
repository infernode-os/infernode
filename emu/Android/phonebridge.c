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
 *   inbound SMS  → ContentResolver observer on content://sms/inbox
 *                  (READ_SMS + RECEIVE_SMS). The observer callback
 *                  formats the canonical wire record and calls
 *                  phonebridge_post_sms(line, len) — devphone fans
 *                  it out to every open reader of /phone/sms.
 *   dial         → TelecomManager.placeCall (CALL_PHONE)
 *   answer / hangup → TelecomManager.acceptRingingCall /
 *                  endCall (ANSWER_PHONE_CALLS, API 26+)
 *   call events  → TelephonyManager TelephonyCallback for
 *                  STATE_RINGING / STATE_OFFHOOK / STATE_IDLE;
 *                  callback formats and calls
 *                  phonebridge_post_call_event().
 *
 * Wiring lives in android-app/.../InfernodeService.kt (the existing
 * JNI surface — see the SDL Activity's JNI bridge for the pattern;
 * INFR-182 documents the two options [direct JNI vs unix socket]).
 */

#include <stdio.h>
#include <string.h>
#include <jni.h>
#include "phonebridge.h"

/* Owns the JavaVM* used by both the JNI bridge and our dial path.
 * jni-emu.c (built into libemu.so) extern-declares this and assigns
 * to it in JNI_OnLoad; the headless o.emu links this translation unit
 * with g_vm staying NULL, and android_dial() handles that as a clean
 * "JNI not initialised" failure. */
JavaVM *g_vm = NULL;

/*
 * INFR-201: fire Intent.ACTION_CALL via InfernodePhoneBridge.dial.
 *
 * Runs on whichever thread called phonebridge_phone_ctl (Inferno
 * kproc), which the JVM doesn't know about. AttachCurrentThread is
 * mandatory; we detach before returning so a long-lived Inferno
 * thread doesn't accumulate JVM attachments.
 *
 * Returns 0 on success, -1 on any failure (no JVM, lookup miss,
 * Kotlin reported failure, exception). Caller surfaces the error
 * string the C side already populated.
 */
static int
android_dial(const char *number, char *err, int errlen)
{
	JNIEnv *env;
	jclass cls;
	jmethodID mid;
	jstring jnum;
	jint rc;
	int attached = 0;

	if(g_vm == NULL){
		snprintf(err, errlen, "phone: JNI not initialised (g_vm null)");
		return -1;
	}
	switch((*g_vm)->GetEnv(g_vm, (void**)&env, JNI_VERSION_1_6)){
	case JNI_OK:
		break;
	case JNI_EDETACHED:
		if((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK){
			snprintf(err, errlen, "phone: AttachCurrentThread failed");
			return -1;
		}
		attached = 1;
		break;
	default:
		snprintf(err, errlen, "phone: GetEnv failed");
		return -1;
	}

	cls = (*env)->FindClass(env, "io/infernode/InfernodePhoneBridge");
	if(cls == NULL){
		(*env)->ExceptionClear(env);
		snprintf(err, errlen,
			"phone: FindClass(InfernodePhoneBridge) failed");
		if(attached) (*g_vm)->DetachCurrentThread(g_vm);
		return -1;
	}
	mid = (*env)->GetStaticMethodID(env, cls, "dial",
		"(Ljava/lang/String;)I");
	if(mid == NULL){
		(*env)->ExceptionClear(env);
		(*env)->DeleteLocalRef(env, cls);
		snprintf(err, errlen,
			"phone: GetStaticMethodID(dial) failed");
		if(attached) (*g_vm)->DetachCurrentThread(g_vm);
		return -1;
	}
	jnum = (*env)->NewStringUTF(env, number ? number : "");
	rc = (*env)->CallStaticIntMethod(env, cls, mid, jnum);
	if((*env)->ExceptionCheck(env)){
		(*env)->ExceptionDescribe(env);
		(*env)->ExceptionClear(env);
		rc = -1;
	}

	(*env)->DeleteLocalRef(env, jnum);
	(*env)->DeleteLocalRef(env, cls);
	if(attached)
		(*g_vm)->DetachCurrentThread(g_vm);

	if(rc != 0){
		snprintf(err, errlen,
			"phone: Android dial returned %d "
			"(no context attached, CALL_PHONE not granted, or no tel: resolver)",
			(int)rc);
		return -1;
	}
	return 0;
}

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

/* Inbound paths land via phonebridge_post_sms / phonebridge_post_call_event
 * once INFR-182 wires the ContentObserver + TelephonyCallback through the
 * JNI surface. Stub does nothing — readers of /phone/sms and /phone/phone
 * block forever, which is the correct behaviour. */

int
phonebridge_phone_ctl(const char *verb, const char *rest, char *err, int errlen)
{
	/* INFR-201: dial is the only verb wired today. answer / hangup
	 * need TelecomManager.acceptRingingCall + endCall (API 26+,
	 * ANSWER_PHONE_CALLS perm) and live with the rest of INFR-182. */
	if(verb != NULL && strcmp(verb, "dial") == 0){
		if(rest == NULL || rest[0] == 0){
			snprintf(err, errlen, "phone: dial: missing number");
			return -1;
		}
		fprintf(stderr, "phone: Android dial %s\n", rest);
		return android_dial(rest, err, errlen);
	}
	fprintf(stderr, "phone: Android phone_ctl %s%s%s (stub — INFR-182)\n",
		verb ? verb : "", rest ? " " : "", rest ? rest : "");
	(void)err; (void)errlen;
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

int
phonebridge_contacts(char *buf, int buflen)
{
	/* INFR-182 will wire ContactsContract via the JNI surface. Same
	 * line format as the iOS bridge: <name>\t<kind>\t<number>\n. */
	return snprintf(buf, buflen, "# contacts: Android bridge not wired (INFR-182)\n");
}

/*
 * Biometric-protected secret storage. INFR-182 will wire this against
 * BiometricPrompt + EncryptedSharedPreferences keyed by
 * setUserAuthenticationRequired(true) — same contract as iOS, same
 * /phone/bio_* userspace surface, only the JNI shim differs.
 */
int
phonebridge_bio_available(void)
{
	return -1;	/* "unsupported" — devphone surfaces this verbatim */
}

int
phonebridge_bio_store(const char *name, const char *payload, int n,
                      char *err, int errlen)
{
	(void)name; (void)payload; (void)n;
	snprintf(err, errlen,
		"bio_store: Android biometric bridge not wired (INFR-182)");
	return -1;
}

int
phonebridge_bio_retrieve(const char *name, char *buf, int buflen,
                         char *err, int errlen)
{
	(void)name; (void)buf; (void)buflen;
	snprintf(err, errlen,
		"bio_retrieve: Android biometric bridge not wired (INFR-182)");
	return -1;
}
