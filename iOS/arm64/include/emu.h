/*
 * iOS arm64 — emu machine-specific declarations (FPU save/restore,
 * `up`, osjmpbuf). Identical to macOS arm64. Forward to the macOS
 * header; fork only on divergence.
 */
#include "../../../MacOSX/arm64/include/emu.h"
