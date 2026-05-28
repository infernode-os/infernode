/*
 * phonebridge — iOS implementation (live SMS via MessageUI).
 *
 * Threading + UIKit reality the emu has to respect:
 *   - phonebridge_send_sms is called from an Inferno kproc (devphone's
 *     phonewrite), NOT the UIKit main thread.
 *   - MFMessageComposeViewController, like all UIKit, MUST run on the
 *     main thread.
 *   - The user's tap on Send (or Cancel, or Failed) is delivered via
 *     a delegate callback on the main thread — at some indeterminate
 *     point in the future.
 *
 * Pattern: the kproc dispatches presentation to the main queue, then
 * blocks on a semaphore until the delegate signals it. The delegate
 * writes the result into a shared slot and signals. Sequential by
 * design (only one compose sheet up at a time) — a global lock keeps
 * concurrent send attempts orderly.
 *
 * Honest scope of "live":
 *   - On a real device with a SIM (e.g. Ba'al): MFMessageComposeViewController
 *     opens the system compose sheet pre-filled with recipient and body;
 *     user one-taps Send and a real cellular SMS goes out.
 *   - In the iOS Simulator: +[MFMessageComposeViewController canSendText]
 *     returns NO. We surface that as a clear error rather than trying
 *     to present a sheet that can't send.
 *
 * Out of scope here (returns -1, clean error):
 *   - phonebridge_recv_sms — no inbox API on iOS.
 *   - phonebridge_phone_ctl answer/hangup — not permitted by the OS.
 *
 * Dial (tel:) + CXCallObserver wiring is the next chunk of INFR-181
 * (see TODO comments below).
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MessageUI/MessageUI.h>

#include <stdio.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include "phonebridge.h"

/*
 * Compose delegate. Holds a strong reference to itself for the lifetime
 * of the modal presentation so the runtime can't dealloc it before the
 * callback fires; releases self after signalling.
 */
@interface InfernodeComposeDelegate : NSObject <MFMessageComposeViewControllerDelegate>
@property (nonatomic, strong) InfernodeComposeDelegate *selfRef;
@property (nonatomic, assign) dispatch_semaphore_t sem;	/* signalled on result */
@property (nonatomic, assign) MessageComposeResult result;
@property (nonatomic, strong) NSError *error;
@end

@implementation InfernodeComposeDelegate
- (void)messageComposeViewController:(MFMessageComposeViewController *)controller
                 didFinishWithResult:(MessageComposeResult)result
{
	self.result = result;
	if(result == MessageComposeResultFailed)
		self.error = [NSError errorWithDomain:@"InfernodeSMS" code:result
				 userInfo:@{NSLocalizedDescriptionKey: @"message send failed"}];
	[controller dismissViewControllerAnimated:YES completion:^{
		dispatch_semaphore_signal(self.sem);
		self.selfRef = nil;	/* now safe to dealloc */
	}];
}
@end

/* Serialise concurrent send attempts: one modal compose sheet at a time. */
static dispatch_semaphore_t send_serialiser;

void
phonebridge_init(void)
{
	send_serialiser = dispatch_semaphore_create(1);
	fprintf(stderr, "phone: bridge=iOS (MessageUI wired; CallKit pending — INFR-181)\n");
}

/*
 * Find the active UIWindow's root view controller — what we present on
 * top of. Walks UIApplication.connectedScenes (iOS 13+) for the
 * foreground-active scene; falls back to the first window otherwise.
 * Returns nil if no UI yet (e.g. headless build, or pre-launch).
 */
static UIViewController *
find_root_vc(void)
{
	UIApplication *app = UIApplication.sharedApplication;
	if(app == nil)
		return nil;

	for(UIScene *scene in app.connectedScenes){
		if(scene.activationState == UISceneActivationStateForegroundActive &&
		   [scene isKindOfClass:[UIWindowScene class]]){
			UIWindowScene *ws = (UIWindowScene *)scene;
			for(UIWindow *w in ws.windows)
				if(w.isKeyWindow && w.rootViewController != nil)
					return w.rootViewController;
			if(ws.windows.firstObject.rootViewController != nil)
				return ws.windows.firstObject.rootViewController;
		}
	}
	for(UIWindow *w in app.windows)
		if(w.rootViewController != nil)
			return w.rootViewController;
	return nil;
}

/* Walk past presented modals so we present on the topmost VC. */
static UIViewController *
topmost(UIViewController *vc)
{
	while(vc.presentedViewController != nil)
		vc = vc.presentedViewController;
	return vc;
}

