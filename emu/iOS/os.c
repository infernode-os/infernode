/*
 * iOS host OS glue. iOS shares macOS's BSD-derived libc, so Phase A
 * reuses the macOS implementation unchanged (single source of truth;
 * see emu/iOS/README.md). Fork into a real file here in Phase B when
 * iOS needs to diverge. The :N: rule in mkfile-g tracks the dependency.
 */
#include "../MacOSX/os.c"
