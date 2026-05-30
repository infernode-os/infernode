/*
 * iOS audio backend (INFR-186). Same SDL3 implementation as macOS — just
 * tell the included source to expect an external audio_platform_init()
 * symbol (provided by emu/iOS/audiosession.m, which configures
 * AVAudioSession with .playAndRecord + .voiceChat for AEC).
 */
#define AUDIO_PLATFORM_INIT_EXTERN
#include "../MacOSX/audio-sdl3.c"
