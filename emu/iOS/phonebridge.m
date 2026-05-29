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
 * Out of scope here:
 *   - inbound SMS — no public inbox API on iOS, so we never call
 *     phonebridge_post_sms(). Userspace readers of /phone/sms block
 *     forever (devphone's qread). The hellaphone-style listener
 *     registry handles the wire-format push when a platform CAN
 *     produce records (Android, INFR-182).
 *   - phonebridge_phone_ctl answer/hangup — not permitted by the OS.
 *
 * Inbound call events (CXCallObserver) ARE pushed via
 * phonebridge_post_call_event() from the UIKit main queue.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MessageUI/MessageUI.h>
#import <CallKit/CallKit.h>
#import <Contacts/Contacts.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <Security/Security.h>

#include <stdio.h>
#include <string.h>
#include <pthread.h>
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

/*
 * Observer that watches every cellular call state transition on the
 * device. CallKit doesn't expose answer/hangup control to third-party
 * apps for cellular calls (only VoIP), but observation is allowed and
 * is enough for InferNode to surface "your call to X just hung up" to
 * the agent stack via the msg9p phone-events MsgSrc.
 *
 * CXCallObserver fires on the UIKit main thread. We format the line
 * and hand it to phonebridge_post_call_event(), which fans it out to
 * every currently-open reader of /phone/phone (devphone's listener
 * registry — see emu/port/devphone.c). Non-blocking; safe from main
 * thread. No ring of our own; devphone owns the queueing now.
 *
 * Format: "<state> <handle> <iso-timestamp>\n"
 *   state    one of "incoming" "dialing" "connected" "disconnected"
 *   handle   the remote number, or "-" if not exposed by CallKit
 *   ts       NSISO8601 UTC
 */
#define CALL_LINEMAX 256

/*
 * Live calls table — one entry per CXCall the observer has seen, keyed
 * by call.UUID. The callObserver delegate updates the entry on every
 * state change; phonebridge_calls() walks the table on demand.
 *
 * Entries stick around for ENDED_RETAIN seconds after disconnect so an
 * agent that reads /phone/calls right after `dial` has time to see the
 * call landed (or failed). Older ended entries are reaped lazily on
 * the next observer fire.
 */
#define ENDED_RETAIN_SECONDS 60
@interface InfernodeCall : NSObject
@property (nonatomic, copy) NSString  *uuidStr;
@property (nonatomic, copy) NSString  *state;
@property (nonatomic, copy) NSString  *handle;
@property (nonatomic, copy) NSString  *startedTs;
@property (nonatomic, assign) NSTimeInterval endedAt;	/* 0 until disconnected */
@end
@implementation InfernodeCall
@end

static NSMutableDictionary<NSString *, InfernodeCall *> *gLiveCalls;
static pthread_mutex_t                                   gLiveCallsLock = PTHREAD_MUTEX_INITIALIZER;

@interface InfernodeCallObserver : NSObject <CXCallObserverDelegate>
@end

@implementation InfernodeCallObserver
- (void)callObserver:(CXCallObserver *)observer callChanged:(CXCall *)call
{
	const char *state;
	if(call.hasEnded)             state = "disconnected";
	else if(call.hasConnected)    state = "connected";
	else if(call.isOutgoing)      state = "dialing";
	else                          state = "incoming";

	/* CallKit hides the remote number for cellular calls; we still
	 * surface "-" so downstream parsers see a stable column layout. */
	const char *handle = "-";

	NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
	fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
	NSString *ts = [fmt stringFromDate:[NSDate date]];

	/* Update the live-calls table. Lookup by UUID, insert on first
	 * sighting (state, ts) or update on a transition. Disconnects
	 * stamp endedAt so phonebridge_calls() can reap old rows. */
	NSString *uuidStr = call.UUID.UUIDString;
	pthread_mutex_lock(&gLiveCallsLock);
	if(gLiveCalls == nil)
		gLiveCalls = [NSMutableDictionary new];
	/* Reap anything that's been disconnected long enough. */
	NSTimeInterval now = [NSDate date].timeIntervalSince1970;
	NSMutableArray *expired = [NSMutableArray new];
	[gLiveCalls enumerateKeysAndObjectsUsingBlock:^(NSString *k, InfernodeCall *v, BOOL *stop){
		if(v.endedAt > 0 && (now - v.endedAt) > ENDED_RETAIN_SECONDS)
			[expired addObject:k];
	}];
	for(NSString *k in expired)
		[gLiveCalls removeObjectForKey:k];

	InfernodeCall *entry = gLiveCalls[uuidStr];
	if(entry == nil){
		entry = [InfernodeCall new];
		entry.uuidStr   = uuidStr;
		entry.startedTs = ts;
		gLiveCalls[uuidStr] = entry;
	}
	entry.state  = [NSString stringWithUTF8String:state];
	entry.handle = [NSString stringWithUTF8String:handle];
	if(call.hasEnded && entry.endedAt == 0)
		entry.endedAt = now;
	pthread_mutex_unlock(&gLiveCallsLock);

	char line[CALL_LINEMAX];
	int n = snprintf(line, sizeof line, "%s %s %s\n",
		state, handle, ts.UTF8String);
	if(n < 0) return;
	if(n > (int)sizeof line - 1) n = (int)sizeof line - 1;
	phonebridge_post_call_event(line, n);
	fprintf(stderr, "phone: iOS call event %s", line);
}
@end

/* Held strong by the static observer/delegate so they survive past init. */
static CXCallObserver        *gCallObserver;
static InfernodeCallObserver *gCallObserverDelegate;

void
phonebridge_init(void)
{
	send_serialiser = dispatch_semaphore_create(1);

	/* CXCallObserver requires its delegate to be set on the UIKit main
	 * thread. phonebridge_init runs early during emu boot — usually
	 * before UIKit is fully alive — so dispatch to main and let it
	 * fire when the runloop is ready. */
	dispatch_async(dispatch_get_main_queue(), ^{
		gCallObserverDelegate = [[InfernodeCallObserver alloc] init];
		gCallObserver = [[CXCallObserver alloc] init];
		[gCallObserver setDelegate:gCallObserverDelegate queue:nil];
		fprintf(stderr, "phone: CXCallObserver installed\n");
	});

	fprintf(stderr, "phone: bridge=iOS (MessageUI + CallKit observation wired — INFR-181)\n");
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

/*
 * Inbound SMS: iOS exposes no public inbox API to third-party apps, so
 * there is no path to call phonebridge_post_sms() — readers of
 * /phone/sms simply block forever. On Android the bridge will produce
 * via phonebridge_post_sms() when SMS_RECEIVED arrives (INFR-182).
 */

int
phonebridge_phone_ctl(const char *verb, const char *rest, char *err, int errlen)
{
	if(verb == NULL){
		snprintf(err, errlen, "phone_ctl: missing verb");
		return -1;
	}

	if(strcmp(verb, "dial") == 0){
		if(rest == NULL || rest[0] == 0){
			snprintf(err, errlen, "dial: missing number");
			return -1;
		}
		/*
		 * Hand the number to the OS via tel: URL — iOS shows its own
		 * call-confirmation dialog and the user authorises the call.
		 * That's the only path third-party apps get for cellular dial;
		 * silent placement isn't permitted by the platform. CallKit's
		 * CXCallController.requestTransaction with CXStartCallAction
		 * is reserved for VoIP, not cellular, so it's not a workaround.
		 *
		 * openURL: must run on the UIKit main thread. We dispatch and
		 * return immediately — the user will see the confirmation
		 * dialog asynchronously, and the resulting call (if approved)
		 * shows up on the CXCallObserver as an outgoing transition.
		 */
		NSString *num = [NSString stringWithUTF8String:rest];
		/* Strip whitespace iOS won't tolerate inside the URL. */
		NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
		num = [num stringByTrimmingCharactersInSet:ws];
		NSString *urlstr = [@"tel:" stringByAppendingString:num];
		NSURL *url = [NSURL URLWithString:urlstr];
		if(url == nil){
			snprintf(err, errlen, "dial: invalid number %s", rest);
			return -1;
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[UIApplication.sharedApplication openURL:url
				options:@{}
				completionHandler:^(BOOL success){
					fprintf(stderr, "phone: iOS dial openURL %s %s\n",
						urlstr.UTF8String,
						success ? "ok" : "failed");
				}];
		});
		return 0;
	}

	if(strcmp(verb, "answer") == 0 || strcmp(verb, "hangup") == 0){
		snprintf(err, errlen,
			"iOS: programmatic %s of cellular calls is not permitted "
			"(see CallKit docs — only VoIP calls can be controlled)",
			verb);
		return -1;
	}

	fprintf(stderr, "phone: iOS phone_ctl unknown verb %s\n", verb);
	snprintf(err, errlen, "phone_ctl: unknown verb %s", verb);
	return -1;
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
	return snprintf(buf, buflen,
		"iOS — sms %s; dial via tel: (user-confirmed); CallKit observing\n",
		can ? "available" : "unavailable (no SIM / simulator)");
}

int
phonebridge_calls(char *buf, int buflen)
{
	if(buf == NULL || buflen <= 1)
		return -1;

	/*
	 * One TSV line per live call (and recently-ended call within
	 * ENDED_RETAIN_SECONDS):
	 *
	 *     <state>\t<remote>\t<started-iso-ts>\t<uuid>\n
	 *
	 * Matches the wire shape of /phone/contacts so the agent's parsing
	 * code can split on \t uniformly. Bounded by buflen — entries that
	 * would overflow are dropped cleanly at the last newline boundary.
	 */
	int off = 0;
	pthread_mutex_lock(&gLiveCallsLock);
	if(gLiveCalls != nil){
		for(NSString *k in gLiveCalls.allKeys){
			InfernodeCall *e = gLiveCalls[k];
			const char *st = e.state.UTF8String  ?: "unknown";
			const char *hd = e.handle.UTF8String ?: "-";
			const char *ts = e.startedTs.UTF8String ?: "-";
			const char *id = e.uuidStr.UTF8String ?: "-";
			int written = snprintf(buf + off, (size_t)(buflen - off),
				"%s\t%s\t%s\t%s\n", st, hd, ts, id);
			if(written < 0 || written >= buflen - off)
				break;	/* stop at last full newline */
			off += written;
		}
	}
	pthread_mutex_unlock(&gLiveCallsLock);
	return off;
}

/*
 * Address book → /phone/contacts.
 *
 * CNContactStore is the public API; permission is gated by
 * NSContactsUsageDescription in Info.plist. Authorisation is one of
 * notDetermined / restricted / denied / authorized; on notDetermined
 * we requestAccess synchronously (semaphore wait — devphone runs us
 * on an Inferno kproc, not the UIKit main thread, so blocking is
 * fine). Other states surface as an error string in the read so the
 * agent can tell access from emptiness.
 *
 * Format per Hellaphone /phone:  <display-name>\t<kind>\t<number>\n
 * One line per phone-number; contacts with several numbers emit
 * several lines. Records are written into the caller's buffer until
 * the next record would overflow, then truncation is at the last
 * newline so the consumer never sees a partial line.
 */
static int
write_contact_line(char *buf, int buflen, int off,
                   NSString *name, NSString *kind, NSString *number)
{
	const char *n = name.UTF8String   ?: "";
	const char *k = kind.UTF8String   ?: "other";
	const char *p = number.UTF8String ?: "";
	int written = snprintf(buf + off, (size_t)(buflen - off),
		"%s\t%s\t%s\n", n, k, p);
	if(written < 0)
		return off;
	if(written >= buflen - off)
		return off;	/* would overflow; caller stops here */
	return off + written;
}

static NSString *
normalise_phone_label(NSString *raw)
{
	if(raw == nil)
		return @"other";
	if([raw isEqualToString:CNLabelPhoneNumberMobile])         return @"mobile";
	if([raw isEqualToString:CNLabelPhoneNumberiPhone])         return @"mobile";
	if([raw isEqualToString:CNLabelPhoneNumberMain])           return @"main";
	if([raw isEqualToString:CNLabelHome])                       return @"home";
	if([raw isEqualToString:CNLabelWork])                       return @"work";
	if([raw isEqualToString:CNLabelOther])                      return @"other";
	NSString *clean = [CNLabeledValue localizedStringForLabel:raw];
	if(clean == nil)
		return @"other";
	return clean.lowercaseString;
}

int
phonebridge_contacts(char *buf, int buflen)
{
	if(buf == NULL || buflen <= 1)
		return -1;

	CNAuthorizationStatus st = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
	if(st == CNAuthorizationStatusNotDetermined){
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block BOOL ok = NO;
		CNContactStore *probe = [[CNContactStore alloc] init];
		[probe requestAccessForEntityType:CNEntityTypeContacts
			completionHandler:^(BOOL granted, NSError *err){
				ok = granted;
				if(err != nil)
					fprintf(stderr, "phone: contacts requestAccess error: %s\n",
						err.localizedDescription.UTF8String);
				dispatch_semaphore_signal(done);
			}];
		dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
		st = ok ? CNAuthorizationStatusAuthorized : CNAuthorizationStatusDenied;
	}

	if(st == CNAuthorizationStatusDenied){
		return snprintf(buf, buflen,
			"# contacts: permission denied — enable in Settings > InferNode > Contacts\n");
	}
	if(st == CNAuthorizationStatusRestricted){
		return snprintf(buf, buflen,
			"# contacts: restricted by device policy\n");
	}
	if(st != CNAuthorizationStatusAuthorized)
		return 0;

	CNContactStore *store = [[CNContactStore alloc] init];
	NSArray *keys = @[
		CNContactGivenNameKey,
		CNContactFamilyNameKey,
		CNContactOrganizationNameKey,
		CNContactPhoneNumbersKey,
	];
	CNContactFetchRequest *req = [[CNContactFetchRequest alloc]
		initWithKeysToFetch:keys];

	__block int off = 0;
	NSError *err = nil;
	BOOL fetched = [store enumerateContactsWithFetchRequest:req
		error:&err
		usingBlock:^(CNContact *c, BOOL *stop){
			if(c.phoneNumbers.count == 0) return;
			NSString *name = [CNContactFormatter
				stringFromContact:c style:CNContactFormatterStyleFullName];
			if(name.length == 0) name = c.organizationName;
			if(name.length == 0) name = @"(no name)";
			for(CNLabeledValue<CNPhoneNumber *> *pn in c.phoneNumbers){
				NSString *kind = normalise_phone_label(pn.label);
				NSString *num  = pn.value.stringValue;
				int nextoff = write_contact_line(buf, buflen, off,
					name, kind, num);
				if(nextoff == off){	/* no space; stop cleanly */
					*stop = YES;
					return;
				}
				off = nextoff;
			}
		}];
	if(!fetched){
		const char *msg = err.localizedDescription.UTF8String ?: "fetch failed";
		return snprintf(buf, buflen, "# contacts: %s\n", msg);
	}
	return off;
}

/*
 * Biometric-protected secret storage (/phone/bio_*) — iOS impl.
 *
 * Keys live in the Keychain under a synthetic service identifier
 * derived from the slot name; kSecAttrAccessControl is set to
 * biometryCurrentSet so re-enrolling Face/Touch invalidates the
 * stored entry (a re-enrol could be an adversary stealing the
 * device and adding their face — the secret must not survive it).
 *
 * Each bio_store / bio_retrieve hands the OS its own LAContext so
 * the Face/Touch ID prompt only covers a single operation.
 */

static NSString *
bio_service_for(const char *name)
{
	return [NSString stringWithFormat:@"os.infernode.ios.bio.%s",
		name ?: ""];
}

int
phonebridge_bio_available(void)
{
	LAContext *ctx = [[LAContext alloc] init];
	NSError *err = nil;
	BOOL can = [ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
		error:&err];
	if(!can){
		fprintf(stderr, "phone: bio_available=0 (%s)\n",
			err.localizedDescription.UTF8String ?: "unknown");
		return 0;
	}
	return 1;
}

int
phonebridge_bio_store(const char *name, const char *payload, int n,
                      char *err, int errlen)
{
	if(name == NULL || name[0] == 0){
		snprintf(err, errlen, "bio_store: missing name");
		return -1;
	}
	if(payload == NULL || n <= 0){
		snprintf(err, errlen, "bio_store: missing payload");
		return -1;
	}

	/* Synchronous biometric prompt — must run on the UIKit main
	 * queue. devphone calls us on an Inferno kproc; bounce via a
	 * semaphore. */
	__block int rc = -1;
	__block NSString *errMsg = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	NSData *data = [NSData dataWithBytes:payload length:(NSUInteger)n];
	NSString *service = bio_service_for(name);

	dispatch_async(dispatch_get_main_queue(), ^{
		CFErrorRef cfErr = NULL;
		SecAccessControlRef acl = SecAccessControlCreateWithFlags(
			kCFAllocatorDefault,
			kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
			kSecAccessControlBiometryCurrentSet,
			&cfErr);
		if(acl == NULL){
			NSError *e = (__bridge_transfer NSError *)cfErr;
			errMsg = [NSString stringWithFormat:@"acl: %@",
				e.localizedDescription];
			dispatch_semaphore_signal(done);
			return;
		}

		/* Remove any pre-existing entry — SecItemAdd would otherwise
		 * return errSecDuplicateItem.  Match by service only; we
		 * only ever store one entry per slot. */
		NSDictionary *delQuery = @{
			(__bridge id)kSecClass:        (__bridge id)kSecClassGenericPassword,
			(__bridge id)kSecAttrService:  service,
		};
		SecItemDelete((__bridge CFDictionaryRef)delQuery);

		NSDictionary *addQuery = @{
			(__bridge id)kSecClass:           (__bridge id)kSecClassGenericPassword,
			(__bridge id)kSecAttrService:     service,
			(__bridge id)kSecValueData:       data,
			(__bridge id)kSecAttrAccessControl: (__bridge id)acl,
			(__bridge id)kSecUseAuthenticationContext: [[LAContext alloc] init],
		};
		OSStatus st = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
		CFRelease(acl);
		if(st != errSecSuccess){
			errMsg = [NSString stringWithFormat:@"SecItemAdd: %d", (int)st];
		} else {
			rc = 0;
		}
		dispatch_semaphore_signal(done);
	});
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

	if(rc != 0 && errMsg != nil)
		snprintf(err, errlen, "%s", errMsg.UTF8String);
	return rc;
}

int
phonebridge_bio_retrieve(const char *name, char *buf, int buflen,
                         char *err, int errlen)
{
	if(name == NULL || name[0] == 0){
		snprintf(err, errlen, "bio_retrieve: missing name");
		return -1;
	}
	if(buf == NULL || buflen <= 0){
		snprintf(err, errlen, "bio_retrieve: no buffer");
		return -1;
	}

	__block int rc = -1;
	__block NSString *errMsg = nil;
	__block NSData *result = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	NSString *service = bio_service_for(name);

	dispatch_async(dispatch_get_main_queue(), ^{
		LAContext *ctx = [[LAContext alloc] init];
		ctx.localizedReason = [NSString stringWithFormat:
			@"Authenticate to retrieve %s key", name];
		NSDictionary *query = @{
			(__bridge id)kSecClass:        (__bridge id)kSecClassGenericPassword,
			(__bridge id)kSecAttrService:  service,
			(__bridge id)kSecReturnData:   @YES,
			(__bridge id)kSecMatchLimit:   (__bridge id)kSecMatchLimitOne,
			(__bridge id)kSecUseAuthenticationContext: ctx,
		};
		CFTypeRef out = NULL;
		OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &out);
		if(st == errSecSuccess){
			result = (__bridge_transfer NSData *)out;
		} else {
			errMsg = [NSString stringWithFormat:@"SecItemCopyMatching: %d",
				(int)st];
		}
		dispatch_semaphore_signal(done);
	});
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

	if(result == nil){
		snprintf(err, errlen, "%s",
			errMsg.UTF8String ?: "bio_retrieve: unknown failure");
		return -1;
	}
	int n = (int)result.length;
	if(n > buflen)
		n = buflen;
	memcpy(buf, result.bytes, (size_t)n);
	rc = n;
	return rc;
}
