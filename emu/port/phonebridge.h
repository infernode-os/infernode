/*
 * phonebridge — host-side telephony/SMS interface for devphone.
 *
 * Per-platform implementations:
 *   emu/iOS/phonebridge.m       MessageUI + CallKit / CXCallObserver
 *   emu/Android/phonebridge.c   SmsManager / Telephony (planned;
 *                               INFR-182 lifts from Plan9-Archive/hellaphone)
 *   (no desktop bridge — desktops mount a phone's /phone over 9P)
 *
 * Two directions:
 *
 *   1. Userspace -> bridge: the synchronous "do this now" functions
 *      below (phonebridge_send_sms, phonebridge_phone_ctl, etc).
 *      These are called from a devphone kproc on the write path.
 *      Return >=0 on success, -1 on error; on -1, write a short
 *      human-readable string to `err` (truncated to errlen-1).
 *
 *   2. Bridge -> userspace: the bridge produces incoming records
 *      (SMS arrived, call state changed) on its own threads, and
 *      pushes them into the devphone listener queues via
 *      phonebridge_post_sms / phonebridge_post_call_event. devphone
 *      then unblocks all current readers of /phone/sms or /phone/phone
 *      (qproduce -> qread). Bridges should call these with newline-
 *      terminated records exactly as the wire format requires.
 *
 *      The post_* functions are *defined* by devphone (emu/port/devphone.c)
 *      and *called* by the bridge implementations — they never block
 *      and are safe to call from any thread.
 */
#ifndef PHONEBRIDGE_H
#define PHONEBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

void	phonebridge_init(void);

/* /phone/ctl */
int	phonebridge_ctl(const char *verb, const char *rest,
			char *err, int errlen);
int	phonebridge_ctl_status(char *buf, int buflen);

/* /phone/sms — write to send (synchronous), read blocks on the
 * per-channel listener queue until a bridge posts a record. */
int	phonebridge_send_sms(const char *number, const char *body,
			     char *err, int errlen);

/* /phone/phone — call control + event stream. Read blocks the same way. */
int	phonebridge_phone_ctl(const char *verb, const char *rest,
			      char *err, int errlen);

/* /phone/signal, /phone/status, /phone/calls — synchronous queries. */
int	phonebridge_signal(void);
int	phonebridge_status(char *buf, int buflen);
int	phonebridge_calls(char *buf, int buflen);

/*
 * Bridge -> userspace push entry points (defined in emu/port/devphone.c).
 * Each call fans the record out to every currently-open reader of the
 * corresponding /phone file via qproduce. Non-blocking; safe from any
 * thread. The `line` buffer is copied internally so the caller may
 * free / reuse it on return.
 */
void	phonebridge_post_sms(const char *line, int n);
void	phonebridge_post_call_event(const char *line, int n);

#ifdef __cplusplus
}
#endif

#endif