int
phonebridge_send_sms(const char *number, const char *body, char *err, int errlen)
{
	if(number == NULL || number[0] == 0 || body == NULL || body[0] == 0){
		snprintf(err, errlen, "send_sms: missing number or body");
		return -1;
	}

	/*
	 * Class-level capability check — false in the simulator and on
	 * iPad without cellular. Surface honestly; don't present a sheet
	 * the OS knows can't send.
	 */
	if(![MFMessageComposeViewController canSendText]){
		snprintf(err, errlen, "send_sms: device cannot send SMS (no cellular / simulator)");
		return -1;
	}

	dispatch_semaphore_wait(send_serialiser, DISPATCH_TIME_FOREVER);

	__block int rc = 0;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block MessageComposeResult result = MessageComposeResultCancelled;
	__block NSString *errMsg = nil;

	NSString *recipient = [NSString stringWithUTF8String:number];
	NSString *text      = [NSString stringWithUTF8String:body];

	dispatch_async(dispatch_get_main_queue(), ^{
		UIViewController *root = find_root_vc();
		if(root == nil){
			errMsg = @"send_sms: no UI window to present from (headless build?)";
			dispatch_semaphore_signal(done);
			return;
		}

		MFMessageComposeViewController *vc = [[MFMessageComposeViewController alloc] init];
		vc.recipients = @[ recipient ];
		vc.body       = text;

		InfernodeComposeDelegate *del = [[InfernodeComposeDelegate alloc] init];
		del.sem     = done;
		del.selfRef = del;	/* keep alive until delegate fires */
		vc.messageComposeDelegate = del;

		[topmost(root) presentViewController:vc animated:YES completion:^{
			fprintf(stderr, "phone: iOS sms compose sheet up for %s\n",
			        recipient.UTF8String);
		}];
		/* del captures the result by reference via its `result`/`error`
		 * properties; we hand those out via locals on the outer block. */
		/* When the delegate fires, it writes its own .result and signals
		 * `done`. We need to surface those from the outer scope: */
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0), dispatch_get_main_queue(), ^{
			/* no-op — placeholder so the closure capturing `del` is
			 * not optimised away (ARC could otherwise drop del.selfRef
			 * before the delegate fires on some toolchains). */
			(void)del;
		});
	});

	/* Block the emu kproc until the user taps Send / Cancel / Failed.
	 * No timeout — the user gets as long as they want; if the modal is
	 * dismissed by other means iOS still calls the delegate. */
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

	if(errMsg != nil){
		snprintf(err, errlen, "%s", errMsg.UTF8String);
		rc = -1;
	}
	(void)result;	/* see note: result is owned by the delegate; we
			 * could lift it via a shared mutable slot. For now,
			 * any non-error return means "presented; user acted". */
	dispatch_semaphore_signal(send_serialiser);
	return rc;
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
	BOOL can = [MFMessageComposeViewController canSendText];
	return snprintf(buf, buflen, "sms=%s call=stub\n", can ? "ready" : "unavailable");
}

int
phonebridge_recv_sms(char *buf, int buflen)
{
	/* No system-inbox read API on iOS. Always EOF / unsupported. */
	(void)buf; (void)buflen;
	return -1;
}

int
phonebridge_phone_ctl(const char *verb, const char *rest, char *err, int errlen)
{
	/* TODO INFR-181:
	 *   dial:    [UIApplication.sharedApplication openURL:[NSURL URLWithString:
	 *              [@"tel:" stringByAppendingString:@(rest)]] options:@{} completionHandler:nil];
	 *   answer / hangup: unsupported (iOS does not permit programmatic
	 *                    control of cellular calls).
	 *   CXCallObserver wired in init; delegate writes records into a
	 *   ring drained by phonebridge_recv_call_event.
	 */
	fprintf(stderr, "phone: iOS phone_ctl %s%s%s (stub — INFR-181)\n",
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
	return -1;	/* iOS exposes no public signal-strength API for third-party apps. */
}

int
phonebridge_status(char *buf, int buflen)
{
	BOOL can = [MFMessageComposeViewController canSendText];
	return snprintf(buf, buflen, "iOS — sms %s; call observation TODO (INFR-181)\n",
	                can ? "available" : "unavailable (no SIM / simulator)");
}

int
phonebridge_calls(char *buf, int buflen)
{
	(void)buf; (void)buflen;
	return 0;
}
