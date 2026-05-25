/*
 * iOS host-command device. Reuses the macOS implementation for Phase A
 * (single source of truth). Phase B forks this: the iOS app sandbox
 * forbids fork/exec of a host shell, so the exec path compiles out.
 */
#include "../MacOSX/cmd.c"
