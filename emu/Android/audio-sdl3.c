/*
 * Android audio backend (INFR-188). Same SDL3 implementation as macOS
 * and iOS — one source of truth at emu/MacOSX/audio-sdl3.c, forwarded
 * here. SDL3 on Android drives AAudio (or OpenSL ES on older devices)
 * internally, so we don't need a separate AAudio backend any more.
 *
 * Unlike iOS we don't define AUDIO_PLATFORM_INIT_EXTERN — Android's
 * audio session is configured at the SDL3 level when the audio device
 * is opened. Mic permission (RECORD_AUDIO) is requested at the APK
 * level (android-app manifest); no run-time C-side hook needed.
 */
#include "../MacOSX/audio-sdl3.c"
