/*
 * audiosession.m — configure AVAudioSession for the InferNode voice
 * stack (INFR-186). Called once from audio-sdl3.c's ensure_sdl_audio
 * before SDL_InitSubSystem(SDL_INIT_AUDIO).
 *
 * Required category/mode for what we actually do (mic capture + speaker
 * playback + hardware AEC):
 *
 *   category .playAndRecord    — without this, .soloAmbient (the
 *                                default) silently makes capture
 *                                return zero samples on device.
 *   mode .voiceChat            — turns on Apple's voice-processing IO
 *                                unit. Hardware AEC + noise suppression
 *                                + voice-isolation in one switch. This
 *                                is the difference between two phones
 *                                in the same room having a normal
 *                                conversation and the v0 "Forbidden
 *                                Planet" feedback loop.
 *   .defaultToSpeaker          — route playback to the loudspeaker by
 *                                default (otherwise it goes to the
 *                                ear-piece, which is the right call
 *                                for a phone-up-to-the-ear UX but
 *                                wrong for handset-on-table testing).
 *   .allowBluetooth            — let bluetooth headsets be used.
 *
 * If anything fails we log and continue: SDL will still try to open
 * the device with whatever session config exists; .playAndRecord
 * without .voiceChat is at least audible (no AEC, but no silence).
 *
 * Threading + permissions (INFR-190): the /dev/audio open path that
 * reaches here runs on an Inferno kproc — a *background* pthread, not
 * the UIKit main thread. Two iOS rules bite us there:
 *
 *   1. AVAudioSession configuration/activation must be marshalled to
 *      the main thread; configuring it from an arbitrary background
 *      thread is unsupported and was a contributor to the crash.
 *   2. The microphone permission prompt is only presented by iOS when
 *      the app is foregrounded/active and the request is issued from
 *      the main thread. Requesting it from a background context never
 *      shows the prompt (and historically crashed). We therefore
 *      foreground-gate the request and skip it entirely when the app
 *      is not active, logging that the prompt will be retried on the
 *      next foreground.
 *
 * The companion entry point audio_request_record_permission_foreground()
 * primes the prompt from a genuine foreground context (app-active /
 * foreground tap); wire it into an app-delegate's
 * applicationDidBecomeActive: / SceneDelegate's sceneDidBecomeActive:
 * where one exists.
 */
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#include <stdio.h>

/*
 * Run a block on the UIKit main thread. If we're already on the main
 * thread, run it inline (a dispatch_sync onto our own queue would
 * deadlock). Otherwise dispatch_async: we deliberately do NOT
 * dispatch_sync from a background thread, because the calling Inferno
 * kproc may be holding a QLock (e.g. inlock/outlock in audio-sdl3.c's
 * audio_file_open) that main-thread UIKit work could end up waiting on,
 * which would deadlock. The recording-open path tolerates the session
 * not being active yet: SDL's capture device simply returns silence
 * until activation lands on the main queue a moment later. Output
 * (playback) is likewise unaffected — the worst case is a brief startup
 * gap, never a hang or crash.
 */
static void
run_on_main(void (^block)(void))
{
	if ([NSThread isMainThread])
		block();
	else
		dispatch_async(dispatch_get_main_queue(), block);
}

/*
 * Request microphone record permission. MUST be called on the main
 * thread and only when the app is active (callers guarantee both).
 * Uses the iOS 17+ AVAudioApplication API when available, falling back
 * to the deprecated AVAudioSession API on older systems. Idempotent:
 * iOS only shows the prompt the first time; once the status is
 * determined the completion handler fires immediately with the stored
 * answer and no UI appears.
 */
static void
request_record_permission_main(void)
{
	if (@available(iOS 17.0, *)) {
		[AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted){
			if (!granted)
				fprintf(stderr, "audiosession: microphone permission denied\n");
		}];
	} else {
		[[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted){
			if (!granted)
				fprintf(stderr, "audiosession: microphone permission denied\n");
		}];
	}
}

/*
 * Foreground-gated record-permission primer, exported for app-delegate
 * hooks (applicationDidBecomeActive:/sceneDidBecomeActive:). Safe to
 * call from any thread: it marshals onto the main thread and checks the
 * application state there. Idempotent — does nothing user-visible once
 * the permission is already determined.
 */
void
audio_request_record_permission_foreground(void)
{
	run_on_main(^{
		if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
			request_record_permission_main();
		} else {
			fprintf(stderr, "audiosession: not foreground/active; "
				"deferring microphone permission prompt to next foreground\n");
		}
	});
}

void
audio_platform_init(void)
{
	static int configured = 0;
	if (configured)
		return;
	configured = 1;

	/*
	 * Marshal the whole session configure/activate (and the
	 * foreground-gated permission request) onto the UIKit main thread.
	 * See run_on_main() for why this is dispatch_async, not _sync.
	 */
	run_on_main(^{
		AVAudioSession *session = [AVAudioSession sharedInstance];
		NSError *err = nil;

		BOOL ok = [session setCategory:AVAudioSessionCategoryPlayAndRecord
					mode:AVAudioSessionModeVoiceChat
					options:(AVAudioSessionCategoryOptionDefaultToSpeaker |
					         AVAudioSessionCategoryOptionAllowBluetooth)
					error:&err];
		if (!ok) {
			fprintf(stderr, "audiosession: setCategory failed: %s\n",
				err ? [[err localizedDescription] UTF8String] : "(nil)");
		}

		err = nil;
		ok = [session setActive:YES error:&err];
		if (!ok) {
			fprintf(stderr, "audiosession: setActive failed: %s\n",
				err ? [[err localizedDescription] UTF8String] : "(nil)");
		}

		/*
		 * Only request mic permission from a foreground/active state.
		 * The audio open frequently arrives from a background kproc
		 * (voice/dial), in which case the prompt cannot be presented —
		 * requesting it there shows nothing and historically crashed.
		 * Configure/activate the session regardless (so playback still
		 * works), but defer the prompt to the next foreground, where
		 * audio_request_record_permission_foreground() (app-active hook)
		 * picks it up.
		 */
		if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
			request_record_permission_main();
		} else {
			fprintf(stderr, "audiosession: audio opened from background; "
				"microphone prompt will be requested on next foreground\n");
		}
	});
}
