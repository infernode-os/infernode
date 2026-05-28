/*
 * phonebridge — host-side telephony/SMS interface for devphone.
 *
 * Per-platform implementations:
 *   emu/iOS/phonebridge.m       MessageUI + CallKit / CXCallObserver
 *   emu/Android/phonebridge.c   SmsManager / Telephony (planned; lift
 *                               from Plan9-Archive/hellaphone's RIL impl)
 *   emu/MacOSX/phonebridge.c    Stub (dev sandbox; logs + canned data)
 *   emu/Linux/phonebridge.c     Stub
 *
 * All functions return >=0 on success, -1 on error. When returning -1
 * the implementation should write a short human-readable error string
 * to `err` (truncated to errlen-1 chars, NUL-terminated). Functions that
 * read a pending event ("recv") return:
 *     >0   bytes written to buf (newline-terminated record)
 *      0   no event available (caller should EOF)
 *     -1   unsupported on this platform
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

/* /phone/sms — write to send, read to receive */
int	phonebridge_send_sms(const char *number, const char *body,
			     char *err, int errlen);
int	phonebridge_recv_sms(char *buf, int buflen);

/* /phone/phone — call control + event stream */
int	phonebridge_phone_ctl(const char *verb, const char *rest,
			      char *err, int errlen);
int	phonebridge_recv_call_event(char *buf, int buflen);

/* /phone/signal, /phone/status, /phone/calls */
int	phonebridge_signal(void);
int	phonebridge_status(char *buf, int buflen);
int	phonebridge_calls(char *buf, int buflen);

#ifdef __cplusplus
}
#endif

#endif
