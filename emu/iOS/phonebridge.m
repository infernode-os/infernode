/*
 * phonebridge — iOS implementation.
 *
 * Connects devphone to the iOS-side telephony/SMS APIs:
 *
 *   send_sms     → MFMessageComposeViewController (assisted compose —
 *                  the only way iOS lets an app send an SMS; user one-
 *                  taps Send and a real cellular SMS goes out)
 *   recv_sms     → unsupported (iOS gives no READ_SMS equivalent;
 *                  always returns -1 / "unsupported on iOS")
 *   dial         → UIApplication openURL: tel:<num> (system shows the
 *                  call-confirmation UI; user authorises)
 *   call events  → CXCallObserver (connected / disconnected events
 *                  observable with no entitlement)
 *
 * This file is the integration *seam*: today it's a logging stub so the
 * devphone framework + Veltro tools land working end-to-end. The real
 * UIKit wiring (find SDL root VC, present compose sheet on the main
 * thread, marshal user-tap result back to the emu thread) is the
 * focused follow-on task — see the INFR-151/150 follow-up tickets.
 *
 * NOTE: this is compiled as Objective-C (.m) so the bridge can call
 * MessageUI / UIKit / CallKit when wired. Today it has no Obj-C imports
 * to keep the simulator build trivial; uncomment the framework imports
 * and the dispatch_async block when implementing the real send path.
 */

#include <stdio.h>
#include <string.h>
#include "phonebridge.h"

/* TODO when wiring the real bridge:
 * #import <UIKit/UIKit.h>
 * #import <MessageUI/MessageUI.h>
 * #import <CallKit/CallKit.h>
 */

void
phonebridge_init(void)
{
	fprintf(stderr, "phone: bridge=iOS-stub (MessageUI/CallKit not yet wired)\n");
}

int
phonebridge_ctl(const char *verb, const char *rest, char *err, int errlen)
{
	fprintf(stderr, "phone: iOS ctl %s%s%s (stub)\n",
		verb ? verb : "", rest ? " " : "", rest ? rest : "");
	(void)err; (void)errlen;
	return 0;
}

int
phonebridge_ctl_status(char *buf, int buflen)
{
	/* When the real bridge lands, report on/off based on radio state. */
	return snprintf(buf, buflen, "on\n");
}

int
phonebridge_send_sms(const char *number, const char *body, char *err, int errlen)
{
	/*
	 * Real impl outline (must be on the main thread; UIKit APIs):
	 *
	 *   dispatch_async(dispatch_get_main_queue(), ^{
	 *     if(![MFMessageComposeViewController canSendText]) { … err }
	 *     MFMessageComposeViewController *vc = [MFMessageComposeViewController new];
	 *     vc.recipients = @[ @(number) ];
	 *     vc.body       = @(body);
	 *     vc.messageComposeDelegate = sharedDelegate;
	 *     UIViewController *root = … (find SDL window's rootViewController)
	 *     [root presentViewController:vc animated:YES completion:nil];
	 *   });
	 *
	 * User tap-Send: delegate gets MessageComposeResultSent; we signal
	 * back to the waiting emu thread. For now we just log and succeed
	 * so the namespace + tool wrappers can be exercised in the sim.
	 */
	fprintf(stderr, "phone: iOS send_sms to=%s body=%s (stub — would open compose sheet)\n",
		number ? number : "(nil)", body ? body : "(nil)");
	(void)err; (void)errlen;
	return 0;
}

int
phonebridge_recv_sms(char *buf, int buflen)
{
	/* iOS has no system-inbox read API. The msg9p sms MsgSrc reading
	 * /phone/sms will simply never see incoming records on iOS — which
	 * is the correct platform behaviour. */
	(void)buf; (void)buflen;
	return -1;
}

int
phonebridge_phone_ctl(const char *verb, const char *rest, char *err, int errlen)
{
	/*
	 * Real impl outline:
	 *   dial:    [UIApplication.sharedApplication openURL:[NSURL URLWithString:
	 *              [@"tel:" stringByAppendingString:@(rest)]] options:@{} completionHandler:nil];
	 *   answer:  unsupported (iOS does not allow programmatic answer of cellular calls)
	 *   hangup:  unsupported (same)
	 *
	 * State observation comes from CXCallObserver — set up in init,
	 * delegate writes call-event records into a ring that
	 * phonebridge_recv_call_event drains.
	 */
	fprintf(stderr, "phone: iOS phone_ctl %s%s%s (stub)\n",
		verb ? verb : "", rest ? " " : "", rest ? rest : "");
	if(verb && (strcmp(verb, "answer") == 0 || strcmp(verb, "hangup") == 0)){
		snprintf(err, errlen, "iOS: programmatic %s of cellular calls is not permitted", verb);
		return -1;
	}
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
	/* iOS exposes no public signal-strength API for third-party apps. */
	return -1;
}

int
phonebridge_status(char *buf, int buflen)
{
	return snprintf(buf, buflen, "iOS — registration unknown (no public API)\n");
}

int
phonebridge_calls(char *buf, int buflen)
{
	(void)buf; (void)buflen;
	return 0;
}
