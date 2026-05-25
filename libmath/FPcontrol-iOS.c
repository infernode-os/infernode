/*
 * iOS FP control. iOS shares macOS's arm64 fpuctl.h (setfsr/getfcr/...),
 * so the macOS FPcontrol implementation applies verbatim. Forward to it
 * rather than copy ~60 lines that would silently drift; fork into a real
 * file here only if iOS ever needs to diverge (hellaphone Phase 2).
 */
#include "FPcontrol-MacOSX.c"
