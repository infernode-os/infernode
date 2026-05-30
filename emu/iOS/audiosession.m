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
 */
#import <AVFoundation/AVFoundation.h>

#include <stdio.h>

void
audio_platform_init(void)
{
	static int configured = 0;
	if (configured)
		return;
	configured = 1;

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
}
