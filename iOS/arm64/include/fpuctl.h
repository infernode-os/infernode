/*
 * iOS arm64 — fpu control. Identical to macOS arm64 (same FPCR/fenv
 * abstraction). Forward to the macOS header; fork only on divergence.
 */
#include "../../../MacOSX/arm64/include/fpuctl.h"
