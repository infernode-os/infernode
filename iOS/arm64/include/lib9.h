/*
 * iOS arm64 — lib9 definitions.
 *
 * iOS ships Apple's BSD-derived libc, identical to macOS for everything
 * lib9 cares about (types, ABI, endianness, the host-conflict renames).
 * Rather than duplicate the 400-line macOS header and let the two drift,
 * forward to it. Fork into a real file here only if iOS ever needs to
 * diverge (hellaphone Phase 2; see emu/iOS/README.md).
 */
#include "../../../MacOSX/arm64/include/lib9.h"
